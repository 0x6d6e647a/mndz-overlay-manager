{-# LANGUAGE OverloadedStrings #-}

-- | GitMvAndManifest apply path and md5-cache gate before mutation.
module Update.Apply.GitMv
  ( applyGitMv,
    requirePackageMd5Cache,
    newEbuildFileName,
  )
where

import CLI.Progress (MultiHandle (..))
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, comparePV, prettyVersion, renderPV, renderPVNoRev)
import System.Directory (doesFileExist, renameFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit (egencacheAndSignedCommit, unitCommitMessage)
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.Check (PackageEntry (..))
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Md5Cache (inspectPackageCache)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource,
    packageKeyText,
    splitPackageKey,
  )

-- | Hard-fail without mutation when package md5-cache is incomplete or mismatched.
requirePackageMd5Cache ::
  FilePath ->
  PackageKey ->
  FilePath ->
  IO (Either ApplyUnitError ())
requirePackageMd5Cache overlayRoot key pkgDir =
  case splitPackageKey key of
    Nothing ->
      pure (Left (ApplyInvalidPackageKey (Just (packageKeyText key))))
    Just (category, pn) -> do
      inspected <- inspectPackageCache overlayRoot category pn pkgDir
      pure $ case inspected of
        Right () -> Right ()
        Left issue -> Left (ApplyMd5CacheGate key issue)

newEbuildFileName :: Text -> EbuildVersion -> FilePath
newEbuildFileName pn remote =
  T.unpack pn <> "-" <> T.unpack (renderPVNoRev remote) <> ".ebuild"

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
          gitMvDo env key local remote oldPath pkgDir pn overlayRoot
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
  ApplyEnv ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  Text ->
  FilePath ->
  IO ApplyOutcome
gitMvDo env key local remote oldPath pkgDir pn overlayRoot = do
  let gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
  cacheGate <- requirePackageMd5Cache overlayRoot key pkgDir
  case cacheGate of
    Left unitErr -> pure $ applyUnitHardFail key unitErr False False
    Right () -> do
      ebuildRel <- relativeOverlayPath overlayRoot oldPath
      let manifestAbs = pkgDir </> "Manifest"
      manRel0 <- relativeOverlayPath overlayRoot manifestAbs
      dirty' <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
      case dirty' of
        Left err -> pure $ ApplyHardFail key err False False
        Right True ->
          pure $ applyUnitHardFail key ApplyDirtyInvolvedPaths False False
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
                  let unitPaths =
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
                      msg = unitCommitMessage key (renderPV remote)
                  committed <-
                    egencacheAndSignedCommit env overlayRoot key unitPaths msg
                  pure $ case committed of
                    Right paths -> ApplySuccess key lines_ paths
                    Left err -> ApplyHardFail key err True False
