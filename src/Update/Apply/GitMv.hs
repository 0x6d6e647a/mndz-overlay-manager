{-# LANGUAGE OverloadedStrings #-}

-- | GitMvAndManifest apply path and md5-cache gate before mutation.
module Update.Apply.GitMv
  ( applyGitMv,
    applyGitMvWithRemote,
    applyGitMvFilesWithRemote,
    commitPendingGitMv,
    PendingGitMvCommit (..),
    requirePackageMd5Cache,
    newEbuildFileName,
  )
where

import CLI.Progress (MultiHandle (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Version (EbuildVersion, comparePV, prettyVersion, renderPV, renderPVNoRev)
import System.Directory (doesFileExist, renameFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit
  ( egencacheUnitPaths,
    signedOverlayCommit,
    unitCommitMessage,
  )
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.AtomClosure
  ( ensureAtomClosedForWrite,
    guardGitMvRenameAway,
  )
import Update.Check (PackageEntry (..))
import Update.CheckCache
  ( computeFingerprintFromDir,
    lookupLatest,
    recordFetch,
    recordHit,
    storeLatest,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Md5Cache (inspectPackageCache)
import Update.OverlayWaves
  ( committingOverlayStatus,
    regeneratingManifestStatus,
  )
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource,
    packageKeyText,
    splitPackageKey,
  )

-- | GitMv file work finished; signed overlay commit not yet created.
data PendingGitMvCommit = PendingGitMvCommit
  { pgcKey :: PackageKey,
    pgcLines :: [SuccessLine],
    pgcPaths :: [FilePath],
    pgcMessage :: Text
  }
  deriving (Eq, Show)

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
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      mh = aeMulti env
      cache = aeCheckCache env
  mhStatus mh key "fetching"
  fp <- computeFingerprintFromDir src pkgDir pn
  mCached <- lookupLatest cache key fp
  fetched <- case mCached of
    Just remote -> do
      recordHit cache
      pure (Right remote)
    Nothing -> do
      recordFetch cache
      result <- aeFetcher env src
      case result of
        Right remote -> do
          storeLatest cache key fp remote
          pure (Right remote)
        Left err -> pure (Left err)
  case fetched of
    Left err ->
      pure $ ApplyHardFail key ("fetch failed: " <> err) False False
    Right remote -> applyGitMvWithRemote env overlayRoot entry src remote

-- | Mutate using a plan-phase remote version (skip re-fetch).
applyGitMvWithRemote ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EbuildVersion ->
  IO ApplyOutcome
applyGitMvWithRemote env overlayRoot entry src remote = do
  result <- applyGitMvFilesWithRemote env overlayRoot entry src remote
  case result of
    Left outcome -> pure outcome
    Right pending -> commitPendingGitMv env overlayRoot pending

-- | Rename, @ebuild … manifest@, and package @egencache@ without committing.
--
-- 'Left' is a terminal skip/fail (or incomparable). 'Right' is emergeable
-- on disk; call 'commitPendingGitMv' for the signed overlay commit.
applyGitMvFilesWithRemote ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EbuildVersion ->
  IO (Either ApplyOutcome PendingGitMvCommit)
applyGitMvFilesWithRemote env overlayRoot entry src remote = do
  let key = peKey entry
      local = peLocal entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      mh = aeMulti env
      cache = aeCheckCache env
  case comparePV local remote of
    Just LT -> do
      mhStatus mh key "applying"
      result <- gitMvFiles env key local remote oldPath pkgDir pn overlayRoot
      case result of
        Right pending -> do
          fp' <- computeFingerprintFromDir src pkgDir pn
          storeLatest cache key fp' remote
          pure (Right pending)
        Left outcome -> pure (Left outcome)
    Just EQ ->
      pure $ Left $ ApplySoftSkip key "already at latest upstream version"
    Just GT ->
      pure $
        Left $
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
        Left $
          ApplyHardFail
            key
            ( "incomparable versions: local="
                <> T.pack (show local)
                <> " remote="
                <> T.pack (show remote)
            )
            False
            False

-- | Create the signed overlay commit for previously finished GitMv file work.
commitPendingGitMv ::
  ApplyEnv ->
  FilePath ->
  PendingGitMvCommit ->
  IO ApplyOutcome
commitPendingGitMv env overlayRoot pending = do
  let key = pgcKey pending
      mh = aeMulti env
  mhStatus mh key committingOverlayStatus
  committed <-
    signedOverlayCommit env overlayRoot (pgcPaths pending) (pgcMessage pending)
  pure $ case committed of
    Right () -> ApplySuccess key (pgcLines pending) (pgcPaths pending)
    Left err -> ApplyHardFail key err True False

gitMvFiles ::
  ApplyEnv ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  Text ->
  FilePath ->
  IO (Either ApplyOutcome PendingGitMvCommit)
gitMvFiles env key local remote oldPath pkgDir pn overlayRoot = do
  let gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      mh = aeMulti env
  cacheGate <- requirePackageMd5Cache overlayRoot key pkgDir
  case cacheGate of
    Left unitErr ->
      pure $ Left $ applyUnitHardFail key unitErr False False
    Right () -> do
      ebuildRel <- relativeOverlayPath overlayRoot oldPath
      let manifestAbs = pkgDir </> "Manifest"
      manRel0 <- relativeOverlayPath overlayRoot manifestAbs
      dirty' <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
      case dirty' of
        Left err -> pure $ Left $ ApplyHardFail key err False False
        Right True ->
          pure $ Left $ applyUnitHardFail key ApplyDirtyInvolvedPaths False False
        Right False -> do
          let newName = newEbuildFileName pn remote
              newPath = pkgDir </> newName
          existsNew <- doesFileExist newPath
          if existsNew && takeFileName oldPath /= newName
            then
              pure $
                Left $
                  ApplyHardFail
                    key
                    ("target ebuild already exists: " <> T.pack newName)
                    False
                    False
            else do
              renameAway <-
                guardGitMvRenameAway
                  (aeAtomClosure env)
                  overlayRoot
                  key
                  local
                  remote
              case renameAway of
                Left err ->
                  pure $
                    Left $
                      applyUnitHardFail key (ApplyAtomClosure err) False False
                Right () -> do
                  toWrite <- TIO.readFile oldPath
                  closed <-
                    ensureAtomClosedForWrite
                      (aeAtomClosure env)
                      mh
                      overlayRoot
                      key
                      toWrite
                  case closed of
                    Left err ->
                      pure $
                        Left $
                          applyUnitHardFail key (ApplyAtomClosure err) False False
                    Right () -> do
                      renamed <-
                        if takeFileName oldPath == newName
                          then pure False
                          else do
                            renameFile oldPath newPath
                            pure True
                      mhStatus mh key regeneratingManifestStatus
                      manResult <- ebuildRun pkgDir newName
                      case manResult of
                        Left err ->
                          pure $ Left $ ApplyHardFail key err renamed False
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
                          ePaths <-
                            egencacheUnitPaths env overlayRoot key unitPaths
                          case ePaths of
                            Left err ->
                              pure $ Left $ ApplyHardFail key err True False
                            Right paths ->
                              pure $
                                Right
                                  PendingGitMvCommit
                                    { pgcKey = key,
                                      pgcLines = lines_,
                                      pgcPaths = paths,
                                      pgcMessage = msg
                                    }
