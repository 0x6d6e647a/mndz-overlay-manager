{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

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
    fetchModelsDevApiJson,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar (withMVar)
import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.ByteString.Lazy qualified as LBS
import Data.Containers.ListUtils (nubOrd)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (statusCode)
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
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.Apply.GitMv (requirePackageMd5Cache)
import Update.Apply.OverlayWrite (findTemplate, overlayAfterAssets)
import Update.Assets.Hash (FileDigests (..), hashFile, writeSidecars)
import Update.Assets.Layout
  ( SidecarPaths (..),
    commitMessage,
    distfileKindForEcosystem,
    distfileTarballName,
    modelsDistfileName,
    releaseName,
    releaseTag,
    sidecarPaths,
  )
import Update.Assets.Release
  ( ReleaseMeta (..),
    ReleaseOps (..),
    lookupNamedAssets,
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
    planErrorMessage,
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
      pure
        [ ApplyHardFail
            key
            ("runtime-lane plan failed: " <> planErrorMessage err)
            False
            False
        ]
    Right plan -> do
      contentFix <- contentFixNeededEnv env eco src pkgDir (pePN entry) key plan
      if not (planNeedsWork localPVs contentFix plan)
        then pure [ApplySoftSkip key "already matches runtime-lane plan"]
        else do
          cacheGate <- requirePackageMd5Cache overlayRoot key pkgDir
          case cacheGate of
            Left unitErr -> pure [applyUnitHardFail key unitErr False False]
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
  PackageKey ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixNeededEnv env eco src pkgDir pn key plan =
  concat <$> mapM checkPlanned (glpEbuilds plan)
  where
    checkPlanned pe = do
      let name = ebuildFileNameWithRev pn (pePV pe)
          path = pkgDir </> name
          pvNoRev = renderPVNoRev (pePV pe)
          required = requiredAssetBasenames key eco pn pvNoRev
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
          manMissing <- anyManifestMissing pkgDir required
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

-- | Required release asset basenames for a package/PV (primary + companions).
requiredAssetBasenames :: PackageKey -> EcosystemSpec -> Text -> Text -> [FilePath]
requiredAssetBasenames key eco pn pvNoRev =
  let primary = distfileTarballName (distfileKindForEcosystem eco) pn pvNoRev
      extras =
        case key of
          PackageKey "dev-util/opencode" -> [modelsDistfileName pn pvNoRev]
          _ -> []
   in primary : extras

anyManifestMissing :: FilePath -> [FilePath] -> IO Bool
anyManifestMissing pkgDir names = do
  checks <- mapM (vendorManifestMissing pkgDir) names
  pure (or checks)

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
contentFixNeeded env owner repo prefix mSub pkgDir pn =
  contentFixNeededEnv
    env
    (Go mSub)
    (GitHub owner repo prefix)
    pkgDir
    pn
    (PackageKey (T.pack "legacy/" <> pn))

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
        nubOrd
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
      assetNames = requiredAssetBasenames key eco pn pvNoRev
      tag = releaseTag pn pvNoRev
      mh = aeMulti env
      remainingAfter = max 0 (remainingPVs - 1)
  case (aeAssetsRoot env, aeGitHubToken env) of
    (Nothing, _) ->
      pure $ applyUnitHardFail key ApplyMissingAssetsPath False False
    (_, Nothing) ->
      pure $ applyUnitHardFail key ApplyMissingGitHubToken False False
    (Just assetsRoot, Just _token) ->
      case splitPackageKey key of
        Nothing ->
          pure $
            applyUnitHardFail key (ApplyInvalidPackageKey Nothing) False False
        Just (category, _) -> do
          mhStatus mh key "probing release asset"
          looked <-
            lookupNamedAssets
              (aeReleaseOps env)
              (aeAssetsOwner env)
              (aeAssetsRepo env)
              tag
              (map T.pack assetNames)
          case looked of
            Left err ->
              pure $
                ApplyHardFail
                  key
                  ("release asset lookup failed: " <> err)
                  False
                  False
            Right (Just downloadUrls) -> do
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
                (zip assetNames downloadUrls)
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
                assetNames
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
  [FilePath] ->
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
  assetNames
  mh
  key
  stepsDoneRef =
    withSystemTempDirectory "mndz-deps-out-" $ \outDir -> do
      built <-
        materializeDistfiles
          env
          eco
          src
          entry
          key
          pn
          pvNoRev
          outDir
          assetNames
          stepsDoneRef
          mh
      case built of
        Left err -> pure $ ApplyHardFail key err False False
        Right (paths, mReqVer, mEbuildBody) -> do
          mhStatus mh key "committing assets"
          distDigests <- mapM (\p -> (takeFileName p,) <$> hashFile p) paths
          let relSidecars =
                [ T.unpack category </> T.unpack pn </> takeFileName p <> ext
                | p <- paths,
                  ext <- [".sha256", ".sha512", ".b3"]
                ]
          mapM_
            ( \(p, digests) -> do
                let sp = sidecarPaths assetsRoot category pn (takeFileName p)
                createDirectoryIfMissing True (takeDirectory (spSha256 sp))
                writeSidecars p digests (spSha256 sp) (spSha512 sp) (spB3 sp)
            )
            distDigests
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
                        roCreateReleaseWithAssets
                          (aeReleaseOps env)
                          meta
                          paths
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
                  distDigests
                  mReqVer
                  mEbuildBody
              case outcome of
                ApplySuccess {} ->
                  markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                _ -> pure ()
              pure outcome

-- | Build all required distfiles (primary + companions); paths in asset order.
materializeDistfiles ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  PackageKey ->
  Text ->
  Text ->
  FilePath ->
  [FilePath] ->
  IORef Int ->
  MultiHandle ->
  IO (Either Text ([FilePath], Maybe Text, Maybe Text))
materializeDistfiles env eco src entry key pn pvNoRev outDir assetNames stepsDoneRef mh =
  case assetNames of
    [] -> pure (Left "no required assets for materialize")
    (primaryName : companionNames) -> do
      primary <-
        materializePrimaryDistfile
          env
          eco
          src
          entry
          key
          pvNoRev
          outDir
          primaryName
          stepsDoneRef
          mh
      case primary of
        Left err -> pure (Left err)
        Right (p, mReqVer, mEbuildBody) -> do
          companions <-
            materializeCompanionAssets env key pn pvNoRev outDir companionNames
          pure $ case companions of
            Left err -> Left err
            Right extras -> Right (p : extras, mReqVer, mEbuildBody)

-- | Build primary vendor/deps/crates tarball.
materializePrimaryDistfile ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  PackageKey ->
  Text ->
  FilePath ->
  FilePath ->
  IORef Int ->
  MultiHandle ->
  IO (Either Text (FilePath, Maybe Text, Maybe Text))
materializePrimaryDistfile env eco src entry key pvNoRev outDir tarballName stepsDoneRef mh =
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

-- | Companion distfiles (e.g. models JSON) required beyond the primary tarball.
materializeCompanionAssets ::
  ApplyEnv ->
  PackageKey ->
  Text ->
  Text ->
  FilePath ->
  [FilePath] ->
  IO (Either Text [FilePath])
materializeCompanionAssets _ _ _ _ _ [] = pure (Right [])
materializeCompanionAssets env key pn pvNoRev outDir names =
  case key of
    PackageKey "dev-util/opencode" ->
      goOpencode names
    _ ->
      pure $
        Left
          ( "unknown companion assets for "
              <> let PackageKey k = key in k
          )
  where
    goOpencode [] = pure (Right [])
    goOpencode (n : rest)
      | n == modelsDistfileName pn pvNoRev = do
          fetched <- aeFetchModelsDev env (outDir </> n)
          case fetched of
            Left err -> pure (Left err)
            Right p -> do
              more <- goOpencode rest
              pure $ case more of
                Left err -> Left err
                Right ps -> Right (p : ps)
      | otherwise =
          pure $
            Left ("unexpected companion distfile for opencode: " <> T.pack n)

-- | GET https://models.dev/api.json → write raw body to dest path.
fetchModelsDevApiJson :: FilePath -> IO (Either Text FilePath)
fetchModelsDevApiJson destPath = do
  mgr <- newManager tlsManagerSettings
  fetchModelsDevApiJsonWith mgr destPath

fetchModelsDevApiJsonWith :: Manager -> FilePath -> IO (Either Text FilePath)
fetchModelsDevApiJsonWith mgr destPath = do
  req0 <- parseRequest "https://models.dev/api.json"
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/json")
              ]
          }
  eres <-
    (Right <$> httpLbs req mgr)
      `catch` \(e :: SomeException) -> pure (Left (T.pack (show e)))
  case eres of
    Left err -> pure (Left ("models.dev fetch failed: " <> err))
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then do
              let body = responseBody resp
              if LBS.null body
                then pure (Left "models.dev returned empty body")
                else do
                  createDirectoryIfMissing True (takeDirectory destPath)
                  LBS.writeFile destPath body
                  pure (Right destPath)
            else
              pure $
                Left $
                  "models.dev HTTP "
                    <> T.pack (show code)
                    <> " fetching api.json"

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
  -- | (basename, browser_download_url) for every required asset.
  [(FilePath, Text)] ->
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
  namedUrls
  stepsDoneRef = do
    let key = peKey entry
        mh = aeMulti env
        reusedLines = markSuccessLinesReused lines_
        verifyLabel = case eco of
          Go _ -> "verifying vendor asset"
          Cargo {} -> "verifying crates asset"
          _ -> "verifying deps asset"
    withSystemTempDirectory "mndz-reuse-asset-" $ \tmpDir -> do
      mhStatus mh key "reusing release assets"
      dlResult <- downloadNamedAssets (aeReleaseOps env) tmpDir namedUrls
      case dlResult of
        Left err ->
          pure $
            ApplyHardFail
              key
              ("download of existing release asset failed: " <> err)
              False
              True
        Right localPaths -> do
          distDigests <- mapM (\p -> (takeFileName p,) <$> hashFile p) localPaths
          markMaterializeStep stepsDoneRef mh key "reusing release assets"
          mhStatus mh key verifyLabel
          sideCheck <- checkAllSidecars assetsRoot category pn distDigests
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
                  distDigests
                  mReq
                  Nothing
              case outcome of
                ApplySuccess k sls paths -> do
                  markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                  pure (ApplySuccess k sls paths)
                other -> pure other

downloadNamedAssets ::
  ReleaseOps ->
  FilePath ->
  [(FilePath, Text)] ->
  IO (Either Text [FilePath])
downloadNamedAssets _ _ [] = pure (Right [])
downloadNamedAssets ops tmpDir ((name, url) : rest) = do
  let dest = tmpDir </> name
  dl <- roDownloadAsset ops url dest
  case dl of
    Left err -> pure (Left err)
    Right () -> do
      more <- downloadNamedAssets ops tmpDir rest
      pure $ case more of
        Left err -> Left err
        Right ps -> Right (dest : ps)

checkAllSidecars ::
  FilePath ->
  Text ->
  Text ->
  [(FilePath, FileDigests)] ->
  IO (Either Text ())
checkAllSidecars _ _ _ [] = pure (Right ())
checkAllSidecars assetsRoot category pn ((name, digests) : rest) = do
  sideCheck <-
    checkSidecarSha512IfPresent
      assetsRoot
      category
      pn
      name
      (digestSHA512 digests)
  case sideCheck of
    Left err -> pure (Left err)
    Right () -> checkAllSidecars assetsRoot category pn rest

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
