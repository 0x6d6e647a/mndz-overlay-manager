{-# LANGUAGE OverloadedStrings #-}

-- | Apply environment and ebuild runner shared by apply submodules.
module Update.Apply.Env
  ( EbuildRunner,
    productionEbuildRunner,
    ApplyEnv (..),
  )
where

import CLI.Progress (MultiHandle)
import Control.Concurrent.MVar (MVar)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (cwd),
    readCreateProcessWithExitCode,
    shell,
  )
import Update.Assets.Release (ReleaseOps)
import Update.Bun.Cache (BunCacheOps)
import Update.Cargo.Crates (CargoOps)
import Update.Deps.Plan (DepsPlanOps)
import Update.Git (GitOps)
import Update.Go.Plan (PlanOps)
import Update.Go.Vendor (VendorOps)
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (NpmCacheOps)
import Update.Types (Fetcher)

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
    aeEgencacheRunner :: EgencacheRunner,
    aeVendorOps :: VendorOps,
    aeNpmCacheOps :: NpmCacheOps,
    aeBunCacheOps :: BunCacheOps,
    aeCargoOps :: CargoOps,
    aeReleaseOps :: ReleaseOps,
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
