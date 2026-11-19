{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser
  ( ColorMode,
    Options (..),
    parseOptions,
    resolveColorMode,
    resolveJobs,
    showTopLevelHelpExit1,
  )
import CLI.Parser qualified as Cmd
import CLI.Progress
  ( ProgressConfig (..),
    StepHandle (..),
    mkProgressConfig,
    pauseActivePanel,
    progressEnabled,
    resumeActivePanel,
    withMultiProgress,
    withStepProgress,
  )
import Colog (LogAction, Message, WithLog, logError, logInfo, logWarning, usingLoggerT)
import Config.Loader
  ( configErrorMessage,
    defaultConfigPath,
    loadConfig,
    loadConfigAllowPlaintextToken,
  )
import Config.Types (OverlayConfig (..))
import Control.Concurrent.MVar (newMVar)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (forM, unless, void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson ((.=))
import Data.Bifunctor (first)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (for_)
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Logging.Bootstrap (LogHold, mkLogHold, mkLogger)
import Metrics.Container (productionCgroupRoots)
import Metrics.Core (Metrics (..), setCount, withSpan)
import Metrics.Process (timedRunner)
import Metrics.Run (RunSetup (..), invocationFor, withRunMetrics)
import Metrics.Sampler (productionSamplerConfig, startSampler)
import Metrics.Startup
  ( MetricsStart (..),
    commandName,
    metricsGate,
    productionMetricsStartupOps,
  )
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Validation (OverlayError (..), validateOverlay)
import Overlay.Version (EbuildVersion (..), prettyVersion)
import Process.Priority (EffectivePriority, PriorityRequest)
import Process.Priority.Apply (applyCommandPriority, productionThreadOps)
import Smoke.Ceilings (loadHostCeilings)
import Smoke.Check (SmokeDef)
import Smoke.CompileCache
  ( CacheUse (..),
    GoChecks,
    HelperCfg (..),
    PrepareCfg (..),
    PrepareResult (..),
    compileCacheLockPath,
    newGoChecks,
    prepareCompileCache,
    recordCacheReport,
    recordCleanup,
  )
import Smoke.Container
  ( FailStage (..),
    OverlayMount (..),
    RunOutcome (..),
    RunResult (..),
    SmokeContainerCfg (..),
    performRun,
    runSandboxProbe,
    withSmokeContainer,
  )
import Smoke.Definitions (lookupSmokeDef)
import Smoke.Image
  ( SmokeImageConfig (..),
    defaultSmokeCacheDir,
    ensureSmokeImage,
    smokeImageTag,
  )
import Smoke.Plan (PackageInput (..), PlannedItem (..), SmokeRun (..), laneRuntimeFor, planSmokeRuns, runAtom)
import Smoke.Preflight (smokePreflight)
import Smoke.Run
  ( SmokeOps (..),
    SmokeSummary (..),
    missingDefinitions,
    pruneRunLogs,
    runSmoke,
    smokeLogsRoot,
    summaryLines,
    uncommittedPackages,
  )
import Smoke.Tree (SnapshotCfg (..), dockerSafe, snapshotTag, sweepStaleSnapshots, withSnapshot)
import System.Directory (createDirectoryIfMissing, findExecutable, makeAbsolute, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.User (getRealUserID)
import Update.Apply (foldExitHardFail, productionEbuildRunner)
import Update.Assets.Release (ReleaseOps (..), productionReleaseOpsWithLatch)
import Update.Assets.Verify (verifyPublishedAsset, verifyUnitAssets)
import Update.Auth
  ( decryptConfigEnvelope,
    prepareGitHubToken,
    productionSecretPrompt,
  )
import Update.Check
  ( LiveGitHubMode (..),
    PackageEntry (..),
    checkOverlayWithDepsPlan,
    finishOutdatedReports,
    groupByPackage,
    groupNewest,
    needsLiveGitHubApi,
    productionFetcherWithLatch,
  )
import Update.CheckCache
  ( cacheSummaryLine,
    flushCheckCache,
    openCheckCache,
    recordCacheCounters,
    withCheckCacheTreeCommit,
  )
import Update.Deps.Plan (productionDepsPlanOpsWithLatch)
import Update.DiskSpace (productionDiskSpaceProbe)
import Update.Distfiles
  ( cleanManagerDistfiles,
    probeDistfilesDir,
    resolveDistfilesPath,
  )
import Update.Gate (GateHandle, GateRequest (..), md5CacheDependencies, md5CacheEntryPath)
import Update.Gate.Session (GateSessionCfg (..), UnitGateCfg (..), gateWaitSpan, runUnitGate, withGateSession)
import Update.GentooTree (GentooTree, gentooTreeCommit, gentooTreePath, productionTreeEnv, releaseGentooTree, resolveGentooTree)
import Update.Git (checkUpstreamSync, gitPushCurrentBranch, isGitWorkTree, productionGitOps)
import Update.GitHub
  ( GitHubLatch,
    gitRemoteOriginUrl,
    gitRemotePushUrl,
    newGitHubLatch,
  )
import Update.GitHubHealth
  ( GitHubHealthScope (..),
    interpretHealthOutcome,
    productionGitHubHealthHttp,
    runGitHubHealthPreflight,
    runGitOperationsHealth,
  )
import Update.GitHubToken
  ( productionGitHubTokenOps,
    runGitHubTokenCommand,
  )
import Update.GpgAgent
  ( newGpgHandle,
    prepareSigningSession,
    productionGpgAgentOps,
    takeGpgSessionSupervisor,
    teardownGpgHandle,
  )
import Update.Hardcoded (lookupPolicy)
import Update.Held (defaultHeldRoot)
import Update.Http (httpLbsEither, newMetricsManager)
import Update.Materialize (EnsureConfig (..), RecipeArch (..), defaultMaterializeSidecarDir, ensureMaterializeImage, ensureToolsImage, hostMachineArch, lookupRecipeArch, productionEnsureNow, prunePreviousMaterializeImage, stage3DigestWith)
import Update.Md5Cache
  ( checkLayoutCacheFormats,
    gencachePackages,
    preflightGencache,
    productionEgencacheRunner,
  )
import Update.OverlayTree (newTreeLock, readEbuildEither, withNewTreeLock)
import Update.Preflight
  ( AssetsPreflight (..),
    preflightUpdateTools,
  )
import Update.Process (CommandRunner, productionCommandRunner)
import Update.Process.Docker
  ( ToolsSession,
    isLiveOverlayManagerPid,
    materializeImageEnvVar,
    resolveToolsContainerCfg,
    secretMaterializeEnvKeys,
    sweepStaleMaterializeSessions,
    withToolsSession,
  )
import Update.Spine
  ( UpdateSpineDeps (..),
    UpdateSpineResult (..),
    runUpdatePhases,
  )
import Update.SshAgent (productionSshAgentOps, takeSshSessionSupervisor)
import Update.Targets
  ( PackageSelection (..),
    emptySelectionError,
    exclusionWarning,
    selectExcluding,
    targetErrorMessage,
  )
import Update.TempWorkspace (newRunId, openRunRootWith, rrPath)
import Update.Types (ApplyOutcome (..), PackageKey (..), PackagePolicy (..), SuccessLine (..), UpdateReport (..), formatOutdatedLine, mkPackageKey, packageKeyText)
import Update.Types qualified as U

data Runtime = Runtime
  { rtOptions :: Options,
    rtJobs :: Int,
    rtColor :: ColorMode,
    rtLogger :: LogAction IO Message,
    rtHold :: LogHold,
    rtProgress :: ProgressConfig,
    -- | One id per invocation: temp run root, metrics directory, container labels.
    rtRunId :: String,
    -- | 'commandTreeSync' of the command: whether it reads the managed Gentoo
    -- tree, and whether it forces a sync.
    rtTreeSync :: Maybe Bool,
    -- | Command-line priority request (merged with the config's at load).
    rtPriority :: PriorityRequest
  }

main :: IO ()
main = do
  tookGpg <- takeGpgSessionSupervisor
  tookSsh <- takeSshSessionSupervisor
  unless (tookGpg || tookSsh) runProgram

runProgram :: IO ()
runProgram = do
  (opts, cliPriority) <- parseOptions
  color <- resolveColorMode (optNoColor opts)
  jobs <- resolveJobs (optJobs opts)
  hold <- mkLogHold
  let logger = mkLogger (optVerbosity opts) color hold
  enabled <- progressEnabled (optNoProgress opts)
  pcfg <- mkProgressConfig enabled color hold logger
  case optCommand opts of
    Nothing -> showTopLevelHelpExit1
    Just cmd -> do
      runId <- newRunId
      gate <-
        metricsGate
          productionMetricsStartupOps
          (usingLoggerT logger . logWarning)
          (optNoMetrics opts)
          cmd
          runId
      let rtFor m =
            Runtime
              { rtOptions = opts,
                rtJobs = jobs,
                rtColor = color,
                rtLogger = logger,
                rtHold = hold,
                rtProgress = pcfg {pcMetrics = m},
                rtRunId = runId,
                rtTreeSync = Cmd.commandTreeSync cmd,
                rtPriority = cliPriority
              }
          dispatch m = do
            registerEnvSecrets m
            usingLoggerT logger (runCommand (rtFor m) cmd)
      case gate of
        Left err -> do
          usingLoggerT logger (logError err)
          exitWith (ExitFailure 1)
        Right MetricsOff -> dispatch (pcMetrics pcfg)
        Right (MetricsOn dir timeVersion) ->
          withRunMetrics
            RunSetup
              { rsRunDir = dir,
                rsRunId = runId,
                rsCommand = commandName cmd,
                rsTimeVersion = timeVersion,
                rsInvocation = invocationFor jobs cmd,
                rsWarn = usingLoggerT logger . logWarning,
                rsStartSampler = \rec -> do
                  cfg <- productionSamplerConfig
                  startSampler cfg rec
              }
            dispatch

runCommand :: (WithLog env Message m, MonadIO m) => Runtime -> Cmd.Command -> m ()
runCommand rt cmd =
  case cmd of
    Cmd.List -> runList rt
    Cmd.Outdated refresh pkgs excludeArgs ->
      runOutdated rt refresh pkgs excludeArgs
    Cmd.Update refresh pkgs excludeArgs noCompileCache ->
      runUpdate rt refresh pkgs excludeArgs noCompileCache
    Cmd.Gencache targets force excludeArgs ->
      runGencache rt targets force excludeArgs
    Cmd.Smoke pkgs excludeArgs noCache resetCache -> runSmokeCommand rt pkgs excludeArgs noCache resetCache
    Cmd.Eclean -> runEclean rt
    Cmd.GitHubToken force -> runGitHubToken rt force

rtMetrics :: Runtime -> Metrics
rtMetrics = pcMetrics . rtProgress

-- | Close the open command phase and open @phase.\<name\>@ (run metrics).
enterPhase :: (MonadIO m) => Runtime -> Text -> m ()
enterPhase rt = liftIO . mEnterPhase (rtMetrics rt)

-- | Values of 'secretMaterializeEnvKeys' are redacted from recorded argv.
registerEnvSecrets :: Metrics -> IO ()
registerEnvSecrets m =
  for_ secretMaterializeEnvKeys $ \key -> do
    v <- lookupEnv key
    for_ v (mAddSecret m . T.pack)

runList :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runList rt = do
  ebuilds <- loadValidatedEbuilds rt
  liftIO $ mapM_ (T.putStrLn . ebuildAtom) ebuilds

-- | Resolve positionals minus exclusions. Target errors exit before the
-- warning. An empty selection logs only the empty-selection error.
resolveCommandSelection ::
  (WithLog env Message m, MonadIO m) =>
  [PackageEntry] ->
  [Text] ->
  [Text] ->
  m [PackageKey]
resolveCommandSelection entries positionals excludes =
  case selectExcluding entries positionals excludes of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right PackageSelection {selectedKeys, removedKeys}
      | null selectedKeys && not (null removedKeys) -> do
          logError (emptySelectionError removedKeys)
          liftIO $ exitWith (ExitFailure 1)
      | otherwise -> do
          for_ (exclusionWarning removedKeys) logWarning
          pure selectedKeys

runOutdated ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  Bool ->
  [String] ->
  [String] ->
  m ()
runOutdated rt refresh pkgArgs excludeArgs = do
  enterPhase rt "config"
  (cfg, overlayResolved, ebuilds, _priority) <- loadValidatedEbuildsFull rt
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
      excludes = map T.pack excludeArgs
  enterPhase rt "select"
  resolveCommandSelection entries tokens excludes >>= \keys -> do
    let selectedEntries = [e | e <- entries, peKey e `elem` keys]
        filteredEbuilds =
          filter
            ( \eb ->
                mkPackageKey (ebuildCategory eb) (ebuildPackage eb) `elem` keys
            )
            ebuilds
        total = length selectedEntries
        byPkg = groupByPackage ebuilds
    tree <- resolveTreeOrDie rt cfg
    enterPhase rt "auth"
    (cache, cacheWarn) <-
      liftIO $
        first (withCheckCacheTreeCommit (gentooTreeCommit tree))
          <$> openCheckCache (checkCacheTtl cfg) refresh overlayResolved
    mapM_ logWarning cacheWarn
    willLive <-
      liftIO
        ( needsLiveGitHubApi
            LiveForOutdated
            cache
            overlayResolved
            selectedEntries
            byPkg
        )
    decryptCache <- liftIO (newIORef Nothing)
    let secretPrompt =
          productionSecretPrompt
            (pauseActivePanel (rtProgress rt))
            (resumeActivePanel (rtProgress rt))
    prepared <-
      liftIO (prepareGitHubToken cfg secretPrompt decryptCache willLive)
    (token, latch) <- case prepared of
      Left err -> dieError (T.unpack err)
      Right (tok, warns) -> do
        mapM_ logWarning warns
        for_ tok (liftIO . mAddSecret (rtMetrics rt))
        l <- liftIO newGitHubLatch
        when willLive $ runGitHubHealth (rtMetrics rt) l tok
        pure (tok, l)
    fetch <- liftIO (productionFetcherWithLatch (rtMetrics rt) latch token)
    depsOps <-
      liftIO
        ( productionDepsPlanOpsWithLatch
            (rtMetrics rt)
            latch
            (gentooTreePath tree)
            token
            (rtJobs rt)
            (Just overlayResolved)
        )
    enterPhase rt "check"
    reports <-
      liftIO $
        withMultiProgress (rtProgress rt) "Checking packages" total $ \mh ->
          checkOverlayWithDepsPlan
            (rtJobs rt)
            mh
            fetch
            depsOps
            cache
            filteredEbuilds
    liftIO (flushCheckCache cache)
    liftIO $ do
      recordCacheCounters (rtMetrics rt) cache
      setCount (rtMetrics rt) "packages.selected" total
      setCount (rtMetrics rt) "packages.needs_work" (length [() | U.Outdated _ <- map reportStatus reports])
      setCount (rtMetrics rt) "packages.failed" (length [() | U.FetchError _ <- map reportStatus reports])
    mSummary <- liftIO (cacheSummaryLine cache)
    mapM_ logInfo mSummary
    enterPhase rt "report"
    (keep, mAbort) <- liftIO (finishOutdatedReports latch reports)
    mapM_ emitReport keep
    case mAbort of
      Just err -> dieError (T.unpack err)
      Nothing -> pure ()

runUpdate ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  Bool ->
  [String] ->
  [String] ->
  -- | @--no-compile-cache@
  Bool ->
  m ()
runUpdate rt refresh pkgArgs excludeArgs noCompileCache = do
  enterPhase rt "config"
  (cfg, overlayPath, ebuilds, priority) <- loadValidatedEbuildsFull rt
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
      excludes = map T.pack excludeArgs
  enterPhase rt "select"
  resolveCommandSelection entries tokens excludes >>= \keys -> do
    let selected = [e | e <- entries, peKey e `elem` keys]
        -- Spine tools only; language/assets tools come after plan.
        spinePf =
          AssetsPreflight
            { apNeedAssets = False,
              apNeedGo = False,
              apNeedNpm = False,
              apNeedBun = False,
              apNeedCargo = False,
              apNeedDocker = False
            }
    enterPhase rt "tools"
    preflightOk <- liftIO $ runSpineToolSteps (rtProgress rt) spinePf
    case preflightOk of
      Left err -> dieError (T.unpack err)
      Right () -> pure ()
    layoutOk <- liftIO $ checkLayoutCacheFormats overlayPath
    case layoutOk of
      Left err -> dieError (T.unpack err)
      Right () -> pure ()
    distDir <-
      liftIO $
        resolveDistfilesPath
          (optDistfilesPath (rtOptions rt))
          (distfilesPath cfg)
    probeOk <- liftIO $ probeDistfilesDir distDir
    case probeOk of
      Left err -> dieError (T.unpack err)
      Right () -> pure ()
    tree <- resolveTreeOrDie rt cfg
    -- Open check cache before plan phase.
    enterPhase rt "auth"
    (cache, cacheWarn) <-
      liftIO $
        first (withCheckCacheTreeCommit (gentooTreeCommit tree))
          <$> openCheckCache (checkCacheTtl cfg) refresh overlayPath
    mapM_ logWarning cacheWarn
    willLive <-
      liftIO
        ( needsLiveGitHubApi
            LiveForUpdate
            cache
            overlayPath
            selected
            (groupByPackage ebuilds)
        )
    decryptCache <- liftIO (newIORef Nothing)
    let pcfg = rtProgress rt
        secretPrompt =
          productionSecretPrompt
            (pauseActivePanel pcfg)
            (resumeActivePanel pcfg)
    prepared <-
      liftIO (prepareGitHubToken cfg secretPrompt decryptCache willLive)
    (token, latch) <- case prepared of
      Left err -> dieError (T.unpack err)
      Right (tok, warns) -> do
        mapM_ logWarning warns
        for_ tok (liftIO . mAddSecret (rtMetrics rt))
        l <- liftIO newGitHubLatch
        when willLive $ runGitHubHealth (rtMetrics rt) l tok
        pure (tok, l)
    fetch <- liftIO (productionFetcherWithLatch (rtMetrics rt) latch token)
    depsOps <-
      liftIO
        ( productionDepsPlanOpsWithLatch
            (rtMetrics rt)
            latch
            (gentooTreePath tree)
            token
            (rtJobs rt)
            (Just overlayPath)
        )
    dummyReleaseOps <-
      liftIO $
        case token of
          Just t -> productionReleaseOpsWithLatch (rtMetrics rt) latch t
          Nothing ->
            pure
              ReleaseOps
                { roGetReleaseByTag = \_ _ _ -> pure (Left "GitHub token required"),
                  roDownloadAsset = \_ _ -> pure (Left "GitHub token required"),
                  roCreateReleaseWithAssets = \_ _ -> pure (Left "GitHub token required")
                }
    let run = timedRunner (rtMetrics rt) productionCommandRunner
        gpgOps =
          productionGpgAgentOps
            (rtMetrics rt)
            (pauseActivePanel pcfg)
            (resumeActivePanel pcfg)
    ensureCfg <- liftIO (productionEnsureConfig rt cfg run overlayPath tree)
    heldRoot <- liftIO defaultHeldRoot
    overlayAbs <- liftIO (makeAbsolute overlayPath)
    senv <- liftIO (mkSmokeEnv rt cfg run overlayAbs tree ebuilds priority)
    uname <- liftIO hostMachineArch
    let hostArch = maybe "" raKeywords (lookupRecipeArch uname)
    spineResult <-
      liftIO $
        withRunToolsSession rt run ensureCfg tree (Just distDir) priority $ \tools ->
          bracket
            (newGpgHandle gpgOps)
            teardownGpgHandle
            ( \gpg -> do
                let unlockEnvelope =
                      case githubToken cfg of
                        Nothing ->
                          pure $
                            Left
                              "GitHub token required for assets publish (set github-token in config or GITHUB_TOKEN/GH_TOKEN)"
                        Just envelope -> do
                          r <- decryptConfigEnvelope secretPrompt decryptCache envelope
                          for_ r (mAddSecret (rtMetrics rt))
                          pure r
                    deps =
                      UpdateSpineDeps
                        { usdJobs = rtJobs rt,
                          usdPriority = priority,
                          usdRunId = rtRunId rt,
                          usdProgress = pcfg,
                          usdFetcher = fetch,
                          usdDepsPlanOps = depsOps,
                          usdReleaseOps = dummyReleaseOps,
                          usdDiskProbe = productionDiskSpaceProbe,
                          usdGitOps = productionGitOps (rtMetrics rt) gpg,
                          usdCheckCache = cache,
                          usdAssetsOwner = "0x6d6e647a",
                          usdAssetsRepo = "mndz-overlay-assets",
                          usdGitHubToken = token,
                          usdUnlockConfigToken = unlockEnvelope,
                          usdMkReleaseOps = productionReleaseOpsWithLatch (rtMetrics rt) latch,
                          usdGitOriginUrl = gitRemoteOriginUrl run,
                          usdGitPushUrl = gitRemotePushUrl run,
                          usdCommandRunner = run,
                          usdAssetsPathCfg = assetsPath cfg,
                          usdDistDir = distDir,
                          usdOverlayRoot = overlayPath,
                          usdSshOps = productionSshAgentOps (rtMetrics rt),
                          usdSshIdentity = sshIdentity cfg,
                          usdEbuildRunner = productionEbuildRunner tools distDir,
                          usdEgencacheRunner = productionEgencacheRunner tools,
                          usdPreflightTools = preflightUpdateTools,
                          usdEnsureImage = (`ensureMaterializeImage` ensureCfg),
                          usdPruneMaterialize =
                            prunePreviousMaterializeImage ensureCfg,
                          usdSweepMaterialize =
                            sweepStaleMaterializeSessions
                              run
                              isLiveOverlayManagerPid,
                          usdMaterializeDockerRunner =
                            Just run,
                          usdGitHubLatch = latch,
                          usdGitOperationsHealth = productionGitOperationsHealth (rtMetrics rt),
                          usdUpstreamSync = checkUpstreamSync run (productionGitOperationsHealth (rtMetrics rt)),
                          usdPushOverlay = gitPushCurrentBranch run,
                          usdVerifyAsset = \prefix root key pv names -> do
                            mgr <- newMetricsManager (rtMetrics rt)
                            verifyUnitAssets
                              (verifyPublishedAsset (httpLbsEither mgr))
                              prefix
                              root
                              key
                              pv
                              names,
                          usdWithGate = productionGateSession rt senv run overlayAbs tree hostArch noCompileCache,
                          usdGatePrereqs = do
                            pre <- smokePreflight findExecutable run overlayAbs
                            pure $ case (pre, lookupRecipeArch uname) of
                              (Left err, _) -> Left err
                              (Right (), Nothing) ->
                                Left ("no official gentoo/stage3 OpenRC flavor for host architecture " <> T.pack uname)
                              (Right (), Just _) -> Right (),
                          usdHeldRoot = heldRoot,
                          usdGitRunner = run,
                          usdPrepareSigning =
                            \runRoot mayAssets overlay mAssets ->
                              prepareSigningSession
                                gpg
                                runRoot
                                ( overlay
                                    : [ assets
                                      | mayAssets,
                                        Just assets <- [mAssets]
                                      ]
                                ),
                          usdReleaseSigning = teardownGpgHandle gpg
                        }
                runUpdatePhases deps entries ebuilds selected
            )
    case spineResult of
      Left err -> dieError (T.unpack err)
      Right res -> do
        liftIO $ do
          let outs = usrOutcomes res
              m = rtMetrics rt
          setCount m "packages.selected" (length selected)
          setCount m "packages.applied" (length [() | ApplySuccess {} <- outs])
          setCount m "packages.skipped" (length [() | ApplySoftSkip {} <- outs])
          setCount m "packages.failed" (length [() | ApplyHardFail {} <- outs])
        mapM_ logWarning (usrWarnings res)
        mapM_ logInfo (usrCacheSummary res)
        case usrOutcomes res of
          [ApplyHardFail (PackageKey "") msg _ _] ->
            dieError (T.unpack msg)
          outcomes -> do
            mapM_ emitOutcome outcomes
            when (foldExitHardFail outcomes) $
              liftIO $
                exitWith (ExitFailure 1)

-- | Default-tag ensure configuration for this run.
productionEnsureConfig :: Runtime -> OverlayConfig -> CommandRunner -> FilePath -> GentooTree -> IO EnsureConfig
productionEnsureConfig rt cfg run overlayPath tree = do
  mgr <- newMetricsManager (rtMetrics rt)
  sidecarDir <- defaultMaterializeSidecarDir
  uname <- hostMachineArch
  mOvr <- lookupEnv materializeImageEnvVar
  prev <- newMVar Nothing
  buildLock <- newMVar ()
  pure
    EnsureConfig
      { ecRun = run,
        ecProbe = productionDiskSpaceProbe,
        ecOverlayRoot = overlayPath,
        ecSidecarDir = sidecarDir,
        ecNow = productionEnsureNow,
        ecUname = uname,
        ecOverrideTag = case mOvr of
          Just s | not (null s) -> Just s
          _ -> Nothing,
        ecPrevImageId = prev,
        ecGentooTree = gentooTreePath tree,
        ecGentooCommit = gentooTreeCommit tree,
        ecStage3Digest = stage3DigestWith (httpLbsEither mgr),
        ecBaseCheckInterval = materializeBaseCheckInterval cfg,
        ecWarn = usingLoggerT (rtLogger rt) . logWarning,
        ecBuildLock = buildLock
      }

-- | The run's Portage tools container (created on first @ebuild@ /
-- @egencache@, removed when the continuation returns).
withRunToolsSession ::
  Runtime ->
  CommandRunner ->
  EnsureConfig ->
  GentooTree ->
  Maybe FilePath ->
  EffectivePriority ->
  (ToolsSession -> IO a) ->
  IO a
withRunToolsSession rt run ensureCfg tree mDist priority k = do
  cfg <- resolveToolsContainerCfg (rtJobs rt) (rtRunId rt) (gentooTreePath tree) (ecOverlayRoot ensureCfg) mDist priority
  baseLock <- newTreeLock
  withToolsSession run cfg (ensureToolsImage baseLock ensureCfg) k

-- | Resolve the managed Gentoo tree once per run, before any tree read.
-- Syncs when due or when the command forces it ('commandTreeSync'); holds
-- the tree shared until exit.
resolveTreeOrDie ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  OverlayConfig ->
  m GentooTree
resolveTreeOrDie rt cfg = do
  refresh <- case rtTreeSync rt of
    Just r -> pure r
    Nothing -> dieError "internal error: this command does not use the Gentoo tree"
  enterPhase rt "tree"
  let say f = usingLoggerT (rtLogger rt) . f
  env <-
    liftIO $
      productionTreeEnv
        (rtMetrics rt)
        (gentooTreeMaxAge cfg)
        refresh
        (say logInfo)
        (say logWarning)
  result <- liftIO (resolveGentooTree env)
  either (dieError . T.unpack) pure result

-- | Spine-tool preflight step (git/gpg/docker only).
runSpineToolSteps :: ProgressConfig -> AssetsPreflight -> IO (Either T.Text ())
runSpineToolSteps pcfg ap =
  withStepProgress pcfg 1 $ \step -> do
    shStep step "Checking required tools"
    preflightUpdateTools ap

emitOutcome :: (WithLog env Message m, MonadIO m) => ApplyOutcome -> m ()
emitOutcome = \case
  ApplySuccess key lines_ _paths -> do
    liftIO $
      mapM_ (T.putStrLn . formatSuccessLine key) lines_
    mapM_
      ( \sl ->
          when (slAssetsReused sl) $
            logInfo $
              packageKeyText key
                <> ": reused release assets for "
                <> prettyVersion (slTo sl)
                <> " (tag/asset "
                <> packageAssetLabel key (slTo sl)
                <> "); verify complete"
      )
      lines_
  ApplySoftSkip key reason ->
    logWarning $ packageKeyText key <> ": " <> reason
  ApplyHardFail key msg halfApplied assetsPublished -> do
    logError
      ( if T.null (packageKeyText key)
          then msg
          else packageKeyText key <> ": " <> msg
      )
    when halfApplied $
      logWarning $
        packageKeyText key
          <> ": package directory may be left dirty or half-applied; fix or restore before retrying; \
             \if ebuild and md5-cache disagree, run gencache or gencache --force for this package"
    when assetsPublished $
      logWarning $
        packageKeyText key
          <> ": assets release may already be published but the overlay update did not complete"

-- | @smoke@: spine, preflight, selection, tree, plan, then 'runSmoke'.
runSmokeCommand ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  [String] ->
  [String] ->
  -- | @--no-compile-cache@
  Bool ->
  -- | @--reset-compile-cache@
  Bool ->
  m ()
runSmokeCommand rt pkgArgs excludeArgs noCompileCache resetCompileCache = do
  enterPhase rt "config"
  (cfg, overlayPath', ebuilds, priority) <- loadValidatedEbuildsFull rt
  let m = rtMetrics rt
      run = timedRunner m productionCommandRunner
  overlay <- liftIO (makeAbsolute overlayPath')
  enterPhase rt "preflight"
  preflight <- liftIO (smokePreflight findExecutable run overlay)
  either (dieError . T.unpack) pure preflight
  enterPhase rt "select"
  keys <- resolveCommandSelection (groupNewest ebuilds) (map T.pack pkgArgs) (map T.pack excludeArgs)
  case missingDefinitions lookupSmokeDef keys of
    [] -> pure ()
    missing ->
      dieError . T.unpack $
        "no smoke definition for: "
          <> T.intercalate ", " (map packageKeyText missing)
          <> " (exclude them with --exclude to test the rest)"
  dirty <- liftIO (uncommittedPackages run overlay keys)
  tree <- resolveTreeOrDie rt cfg
  enterPhase rt "plan"
  uname <- liftIO hostMachineArch
  arch <- case lookupRecipeArch uname of
    Just a -> pure (raKeywords a)
    Nothing -> dieError ("no official gentoo/stage3 OpenRC flavor for host architecture " <> uname)
  inputs <- fmap concat . forM keys $ \key -> do
    let pkgEbuilds = [e | e <- ebuilds, mkPackageKey (ebuildCategory e) (ebuildPackage e) == key]
    texts <- liftIO (withNewTreeLock (\inTree -> traverse (readEbuildEither inTree . ebuildPath) pkgEbuilds))
    case (sequence texts, lookupPolicy key) of
      (Left err, _) -> dieError ("could not read the ebuilds of " <> T.unpack (packageKeyText key) <> ": " <> T.unpack err)
      (_, Nothing) -> dieError ("no update policy for " <> T.unpack (packageKeyText key))
      (Right bodies, Just policy) ->
        pure [PackageInput {piKey = key, piTechnique = policyTechnique policy, piEbuilds = zip pkgEbuilds bodies}]
  let runtimes = nubOrd [r | i <- inputs, Just r <- [laneRuntimeFor (piTechnique i)]]
  eCeilings <- liftIO (loadHostCeilings arch (gentooTreePath tree) overlay runtimes)
  ceilings <- either (dieError . T.unpack) pure eCeilings
  let items = planSmokeRuns arch ceilings inputs
  liftIO (setCount m "packages.selected" (length keys))
  enterPhase rt "smoke"
  senv <- liftIO (mkSmokeEnv rt cfg run overlay tree ebuilds priority)
  let prepareCfg =
        smokePrepareCfg
          senv
          (nubOrd [packageKeyText (srKey r) | PlannedRun r <- items])
          (if resetCompileCache then map packageKeyText keys else [])
          (not noCompileCache)
      logsDir = seLogsDir senv
      defFor key = case lookupSmokeDef key of
        Just d -> d
        Nothing -> error "selected key without a definition"
  result <-
    liftIO $
      withStepProgress (rtProgress rt) (length items) $ \step ->
        runSmoke
          ( smokeOpsFor
              rt
              senv
              prepareCfg
              (releaseGentooTree tree)
              (WorktreeMount overlay)
              (\atom stage -> shStep step (atom <> ": " <> stage))
          )
            { soProgress = \i total atom ->
                shStep step ("[" <> T.pack (show i) <> "/" <> T.pack (show total) <> "] " <> atom)
            }
          defFor
          logsDir
          items
  case result of
    Left err -> dieError (T.unpack err)
    Right summary -> do
      liftIO $ do
        setCount m "runs.passed" (ssPassed summary)
        setCount m "runs.failed" (ssFailed summary)
        setCount m "runs.skipped" (ssSkipped summary)
      let lines_ = summaryLines summary logsDir dirty
          report = if ssFailed summary > 0 || not (null dirty) then logWarning else logInfo
      mapM_ report lines_
      when (ssFailed summary > 0) $ liftIO (exitWith (ExitFailure 1))

-- | Command-scoped smoke settings shared by @smoke@ and @update@'s gate.
data SmokeEnv = SmokeEnv
  { seContainer :: SmokeContainerCfg,
    seImage :: SmokeImageConfig,
    seSnapshot :: SnapshotCfg,
    seLogsDir :: FilePath,
    seCacheDir :: FilePath,
    seHelper :: HelperCfg,
    seMaxCacheSize :: Integer,
    seGoChecks :: GoChecks
  }

mkSmokeEnv :: Runtime -> OverlayConfig -> CommandRunner -> FilePath -> GentooTree -> [Ebuild] -> EffectivePriority -> IO SmokeEnv
mkSmokeEnv rt cfg run overlay tree ebuilds priority = do
  let m = rtMetrics rt
  cacheDir <- defaultSmokeCacheDir
  let logsRoot = smokeLogsRoot cacheDir
  pruneRunLogs logsRoot
  mgr <- newMetricsManager m
  uid <- getRealUserID
  pid <- getProcessID
  uname <- hostMachineArch
  goChecks <- newGoChecks
  let say f = usingLoggerT (rtLogger rt) . f
  pure
    SmokeEnv
      { seContainer =
          SmokeContainerCfg
            { sccRunId = rtRunId rt,
              sccCliPid = show pid,
              sccImage = smokeImageTag,
              sccSnapshot = snapshotTag (rtRunId rt),
              sccOverlay = WorktreeMount overlay,
              sccTimeDir = if mEnabled m then mTimeDir m else Nothing,
              sccOperatorUid = fromIntegral uid,
              sccJobs = rtJobs rt,
              sccOverlayNames = nubOrd [ebuildCategory e <> "/" <> ebuildPackage e | e <- ebuilds],
              sccCache = CacheOff,
              sccPriority = priority
            },
        seImage =
          SmokeImageConfig
            { sicRun = run,
              sicProbe = productionDiskSpaceProbe,
              sicCacheDir = cacheDir,
              sicUname = uname,
              sicGentooTree = gentooTreePath tree,
              sicGentooCommit = gentooTreeCommit tree,
              sicNow = getCurrentTime,
              sicStage3Digest = stage3DigestWith (httpLbsEither mgr),
              sicBaseCheckInterval = materializeBaseCheckInterval cfg,
              sicWarn = say logWarning
            },
        seSnapshot =
          SnapshotCfg
            { scRunId = rtRunId rt,
              scCliPid = show pid,
              scImage = smokeImageTag,
              scTree = gentooTreePath tree
            },
        seLogsDir = logsRoot </> dockerSafe (rtRunId rt),
        seCacheDir = cacheDir,
        seHelper = HelperCfg {hcImage = smokeImageTag, hcRunId = rtRunId rt, hcCliPid = show pid},
        seMaxCacheSize = smokeCompileCacheMaxSize cfg,
        seGoChecks = goChecks
      }

-- | Compile cache preparation for these selected packages.
smokePrepareCfg :: SmokeEnv -> [T.Text] -> [T.Text] -> Bool -> PrepareCfg
smokePrepareCfg senv selected reset enabled =
  PrepareCfg
    { pcRun = sicRun (seImage senv),
      pcHelper = seHelper senv,
      pcLockPath = compileCacheLockPath (seCacheDir senv),
      pcNow = floor <$> getPOSIXTime,
      pcMaxSize = seMaxCacheSize senv,
      pcInventory = sccOverlayNames (seContainer senv),
      pcSelected = selected,
      pcReset = reset,
      pcEnabled = enabled
    }

-- | Session and run effects of a smoke command or gate. @progress@ gets a
-- run's atom and stage.
smokeOpsFor ::
  Runtime ->
  SmokeEnv ->
  PrepareCfg ->
  IO () ->
  OverlayMount ->
  (T.Text -> T.Text -> IO ()) ->
  SmokeOps
smokeOpsFor rt senv prepareCfg releaseTree mount progress =
  SmokeOps
    { soSweep = do
        sweepStaleMaterializeSessions run isLiveOverlayManagerPid
        sweepStaleSnapshots run isLiveOverlayManagerPid,
      soEnsureImage =
        withSpan m "smoke.image" [] (void <$> ensureSmokeImage (seImage senv)),
      soWithSnapshot = withSpan m "smoke.snapshot" [] . withSnapshot run (seSnapshot senv) . const,
      soReleaseTree = releaseTree,
      soProbe = withSpan m "smoke.probe" [] (runSandboxProbe run (seContainer senv)),
      soPrepareCache = withSpan m "smoke.compile-cache" [] $ do
        prepared <- prepareCompileCache prepareCfg
        mapM_ (say logWarning) (prWarnings prepared)
        for_ (prPlan prepared) (recordCleanup m)
        pure (prUse prepared),
      soRun = smokeRunIn rt senv mount progress,
      soEmit = \line -> T.putStrLn line >> hFlush stdout,
      soLogFailure = say logError,
      soLogWarning = say logWarning,
      soLogInfo = say logInfo,
      soProgress = \_ _ _ -> pure ()
    }
  where
    m = rtMetrics rt
    run = sicRun (seImage senv)
    say f = usingLoggerT (rtLogger rt) . f

-- | One run in a fresh container with @mount@ as its overlay.
smokeRunIn ::
  Runtime ->
  SmokeEnv ->
  OverlayMount ->
  (T.Text -> T.Text -> IO ()) ->
  CacheUse ->
  SmokeRun ->
  SmokeDef ->
  FilePath ->
  IO RunOutcome
smokeRunIn rt senv mount progress cache smokeRun def dir =
  withSpan m "smoke.run" ["atom" .= runAtom smokeRun] $ do
    let runCfg = (seContainer senv) {sccCache = cache, sccOverlay = mount}
    r <-
      withSmokeContainer m productionCgroupRoots run runCfg smokeRun $ \session ->
        performRun session runCfg (seGoChecks senv) (srKey smokeRun) def smokeRun dir (progress (runAtom smokeRun))
    case r of
      Right res -> do
        for_ (roCache res) (recordCacheReport m (runAtom smokeRun))
        pure res
      Left err -> do
        createDirectoryIfMissing True dir
        let file = dir </> "container.log"
        TIO.writeFile file err
        pure (RunOutcome (RunFail FailDependencies err file) Nothing)
  where
    m = rtMetrics rt
    run = sicRun (seImage senv)

-- | The smoke gate of an @update@ run: the session opens concurrently with
-- the first units; each unit is run against its overlay snapshot.
productionGateSession ::
  Runtime ->
  SmokeEnv ->
  CommandRunner ->
  FilePath ->
  GentooTree ->
  T.Text ->
  -- | @--no-compile-cache@
  Bool ->
  [PackageKey] ->
  (GateHandle -> IO (Maybe T.Text) -> IO a) ->
  IO a
productionGateSession rt senv run overlay tree arch noCompileCache keys k = do
  gateRoot <- rrPath <$> openRunRootWith (rtRunId rt <> "-gate")
  let workDir = gateRoot </> "gate"
  let prepareCfg = smokePrepareCfg senv (map packageKeyText keys) [] (not noCompileCache)
      ops = smokeOpsFor rt senv prepareCfg (pure ()) (WorktreeMount overlay) (\_ _ -> pure ())
      unitCfg =
        UnitGateCfg
          { ugRunner = run,
            ugOverlay = overlay,
            ugWorkDir = workDir,
            ugArch = arch,
            ugCeilings = loadHostCeilings arch (gentooTreePath tree),
            ugTechnique = fmap policyTechnique . lookupPolicy,
            ugDefinition = lookupSmokeDef,
            ugLogsDir = seLogsDir senv,
            ugMetrics = rtMetrics rt,
            ugRun = smokeRunIn rt senv
          }
  withGateSession
    GateSessionCfg
      { gscSmokeOps = ops,
        gscRunUnit = runUnitGate unitCfg ops,
        gscDependencies = \req -> case md5CacheEntryPath overlay (grKey req) (grPv req) of
          Nothing -> pure []
          Just path -> do
            body <- try @IOException (TIO.readFile path)
            pure (either (const []) md5CacheDependencies body),
        gscAroundWait = gateWaitSpan (rtMetrics rt)
      }
    keys
    k
    `finally` try @IOException (removeDirectoryRecursive gateRoot)

-- | Clean the manager private distfiles cache (never system Portage DISTDIR).
runGitHubToken :: (WithLog env Message m, MonadIO m) => Runtime -> Bool -> m ()
runGitHubToken rt force = do
  let override = optConfig (rtOptions rt)
  result <- liftIO (loadConfigAllowPlaintextToken override)
  cfg <- case result of
    Left err -> dieError (configErrorMessage err)
    Right c -> pure c
  _ <- applyPriorityOrDie rt cfg
  configPath <- liftIO (maybe defaultConfigPath pure override)
  let pcfg = rtProgress rt
  ops <-
    liftIO $
      productionGitHubTokenOps
        (pauseActivePanel pcfg)
        (resumeActivePanel pcfg)
  written <- liftIO (runGitHubTokenCommand ops configPath cfg force)
  case written of
    Left err -> dieError (T.unpack err)
    Right writtenPath ->
      logInfo ("wrote encrypted github-token to " <> T.pack writtenPath)

runGitHubHealth ::
  (WithLog env Message m, MonadIO m) =>
  Metrics ->
  GitHubLatch ->
  Maybe T.Text ->
  m ()
runGitHubHealth metrics latch token = do
  http <- liftIO (productionGitHubHealthHttp metrics)
  outcome <-
    liftIO $
      runGitHubHealthPreflight
        latch
        http
        token
        GitHubHealthScope
          { ghsCheckApiRequests = True,
            ghsCheckGitOperations = False
          }
  case interpretHealthOutcome outcome of
    Left err -> dieError (T.unpack err)
    Right warns -> mapM_ logWarning warns

productionGitOperationsHealth :: Metrics -> IO (Either T.Text ())
productionGitOperationsHealth metrics = do
  http <- productionGitHubHealthHttp metrics
  outcome <- runGitOperationsHealth http
  pure $ case interpretHealthOutcome outcome of
    Left err -> Left err
    Right _ -> Right ()

runEclean :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runEclean rt = do
  enterPhase rt "config"
  cfg <- loadConfigOrDie (optConfig (rtOptions rt))
  _ <- applyPriorityOrDie rt cfg
  distDir <-
    liftIO $
      resolveDistfilesPath
        (optDistfilesPath (rtOptions rt))
        (distfilesPath cfg)
  enterPhase rt "eclean"
  result <- liftIO (cleanManagerDistfiles (rtMetrics rt) distDir)
  case result of
    Left err -> dieError (T.unpack err)
    Right () ->
      logInfo $ "eclean: cleaned manager distfiles cache at " <> T.pack distDir

runGencache ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  [String] ->
  Bool ->
  [String] ->
  m ()
runGencache rt pkgArgs force excludeArgs = do
  enterPhase rt "config"
  (cfg, overlayPath, ebuilds, priority) <- loadValidatedEbuildsFull rt
  enterPhase rt "preflight"
  isGit <- liftIO (isGitWorkTree (timedRunner (rtMetrics rt) productionCommandRunner) overlayPath)
  unless isGit $
    dieError ("overlay path is not a git work tree: " <> overlayPath)
  toolsOk <- liftIO preflightGencache
  case toolsOk of
    Left err -> dieError (T.unpack err)
    Right () -> pure ()
  layoutOk <- liftIO $ checkLayoutCacheFormats overlayPath
  case layoutOk of
    Left err -> dieError (T.unpack err)
    Right () -> pure ()
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
      excludes = map T.pack excludeArgs
  enterPhase rt "select"
  resolveCommandSelection entries tokens excludes >>= \keys -> do
    tree <- resolveTreeOrDie rt cfg
    enterPhase rt "gencache"
    liftIO (setCount (rtMetrics rt) "packages.selected" (length keys))
    let pcfg = rtProgress rt
        gpgOps =
          productionGpgAgentOps
            (rtMetrics rt)
            (pauseActivePanel pcfg)
            (resumeActivePanel pcfg)
        run = timedRunner (rtMetrics rt) productionCommandRunner
    ensureCfg <- liftIO (productionEnsureConfig rt cfg run overlayPath tree)
    result <-
      liftIO $
        withRunToolsSession rt run ensureCfg tree Nothing priority $ \tools ->
          bracket
            (newGpgHandle gpgOps)
            teardownGpgHandle
            ( \gpg ->
                gencachePackages
                  (productionEgencacheRunner tools)
                  (productionGitOps (rtMetrics rt) gpg)
                  overlayPath
                  keys
                  force
                  (Just (rtJobs rt))
                  ( do
                      runRoot <- openRunRootWith (rtRunId rt)
                      prepareSigningSession gpg (rrPath runRoot) [overlayPath]
                  )
            )
    case result of
      Left err -> dieError (T.unpack err)
      Right Nothing ->
        logInfo "gencache: no md5-cache changes; no commit created"
      Right (Just paths) ->
        logInfo $
          "gencache: signed commit of "
            <> T.pack (show (length paths))
            <> " cache path(s)"

-- | @{pn}-{pv}@ release tag label for deferred reuse logs.
packageAssetLabel :: PackageKey -> EbuildVersion -> T.Text
packageAssetLabel key ver =
  let pn = case T.breakOnEnd "/" (packageKeyText key) of
        (_, rest) | not (T.null rest) -> rest
        _ -> packageKeyText key
      pn' = T.dropWhile (== '/') pn
      -- Release tags use PV without leading @v@ and without @-rN@.
      pv = case ver of
        Numeric comps _ ->
          T.intercalate "." (map (T.pack . show) comps)
        Raw t -> t
   in pn' <> "-" <> pv

formatSuccessLine :: PackageKey -> SuccessLine -> T.Text
formatSuccessLine key sl =
  packageKeyText key
    <> " "
    <> prettyVersion (slFrom sl)
    <> " -> "
    <> prettyVersion (slTo sl)
    <> case slLabel sl of
      Nothing -> ""
      Just lab -> " " <> lab
    <> if slAssetsReused sl then " [assets reused]" else ""

loadValidatedEbuilds ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  m [Ebuild]
loadValidatedEbuilds rt = do
  (_, _, ebuilds, _) <- loadValidatedEbuildsFull rt
  pure ebuilds

-- | Load the config, apply the run's priority, then validate the overlay
-- and collect its ebuilds.
loadValidatedEbuildsFull ::
  (WithLog env Message m, MonadIO m) =>
  Runtime ->
  m (OverlayConfig, FilePath, [Ebuild], EffectivePriority)
loadValidatedEbuildsFull rt = do
  let opts = rtOptions rt
  cfg <- loadConfigOrDie (optConfig opts)
  priority <- applyPriorityOrDie rt cfg
  -- Local name must not shadow the OverlayConfig field accessor `overlayPath`.
  let resolvedOverlay = case optOverlayPath opts of
        Just p -> p
        Nothing -> overlayPath cfg
  liftIO (validateOverlay resolvedOverlay) >>= \case
    Left err -> dieError (overlayErrorMessage err)
    Right () -> pure ()
  liftIO (collectEbuilds resolvedOverlay) >>= \case
    Left err -> dieError (discoveryErrorMessage err)
    Right [] -> dieError ("no ebuilds found in overlay: " <> resolvedOverlay)
    Right ebuilds -> pure (cfg, resolvedOverlay, ebuilds, priority)

emitReport :: (WithLog env Message m, MonadIO m) => UpdateReport -> m ()
emitReport report = do
  case reportStatus report of
    U.Outdated lines_ ->
      liftIO $
        mapM_ (T.putStrLn . formatOutdatedLine (reportKey report)) lines_
    U.Ok _ -> pure ()
    U.Ahead local remote ->
      logWarning $
        packageKeyText (reportKey report)
          <> " is ahead of upstream ("
          <> prettyVersion local
          <> " > "
          <> prettyVersion remote
          <> ")"
    U.Unconfigured ->
      logWarning $
        packageKeyText (reportKey report)
          <> ": no update source configured"
    U.FetchError err ->
      logWarning $
        packageKeyText (reportKey report)
          <> ": "
          <> err
  case reportWarning report of
    Nothing -> pure ()
    Just err ->
      logWarning $
        packageKeyText (reportKey report)
          <> ": "
          <> err

loadConfigOrDie :: (WithLog env Message m, MonadIO m) => Maybe FilePath -> m OverlayConfig
loadConfigOrDie override = do
  result <- liftIO (loadConfig override)
  case result of
    Left err -> dieError (configErrorMessage err)
    Right cfg -> pure cfg

-- | Apply the command-line and config priority to every manager thread
-- right after the config load, before any workload process starts.
applyPriorityOrDie :: (WithLog env Message m, MonadIO m) => Runtime -> OverlayConfig -> m EffectivePriority
applyPriorityOrDie rt cfg = do
  applied <-
    liftIO $
      applyCommandPriority
        productionThreadOps
        (rtMetrics rt)
        (usingLoggerT (rtLogger rt) . logWarning)
        (rtPriority rt)
        (configPriority cfg)
  either (dieError . T.unpack) pure applied

dieError :: (WithLog env Message m, MonadIO m) => String -> m a
dieError msg = do
  logError (T.pack msg)
  liftIO $ exitWith (ExitFailure 1)

overlayErrorMessage :: OverlayError -> String
overlayErrorMessage = \case
  NotADirectory path ->
    "overlay path is not a directory: " <> path
  MissingDirectory path ->
    "missing required overlay directory: " <> path
  MissingFile path ->
    "missing required overlay file: " <> path
  RepoNameMismatch path got ->
    "repo_name mismatch in " <> path <> ": expected mndz, got " <> got
