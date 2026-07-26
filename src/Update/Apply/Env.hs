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
import System.Exit (ExitCode (..))
import Update.Assets.Release (ReleaseOps)
import Update.Bun.Cache (BunCacheOps)
import Update.Cargo.Crates (CargoOps)
import Update.Deps.Plan (DepsPlanOps)
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
import Update.Types (Fetcher)

type EbuildRunner = FilePath -> FilePath -> IO (Either Text ())

-- | Build ebuild runner over an injectable command runner (shell mode).
mkEbuildRunner :: CommandRunner -> EbuildRunner
mkEbuildRunner run pkgDir ebuildFileName = do
  let cmd = "ebuild ./" <> ebuildFileName <> " manifest"
  res <-
    run
      ProcessRequest
        { prMode = ShellCmd cmd,
          prCwd = Just pkgDir,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("ebuild manifest failed: " <> T.pack (prStderr res))

productionEbuildRunner :: EbuildRunner
productionEbuildRunner = mkEbuildRunner productionCommandRunner

data ApplyEnv = ApplyEnv
  { aeFetcher :: Fetcher,
    aeGitOps :: GitOps,
    aeEbuildRunner :: EbuildRunner,
    aeEgencacheRunner :: EgencacheRunner,
    aeVendorOps :: VendorOps,
    aeNpmCacheOps :: NpmCacheOps,
    aeBunCacheOps :: BunCacheOps,
    aeCargoOps :: CargoOps,
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
