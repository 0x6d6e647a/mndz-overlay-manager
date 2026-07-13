{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Parser (Command (Help, List, Outdated), Options (..), parserInfo, showHelp)
import Colog (Message, WithLog, logError, logWarning, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
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
import Update.Check (checkOverlay, productionFetcher)
import Update.Types
  ( UpdateReport (..),
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

loadValidatedEbuilds ::
  (WithLog env Message m, MonadIO m) =>
  Options ->
  m [Ebuild]
loadValidatedEbuilds opts = do
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
    Right ebuilds -> pure ebuilds

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
