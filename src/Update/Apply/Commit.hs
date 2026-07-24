{-# LANGUAGE OverloadedStrings #-}

-- | Signed overlay commit helpers under the overlay lock.
module Update.Apply.Commit
  ( signedOverlayCommit,
    egencacheAndSignedCommit,
    unitCommitMessage,
    pruneCommitMessage,
  )
where

import Control.Concurrent.MVar (withMVar)
import Data.Containers.ListUtils (nubOrd)
import Data.Text (Text)
import Update.Apply.Env (ApplyEnv (..))
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

-- | Package-scoped @egencache@ then signed commit under the overlay lock.
-- Returns the full staged path list (unit paths plus md5-cache pathspecs).
egencacheAndSignedCommit ::
  ApplyEnv ->
  FilePath ->
  PackageKey ->
  [FilePath] ->
  Text ->
  IO (Either Text [FilePath])
egencacheAndSignedCommit env overlayRoot key unitPaths msg =
  withMVar (aeOverlayLock env) $ \() -> do
    cacheResult <-
      runPackageEgencache
        (aeEgencacheRunner env)
        overlayRoot
        key
        (Just (aeJobs env))
    case cacheResult of
      Left err -> pure (Left err)
      Right cachePaths -> do
        let paths = nubOrd (unitPaths <> cachePaths)
        committed <- goAddAndCommit (aeGitOps env) overlayRoot paths msg
        pure $ case committed of
          Left err -> Left err
          Right () -> Right paths

-- | Commit message for a successful apply unit: @category/package: version@.
unitCommitMessage :: PackageKey -> Text -> Text
unitCommitMessage key verText = packageKeyText key <> ": " <> verText

-- | Prune unit commit message when extras were removed.
pruneCommitMessage :: PackageKey -> Text
pruneCommitMessage key = packageKeyText key <> ": prune obsolete ebuilds"
