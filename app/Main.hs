{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser (Command (Help, List, Outdated, Update), Options (..), parserInfo, showHelp)
import Colog (Message, WithLog, logError, logWarning, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Concurrent.MVar (newMVar)
import Control.Exception (bracket)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Logging.Bootstrap (bootstrapLogger)
import Options.Applicative (execParser)
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (Ebuild, ebuildAtom)
import Overlay.Validation (OverlayError (..), validateOverlay)
import Overlay.Version (prettyVersion)
import System.Exit (ExitCode (..), exitWith)
import Update.Apply
  ( ApplyEnv (..),
    applyOverlay,
    foldExitHardFail,
    productionEbuildRunner,
  )
import Update.Auth (resolveGitHubToken)
import Update.Check
  ( PackageEntry (..),
    checkOverlay,
    groupNewest,
    productionFetcherWithToken,
  )
import Update.Git (productionGitOps)
import Update.Go.Vendor (productionVendorOps)
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
    PackageKey (..),
    PackagePolicy (..),
    UpdateReport (..),
    UpdateStatus (Ahead, FetchError, Ok, Unconfigured),
    packageKeyText,
    techniqueNeedsAssets,
  )
import Update.Types qualified as U

main :: IO ()
main = usingLoggerT bootstrapLogger $ do
  opts <- liftIO $ execParser parserInfo
  case optCommand opts of
    Help -> liftIO showHelp
    List -> runList opts
    Outdated -> runOutdated opts
    Update pkgs -> runUpdate opts pkgs

runList :: (WithLog env Message m, MonadIO m) => Options -> m ()
runList opts = do
  ebuilds <- loadValidatedEbuilds opts
  liftIO $ mapM_ (T.putStrLn . ebuildAtom) ebuilds

runOutdated :: (WithLog env Message m, MonadIO m) => Options -> m ()
runOutdated opts = do
  (cfg, ebuilds) <- loadValidatedEbuildsWithConfig opts
  token <- liftIO (resolveGitHubToken cfg)
  fetch <- liftIO (productionFetcherWithToken token)
  reports <- liftIO (checkOverlay fetch ebuilds)
  mapM_ emitReport reports

runUpdate :: (WithLog env Message m, MonadIO m) => Options -> [String] -> m ()
runUpdate opts pkgArgs = do
  (cfg, overlayPath, ebuilds) <- loadValidatedEbuildsFull opts
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
      liftIO (preflightUpdateWith needAssets) >>= \case
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
      let runApply = do
            lock <- newMVar ()
            fetch <- productionFetcherWithToken token
            let env =
                  ApplyEnv
                    { aeFetcher = fetch,
                      aeGitOps = productionGitOps,
                      aeEbuildRunner = productionEbuildRunner,
                      aeVendorOps = productionVendorOps,
                      aeAssetsRoot = assetsRoot,
                      aeGitHubToken = token,
                      aeAssetsOwner = "0x6d6e647a",
                      aeAssetsRepo = "mndz-overlay-assets",
                      aeAssetsLock = lock
                    }
            applyOverlay env overlayPath entries mFilter
      outcomes <-
        liftIO $
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
                    Right _sess -> runApply
                )
            else runApply
      case outcomes of
        [ApplyHardFail (PackageKey "") msg _ _] ->
          dieError (T.unpack msg)
        _ -> do
          mapM_ emitOutcome outcomes
          when (foldExitHardFail outcomes) $
            liftIO $
              exitWith (ExitFailure 1)

entryNeedsAssets :: PackageEntry -> Bool
entryNeedsAssets e =
  case lookupPolicy (peKey e) of
    Just p -> techniqueNeedsAssets (policyTechnique p)
    Nothing -> False

emitOutcome :: (WithLog env Message m, MonadIO m) => ApplyOutcome -> m ()
emitOutcome = \case
  ApplySuccess key local remote _paths ->
    liftIO $
      T.putStrLn $
        packageKeyText key
          <> " "
          <> prettyVersion local
          <> " -> "
          <> prettyVersion remote
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
    U.Outdated local remote ->
      liftIO $
        T.putStrLn $
          packageKeyText (reportKey report)
            <> " "
            <> prettyVersion local
            <> " -> "
            <> prettyVersion remote
    Ok _ -> pure ()
    Ahead local remote ->
      logWarning $
        packageKeyText (reportKey report)
          <> " is ahead of upstream ("
          <> prettyVersion local
          <> " > "
          <> prettyVersion remote
          <> ")"
    Unconfigured ->
      logWarning $
        packageKeyText (reportKey report)
          <> ": no update source configured"
    FetchError err ->
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
