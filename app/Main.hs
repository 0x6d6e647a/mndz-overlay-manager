{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser
  ( ColorMode,
    Options (..),
    parserInfo,
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
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Logging.Bootstrap (LogHold, mkLogHold, mkLogger)
import Metrics.Core (Metrics (..), setCount)
import Metrics.Process (timedRunner)
import Metrics.Run (RunSetup (..), invocationFor, withRunMetrics)
import Metrics.Sampler (productionSamplerConfig, startSampler)
import Metrics.Startup
  ( MetricsStart (..),
    commandName,
    metricsGate,
    productionMetricsStartupOps,
  )
import Options.Applicative (execParser)
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (Ebuild, ebuildAtom, ebuildCategory, ebuildPackage)
import Overlay.Validation (OverlayError (..), validateOverlay)
import Overlay.Version (EbuildVersion (..), prettyVersion)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import Update.Apply (foldExitHardFail, productionEbuildRunner)
import Update.Assets.Release (ReleaseOps (..), productionReleaseOpsWithLatch)
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
  )
import Update.Deps.Plan (productionDepsPlanOpsWithLatch)
import Update.DiskSpace (productionDiskSpaceProbe)
import Update.Distfiles
  ( cleanManagerDistfiles,
    probeDistfilesDir,
    resolveDistfilesPath,
  )
import Update.Git (isGitWorkTree, productionGitOps)
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
import Update.Materialize
  ( EnsureConfig (..),
    defaultMaterializeSidecarDir,
    ensureMaterializeImage,
    hostMachineArch,
    productionEnsureNow,
    prunePreviousMaterializeImage,
  )
import Update.Md5Cache
  ( checkLayoutCacheFormats,
    gencachePackages,
    preflightGencache,
    productionEgencacheRunner,
  )
import Update.Preflight
  ( AssetsPreflight (..),
    preflightUpdateTools,
  )
import Update.Process (productionCommandRunner)
import Update.Process.Docker
  ( isLiveOverlayManagerPid,
    materializeImageEnvVar,
    secretMaterializeEnvKeys,
    sweepStaleMaterializeSessions,
  )
import Update.Runtime.Ceilings (gentooRepoPath, productionPortageqRunner)
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
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateReport (..),
    formatOutdatedLine,
    mkPackageKey,
    packageKeyText,
  )
import Update.Types qualified as U

data Runtime = Runtime
  { rtOptions :: Options,
    rtJobs :: Int,
    rtColor :: ColorMode,
    rtLogger :: LogAction IO Message,
    rtHold :: LogHold,
    rtProgress :: ProgressConfig,
    -- | One id per invocation: temp run root, metrics directory, container labels.
    rtRunId :: String
  }

main :: IO ()
main = do
  tookGpg <- takeGpgSessionSupervisor
  tookSsh <- takeSshSessionSupervisor
  unless (tookGpg || tookSsh) runProgram

runProgram :: IO ()
runProgram = do
  opts <- execParser parserInfo
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
                rtRunId = runId
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
    Cmd.Update refresh pkgs excludeArgs ->
      runUpdate rt refresh pkgs excludeArgs
    Cmd.Gencache targets force excludeArgs ->
      runGencache rt targets force excludeArgs
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
  ebuilds <- loadValidatedEbuilds (rtOptions rt)
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
  (cfg, overlayResolved, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
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
    enterPhase rt "auth"
    (cache, cacheWarn) <-
      liftIO $ openCheckCache (checkCacheTtl cfg) refresh overlayResolved
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
  m ()
runUpdate rt refresh pkgArgs excludeArgs = do
  enterPhase rt "config"
  (cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
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
    -- Open check cache before plan phase.
    enterPhase rt "auth"
    (cache, cacheWarn) <-
      liftIO $ openCheckCache (checkCacheTtl cfg) refresh overlayPath
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
    spineResult <-
      liftIO $
        bracket
          (newGpgHandle gpgOps)
          teardownGpgHandle
          ( \gpg -> do
              sidecarDir <- defaultMaterializeSidecarDir
              uname <- hostMachineArch
              mOvr <- lookupEnv materializeImageEnvVar
              prev <- newMVar Nothing
              let ovr = case mOvr of
                    Just s | not (null s) -> Just s
                    _ -> Nothing
                  ensureCfg =
                    EnsureConfig
                      { ecRun = run,
                        ecProbe = productionDiskSpaceProbe,
                        ecOverlayRoot = overlayPath,
                        ecSidecarDir = sidecarDir,
                        ecNow = productionEnsureNow,
                        ecUname = uname,
                        ecOverrideTag = ovr,
                        ecPrevImageId = prev,
                        ecGentooRoot = gentooRepoPath (productionPortageqRunner (rtMetrics rt))
                      }
                  unlockEnvelope =
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
                        usdGitOriginUrl = gitRemoteOriginUrl (rtMetrics rt),
                        usdGitPushUrl = gitRemotePushUrl (rtMetrics rt),
                        usdCommandRunner = run,
                        usdAssetsPathCfg = assetsPath cfg,
                        usdDistDir = distDir,
                        usdOverlayRoot = overlayPath,
                        usdSshOps = productionSshAgentOps (rtMetrics rt),
                        usdSshIdentity = sshIdentity cfg,
                        usdEbuildRunner = productionEbuildRunner (rtMetrics rt) distDir,
                        usdEgencacheRunner = productionEgencacheRunner (rtMetrics rt),
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

-- | Spine-tool preflight step (git/ebuild/egencache/gpg only).
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

-- | Clean the manager private distfiles cache (never system Portage DISTDIR).
runGitHubToken :: (WithLog env Message m, MonadIO m) => Runtime -> Bool -> m ()
runGitHubToken rt force = do
  let override = optConfig (rtOptions rt)
  result <- liftIO (loadConfigAllowPlaintextToken override)
  cfg <- case result of
    Left err -> dieError (configErrorMessage err)
    Right c -> pure c
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
  (_cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
  enterPhase rt "preflight"
  isGit <- liftIO (isGitWorkTree (rtMetrics rt) overlayPath)
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
    enterPhase rt "gencache"
    liftIO (setCount (rtMetrics rt) "packages.selected" (length keys))
    let pcfg = rtProgress rt
        gpgOps =
          productionGpgAgentOps
            (rtMetrics rt)
            (pauseActivePanel pcfg)
            (resumeActivePanel pcfg)
    result <-
      liftIO $
        bracket
          (newGpgHandle gpgOps)
          teardownGpgHandle
          ( \gpg ->
              gencachePackages
                (productionEgencacheRunner (rtMetrics rt))
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
  Options ->
  m [Ebuild]
loadValidatedEbuilds opts = do
  (_, _, ebuilds) <- loadValidatedEbuildsFull opts
  pure ebuilds

loadValidatedEbuildsFull ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m (OverlayConfig, FilePath, [Ebuild])
loadValidatedEbuildsFull opts = do
  cfg <- loadConfigOrDie (optConfig opts)
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
    Right ebuilds -> pure (cfg, resolvedOverlay, ebuilds)

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
