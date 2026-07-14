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
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), comparePV, prettyVersion)
import System.Directory (doesFileExist, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process
  ( CreateProcess (cwd),
    readCreateProcessWithExitCode,
    shell,
  )
import Update.Check (PackageEntry (..))
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( ApplyOutcome (..),
    Fetcher,
    PackageKey (..),
    PackagePolicy (..),
    UpdateSource,
    UpdateTechnique (..),
    outcomeIsHardFail,
    packageKeyText,
  )

-- | Run @ebuild ./file.ebuild manifest@ with cwd = package directory.
type EbuildRunner = FilePath -> FilePath -> IO (Either Text ())

productionEbuildRunner :: EbuildRunner
productionEbuildRunner pkgDir ebuildFileName = do
  let cmd = "ebuild ./" <> ebuildFileName <> " manifest"
      proc = (shell cmd) {cwd = Just pkgDir}
  (code, _out, err) <- readCreateProcessWithExitCode proc ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("ebuild manifest failed: " <> T.pack err)

-- | Version string for filenames and commit messages (no leading v, no -rN).
renderPVNoRev :: EbuildVersion -> Text
renderPVNoRev (Raw t) = t
renderPVNoRev (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)

-- | @pn-NEWPV.ebuild@
newEbuildFileName :: Text -> EbuildVersion -> FilePath
newEbuildFileName pn remote =
  T.unpack pn <> "-" <> T.unpack (renderPVNoRev remote) <> ".ebuild"

-- | True if any hard failure in outcomes.
foldExitHardFail :: [ApplyOutcome] -> Bool
foldExitHardFail = any outcomeIsHardFail

-- | Full update pipeline: phase 1 parallel, phase 2 serial signed commits.
--
-- If the overlay is not a git work tree, returns a single hard-fail outcome
-- with an empty package key (spine should treat as fatal).
applyOverlay ::
  Fetcher ->
  GitOps ->
  EbuildRunner ->
  FilePath ->
  [PackageEntry] ->
  -- | When Just, only these keys; Nothing means all entries.
  Maybe [PackageKey] ->
  IO [ApplyOutcome]
applyOverlay fetch gitOps ebuildRun overlayRoot entries mFilter = do
  isGit <- goIsWorkTree gitOps overlayRoot
  if not isGit
    then
      pure
        [ ApplyHardFail
            (PackageKey "")
            "overlay path is not a git work tree"
            False
        ]
    else do
      let selected = case mFilter of
            Nothing -> entries
            Just keys -> [e | e <- entries, peKey e `elem` keys]
      phase1 <-
        mapConcurrently
          (applyPackagePhase1 fetch gitOps ebuildRun overlayRoot)
          selected
      let successes =
            sortOn
              (packageKeyText . successKey)
              [o | o@ApplySuccess {} <- phase1]
          others = [o | o <- phase1, not (isSuccess o)]
      committed <- commitSuccesses gitOps overlayRoot successes
      pure (others <> committed)
  where
    successKey (ApplySuccess k _ _ _) = k
    successKey _ = PackageKey ""
    isSuccess ApplySuccess {} = True
    isSuccess _ = False

-- | Phase 1 for one package: policy, fetch, dirty, rename, manifest.
applyPackagePhase1 ::
  Fetcher ->
  GitOps ->
  EbuildRunner ->
  FilePath ->
  PackageEntry ->
  IO ApplyOutcome
applyPackagePhase1 fetch gitOps ebuildRun overlayRoot entry =
  case lookupPolicy (peKey entry) of
    Nothing ->
      pure $
        ApplySoftSkip
          (peKey entry)
          "no hardcoded policy for package"
    Just policy ->
      case policyTechnique policy of
        Unsupported reason ->
          pure $
            ApplySoftSkip
              (peKey entry)
              ("unsupported update technique: " <> reason)
        GitMvAndManifest ->
          applyGitMv fetch gitOps ebuildRun overlayRoot entry (policySource policy)

applyGitMv ::
  Fetcher ->
  GitOps ->
  EbuildRunner ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  IO ApplyOutcome
applyGitMv fetch gitOps ebuildRun overlayRoot entry src = do
  let key = peKey entry
      local = peLocal entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
  fetched <- fetch src
  case fetched of
    Left err ->
      pure $ ApplyHardFail key ("fetch failed: " <> err) False
    Right remote ->
      case comparePV local remote of
        Just LT -> doApply key local remote oldPath pkgDir
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
  where
    doApply key local remote oldPath pkgDir = do
      ebuildRel <- relativeOverlayPath overlayRoot oldPath
      let manifestAbs = pkgDir </> "Manifest"
      manifestRel <- relativeOverlayPath overlayRoot manifestAbs
      dirty <- goPathsDirty gitOps overlayRoot [ebuildRel, manifestRel]
      case dirty of
        Left err -> pure $ ApplyHardFail key err False
        Right True ->
          pure $
            ApplyHardFail
              key
              "involved paths are dirty (newest ebuild and/or Manifest)"
              False
        Right False -> do
          let newName = newEbuildFileName (pePN entry) remote
              newPath = pkgDir </> newName
          existsNew <- doesFileExist newPath
          if existsNew && takeFileName oldPath /= newName
            then
              pure $
                ApplyHardFail
                  key
                  ("target ebuild already exists: " <> T.pack newName)
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
                Left err ->
                  pure $
                    ApplyHardFail
                      key
                      err
                      renamed
                Right () -> do
                  newRel <- relativeOverlayPath overlayRoot newPath
                  manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
                  -- Stage the old ebuild path as well so git records the
                  -- deletion (plain rename leaves a D unstaged if we only
                  -- add the new name). git add on a deleted tracked path
                  -- stages the removal; together with newRel this is a rename.
                  let paths =
                        if renamed
                          then [ebuildRel, newRel, manRel]
                          else [newRel, manRel]
                  pure $
                    ApplySuccess key local remote paths

-- | Phase 2: signed commits for successful applies (already sorted by caller).
commitSuccesses ::
  GitOps ->
  FilePath ->
  [ApplyOutcome] ->
  IO [ApplyOutcome]
commitSuccesses gitOps overlayRoot = mapM commitOne
  where
    commitOne (ApplySuccess key local remote paths) = do
      let msg =
            packageKeyText key
              <> ": "
              <> renderPVNoRev remote
      result <- goAddAndCommit gitOps overlayRoot paths msg
      pure $ case result of
        Right () -> ApplySuccess key local remote paths
        Left err -> ApplyHardFail key err False
    commitOne other = pure other
