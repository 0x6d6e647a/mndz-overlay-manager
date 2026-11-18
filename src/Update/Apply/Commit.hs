{-# LANGUAGE OverloadedStrings #-}

-- | Signed overlay commit helpers under the overlay lock.
module Update.Apply.Commit
  ( signedOverlayCommit,
    CommitOutcome (..),
    commitAndPushOverlay,
    pushingOverlayStatus,
    egencacheUnitPaths,
    unitCommitMessage,
    pruneCommitMessage,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar (withMVar)
import Data.Containers.ListUtils (nubOrd)
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text)
import Update.Apply.Env (ApplyEnv (..), PublishControl (..))
import Update.Git (GitOps (..))
import Update.Md5Cache (runPackageEgencache)
import Update.Types (PackageKey (..), packageKeyText)

-- | Stage unit paths and create a signed overlay commit under the overlay lock.
-- GPG readiness runs inside @goAddAndCommit@ (production GitOps).
signedOverlayCommit ::
  ApplyEnv ->
  FilePath ->
  [FilePath] ->
  Text ->
  IO (Either Text ())
signedOverlayCommit env overlayRoot paths msg =
  withMVar (aeOverlayLock env) $ \() ->
    goAddAndCommit (aeGitOps env) overlayRoot paths msg

pushingOverlayStatus :: Text
pushingOverlayStatus = "pushing overlay"

-- | Result of a unit's commit and overlay push.
data CommitOutcome
  = Committed
  | -- | Publishing had halted; nothing was committed. The halting cause.
    CommitHalted Text
  | CommitFailed Text
  | -- | The commit exists; the push (or its Git Operations check) failed and
    -- publishing is now halted.
    PushFailed Text
  deriving (Eq, Show)

-- | Under the overlay lock: refuse when publishing halted, create the
-- signed commit, apply the Git Operations check, and push the overlay's
-- current branch. A failed push sets the halt flag. Commit order and push
-- order are therefore the same.
commitAndPushOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageKey ->
  [FilePath] ->
  Text ->
  IO CommitOutcome
commitAndPushOverlay env overlayRoot key paths msg =
  withMVar (aeOverlayLock env) $ \() -> do
    let publish = aePublish env
    halted <- readIORef (pcHalted publish)
    case halted of
      Just cause -> pure (CommitHalted cause)
      Nothing -> do
        committed <- goAddAndCommit (aeGitOps env) overlayRoot paths msg
        case committed of
          Left err -> pure (CommitFailed err)
          Right () -> do
            mhStatus (aeMulti env) key pushingOverlayStatus
            health <- aeGitOperationsHealth env
            pushed <- either (pure . Left) (const (pcPushOverlay publish overlayRoot)) health
            case pushed of
              Right () -> pure Committed
              Left err -> do
                writeIORef (pcHalted publish) (Just ("the overlay push of \"" <> msg <> "\" failed: " <> err))
                pure (PushFailed err)

-- | Package-scoped @egencache@ under the overlay lock (no commit).
-- Returns unit paths plus md5-cache pathspecs.
egencacheUnitPaths ::
  ApplyEnv ->
  FilePath ->
  PackageKey ->
  [FilePath] ->
  IO (Either Text [FilePath])
egencacheUnitPaths env overlayRoot key unitPaths =
  withMVar (aeOverlayLock env) $ \() -> do
    cacheResult <-
      runPackageEgencache
        (aeEgencacheRunner env)
        overlayRoot
        key
        (Just (aeJobs env))
    pure $ case cacheResult of
      Left err -> Left err
      Right cachePaths -> Right (nubOrd (unitPaths <> cachePaths))

-- | Commit message for a successful apply unit: @category/package: version@.
unitCommitMessage :: PackageKey -> Text -> Text
unitCommitMessage key verText = packageKeyText key <> ": " <> verText

-- | Prune unit commit message when extras were removed.
pruneCommitMessage :: PackageKey -> Text
pruneCommitMessage key = packageKeyText key <> ": prune obsolete ebuilds"
