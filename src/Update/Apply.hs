{-# LANGUAGE OverloadedStrings #-}

module Update.Apply
  ( applyOverlay,
    applyPackagePhase1,
    commitSuccesses,
    foldExitHardFail,
    newEbuildFileName,
    renderPVNoRev,
    EbuildRunner,
    productionEbuildRunner,
    ApplyEnv (..),
    needsGoAssetsApply,
    contentFixNeeded,
    goPublishAndOverlay,
    markSuccessLinesReused,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig,
    StepHandle (..),
    withMultiProgress,
    withStepProgress,
  )
import Control.Concurrent.MVar (MVar, withMVar)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (nub, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, prettyVersion, renderPV)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
    removeFile,
    renameFile,
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (cwd),
    readCreateProcessWithExitCode,
    shell,
  )
import Update.Assets.Hash (FileDigests (..), hashFile, writeSidecars)
import Update.Assets.Layout
  ( SidecarPaths (..),
    commitMessage,
    releaseName,
    releaseTag,
    sidecarPaths,
    vendorTarballName,
  )
import Update.Assets.Release
  ( ReleaseMeta (..),
    ReleaseOps (..),
    createReleaseWithAsset,
    lookupNamedAsset,
  )
import Update.Check (PackageEntry (..))
import Update.EbuildEdit
  ( ebuildFileNameWithRev,
    ebuildNeedsContentFix,
    ensureGoBdepend,
    manifestHasVendorDist,
    nextRevisionVersion,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
    setKeywords,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Go.Lanes
  ( GapLine (..),
    GoLanePlan (..),
    PlannedEbuild (..),
    buildGapLines,
    missingTargets,
    planNeedsWork,
  )
import Update.Go.ModFetch (GoModKey (..), parseGoReqFromMod)
import Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    isLivePackageVersion,
    planGoPackageWithProgress,
  )
import Update.Go.Vendor (VendorOps (..), VendorResult (..), buildVendorTarball, versionTag)
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( ApplyOutcome (..),
    Fetcher,
    PackageKey (..),
    PackagePolicy (..),
    SuccessLine (..),
    UpdateSource (..),
    UpdateTechnique (..),
    outcomeIsHardFail,
    packageKeyText,
    splitPackageKey,
    techniqueNeedsAssets,
  )

type EbuildRunner = FilePath -> FilePath -> IO (Either Text ())

productionEbuildRunner :: EbuildRunner
productionEbuildRunner pkgDir ebuildFileName = do
  let cmd = "ebuild ./" <> ebuildFileName <> " manifest"
      proc' = (shell cmd) {cwd = Just pkgDir}
  (code, _out, err) <- readCreateProcessWithExitCode proc' ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("ebuild manifest failed: " <> T.pack err)

data ApplyEnv = ApplyEnv
  { aeFetcher :: Fetcher,
    aeGitOps :: GitOps,
    aeEbuildRunner :: EbuildRunner,
    aeVendorOps :: VendorOps,
    aeReleaseOps :: ReleaseOps,
    aeAssetsRoot :: Maybe FilePath,
    aeGitHubToken :: Maybe Text,
    aeAssetsOwner :: Text,
    aeAssetsRepo :: Text,
    aeAssetsLock :: MVar (),
    aeJobs :: Int,
    aeMulti :: MultiHandle,
    aeCommitStep :: StepHandle,
    aePlanOps :: PlanOps
  }

needsGoAssetsApply :: [PackageEntry] -> Bool
needsGoAssetsApply =
  any $ \e ->
    case lookupPolicy (peKey e) of
      Just p -> techniqueNeedsAssets (policyTechnique p)
      Nothing -> False

renderPVNoRev :: EbuildVersion -> Text
renderPVNoRev (Raw t) = t
renderPVNoRev (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)

newEbuildFileName :: Text -> EbuildVersion -> FilePath
newEbuildFileName pn remote =
  T.unpack pn <> "-" <> T.unpack (renderPVNoRev remote) <> ".ebuild"

foldExitHardFail :: [ApplyOutcome] -> Bool
foldExitHardFail = any outcomeIsHardFail

applyOverlay ::
  ProgressConfig ->
  ApplyEnv ->
  FilePath ->
  [PackageEntry] ->
  Maybe [PackageKey] ->
  IO [ApplyOutcome]
applyOverlay pcfg env overlayRoot entries mFilter = do
  isGit <- goIsWorkTree (aeGitOps env) overlayRoot
  if not isGit
    then
      pure
        [ ApplyHardFail
            (PackageKey "")
            "overlay path is not a git work tree"
            False
            False
        ]
    else do
      let selected = case mFilter of
            Nothing -> entries
            Just keys -> [e | e <- entries, peKey e `elem` keys]
      phase1Nested <-
        withMultiProgress pcfg "Updating packages" (length selected) $ \mh ->
          let env' = env {aeMulti = mh}
           in mapConcurrentlyN
                (aeJobs env')
                (applyPackagePhase1Tracked env' overlayRoot)
                selected
      let phase1 = concat phase1Nested
          successes =
            sortOn
              (packageKeyText . successKey)
              [o | o@ApplySuccess {} <- phase1]
          others = [o | o <- phase1, not (isSuccess o)]
      committed <-
        withStepProgress pcfg (length successes) $ \sh ->
          commitSuccesses
            (aeGitOps env)
            sh
            overlayRoot
            successes
      pure (others <> committed)
  where
    successKey (ApplySuccess k _ _) = k
    successKey _ = PackageKey ""
    isSuccess ApplySuccess {} = True
    isSuccess _ = False

applyPackagePhase1Tracked ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  IO [ApplyOutcome]
applyPackagePhase1Tracked env overlayRoot entry = do
  let key = peKey entry
      mh = aeMulti env
  mhStart mh key
  outcomes <- applyPackagePhase1 env overlayRoot entry
  case outcomes of
    [] -> mhSuccess mh key
    _ ->
      if any outcomeIsHardFail outcomes
        then
          let msg = case [m | ApplyHardFail _ m _ _ <- outcomes] of
                (m : _) -> m
                [] -> "hard fail"
           in mhFail mh key (shortReason msg)
        else
          if all isSoft outcomes
            then
              let reason = case [r | ApplySoftSkip _ r <- outcomes] of
                    (r : _) -> r
                    [] -> "skipped"
               in mhFail mh key (shortReason reason)
            else mhSuccess mh key
  pure outcomes
  where
    isSoft ApplySoftSkip {} = True
    isSoft _ = False

shortReason :: Text -> Text
shortReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

applyPackagePhase1 ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  IO [ApplyOutcome]
applyPackagePhase1 env overlayRoot entry =
  case lookupPolicy (peKey entry) of
    Nothing ->
      pure [ApplySoftSkip (peKey entry) "no hardcoded policy for package"]
    Just policy ->
      case policyTechnique policy of
        Unsupported reason ->
          pure
            [ ApplySoftSkip
                (peKey entry)
                ("unsupported update technique: " <> reason)
            ]
        GitMvAndManifest ->
          (: []) <$> applyGitMv env overlayRoot entry (policySource policy)
        GoVendorAndAssets mSub ->
          applyGoVendorLanes env overlayRoot entry (policySource policy) mSub

------------------------------------------------------------------------
-- GitMvAndManifest
------------------------------------------------------------------------

applyGitMv ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  IO ApplyOutcome
applyGitMv env overlayRoot entry src = do
  let key = peKey entry
      local = peLocal entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      mh = aeMulti env
  mhStatus mh key "fetching"
  fetched <- aeFetcher env src
  case fetched of
    Left err ->
      pure $ ApplyHardFail key ("fetch failed: " <> err) False False
    Right remote ->
      case comparePV local remote of
        Just LT -> do
          mhStatus mh key "applying"
          gitMvDo key local remote oldPath pkgDir pn gitOps ebuildRun overlayRoot
        Just EQ ->
          pure $ ApplySoftSkip key "already at latest upstream version"
        Just GT ->
          pure $
            ApplySoftSkip
              key
              ( "local version is ahead of upstream ("
                  <> prettyVersion local
                  <> " > "
                  <> prettyVersion remote
                  <> ")"
              )
        Nothing ->
          pure $
            ApplyHardFail
              key
              ( "incomparable versions: local="
                  <> T.pack (show local)
                  <> " remote="
                  <> T.pack (show remote)
              )
              False
              False

gitMvDo ::
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  Text ->
  GitOps ->
  EbuildRunner ->
  FilePath ->
  IO ApplyOutcome
gitMvDo key local remote oldPath pkgDir pn gitOps ebuildRun overlayRoot = do
  ebuildRel <- relativeOverlayPath overlayRoot oldPath
  let manifestAbs = pkgDir </> "Manifest"
  manRel0 <- relativeOverlayPath overlayRoot manifestAbs
  dirty' <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
  case dirty' of
    Left err -> pure $ ApplyHardFail key err False False
    Right True ->
      pure $
        ApplyHardFail
          key
          "involved paths are dirty (newest ebuild and/or Manifest)"
          False
          False
    Right False -> do
      let newName = newEbuildFileName pn remote
          newPath = pkgDir </> newName
      existsNew <- doesFileExist newPath
      if existsNew && takeFileName oldPath /= newName
        then
          pure $
            ApplyHardFail
              key
              ("target ebuild already exists: " <> T.pack newName)
              False
              False
        else do
          renamed <-
            if takeFileName oldPath == newName
              then pure False
              else do
                renameFile oldPath newPath
                pure True
          manResult <- ebuildRun pkgDir newName
          case manResult of
            Left err -> pure $ ApplyHardFail key err renamed False
            Right () -> do
              newRel <- relativeOverlayPath overlayRoot newPath
              manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
              let paths =
                    if renamed
                      then [ebuildRel, newRel, manRel]
                      else [newRel, manRel]
                  lines_ =
                    [ SuccessLine
                        { slFrom = local,
                          slTo = remote,
                          slLabel = Nothing,
                          slAssetsReused = False
                        }
                    ]
              pure $ ApplySuccess key lines_ paths

------------------------------------------------------------------------
-- GoVendorAndAssets (tree-lane multi-PV)
------------------------------------------------------------------------

applyGoVendorLanes ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  Maybe FilePath ->
  IO [ApplyOutcome]
applyGoVendorLanes env overlayRoot entry src mSub = do
  let key = peKey entry
      mh = aeMulti env
  planDoneRef <- newIORef (0 :: Int)
  let progress = goApplyPlanProgress mh key planDoneRef
  case src of
    GitHub owner repo prefix -> do
      planResult <-
        planGoPackageWithProgress (aePlanOps env) progress src mSub
      case planResult of
        Left err ->
          pure [ApplyHardFail key ("Go tree-lane plan failed: " <> err) False False]
        Right plan -> do
          let pkgDir = takeDirectory (pePath entry)
          localPVs <- listLocalNonLivePVs pkgDir (pePN entry)
          contentFix <- contentFixNeeded pkgDir (pePN entry) plan
          if not (planNeedsWork localPVs contentFix plan)
            then pure [ApplySoftSkip key "already matches Go tree-lane plan"]
            else do
              planDone <- readIORef planDoneRef
              materializePlan
                env
                overlayRoot
                entry
                owner
                repo
                prefix
                mSub
                plan
                localPVs
                contentFix
                planDone
    _ ->
      pure
        [ ApplyHardFail
            key
            "GoVendorAndAssets requires a GitHub update source"
            False
            False
        ]

-- | Planning progress during update apply (same step model as outdated).
goApplyPlanProgress :: MultiHandle -> PackageKey -> IORef Int -> PlanProgress
goApplyPlanProgress mh key doneRef =
  PlanProgress
    { ppOnCeilingsStart = do
        mhSteps mh key 2
        mhStatus mh key "discovering go ceilings",
      ppOnCeilingsDone = do
        atomicModifyIORef' doneRef (\n -> (n + 1, ()))
        mhStep mh key "discovering go ceilings",
      ppOnListStart = mhStatus mh key "listing versions",
      ppOnListDone = \n -> do
        mhSteps mh key (2 + n)
        atomicModifyIORef' doneRef (\d -> (d + 1, ()))
        mhStep mh key "listing versions",
      ppOnProbeDone = do
        atomicModifyIORef' doneRef (\n -> (n + 1, ()))
        mhStep mh key "probing go.mod"
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

contentFixNeeded :: FilePath -> Text -> GoLanePlan -> IO [EbuildVersion]
contentFixNeeded pkgDir pn plan =
  concat <$> mapM checkPlanned (glpEbuilds plan)
  where
    checkPlanned pe = do
      let name = ebuildFileNameWithRev pn (pePV pe)
          path = pkgDir </> name
          tarball = vendorTarballName pn (renderPVNoRev (pePV pe))
      -- Also try without revision suffix variants by scanning dir.
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
          let bad =
                ebuildNeedsContentFix (peKeywords pe) content || manMissing
          pure [pePV pe | bad]
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

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

materializePlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  GoLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  Int ->
  IO [ApplyOutcome]
materializePlan env overlayRoot entry owner repo prefix mSub plan localPVs contentFix planDone = do
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
      -- Per-PV: vendoring, publishing assets, regenerating manifest.
      applySteps = length sortedPlanned * 3
  -- Extend step total so apply phases continue the same package row bar.
  when (applySteps > 0) $
    mhSteps mh key (planDone + applySteps)
  results <- mapM (materializeOne env overlayRoot entry owner repo prefix mSub localPVs plan) sortedPlanned
  let failures = [o | o@ApplyHardFail {} <- results]
      successes = [o | o@ApplySuccess {} <- results]
  if not (null failures)
    then pure (successes <> failures)
    else do
      -- Prune only after all targets materialized.
      pruneResult <- pruneExtras env overlayRoot entry plan
      case pruneResult of
        Left err ->
          pure
            ( successes
                <> [ApplyHardFail key err True False]
            )
        Right extraPaths ->
          pure $
            case reverse successes of
              [] ->
                -- Prune-only / keywords-only with no materialize (shouldn't happen often)
                if null extraPaths
                  then [ApplySoftSkip key "already matches Go tree-lane plan"]
                  else
                    let lines_ = gapSuccessLines localPVs needPVs plan
                     in [ApplySuccess key lines_ extraPaths]
              (ApplySuccess k sls paths : rest) ->
                reverse rest
                  <> [ApplySuccess k sls (nub (paths <> extraPaths))]
              _ -> successes
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

gapSuccessLines :: [EbuildVersion] -> [EbuildVersion] -> GoLanePlan -> [SuccessLine]
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

materializeOne ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [EbuildVersion] ->
  GoLanePlan ->
  PlannedEbuild ->
  IO ApplyOutcome
materializeOne env overlayRoot entry owner repo prefix mSub localPVs plan pe = do
  let targetVer = case pePV pe of
        Numeric comps _ -> Numeric comps Nothing
        Raw t -> Raw t
      -- Content-fix same PV may need revision bump.
      alreadyLocal = any (samePV targetVer) localPVs
      writeVer =
        if alreadyLocal
          then nextRevisionVersion targetVer
          else targetVer
      lines_ =
        filter
          (\sl -> samePV (slTo sl) targetVer)
          (gapSuccessLines localPVs [targetVer] plan)
  goPublishAndOverlay
    env
    overlayRoot
    entry
    owner
    repo
    prefix
    mSub
    (peKeywords pe)
    lines_
    writeVer
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

pruneExtras ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  GoLanePlan ->
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
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

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
  IO ApplyOutcome
goPublishAndOverlay env overlayRoot entry owner repo prefix mSub keywords lines_ targetVer = do
  let key = peKey entry
      pn = pePN entry
      pvNoRev = renderPVNoRev targetVer
      tarballName = vendorTarballName pn pvNoRev
      tag = releaseTag pn pvNoRev
      assetName = T.pack tarballName
      mh = aeMulti env
  case (aeAssetsRoot env, aeGitHubToken env) of
    (Nothing, _) ->
      pure $
        ApplyHardFail
          key
          "assets-path is required for Go vendor packages"
          False
          False
    (_, Nothing) ->
      pure $
        ApplyHardFail
          key
          "GitHub token is required to publish assets releases"
          False
          False
    (Just assetsRoot, Just token) ->
      case splitPackageKey key of
        Nothing ->
          pure $ ApplyHardFail key "invalid package key" False False
        Just (category, _) -> do
          -- Probe existing release asset first (reuse short-circuit).
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
            Right (Just downloadUrl) ->
              reuseReleaseAsset
                env
                overlayRoot
                entry
                owner
                repo
                prefix
                mSub
                keywords
                lines_
                targetVer
                assetsRoot
                category
                pn
                pvNoRev
                tarballName
                downloadUrl
            Right Nothing ->
              fullPublishAndOverlay
                env
                overlayRoot
                entry
                owner
                repo
                prefix
                mSub
                keywords
                lines_
                targetVer
                assetsRoot
                token
                category
                pn
                pvNoRev
                tarballName
                mh
                key

-- | Full vendor + assets publish + overlay path (release asset absent).
fullPublishAndOverlay ::
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
  FilePath ->
  Text ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  MultiHandle ->
  PackageKey ->
  IO ApplyOutcome
fullPublishAndOverlay
  env
  overlayRoot
  entry
  owner
  repo
  prefix
  mSub
  keywords
  lines_
  targetVer
  assetsRoot
  token
  category
  pn
  pvNoRev
  tarballName
  mh
  key =
    withSystemTempDirectory "mndz-vendor-out-" $ \outDir -> do
      mhStatus mh key "vendoring"
      built <-
        buildVendorTarball
          (aeVendorOps env)
          owner
          repo
          prefix
          pvNoRev
          mSub
          outDir
          tarballName
      case built of
        Left err -> pure $ ApplyHardFail key err False False
        Right VendorResult {vrTarballPath = tarballPath, vrGoModVersion = mGoVer} -> do
          mhStep mh key "vendoring"
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
          mhStatus mh key "publishing assets"
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
                  pushed <- goPush (aeGitOps env) assetsRoot
                  case pushed of
                    Left err -> pure (Left err)
                    Right () -> do
                      let meta =
                            ReleaseMeta
                              { rmOwner = aeAssetsOwner env,
                                rmRepo = aeAssetsRepo env,
                                rmTag = releaseTag pn pvNoRev,
                                rmName = releaseName category pn pvNoRev,
                                rmBody = msg,
                                rmTargetCommitish = "main"
                              }
                      createReleaseWithAsset token meta tarballPath
          case pubResult of
            Left err ->
              pure $
                ApplyHardFail
                  key
                  ("assets publish failed: " <> err)
                  False
                  False
            Right () -> do
              mhStep mh key "publishing assets"
              mhStatus mh key "regenerating manifest"
              outcome <-
                overlayAfterAssets
                  env
                  overlayRoot
                  entry
                  keywords
                  lines_
                  targetVer
                  digests
                  tarballName
                  mGoVer
              case outcome of
                ApplySuccess {} -> mhStep mh key "regenerating manifest"
                _ -> pure ()
              pure outcome

-- | Overlay-only path: download existing release asset, verify, rewrite ebuild.
reuseReleaseAsset ::
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
  FilePath ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  Text ->
  IO ApplyOutcome
reuseReleaseAsset
  env
  overlayRoot
  entry
  owner
  repo
  prefix
  mSub
  keywords
  lines_
  targetVer
  assetsRoot
  category
  pn
  pvNoRev
  tarballName
  downloadUrl = do
    let key = peKey entry
        mh = aeMulti env
        reusedLines = markSuccessLinesReused lines_
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
          mhStep mh key "reusing release assets"
          mhStatus mh key "verifying vendor asset"
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
              mGoVer <- fetchGoModVersion env owner repo prefix pvNoRev mSub
              mhStep mh key "verifying vendor asset"
              mhStatus mh key "regenerating manifest"
              outcome <-
                overlayAfterAssets
                  env
                  overlayRoot
                  entry
                  keywords
                  reusedLines
                  targetVer
                  digests
                  tarballName
                  mGoVer
              case outcome of
                ApplySuccess k sls paths -> do
                  mhStep mh key "regenerating manifest"
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
  eres <- poFetchGoMod (aePlanOps env) key
  pure $ case eres of
    Right body -> parseGoReqFromMod body
    Left _ -> Nothing

overlayAfterAssets ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  FileDigests ->
  FilePath ->
  Maybe Text ->
  IO ApplyOutcome
overlayAfterAssets env overlayRoot entry keywords lines_ targetVer digests tarballName mGoVer = do
  let key = peKey entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      orphan = True
  -- Prefer an existing ebuild for this PV as template; else newest tip.
  templatePath <- findTemplate pkgDir pn targetVer oldPath
  ebuildRel <- relativeOverlayPath overlayRoot templatePath
  manRel0 <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
  dirty <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
  case dirty of
    Left err -> pure $ ApplyHardFail key err False orphan
    Right True ->
      pure $
        ApplyHardFail
          key
          "involved paths are dirty (newest ebuild and/or Manifest)"
          False
          orphan
    Right False -> do
      content <- TIO.readFile templatePath
      let parameterized = parameterizeAssetsSrcUri pn content
          withKw = setKeywords keywords parameterized
      contentFixed <- case mGoVer of
        Nothing -> pure (Right withKw)
        Just goVer -> pure (ensureGoBdepend goVer withKw)
      case contentFixed of
        Left err -> pure $ ApplyHardFail key err False orphan
        Right fixed -> do
          let newName = ebuildFileNameWithRev pn targetVer
              newPath = pkgDir </> newName
          -- Writing same path is fine; different existing path for same PV is replace.
          TIO.writeFile newPath fixed
          removedTemplate <-
            if templatePath /= newPath && takeFileName templatePath /= newName
              then do
                -- Only remove template when it was a different version file we are replacing
                -- as part of rename from newest tip. For multi-PV, keep other versions.
                let templateIsTarget =
                      case parseEbuildFileName (takeFileName templatePath) of
                        Just (_, verStr) ->
                          case comparePV (parseEbuildVersion (T.pack verStr)) targetVer of
                            Just EQ -> True
                            _ -> False
                        Nothing -> False
                if templateIsTarget
                  then removeFile templatePath >> pure True
                  else pure False
              else pure False
          manResult <- ebuildRun pkgDir newName
          case manResult of
            Left err -> pure $ ApplyHardFail key err True orphan
            Right () -> do
              manText <- TIO.readFile (pkgDir </> "Manifest")
              case parseManifestVendorSHA512 manText tarballName of
                Nothing ->
                  pure $
                    ApplyHardFail
                      key
                      "could not parse vendor SHA512 from Manifest after ebuild manifest"
                      True
                      orphan
                Just manSha
                  | manSha == digestSHA512 digests -> do
                      newRel <- relativeOverlayPath overlayRoot newPath
                      manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
                      let paths =
                            nub $
                              [newRel, manRel]
                                <> [ebuildRel | removedTemplate || templatePath /= newPath]
                      pure $ ApplySuccess key lines_ paths
                  | otherwise ->
                      pure $
                        ApplyHardFail
                          key
                          "Manifest SHA512 does not match published vendor tarball"
                          True
                          orphan

findTemplate :: FilePath -> Text -> EbuildVersion -> FilePath -> IO FilePath
findTemplate pkgDir pn targetVer fallback = do
  names <- listDirectory pkgDir
  let same =
        [ pkgDir </> n
        | n <- names,
          Just (pkg, verStr) <- [parseEbuildFileName n],
          T.pack pkg == pn,
          case comparePV (parseEbuildVersion (T.pack verStr)) targetVer of
            Just EQ -> True
            _ -> False
        ]
  pure $ case same of
    (p : _) -> p
    [] -> fallback

commitSuccesses ::
  GitOps ->
  StepHandle ->
  FilePath ->
  [ApplyOutcome] ->
  IO [ApplyOutcome]
commitSuccesses gitOps step overlayRoot = mapM commitOne
  where
    commitOne (ApplySuccess key lines_ paths) = do
      shStep step (packageKeyText key)
      let verText = case lines_ of
            (SuccessLine _ to _ _ : _) -> renderPV to
            [] -> "update"
          msg = packageKeyText key <> ": " <> verText
      result <- goAddAndCommit gitOps overlayRoot paths msg
      pure $ case result of
        Right () -> ApplySuccess key lines_ paths
        Left err -> ApplyHardFail key err False False
    commitOne other = pure other
