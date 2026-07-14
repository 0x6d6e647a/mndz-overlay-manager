{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser (Command (Help, List, Outdated, Update), Options (..), parserInfo, showHelp)
import Colog (Message, WithLog, logError, logWarning, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
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
  ( applyOverlay,
    foldExitHardFail,
    productionEbuildRunner,
  )
import Update.Check (checkOverlay, groupNewest, productionFetcher)
import Update.Git (productionGitOps)
import Update.Preflight (preflightUpdate)
import Update.Targets (resolveTargets, targetErrorMessage)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    UpdateReport (..),
    UpdateStatus (Ahead, FetchError, Ok, Unconfigured),
    packageKeyText,
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
  ebuilds <- loadValidatedEbuilds opts
  fetch <- liftIO productionFetcher
  reports <- liftIO (checkOverlay fetch ebuilds)
  mapM_ emitReport reports

runUpdate :: (WithLog env Message m, MonadIO m) => Options -> [String] -> m ()
runUpdate opts pkgArgs = do
  (overlayPath, ebuilds) <- loadValidatedEbuildsWithPath opts
  liftIO preflightUpdate >>= \case
    Left err -> dieError (T.unpack err)
    Right () -> pure ()
  let entries = groupNewest ebuilds
      tokens = map T.pack pkgArgs
  case resolveTargets entries tokens of
    Left errs -> do
      mapM_ (logError . targetErrorMessage) errs
      liftIO $ exitWith (ExitFailure 1)
    Right keys -> do
      fetch <- liftIO productionFetcher
      let mFilter = if null pkgArgs then Nothing else Just keys
          -- When no args, applyOverlay still gets all entries; soft-skips not outdated.
          -- When args given, only those keys.
          filterKeys = mFilter
      outcomes <-
        liftIO $
          applyOverlay
            fetch
            productionGitOps
            productionEbuildRunner
            overlayPath
            entries
            filterKeys
      case outcomes of
        [ApplyHardFail (PackageKey "") msg _] ->
          dieError (T.unpack msg)
        _ -> do
          mapM_ emitOutcome outcomes
          when (foldExitHardFail outcomes) $
            liftIO $
              exitWith (ExitFailure 1)

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
  ApplyHardFail key msg halfApplied -> do
    logError
      ( if T.null (packageKeyText key)
          then msg
          else packageKeyText key <> ": " <> msg
      )
    when halfApplied $
      logWarning $
        packageKeyText key
          <> ": package directory may be left dirty or half-applied; fix or restore before retrying"

loadValidatedEbuilds ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m [Ebuild]
loadValidatedEbuilds opts = snd <$> loadValidatedEbuildsWithPath opts

loadValidatedEbuildsWithPath ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m (FilePath, [Ebuild])
loadValidatedEbuildsWithPath opts = do
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
    Right ebuilds -> pure (overlayPath, ebuilds)

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
