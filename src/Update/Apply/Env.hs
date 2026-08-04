{-# LANGUAGE OverloadedStrings #-}

-- | Apply environment and ebuild runner shared by apply submodules.
module Update.Apply.Env
  ( EbuildRunner,
    productionEbuildRunner,
    mkEbuildRunner,
    ApplyEnv (..),
  )
where

import CLI.Progress (MultiHandle)
import Control.Concurrent.MVar (MVar)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import Update.Assets.Release (ReleaseOps)
import Update.Bun.Cache (BunCacheOps)
import Update.Cargo.Crates (CargoOps)
import Update.Deps.Plan (DepsPlanOps)
import Update.Distfiles
  ( ebuildManifestEnv,
    enrichEbuildManifestError,
  )
import Update.Git (GitOps)
import Update.Go.Plan (PlanOps)
import Update.Go.Vendor (VendorOps)
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (NpmCacheOps)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Sbcl.Deps (SbclDepsOps)
import Update.Types (Fetcher)

type EbuildRunner = FilePath -> FilePath -> IO (Either Text ())

-- | Build ebuild runner over an injectable command runner (shell mode).
-- Sets @DISTDIR@ to the effective manager distfiles path and empties
-- @GENTOO_MIRRORS@; merges onto the full parent environment.
mkEbuildRunner :: FilePath -> CommandRunner -> EbuildRunner
mkEbuildRunner distDir run pkgDir ebuildFileName = do
  env0 <- getEnvironment
  let cmd = "ebuild ./" <> ebuildFileName <> " manifest"
  res <-
    run
      ProcessRequest
        { prMode = ShellCmd cmd,
          prCwd = Just pkgDir,
          prEnv = Just (ebuildManifestEnv distDir env0),
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (enrichEbuildManifestError distDir (T.pack (prStderr res)))

-- | Production ebuild runner for the given effective manager distfiles path.
productionEbuildRunner :: FilePath -> EbuildRunner
productionEbuildRunner distDir = mkEbuildRunner distDir productionCommandRunner

data ApplyEnv = ApplyEnv
  { aeFetcher :: Fetcher,
    aeGitOps :: GitOps,
    aeEbuildRunner :: EbuildRunner,
    aeEgencacheRunner :: EgencacheRunner,
    aeVendorOps :: VendorOps,
    aeNpmCacheOps :: NpmCacheOps,
    aeBunCacheOps :: BunCacheOps,
    aeCargoOps :: CargoOps,
    aeSbclDepsOps :: SbclDepsOps,
    aeReleaseOps :: ReleaseOps,
    -- | Write models.dev API JSON body to the given destination path.
    aeFetchModelsDev :: FilePath -> IO (Either Text FilePath),
    aeAssetsRoot :: Maybe FilePath,
    aeGitHubToken :: Maybe Text,
    aeAssetsOwner :: Text,
    aeAssetsRepo :: Text,
    aeAssetsLock :: MVar (),
    -- | Serializes package @egencache@ + overlay @git add@ / signed @git commit@.
    aeOverlayLock :: MVar (),
    aeJobs :: Int,
    aeMulti :: MultiHandle,
    aePlanOps :: PlanOps,
    aeDepsPlanOps :: DepsPlanOps
  }
