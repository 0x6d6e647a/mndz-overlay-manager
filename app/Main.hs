{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser
  ( ColorMode,
    Options (..),
    parserInfo,
    resolveColorMode,
    resolveJobs,
    showHelp,
  )
import CLI.Parser qualified as Cmd
import CLI.Progress
  ( ProgressConfig,
    StepHandle (..),
    mkProgressConfig,
    noopMultiHandle,
    noopStepHandle,
    pauseActivePanel,
    progressEnabled,
    resumeActivePanel,
    withMultiProgress,
    withStepProgress,
  )
import Colog (LogAction, Message, WithLog, logError, logInfo, logWarning, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Concurrent.MVar (newMVar)
import Control.Exception (bracket)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Logging.Bootstrap (LogHold, mkLogHold, mkLogger)
import Options.Applicative (execParser)
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (Ebuild, ebuildAtom)
import Overlay.Validation (OverlayError (..), validateOverlay)
import Overlay.Version (EbuildVersion (..), prettyVersion)
import System.Exit (ExitCode (..), exitWith)
import Update.Apply
  ( ApplyEnv (..),
    applyOverlay,
    foldExitHardFail,
    productionEbuildRunner,
  )
import Update.Assets.Release (ReleaseOps (..), productionReleaseOps)
import Update.Auth (resolveGitHubToken)
import Update.Check
  ( PackageEntry (..),
    checkOverlayWithPlan,
    groupNewest,
    productionFetcherWithToken,
  )
import Update.Git (productionGitOps)
import Update.Go.Plan (productionPlanOps)
import Update.Go.Vendor (productionVendorOps)
import Update.GpgAgent
  ( newGpgHandle,
    productionGpgAgentOps,
    teardownGpgHandle,
  )
import Update.Hardcoded (lookupPolicy)
import Update.Preflight
  ( preflightUpdateWith,
    validateAssetsPath,
  )
import Update.SshAgent
  ( ensureSshAgent,
    productionSshAgentOps,
    teardownSshSession,
  )
import Update.Targets (resolveTargets, targetErrorMessage)
import Update.Types
  ( ApplyOutcome (..),
    OutdatedLine (..),
    PackageKey (..),
    PackagePolicy (..),
    SuccessLine (..),
    UpdateReport (..),
    packageKeyText,
    techniqueNeedsAssets,
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
  usingLoggerT logger $
    case optCommand opts of
      Cmd.Help -> liftIO showHelp
      Cmd.List -> runList rt
      Cmd.Outdated -> runOutdated rt
      Cmd.Update pkgs -> runUpdate rt pkgs

runList :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runList rt = do
  ebuilds <- loadValidatedEbuilds (rtOptions rt)
  liftIO $ mapM_ (T.putStrLn . ebuildAtom) ebuilds

runOutdated :: (WithLog env Message m, MonadIO m) => Runtime -> m ()
runOutdated rt = do
  (cfg, ebuilds) <- loadValidatedEbuildsWithConfig (rtOptions rt)
  token <- liftIO (resolveGitHubToken cfg)
  fetch <- liftIO (productionFetcherWithToken token)
  planOps <- liftIO (productionPlanOps token (rtJobs rt))
  let total = length (groupNewest ebuilds)
  reports <-
    liftIO $
      withMultiProgress (rtProgress rt) "Checking packages" total $ \mh ->
        checkOverlayWithPlan (rtJobs rt) mh fetch planOps ebuilds
  mapM_ emitReport reports

runUpdate :: (WithLog env Message m, MonadIO m) => Runtime -> [String] -> m ()
runUpdate rt pkgArgs = do
  (cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull (rtOptions rt)
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
  case resolveTargets entries tokens of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right keys -> do
      let mFilter = if null pkgArgs then Nothing else Just keys
          selected = case mFilter of
            Nothing -> entries
            Just ks -> [e | e <- entries, peKey e `elem` ks]
          needAssets = any entryNeedsAssets selected
      preflightOk <- liftIO $ runPreflightSteps (rtProgress rt) needAssets
      case preflightOk of
        Left err -> dieError (T.unpack err)
        Right () -> pure ()
      token <- liftIO (resolveGitHubToken cfg)
      assetsRoot <-
        if needAssets
          then
            liftIO (validateAssetsPath (mndzOverlayAssetsPath cfg)) >>= \case
              Left err -> dieError (T.unpack err)
              Right p -> pure (Just p)
          else pure Nothing
      when needAssets $
        case token of
          Nothing ->
            dieError
              "GitHub token required for assets publish (set github-token in config or GITHUB_TOKEN/GH_TOKEN)"
          Just _ -> pure ()
      let runApply gpg = do
            lock <- newMVar ()
            fetch <- productionFetcherWithToken token
            planOps <- productionPlanOps token (rtJobs rt)
            releaseOps <- case token of
              Just t -> productionReleaseOps t
              Nothing ->
                pure
                  ReleaseOps
                    { roGetReleaseByTag = \_ _ _ -> pure (Left "GitHub token required"),
                      roDownloadAsset = \_ _ -> pure (Left "GitHub token required")
                    }
            let env =
                  ApplyEnv
                    { aeFetcher = fetch,
                      aeGitOps = productionGitOps gpg,
                      aeEbuildRunner = productionEbuildRunner,
                      aeVendorOps = productionVendorOps,
                      aeReleaseOps = releaseOps,
                      aeAssetsRoot = assetsRoot,
                      aeGitHubToken = token,
                      aeAssetsOwner = "0x6d6e647a",
                      aeAssetsRepo = "mndz-overlay-assets",
                      aeAssetsLock = lock,
                      aeJobs = rtJobs rt,
                      aeMulti = noopMultiHandle,
                      aeCommitStep = noopStepHandle,
                      aePlanOps = planOps
                    }
            applyOverlay (rtProgress rt) env overlayPath entries mFilter
      let pcfg = rtProgress rt
          gpgOps =
            productionGpgAgentOps
              (pauseActivePanel pcfg)
              (resumeActivePanel pcfg)
      outcomes <-
        liftIO $
          bracket
            (newGpgHandle gpgOps)
            teardownGpgHandle
            ( \gpg ->
                if needAssets
                  then
                    bracket
                      (ensureSshAgent productionSshAgentOps)
                      ( \case
                          Left _ -> pure ()
                          Right sess -> teardownSshSession productionSshAgentOps sess
                      )
                      ( \case
                          Left err ->
                            pure
                              [ ApplyHardFail
                                  (PackageKey "")
                                  ("SSH agent setup failed: " <> err)
                                  False
                                  False
                              ]
                          Right _sess -> runApply gpg
                      )
                  else runApply gpg
            )
      case outcomes of
        [ApplyHardFail (PackageKey "") msg _ _] ->
          dieError (T.unpack msg)
        _ -> do
          mapM_ emitOutcome outcomes
          when (foldExitHardFail outcomes) $
            liftIO $
              exitWith (ExitFailure 1)

-- | Sequential preflight step bar covering tool checks (and counting conditional steps).
runPreflightSteps :: ProgressConfig -> Bool -> IO (Either T.Text ())
runPreflightSteps pcfg needAssets = do
  let stepDescs =
        ["Checking required tools"]
          <> ["Validating assets path" | needAssets]
          <> ["Resolving GitHub credentials" | needAssets]
          <> ["Preparing SSH agent" | needAssets]
      total = length stepDescs
  withStepProgress pcfg total $ \step -> do
    shStep step "Checking required tools"
    tools <- preflightUpdateWith needAssets
    case tools of
      Left err -> pure (Left err)
      Right () -> do
        -- Remaining steps are informational markers; real work runs after return.
        mapM_ (shStep step) (drop 1 stepDescs)
        pure (Right ())

entryNeedsAssets :: PackageEntry -> Bool
entryNeedsAssets e =
  case lookupPolicy (peKey e) of
    Just p -> techniqueNeedsAssets (policyTechnique p)
    Nothing -> False

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
          <> ": package directory may be left dirty or half-applied; fix or restore before retrying"
    when assetsPublished $
      logWarning $
        packageKeyText key
          <> ": assets release may already be published but the overlay update did not complete"

-- | @{pn}-{pv} / {pn}-{pv}-vendor.tar.xz@ for deferred reuse logs.
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
   in pn' <> "-" <> pv <> " / " <> pn' <> "-" <> pv <> "-vendor.tar.xz"

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

loadValidatedEbuildsWithConfig ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m (OverlayConfig, [Ebuild])
loadValidatedEbuildsWithConfig opts = do
  (cfg, _, ebuilds) <- loadValidatedEbuildsFull opts
  pure (cfg, ebuilds)

loadValidatedEbuildsFull ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m (OverlayConfig, FilePath, [Ebuild])
loadValidatedEbuildsFull opts = do
  cfg <- loadConfigOrDie (optConfig opts)
  let overlayPath = case optOverlayPath opts of
        Just p -> p
        Nothing -> mndzOverlayPath cfg
  liftIO (validateOverlay overlayPath) >>= \case
    Left err -> dieError (overlayErrorMessage err)
    Right () -> pure ()
  liftIO (collectEbuilds overlayPath) >>= \case
    Left err -> dieError (discoveryErrorMessage err)
    Right [] -> dieError ("no ebuilds found in overlay: " <> overlayPath)
    Right ebuilds -> pure (cfg, overlayPath, ebuilds)

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
