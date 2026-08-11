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
  ( ProgressConfig,
    StepHandle (..),
    mkProgressConfig,
    pauseActivePanel,
    progressEnabled,
    resumeActivePanel,
    withMultiProgress,
    withStepProgress,
  )
import Colog (LogAction, Message, WithLog, logError, logInfo, logWarning, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Logging.Bootstrap (LogHold, mkLogHold, mkLogger)
import Options.Applicative (execParser)
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (Ebuild, ebuildAtom, ebuildCategory, ebuildPackage)
import Overlay.Validation (OverlayError (..), validateOverlay)
import Overlay.Version (EbuildVersion (..), prettyVersion)
import System.Exit (ExitCode (..), exitWith)
import Update.Apply (foldExitHardFail)
import Update.Assets.Release (ReleaseOps (..), productionReleaseOps)
import Update.Auth (resolveGitHubToken)
import Update.Check
  ( PackageEntry (..),
    checkOverlayWithDepsPlan,
    groupNewest,
    productionFetcherWithToken,
  )
import Update.CheckCache
  ( cacheSummaryLine,
    flushCheckCache,
    openCheckCache,
  )
import Update.Deps.Plan (productionDepsPlanOps)
import Update.DiskSpace (productionDiskSpaceProbe)
import Update.Distfiles
  ( cleanManagerDistfiles,
    probeDistfilesDir,
    resolveDistfilesPath,
  )
import Update.Git (isGitWorkTree, productionGitOps)
import Update.GpgAgent
  ( newGpgHandle,
    productionGpgAgentOps,
    teardownGpgHandle,
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
import Update.Spine
  ( UpdateSpineDeps (..),
    UpdateSpineResult (..),
    runUpdatePhases,
  )
import Update.SshAgent (productionSshAgentOps)
import Update.Targets (resolveTargets, targetErrorMessage)
import Update.Types
  ( ApplyOutcome (..),
    OutdatedLine (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateReport (..),
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
    rtProgress :: ProgressConfig
  }

main :: IO ()
main = do
  opts <- execParser parserInfo
  color <- resolveColorMode (optNoColor opts)
  jobs <- resolveJobs (optJobs opts)
  hold <- mkLogHold
  let logger = mkLogger (optVerbosity opts) color hold
  enabled <- progressEnabled (optNoProgress opts)
  pcfg <- mkProgressConfig enabled color hold logger
  let rt =
        Runtime
          { rtOptions = opts,
            rtJobs = jobs,
            rtColor = color,
            rtLogger = logger,
            rtHold = hold,
            rtProgress = pcfg
          }
  case optCommand opts of
    Nothing -> showTopLevelHelpExit1
    Just cmd ->
      usingLoggerT logger $
        case cmd of
          Cmd.List -> runList rt
          Cmd.Outdated refresh pkgs -> runOutdated rt refresh pkgs
          Cmd.Update refresh pkgs -> runUpdate rt refresh pkgs
          Cmd.Gencache targets force -> runGencache rt targets force
          Cmd.Eclean -> runEclean rt

runList :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runList rt = do
  ebuilds <- loadValidatedEbuilds (rtOptions rt)
  liftIO $ mapM_ (T.putStrLn . ebuildAtom) ebuilds

runOutdated ::
  (WithLog env Message m, MonadIO m) => Runtime -> Bool -> [String] -> m ()
runOutdated rt refresh pkgArgs = do
  (cfg, overlayResolved, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
  case resolveTargets entries tokens of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right keys -> do
      let selectedEntries = [e | e <- entries, peKey e `elem` keys]
          filteredEbuilds =
            filter
              ( \eb ->
                  mkPackageKey (ebuildCategory eb) (ebuildPackage eb) `elem` keys
              )
              ebuilds
          total = length selectedEntries
      token <- liftIO (resolveGitHubToken cfg)
      fetch <- liftIO (productionFetcherWithToken token)
      depsOps <-
        liftIO (productionDepsPlanOps token (rtJobs rt) (Just overlayResolved))
      (cache, cacheWarn) <-
        liftIO $ openCheckCache (checkCacheTtl cfg) refresh overlayResolved
      mapM_ logWarning cacheWarn
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
      mSummary <- liftIO (cacheSummaryLine cache)
      mapM_ logInfo mSummary
      mapM_ emitReport reports

runUpdate ::
  (WithLog env Message m, MonadIO m) => Runtime -> Bool -> [String] -> m ()
runUpdate rt refresh pkgArgs = do
  (cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
  case resolveTargets entries tokens of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right keys -> do
      let selected =
            if null pkgArgs
              then entries
              else [e | e <- entries, peKey e `elem` keys]
          -- Spine tools only; language/assets tools come after plan.
          spinePf =
            AssetsPreflight
              { apNeedAssets = False,
                apNeedGo = False,
                apNeedNpm = False,
                apNeedBun = False,
                apNeedCargo = False
              }
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
      token <- liftIO (resolveGitHubToken cfg)
      -- Open check cache before plan phase.
      (cache, cacheWarn) <-
        liftIO $ openCheckCache (checkCacheTtl cfg) refresh overlayPath
      mapM_ logWarning cacheWarn
      fetch <- liftIO (productionFetcherWithToken token)
      depsOps <-
        liftIO (productionDepsPlanOps token (rtJobs rt) (Just overlayPath))
      releaseOps <-
        liftIO $
          case token of
            Just t -> productionReleaseOps t
            Nothing ->
              pure
                ReleaseOps
                  { roGetReleaseByTag = \_ _ _ -> pure (Left "GitHub token required"),
                    roDownloadAsset = \_ _ -> pure (Left "GitHub token required"),
                    roCreateReleaseWithAssets = \_ _ -> pure (Left "GitHub token required")
                  }
      let pcfg = rtProgress rt
          gpgOps =
            productionGpgAgentOps
              (pauseActivePanel pcfg)
              (resumeActivePanel pcfg)
      spineResult <-
        liftIO $
          bracket
            (newGpgHandle gpgOps)
            teardownGpgHandle
            ( \gpg ->
                let deps =
                      UpdateSpineDeps
                        { usdJobs = rtJobs rt,
                          usdProgress = pcfg,
                          usdFetcher = fetch,
                          usdDepsPlanOps = depsOps,
                          usdReleaseOps = releaseOps,
                          usdDiskProbe = productionDiskSpaceProbe,
                          usdGitOps = productionGitOps gpg,
                          usdCheckCache = cache,
                          usdAssetsOwner = "0x6d6e647a",
                          usdAssetsRepo = "mndz-overlay-assets",
                          usdGitHubToken = token,
                          usdAssetsPathCfg = assetsPath cfg,
                          usdDistDir = distDir,
                          usdOverlayRoot = overlayPath,
                          usdSshOps = productionSshAgentOps
                        }
                 in runUpdatePhases deps entries ebuilds selected
            )
      case spineResult of
        Left err -> dieError (T.unpack err)
        Right res -> do
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
runEclean :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runEclean rt = do
  cfg <- loadConfigOrDie (optConfig (rtOptions rt))
  distDir <-
    liftIO $
      resolveDistfilesPath
        (optDistfilesPath (rtOptions rt))
        (distfilesPath cfg)
  result <- liftIO (cleanManagerDistfiles distDir)
  case result of
    Left err -> dieError (T.unpack err)
    Right () ->
      logInfo $ "eclean: cleaned manager distfiles cache at " <> T.pack distDir

runGencache :: (WithLog env Message m, MonadIO m) => Runtime -> [String] -> Bool -> m ()
runGencache rt pkgArgs force = do
  (_cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
  isGit <- liftIO (isGitWorkTree overlayPath)
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
  case resolveTargets entries tokens of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right keys -> do
      let pcfg = rtProgress rt
          gpgOps =
            productionGpgAgentOps
              (pauseActivePanel pcfg)
              (resumeActivePanel pcfg)
      result <-
        liftIO $
          bracket
            (newGpgHandle gpgOps)
            teardownGpgHandle
            ( \gpg ->
                gencachePackages
                  productionEgencacheRunner
                  (productionGitOps gpg)
                  overlayPath
                  keys
                  force
                  (Just (rtJobs rt))
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
emitReport report =
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

formatOutdatedLine :: PackageKey -> OutdatedLine -> T.Text
formatOutdatedLine key ol =
  packageKeyText key
    <> " "
    <> prettyVersion (olFrom ol)
    <> " -> "
    <> prettyVersion (olTo ol)
    <> case olLabel ol of
      Nothing -> ""
      Just lab -> " " <> lab
    <> if olAssetsReusable ol then " [assets reusable]" else ""

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
