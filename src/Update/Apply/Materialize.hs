{-# LANGUAGE OverloadedStrings #-}

-- | DepsAndAssets materialize: plan, distfile, reuse/full publish, step budgets.
module Update.Apply.Materialize
  ( applyDepsAndAssets,
    contentFixNeeded,
    goPublishAndOverlay,
    markSuccessLinesReused,
    materializePlan,
    fullPathMaterializeSteps,
    reusePathMaterializeSteps,
    materializeStepTotalUpper,
    reviseMaterializeStepTotal,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar (withMVar)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (nub, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version
  ( EbuildVersion (..),
    parseEbuildVersion,
    renderPV,
    renderPVNoRev,
    samePV,
  )
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
    removeFile,
  )
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Update.Apply.Commit (egencacheAndSignedCommit, pruneCommitMessage)
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.GitMv (requirePackageMd5Cache)
import Update.Apply.OverlayWrite (findTemplate, overlayAfterAssets)
import Update.Assets.Hash (FileDigests (..), hashFile, writeSidecars)
import Update.Assets.Layout
  ( SidecarPaths (..),
    commitMessage,
    distfileKindForEcosystem,
    distfileTarballName,
    releaseName,
    releaseTag,
    sidecarPaths,
  )
import Update.Assets.Release
  ( ReleaseMeta (..),
    ReleaseOps (..),
    lookupNamedAsset,
  )
import Update.Bun.Cache
  ( BunCacheProgress (..),
    buildBunDepsTarball,
  )
import Update.Cargo.Crates
  ( CargoProgress (..),
    CargoResult (..),
    buildCargoCratesTarball,
  )
import Update.Cargo.Msrv
  ( combineMsrv,
    parseRustMinVerFromEbuild,
    probeRustVersionFromCargoTomls,
  )
import Update.Check (PackageEntry (..))
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithProgress,
  )
import Update.EbuildEdit
  ( bunBdependAtom,
    ebuildFileNameWithRev,
    ebuildNeedsCargoContentFix,
    ebuildNeedsContentFix,
    ebuildNeedsContentFixAtom,
    goBdependAtom,
    manifestHasVendorDist,
    nodejsBdependAtom,
    writeVersionForPlannedPV,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Go.Lanes
  ( GapLine (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    buildGapLines,
    missingTargets,
    planNeedsWork,
  )
import Update.Go.ModFetch (GoModKey (..), parseGoReqFromMod)
import Update.Go.Plan
  ( PlanProgress (..),
    isLivePackageVersion,
  )
import Update.Go.Vendor
  ( VendorProgress (..),
    VendorResult (..),
    buildVendorTarball,
    versionTag,
  )
import Update.Npm.Cache
  ( NpmCacheProgress (..),
    buildNpmDepsTarball,
  )
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource (..),
    splitPackageKey,
  )

applyDepsAndAssets ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  IO [ApplyOutcome]
applyDepsAndAssets env overlayRoot entry src eco = do
  let key = peKey entry
      mh = aeMulti env
      pkgDir = takeDirectory (pePath entry)
  planDoneRef <- newIORef (0 :: Int)
  let progress = depsApplyPlanProgress mh key eco planDoneRef
  localPVs <- listLocalNonLivePVs pkgDir (pePN entry)
  planResult <-
    planDepsPackageWithProgress
      (aeDepsPlanOps env)
      progress
      eco
      src
      localPVs
  case planResult of
    Left err ->
      pure [ApplyHardFail key ("runtime-lane plan failed: " <> err) False False]
    Right plan -> do
      contentFix <- contentFixNeededEnv env eco src pkgDir (pePN entry) plan
      if not (planNeedsWork localPVs contentFix plan)
        then pure [ApplySoftSkip key "already matches runtime-lane plan"]
        else do
          cacheGate <- requirePackageMd5Cache overlayRoot key pkgDir
          case cacheGate of
            Left err -> pure [ApplyHardFail key err False False]
            Right () -> do
              planDone <- readIORef planDoneRef
              materializeDepsPlan
                env
                overlayRoot
                entry
                src
                eco
                plan
                localPVs
                contentFix
                planDone

-- | Planning progress during update apply (same 3-step model as outdated).
depsApplyPlanProgress ::
  MultiHandle -> PackageKey -> EcosystemSpec -> IORef Int -> PlanProgress
depsApplyPlanProgress mh key eco doneRef =
  let ceilLabel = case eco of
        Go _ -> "discovering go ceilings"
        NpmEco -> "discovering nodejs ceilings"
        Bun -> "discovering bun-bin ceilings"
        Cargo {} -> "discovering rust ceilings"
      probeLabel = case eco of
        Go _ -> "probing go.mod"
        NpmEco -> "probing engines.node"
        Bun -> "probing engines.bun"
        Cargo {} -> "probing rust-version"
   in PlanProgress
        { ppOnCeilingsStart = do
            mhSteps mh key 3
            mhStatus mh key ceilLabel,
          ppOnCeilingsDone = do
            atomicModifyIORef' doneRef (\n -> (n + 1, ()))
            mhStep mh key ceilLabel,
          ppOnListStart = mhStatus mh key "listing versions",
          ppOnListDone = \_n -> do
            atomicModifyIORef' doneRef (\d -> (d + 1, ()))
            mhStep mh key "listing versions",
          ppOnProbeDone = do
            atomicModifyIORef' doneRef (\n -> (n + 1, ()))
            mhStep mh key probeLabel
        }

listLocalNonLivePVs :: FilePath -> Text -> IO [EbuildVersion]
listLocalNonLivePVs pkgDir pn = do
  names <- listDirectory pkgDir
  let vers =
        [ parseEbuildVersion (T.pack verStr)
        | name <- names,
          Just (pkg, verStr) <- [parseEbuildFileName name],
          T.pack pkg == pn,
          let v = parseEbuildVersion (T.pack verStr),
          not (isLivePackageVersion v)
        ]
  pure vers

-- | Present planned PVs whose ebuild content, BDEPEND, or Manifest needs fix.
contentFixNeededEnv ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  FilePath ->
  Text ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixNeededEnv env eco src pkgDir pn plan =
  concat <$> mapM checkPlanned (glpEbuilds plan)
  where
    kind = distfileKindForEcosystem eco
    checkPlanned pe = do
      let name = ebuildFileNameWithRev pn (pePV pe)
          path = pkgDir </> name
          pvNoRev = renderPVNoRev (pePV pe)
          tarball = distfileTarballName kind pn pvNoRev
      exists <- doesFileExist path
      paths <-
        if exists
          then pure [path]
          else do
            names <- listDirectory pkgDir
            pure
              [ pkgDir </> n
              | n <- names,
                Just (pkg, verStr) <- [parseEbuildFileName n],
                T.pack pkg == pn,
                samePV (parseEbuildVersion (T.pack verStr)) (pePV pe)
              ]
      case paths of
        [] -> pure []
        (p : _) -> do
          content <- TIO.readFile p
          manMissing <- vendorManifestMissing pkgDir tarball
          bad <- case eco of
            Go mSub -> do
              mGoVer <- case src of
                GitHub owner repo prefix ->
                  fetchGoModVersion env owner repo prefix pvNoRev mSub
                _ -> pure Nothing
              pure $
                ebuildNeedsContentFix (peKeywords pe) content mGoVer || manMissing
            Cargo mLock mPkg -> do
              mMsrv <- fetchCargoMsrvForPV env src mLock mPkg pvNoRev content
              pure $
                ebuildNeedsCargoContentFix (peKeywords pe) content mMsrv || manMissing
            _ -> do
              mAtom <- fetchRequiredBdependAtom env eco src pvNoRev
              pure $
                ebuildNeedsContentFixAtom (peKeywords pe) content mAtom || manMissing
          pure [pePV pe | bad]

-- | Full required BDEPEND atom for a planned PV, when obtainable.
fetchRequiredBdependAtom ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  Text ->
  IO (Maybe Text)
fetchRequiredBdependAtom env eco src pvNoRev =
  case (eco, src) of
    (Go mSub, GitHub owner repo prefix) -> do
      mGo <- fetchGoModVersion env owner repo prefix pvNoRev mSub
      pure (goBdependAtom <$> mGo)
    (NpmEco, Npm npmPkg) -> do
      eres <- dpoFetchNpmEngines (aeDepsPlanOps env) npmPkg pvNoRev
      pure $ case eres of
        Right ver -> Just (nodejsBdependAtom ver)
        Left _ -> Nothing
    (Bun, GitHub owner repo prefix) -> do
      eres <-
        dpoFetchBunEngines (aeDepsPlanOps env) owner repo prefix pvNoRev
      pure $ case eres of
        Right ver -> Just (bunBdependAtom ver)
        Left _ -> Nothing
    (Cargo {}, _) -> pure Nothing
    _ -> pure Nothing

-- | Plan/content-fix MSRV: root Cargo.toml (+ donor when content provided).
fetchCargoMsrvForPV ::
  ApplyEnv ->
  UpdateSource ->
  Maybe FilePath ->
  Maybe FilePath ->
  Text ->
  Text ->
  IO (Maybe Text)
fetchCargoMsrvForPV env src mLock mPkg pvNoRev donorContent =
  case src of
    GitHub owner repo prefix -> do
      mRoot <-
        probeRustVersionFromCargoTomls mPkg mLock $ \mSub ->
          dpoFetchCargoToml (aeDepsPlanOps env) owner repo prefix pvNoRev mSub
      let mDonor = parseRustMinVerFromEbuild donorContent
      pure (combineMsrv mRoot Nothing mDonor)
    _ -> pure (parseRustMinVerFromEbuild donorContent)

-- | Legacy Go-only content fix (tests).
contentFixNeeded ::
  ApplyEnv ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  FilePath ->
  Text ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixNeeded env owner repo prefix mSub =
  contentFixNeededEnv env (Go mSub) (GitHub owner repo prefix)

-- | True when package Manifest lacks a DIST line for the vendor tarball.
vendorManifestMissing :: FilePath -> FilePath -> IO Bool
vendorManifestMissing pkgDir tarballName = do
  let manPath = pkgDir </> "Manifest"
  exists <- doesFileExist manPath
  if not exists
    then pure True
    else do
      manText <- TIO.readFile manPath
      pure (not (manifestHasVendorDist manText tarballName))

materializeDepsPlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  Int ->
  IO [ApplyOutcome]
materializeDepsPlan env overlayRoot entry src eco plan localPVs contentFix planDone = do
  let key = peKey entry
      mh = aeMulti env
      needPVs =
        nub
          ( missingTargets localPVs plan
              <> contentFix
          )
      planned = [pe | pe <- glpEbuilds plan, any (samePV (pePV pe)) needPVs]
      sortedPlanned =
        sortOn
          ( \pe ->
              case pePV pe of
                Numeric comps _ -> comps
                Raw _ -> []
          )
          planned
      nPVs = length sortedPlanned
  when (nPVs > 0) $
    mhSteps mh key (materializeStepTotalUpper planDone nPVs)
  stepsDoneRef <- newIORef planDone
  results <- materializeUntilFail stepsDoneRef sortedPlanned
  let failures = [o | o@ApplyHardFail {} <- results]
      successes = [o | o@ApplySuccess {} <- results]
  if not (null failures)
    then pure (successes <> failures)
    else do
      pruneResult <- pruneExtras env overlayRoot entry plan
      case pruneResult of
        Left err ->
          pure
            ( successes
                <> [ApplyHardFail key err True False]
            )
        Right extraPaths
          | null extraPaths ->
              pure $
                if null successes
                  then [ApplySoftSkip key "already matches runtime-lane plan"]
                  else successes
          | otherwise -> do
              committed <-
                egencacheAndSignedCommit
                  env
                  overlayRoot
                  key
                  extraPaths
                  (pruneCommitMessage key)
              pure $ case committed of
                Left err ->
                  successes <> [ApplyHardFail key err True False]
                Right paths
                  | null successes ->
                      let lines_ = gapSuccessLines localPVs needPVs plan
                       in [ApplySuccess key lines_ paths]
                  | otherwise -> successes
  where
    materializeUntilFail _ [] = pure []
    materializeUntilFail stepsDoneRef remaining@(pe : rest) = do
      r <-
        materializeOneDeps
          env
          overlayRoot
          entry
          src
          eco
          localPVs
          plan
          pe
          stepsDoneRef
          (length remaining)
      case r of
        ApplyHardFail {} -> pure [r]
        _ -> do
          more <- materializeUntilFail stepsDoneRef rest
          pure (r : more)

-- | Legacy Go-only entry used by tests.
materializePlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  Int ->
  IO [ApplyOutcome]
materializePlan env overlayRoot entry owner repo prefix mSub =
  materializeDepsPlan
    env
    overlayRoot
    entry
    (GitHub owner repo prefix)
    (Go mSub)

gapSuccessLines :: [EbuildVersion] -> [EbuildVersion] -> RuntimeLanePlan -> [SuccessLine]
gapSuccessLines localPVs needs plan =
  [ SuccessLine
      { slFrom = glFrom g,
        slTo = glTo g,
        slLabel = Just (glLabel g),
        slAssetsReused = False
      }
  | g <- buildGapLines localPVs needs plan
  ]

-- | Mark success lines as completed via the release-asset reuse path.
markSuccessLinesReused :: [SuccessLine] -> [SuccessLine]
markSuccessLinesReused = map (\sl -> sl {slAssetsReused = True})

materializeOneDeps ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  PlannedEbuild ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
materializeOneDeps env overlayRoot entry src eco localPVs plan pe stepsDoneRef remainingPVs = do
  let targetVer = case pePV pe of
        Numeric comps _ -> Numeric comps Nothing
        Raw t -> Raw t
      writeVer = writeVersionForPlannedPV targetVer localPVs
      lines_ =
        filter
          (\sl -> samePV (slTo sl) targetVer)
          (gapSuccessLines localPVs [targetVer] plan)
  depsPublishAndOverlay
    env
    overlayRoot
    entry
    src
    eco
    (peKeywords pe)
    lines_
    writeVer
    stepsDoneRef
    remainingPVs

pruneExtras ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  RuntimeLanePlan ->
  IO (Either Text [FilePath])
pruneExtras env overlayRoot entry plan = do
  let pkgDir = takeDirectory (pePath entry)
      pn = pePN entry
  names <- listDirectory pkgDir
  let extras =
        [ pkgDir </> n
        | n <- names,
          Just (pkg, verStr) <- [parseEbuildFileName n],
          T.pack pkg == pn,
          let v = parseEbuildVersion (T.pack verStr),
          not (isLivePackageVersion v),
          not (any (samePV v) (glpUniquePVs plan))
        ]
  if null extras
    then pure (Right [])
    else do
      mapM_ removeFile extras
      rels <- mapM (relativeOverlayPath overlayRoot) extras
      -- Manifest after deletions.
      manResult <-
        case [n | n <- names, ".ebuild" `T.isSuffixOf` T.pack n, n `notElem` map takeFileName extras] of
          (keep : _) -> aeEbuildRunner env pkgDir keep
          [] -> pure (Right ())
      case manResult of
        Left err -> pure (Left err)
        Right () -> do
          manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
          pure (Right (rels <> [manRel]))

-- | Full materialize path: 7 discrete multi-progress steps.
fullPathMaterializeSteps :: Int
fullPathMaterializeSteps = 7

-- | Reuse materialize path: 3 discrete multi-progress steps.
reusePathMaterializeSteps :: Int
reusePathMaterializeSteps = 3

-- | Upper-bound package step total after planning: @planDone + nPVs × 7@.
materializeStepTotalUpper :: Int -> Int -> Int
materializeStepTotalUpper planDone nPVs =
  planDone + nPVs * fullPathMaterializeSteps

-- | After path selection: @stepsDone + thisPath + remainingUnstarted × 7@.
reviseMaterializeStepTotal :: Int -> Int -> Int -> Int
reviseMaterializeStepTotal stepsDone thisPathSteps remainingUnstartedPVs =
  stepsDone + thisPathSteps + remainingUnstartedPVs * fullPathMaterializeSteps

markMaterializeStep :: IORef Int -> MultiHandle -> PackageKey -> Text -> IO ()
markMaterializeStep stepsDoneRef mh key name = do
  atomicModifyIORef' stepsDoneRef (\n -> (n + 1, ()))
  mhStep mh key name

goVendorProgress :: IORef Int -> MultiHandle -> PackageKey -> VendorProgress
goVendorProgress stepsDoneRef mh key =
  VendorProgress
    { vpOnCloneStart = mhStatus mh key "cloning upstream",
      vpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      vpOnDownloadStart = mhStatus mh key "go mod download",
      vpOnDownloadDone = markMaterializeStep stepsDoneRef mh key "go mod download",
      vpOnCompressStart = mhStatus mh key "compressing tarball",
      vpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

depsPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
depsPublishAndOverlay env overlayRoot entry src eco keywords lines_ targetVer stepsDoneRef remainingPVs = do
  let key = peKey entry
      pn = pePN entry
      pvNoRev = renderPVNoRev targetVer
      kind = distfileKindForEcosystem eco
      tarballName = distfileTarballName kind pn pvNoRev
      tag = releaseTag pn pvNoRev
      assetName = T.pack tarballName
      mh = aeMulti env
      remainingAfter = max 0 (remainingPVs - 1)
  case (aeAssetsRoot env, aeGitHubToken env) of
    (Nothing, _) ->
      pure $
        ApplyHardFail
          key
          "assets-path is required for DepsAndAssets packages"
          False
          False
    (_, Nothing) ->
      pure $
        ApplyHardFail
          key
          "GitHub token is required to publish assets releases"
          False
          False
    (Just assetsRoot, Just _token) ->
      case splitPackageKey key of
        Nothing ->
          pure $ ApplyHardFail key "invalid package key" False False
        Just (category, _) -> do
          mhStatus mh key "probing release asset"
          looked <-
            lookupNamedAsset
              (aeReleaseOps env)
              (aeAssetsOwner env)
              (aeAssetsRepo env)
              tag
              assetName
          case looked of
            Left err ->
              pure $
                ApplyHardFail
                  key
                  ("release asset lookup failed: " <> err)
                  False
                  False
            Right (Just downloadUrl) -> do
              done <- readIORef stepsDoneRef
              mhSteps
                mh
                key
                ( reviseMaterializeStepTotal
                    done
                    reusePathMaterializeSteps
                    remainingAfter
                )
              reuseDepsReleaseAsset
                env
                overlayRoot
                entry
                src
                eco
                keywords
                lines_
                targetVer
                assetsRoot
                category
                pn
                pvNoRev
                tarballName
                downloadUrl
                stepsDoneRef
            Right Nothing -> do
              done <- readIORef stepsDoneRef
              mhSteps
                mh
                key
                ( reviseMaterializeStepTotal
                    done
                    fullPathMaterializeSteps
                    remainingAfter
                )
              fullDepsPublishAndOverlay
                env
                overlayRoot
                entry
                src
                eco
                keywords
                lines_
                targetVer
                assetsRoot
                category
                pn
                pvNoRev
                tarballName
                mh
                key
                stepsDoneRef

goPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
goPublishAndOverlay env overlayRoot entry owner repo prefix mSub =
  depsPublishAndOverlay
    env
    overlayRoot
    entry
    (GitHub owner repo prefix)
    (Go mSub)

fullDepsPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  FilePath ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  MultiHandle ->
  PackageKey ->
  IORef Int ->
  IO ApplyOutcome
fullDepsPublishAndOverlay
  env
  overlayRoot
  entry
  src
  eco
  keywords
  lines_
  targetVer
  assetsRoot
  category
  pn
  pvNoRev
  tarballName
  mh
  key
  stepsDoneRef =
    withSystemTempDirectory "mndz-deps-out-" $ \outDir -> do
      built <-
        materializeDistfile
          env
          eco
          src
          entry
          pvNoRev
          outDir
          tarballName
          stepsDoneRef
          mh
          key
      case built of
        Left err -> pure $ ApplyHardFail key err False False
        Right (tarballPath, mReqVer, mEbuildBody) -> do
          mhStatus mh key "committing assets"
          digests <- hashFile tarballPath
          let sp = sidecarPaths assetsRoot category pn tarballName
              relSidecars =
                [ T.unpack category </> T.unpack pn </> tarballName <> ext
                | ext <- [".sha256", ".sha512", ".b3"]
                ]
          createDirectoryIfMissing True (takeDirectory (spSha256 sp))
          writeSidecars
            tarballPath
            digests
            (spSha256 sp)
            (spSha512 sp)
            (spB3 sp)
          let msg = commitMessage category pn (renderPV targetVer)
              meta =
                ReleaseMeta
                  { rmOwner = aeAssetsOwner env,
                    rmRepo = aeAssetsRepo env,
                    rmTag = releaseTag pn pvNoRev,
                    rmName = releaseName category pn pvNoRev,
                    rmBody = msg,
                    rmTargetCommitish = "main"
                  }
          pubResult <-
            withMVar (aeAssetsLock env) $ \() -> do
              committed <-
                goAddAndCommit
                  (aeGitOps env)
                  assetsRoot
                  relSidecars
                  msg
              case committed of
                Left err -> pure (Left err)
                Right () -> do
                  markMaterializeStep stepsDoneRef mh key "committing assets"
                  mhStatus mh key "pushing assets"
                  pushed <- goPush (aeGitOps env) assetsRoot
                  case pushed of
                    Left err -> pure (Left err)
                    Right () -> do
                      markMaterializeStep stepsDoneRef mh key "pushing assets"
                      mhStatus mh key "uploading release asset"
                      uploaded <-
                        roCreateReleaseWithAsset
                          (aeReleaseOps env)
                          meta
                          tarballPath
                      case uploaded of
                        Left err -> pure (Left err)
                        Right () -> do
                          markMaterializeStep stepsDoneRef mh key "uploading release asset"
                          pure (Right ())
          case pubResult of
            Left err ->
              pure $
                ApplyHardFail
                  key
                  ("assets publish failed: " <> err)
                  False
                  False
            Right () -> do
              mhStatus mh key "regenerating manifest"
              outcome <-
                overlayAfterAssets
                  env
                  overlayRoot
                  entry
                  eco
                  keywords
                  lines_
                  targetVer
                  digests
                  tarballName
                  mReqVer
                  mEbuildBody
              case outcome of
                ApplySuccess {} ->
                  markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                _ -> pure ()
              pure outcome

-- | Build vendor/deps/crates tarball; returns path, optional runtime version, optional ebuild body.
materializeDistfile ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  Text ->
  FilePath ->
  FilePath ->
  IORef Int ->
  MultiHandle ->
  PackageKey ->
  IO (Either Text (FilePath, Maybe Text, Maybe Text))
materializeDistfile env eco src entry pvNoRev outDir tarballName stepsDoneRef mh key =
  case (eco, src) of
    (Go mSub, GitHub owner repo prefix) -> do
      built <-
        buildVendorTarball
          (aeVendorOps env)
          (goVendorProgress stepsDoneRef mh key)
          owner
          repo
          prefix
          pvNoRev
          mSub
          outDir
          tarballName
      pure $ case built of
        Left err -> Left err
        Right VendorResult {vrTarballPath = p, vrGoModVersion = mGo} ->
          Right (p, mGo, Nothing)
    (NpmEco, Npm npmPkg) -> do
      -- Require engines for host gate: fetch first
      eng <- dpoFetchNpmEngines (aeDepsPlanOps env) npmPkg pvNoRev
      case eng of
        Left err -> pure (Left err)
        Right nodeReq -> do
          let progress = npmCacheProgress stepsDoneRef mh key
          built <-
            buildNpmDepsTarball
              (aeNpmCacheOps env)
              progress
              npmPkg
              pvNoRev
              nodeReq
              outDir
              tarballName
          pure $ case built of
            Left err -> Left err
            Right p -> Right (p, Just nodeReq, Nothing)
    (Bun, GitHub owner repo prefix) -> do
      eng <-
        dpoFetchBunEngines (aeDepsPlanOps env) owner repo prefix pvNoRev
      case eng of
        Left err -> pure (Left err)
        Right bunReq -> do
          let progress = bunCacheProgress stepsDoneRef mh key
          built <-
            buildBunDepsTarball
              (aeBunCacheOps env)
              progress
              owner
              repo
              prefix
              pvNoRev
              bunReq
              outDir
              tarballName
          pure $ case built of
            Left err -> Left err
            Right p -> Right (p, Just bunReq, Nothing)
    (Cargo mLock mPkg, GitHub owner repo prefix) -> do
      donorPath <- findTemplate (takeDirectory (pePath entry)) (pePN entry) (parseEbuildVersion pvNoRev) (pePath entry)
      donorContent <- TIO.readFile donorPath
      let progress = cargoCratesProgress stepsDoneRef mh key
      built <-
        buildCargoCratesTarball
          (aeCargoOps env)
          progress
          owner
          repo
          prefix
          pvNoRev
          mLock
          mPkg
          donorContent
          (pePN entry)
          outDir
          tarballName
      pure $ case built of
        Left err -> Left err
        Right
          CargoResult
            { crTarballPath = p,
              crMsrv = msrv,
              crEbuildBody = body
            } ->
            Right (p, Just msrv, Just body)
    (Go _, _) -> pure (Left "DepsAndAssets Go requires a GitHub update source")
    (NpmEco, _) -> pure (Left "DepsAndAssets Npm requires an Npm update source")
    (Bun, _) -> pure (Left "DepsAndAssets Bun requires a GitHub update source")
    (Cargo {}, _) -> pure (Left "DepsAndAssets Cargo requires a GitHub update source")

npmCacheProgress :: IORef Int -> MultiHandle -> PackageKey -> NpmCacheProgress
npmCacheProgress stepsDoneRef mh key =
  NpmCacheProgress
    { ncpOnPackStart = mhStatus mh key "npm pack",
      ncpOnPackDone = markMaterializeStep stepsDoneRef mh key "npm pack",
      ncpOnInstallStart = mhStatus mh key "npm cache install",
      ncpOnInstallDone = markMaterializeStep stepsDoneRef mh key "npm cache install",
      ncpOnCompressStart = mhStatus mh key "compressing tarball",
      ncpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

bunCacheProgress :: IORef Int -> MultiHandle -> PackageKey -> BunCacheProgress
bunCacheProgress stepsDoneRef mh key =
  BunCacheProgress
    { bcpOnCloneStart = mhStatus mh key "cloning upstream",
      bcpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      bcpOnInstallStart = mhStatus mh key "bun install",
      bcpOnInstallDone = markMaterializeStep stepsDoneRef mh key "bun install",
      bcpOnCompressStart = mhStatus mh key "compressing tarball",
      bcpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

cargoCratesProgress :: IORef Int -> MultiHandle -> PackageKey -> CargoProgress
cargoCratesProgress stepsDoneRef mh key =
  CargoProgress
    { cgpOnCloneStart = mhStatus mh key "cloning upstream",
      cgpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      cgpOnPycargoStart = mhStatus mh key "pycargoebuild",
      cgpOnPycargoDone = markMaterializeStep stepsDoneRef mh key "pycargoebuild"
    }

reuseDepsReleaseAsset ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  FilePath ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  Text ->
  IORef Int ->
  IO ApplyOutcome
reuseDepsReleaseAsset
  env
  overlayRoot
  entry
  src
  eco
  keywords
  lines_
  targetVer
  assetsRoot
  category
  pn
  pvNoRev
  tarballName
  downloadUrl
  stepsDoneRef = do
    let key = peKey entry
        mh = aeMulti env
        reusedLines = markSuccessLinesReused lines_
        verifyLabel = case eco of
          Go _ -> "verifying vendor asset"
          Cargo {} -> "verifying crates asset"
          _ -> "verifying deps asset"
    withSystemTempDirectory "mndz-reuse-asset-" $ \tmpDir -> do
      let dest = tmpDir </> tarballName
      mhStatus mh key "reusing release assets"
      dl <- roDownloadAsset (aeReleaseOps env) downloadUrl dest
      case dl of
        Left err ->
          pure $
            ApplyHardFail
              key
              ("download of existing release asset failed: " <> err)
              False
              True
        Right () -> do
          digests <- hashFile dest
          markMaterializeStep stepsDoneRef mh key "reusing release assets"
          mhStatus mh key verifyLabel
          sideCheck <-
            checkSidecarSha512IfPresent
              assetsRoot
              category
              pn
              tarballName
              (digestSHA512 digests)
          case sideCheck of
            Left err -> pure $ ApplyHardFail key err False True
            Right () -> do
              mReq <- case eco of
                Go mSub -> case src of
                  GitHub owner repo prefix ->
                    fetchGoModVersion env owner repo prefix pvNoRev mSub
                  _ -> pure Nothing
                Cargo mLock mPkg -> do
                  donorPath <-
                    findTemplate
                      (takeDirectory (pePath entry))
                      (pePN entry)
                      targetVer
                      (pePath entry)
                  donorContent <- TIO.readFile donorPath
                  fetchCargoMsrvForPV env src mLock mPkg pvNoRev donorContent
                _ -> do
                  mAtom <- fetchRequiredBdependAtom env eco src pvNoRev
                  pure $ case mAtom of
                    Just atom
                      | "nodejs-" `T.isInfixOf` atom ->
                          Just (T.takeWhile (/= '[') (T.drop (T.length (">=net-libs/nodejs-" :: Text)) atom))
                      | "bun-bin-" `T.isInfixOf` atom ->
                          Just (T.drop (T.length (">=dev-lang/bun-bin-" :: Text)) atom)
                      | otherwise -> Nothing
                    Nothing -> Nothing
              markMaterializeStep stepsDoneRef mh key verifyLabel
              mhStatus mh key "regenerating manifest"
              outcome <-
                overlayAfterAssets
                  env
                  overlayRoot
                  entry
                  eco
                  keywords
                  reusedLines
                  targetVer
                  digests
                  tarballName
                  mReq
                  Nothing
              case outcome of
                ApplySuccess k sls paths -> do
                  markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                  pure (ApplySuccess k sls paths)
                other -> pure other

-- | Optional assets-repo sidecar SHA512 cross-check (only when file exists).
checkSidecarSha512IfPresent ::
  FilePath ->
  Text ->
  Text ->
  FilePath ->
  Text ->
  IO (Either Text ())
checkSidecarSha512IfPresent assetsRoot category pn tarballName expectedSha = do
  let sp = sidecarPaths assetsRoot category pn tarballName
      path = spSha512 sp
  exists <- doesFileExist path
  if not exists
    then pure (Right ())
    else do
      text <- TIO.readFile path
      case T.words (T.strip text) of
        (hex : _)
          | T.toLower hex == T.toLower expectedSha -> pure (Right ())
          | otherwise ->
              pure $
                Left
                  ( "assets-repo sidecar SHA512 disagrees with GitHub release asset for "
                      <> T.pack tarballName
                      <> " (assets repo and release are out of sync)"
                  )
        _ ->
          pure $
            Left
              ( "could not parse assets-repo SHA512 sidecar for "
                  <> T.pack tarballName
              )

-- | go.mod @go@ directive for BDEPEND without a vendor clone (reuse path).
fetchGoModVersion ::
  ApplyEnv ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO (Maybe Text)
fetchGoModVersion env owner repo prefix pvNoRev mSub = do
  let tag = versionTag prefix pvNoRev
      key =
        GoModKey
          { gmkOwner = owner,
            gmkRepo = repo,
            gmkTag = tag,
            gmkSubdir = mSub
          }
  eres <- dpoFetchGoMod (aeDepsPlanOps env) key
  pure $ case eres of
    Right body -> parseGoReqFromMod body
    Left _ -> Nothing
