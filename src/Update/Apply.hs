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
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Version (EbuildVersion (..), comparePV, prettyVersion, renderPV)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
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
import Update.Assets.Release (ReleaseMeta (..), createReleaseWithAsset)
import Update.Check (PackageEntry (..))
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildFileNameWithRev,
    ebuildHasDevLangGoBdepend,
    ensureGoBdepend,
    nextRevisionVersion,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Go.Vendor (VendorOps (..), VendorResult (..), buildVendorTarball)
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( ApplyOutcome (..),
    Fetcher,
    PackageKey (..),
    PackagePolicy (..),
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
    aeAssetsRoot :: Maybe FilePath,
    aeGitHubToken :: Maybe Text,
    aeAssetsOwner :: Text,
    aeAssetsRepo :: Text,
    aeAssetsLock :: MVar (),
    aeJobs :: Int,
    -- | Mutated for the duration of phase-1 / commit panels.
    aeMulti :: MultiHandle,
    aeCommitStep :: StepHandle
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
      phase1 <-
        withMultiProgress pcfg "Updating packages" (length selected) $ \mh ->
          let env' = env {aeMulti = mh}
           in mapConcurrentlyN
                (aeJobs env')
                (applyPackagePhase1Tracked env' overlayRoot)
                selected
      let successes =
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
    successKey (ApplySuccess k _ _ _) = k
    successKey _ = PackageKey ""
    isSuccess ApplySuccess {} = True
    isSuccess _ = False

applyPackagePhase1Tracked ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  IO ApplyOutcome
applyPackagePhase1Tracked env overlayRoot entry = do
  let key = peKey entry
      mh = aeMulti env
  mhStart mh key
  outcome <- applyPackagePhase1 env overlayRoot entry
  case outcome of
    ApplySuccess {} -> mhSuccess mh key
    ApplySoftSkip _ reason -> mhFail mh key (shortReason reason)
    ApplyHardFail _ msg _ _ -> mhFail mh key (shortReason msg)
  pure outcome

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
  IO ApplyOutcome
applyPackagePhase1 env overlayRoot entry =
  case lookupPolicy (peKey entry) of
    Nothing ->
      pure $ ApplySoftSkip (peKey entry) "no hardcoded policy for package"
    Just policy ->
      case policyTechnique policy of
        Unsupported reason ->
          pure $
            ApplySoftSkip
              (peKey entry)
              ("unsupported update technique: " <> reason)
        GitMvAndManifest ->
          applyGitMv env overlayRoot entry (policySource policy)
        GoVendorAndAssets mSub ->
          applyGoVendor env overlayRoot entry (policySource policy) mSub

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
              pure $ ApplySuccess key local remote paths

------------------------------------------------------------------------
-- GoVendorAndAssets
------------------------------------------------------------------------

applyGoVendor ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  Maybe FilePath ->
  IO ApplyOutcome
applyGoVendor env overlayRoot entry src mSub = do
  let key = peKey entry
      local = peLocal entry
      oldPath = pePath entry
      mh = aeMulti env
  case src of
    GitHub owner repo prefix -> do
      mhStatus mh key "fetching"
      fetched <- aeFetcher env src
      case fetched of
        Left err ->
          pure $ ApplyHardFail key ("fetch failed: " <> err) False False
        Right remote -> do
          content <- TIO.readFile oldPath
          let parameterized = assetsSrcUriParameterized content
              hasGoBdepend = ebuildHasDevLangGoBdepend content
              -- Same-PV content fix when SRC_URI or Go BDEPEND still needs work.
              needsSamePvFix = not parameterized || not hasGoBdepend
          case comparePV local remote of
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
            Just EQ
              | not needsSamePvFix ->
                  pure $ ApplySoftSkip key "already at latest upstream version"
            Just EQ ->
              goPublishAndOverlay
                env
                overlayRoot
                entry
                owner
                repo
                prefix
                mSub
                local
                (nextRevisionVersion local)
            Just LT ->
              goPublishAndOverlay
                env
                overlayRoot
                entry
                owner
                repo
                prefix
                mSub
                local
                ( case remote of
                    Numeric comps _ -> Numeric comps Nothing
                    Raw t -> Raw t
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
    _ ->
      pure $
        ApplyHardFail
          key
          "GoVendorAndAssets requires a GitHub update source"
          False
          False

goPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  EbuildVersion ->
  EbuildVersion ->
  IO ApplyOutcome
goPublishAndOverlay env overlayRoot entry owner repo prefix mSub local targetVer = do
  let key = peKey entry
      pn = pePN entry
      pvNoRev = renderPVNoRev targetVer
      tarballName = vendorTarballName pn pvNoRev
      mh = aeMulti env
  case (aeAssetsRoot env, aeGitHubToken env) of
    (Nothing, _) ->
      pure $
        ApplyHardFail
          key
          "mndz-overlay-assets-path is required for Go vendor packages"
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
        Just (category, _) ->
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
                    mhStatus mh key "regenerating manifest"
                    overlayAfterAssets
                      env
                      overlayRoot
                      entry
                      local
                      targetVer
                      digests
                      tarballName
                      mGoVer

overlayAfterAssets ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  EbuildVersion ->
  EbuildVersion ->
  FileDigests ->
  FilePath ->
  Maybe Text ->
  IO ApplyOutcome
overlayAfterAssets env overlayRoot entry local targetVer digests tarballName mGoVer = do
  let key = peKey entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      orphan = True
  ebuildRel <- relativeOverlayPath overlayRoot oldPath
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
      content <- TIO.readFile oldPath
      let parameterized = parameterizeAssetsSrcUri pn content
      contentFixed <- case mGoVer of
        Nothing -> pure (Right parameterized)
        Just goVer -> pure (ensureGoBdepend goVer parameterized)
      case contentFixed of
        Left err -> pure $ ApplyHardFail key err False orphan
        Right fixed -> do
          let newName = ebuildFileNameWithRev pn targetVer
              newPath = pkgDir </> newName
          existsNew <- doesFileExist newPath
          if existsNew && takeFileName oldPath /= newName
            then
              pure $
                ApplyHardFail
                  key
                  ("target ebuild already exists: " <> T.pack newName)
                  False
                  orphan
            else do
              TIO.writeFile newPath fixed
              renamed <-
                if takeFileName oldPath == newName
                  then pure False
                  else do
                    removeFile oldPath
                    pure True
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
                                if renamed
                                  then [ebuildRel, newRel, manRel]
                                  else [newRel, manRel]
                          pure $ ApplySuccess key local targetVer paths
                      | otherwise ->
                          pure $
                            ApplyHardFail
                              key
                              "Manifest SHA512 does not match published vendor tarball"
                              True
                              orphan

commitSuccesses ::
  GitOps ->
  StepHandle ->
  FilePath ->
  [ApplyOutcome] ->
  IO [ApplyOutcome]
commitSuccesses gitOps step overlayRoot = mapM commitOne
  where
    commitOne (ApplySuccess key local remote paths) = do
      shStep step (packageKeyText key)
      let msg = packageKeyText key <> ": " <> renderPV remote
      result <- goAddAndCommit gitOps overlayRoot paths msg
      pure $ case result of
        Right () -> ApplySuccess key local remote paths
        Left err -> ApplyHardFail key err False False
    commitOne other = pure other
