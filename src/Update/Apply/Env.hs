{-# LANGUAGE OverloadedStrings #-}

-- | Apply environment and ebuild runner shared by apply submodules.
module Update.Apply.Env
  ( EbuildRunner,
    productionEbuildRunner,
    mkEbuildRunner,
    ApplyEnv (..),
    HoldRequest (..),
    PublishControl (..),
    newPublishControl,
  )
where

import CLI.Jobs (PackSlot)
import CLI.Progress (MultiHandle)
import Control.Concurrent.MVar (MVar)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import Update.Assets.Release (ReleaseOps)
import Update.AtomClosure (AtomClosureSession)
import Update.Bun.Cache (BunCacheOps)
import Update.Cargo.Crates (CargoOps)
import Update.CheckCache (CheckCacheHandle)
import Update.Deps.Plan (DepsPlanOps)
import Update.Distfiles
  ( ebuildManifestEnv,
    enrichEbuildManifestError,
  )
import Update.Gate (GateHandle)
import Update.Git (GitOps)
import Update.Go.Plan (PlanOps)
import Update.Go.Vendor (VendorOps)
import Update.Held (AssetRecord, GateRunRecord, HeldReason)
import Update.Http (HttpLbs)
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (NpmCacheOps)
import Update.OverlayTree (TreeLock)
import Update.Pdm.Deps (PdmDepsOps)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker (MaterializeDockerCfg, ToolsSession, toolsSessionRunner)
import Update.Sbcl.Deps (SbclDepsOps)
import Update.TempWorkspace (RunRoot)
import Update.Types (ApplyOutcome, Fetcher, PackageKey)
import Update.Uv.Deps (UvDepsOps)

type EbuildRunner = FilePath -> FilePath -> IO (Either Text ())

-- | Build ebuild runner over an injectable command runner (shell mode).
-- Sets @DISTDIR@ to the effective manager distfiles path and empties
-- @GENTOO_MIRRORS@; the runner's process keeps its other variables.
mkEbuildRunner :: FilePath -> CommandRunner -> EbuildRunner
mkEbuildRunner distDir run pkgDir ebuildFileName = do
  let cmd = "ebuild ./" <> ebuildFileName <> " manifest"
  res <-
    run
      ProcessRequest
        { prMode = ShellCmd cmd,
          prCwd = Just pkgDir,
          prEnv = Just (ebuildManifestEnv distDir),
          prStdin = "",
          prMeasure = Timed
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (enrichEbuildManifestError distDir (T.pack (prStderr res)))

-- | Production ebuild runner: @ebuild … manifest@ in the run's Portage tools
-- container, with the effective manager distfiles path.
productionEbuildRunner :: ToolsSession -> FilePath -> EbuildRunner
productionEbuildRunner tools distDir pkgDir ebuildFileName = do
  -- The container binds distfiles at its absolute host path.
  distAbs <- makeAbsolute distDir
  mkEbuildRunner distAbs (toolsSessionRunner tools) pkgDir ebuildFileName

data ApplyEnv = ApplyEnv
  { aeFetcher :: Fetcher,
    -- | Raw HTTP for apply-time feed reads (grok-bot commit pin). Tests inject this.
    aeHttpLbs :: HttpLbs,
    aeGitOps :: GitOps,
    aeEbuildRunner :: EbuildRunner,
    -- | Copy a full-path unit's built distfiles into the manager @DISTDIR@
    -- before its Manifest is generated.
    aeSeedDistfiles :: [FilePath] -> IO (Either Text ()),
    aeEgencacheRunner :: EgencacheRunner,
    aeVendorOps :: VendorOps,
    aeNpmCacheOps :: NpmCacheOps,
    aeBunCacheOps :: BunCacheOps,
    aeCargoOps :: CargoOps,
    aeSbclDepsOps :: SbclDepsOps,
    aeUvDepsOps :: UvDepsOps,
    aePdmDepsOps :: PdmDepsOps,
    aeReleaseOps :: ReleaseOps,
    aeAssetsRoot :: Maybe FilePath,
    aeGitHubToken :: Maybe Text,
    aeAssetsOwner :: Text,
    aeAssetsRepo :: Text,
    aeAssetsLock :: MVar (),
    -- | Serializes package @egencache@ + overlay @git add@ / signed @git commit@.
    aeOverlayLock :: MVar (),
    -- | Overlay ebuild observation and the publish that follows from it.
    aeTreeLock :: TreeLock,
    aeJobs :: Int,
    -- | Capacity-1 lock shared by this update's DepsAndAssets tar/xz packs.
    aePackSlot :: PackSlot,
    aeMulti :: MultiHandle,
    aePlanOps :: PlanOps,
    aeDepsPlanOps :: DepsPlanOps,
    -- | Product temp workspace run root for heavy materialize scratch.
    aeTempRun :: RunRoot,
    -- | Shared check cache (disabled handle is a no-op).
    aeCheckCache :: CheckCacheHandle,
    -- | When @Just@, full-path materialize opens a per-unit Docker session
    -- (image\/user\/run-id plus the inner @docker@ CLI runner). @Nothing@
    -- keeps injected @ae*Ops@ (tests).
    aeMaterializeDocker :: Maybe (MaterializeDockerCfg, CommandRunner),
    -- | Overlay-internal atom-closure wait/refuse session for this apply
    -- run. @Nothing@ checks current disk only (no wait).
    aeAtomClosure :: Maybe AtomClosureSession,
    -- | Git Operations Statuspage check immediately before assets @git push@.
    aeGitOperationsHealth :: IO (Either Text ()),
    -- | Kill the session agent before a successful run root is deleted.
    aeReleaseSigningSession :: IO (),
    -- | Smoke gate for each unit before it publishes or commits.
    aeGate :: GateHandle,
    -- | Save a unit's uncommitted work and roll it back; 'Right' is the held
    -- entry. Takes the overlay critical section itself.
    aeHold :: HoldRequest -> IO (Either Text FilePath),
    aePublish :: PublishControl,
    -- | Units past their gate's start and not yet finished, with the action
    -- that holds each as interrupted.
    aeInFlight :: IORef (Map PackageKey (IO ApplyOutcome))
  }

-- | A unit to hold: what @held.json@ records beyond the run's own context.
data HoldRequest = HoldRequest
  { hrKey :: PackageKey,
    hrPv :: Text,
    hrTechnique :: Text,
    -- | @full@ or @reuse@ for a DepsAndAssets unit.
    hrPath :: Maybe Text,
    hrRuns :: [GateRunRecord],
    hrReason :: HeldReason,
    hrDetail :: Text,
    hrRelease :: Maybe Text,
    hrAssets :: [AssetRecord],
    -- | Overlay-relative paths the unit changed.
    hrPaths :: [FilePath],
    hrDistfiles :: [FilePath],
    hrLogDirs :: [FilePath]
  }
  deriving (Eq, Show)

-- | Overlay push and the run-wide stop on push failure.
data PublishControl = PublishControl
  { -- | The push failure that halted publishing, once one has.
    pcHalted :: IORef (Maybe Text),
    -- | Push the overlay's current branch to its upstream.
    pcPushOverlay :: FilePath -> IO (Either Text ()),
    -- | Verify a unit's published assets (download prefix, overlay root,
    -- package, PVR, asset names) at the URLs its ebuild names; 'Left' is
    -- the URL and mismatch.
    pcVerify :: Text -> FilePath -> PackageKey -> Text -> [Text] -> IO (Either (Text, Text) ()),
    -- | 'Just' the reason no further unit may start (gate prerequisites
    -- failed). Halted publishing is checked separately.
    pcStopStarting :: IO (Maybe Text)
  }

-- | Halt flag unset, the given push and verification, no other stop.
newPublishControl ::
  (FilePath -> IO (Either Text ())) ->
  (Text -> FilePath -> PackageKey -> Text -> [Text] -> IO (Either (Text, Text) ())) ->
  IO PublishControl
newPublishControl push verify = do
  halted <- newIORef Nothing
  pure
    PublishControl
      { pcHalted = halted,
        pcPushOverlay = push,
        pcVerify = verify,
        pcStopStarting = fmap (fmap ("publishing halted because " <>)) (readIORef halted)
      }
