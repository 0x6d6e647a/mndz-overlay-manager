module Main (main) where

import CLI.Parser (Command (..), Options (..), parserInfo, showHelp)
import Colog (Message, WithLog, logError, usingLoggerT)
import Config.Loader (configErrorMessage, loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Logging.Bootstrap (bootstrapLogger)
import Options.Applicative (execParser)
import Overlay.Discovery (collectEbuilds, discoveryErrorMessage)
import Overlay.Types (ebuildAtom)
import Overlay.Validation (OverlayError (..), validateOverlay)
import System.Exit (ExitCode (..), exitWith)

main :: IO ()
main = usingLoggerT bootstrapLogger $ do
  opts <- liftIO $ execParser parserInfo
  case optCommand opts of
    Help -> liftIO showHelp
    List -> runList opts

runList :: (WithLog env Message m, MonadIO m) => Options -> m ()
runList opts = do
  cfg <- loadConfigOrDie (optConfig opts)
  let overlayPath = case optOverlayPath opts of
        Just p  -> p
        Nothing -> mndzOverlayPath cfg
  liftIO (validateOverlay overlayPath) >>= \case
    Left err -> dieError (overlayErrorMessage err)
    Right () -> pure ()
  liftIO (collectEbuilds overlayPath) >>= \case
    Left err -> dieError (discoveryErrorMessage err)
    Right [] -> dieError ("no ebuilds found in overlay: " <> overlayPath)
    Right ebuilds ->
      liftIO $ mapM_ (T.putStrLn . ebuildAtom) ebuilds

loadConfigOrDie :: (WithLog env Message m, MonadIO m) => Maybe FilePath -> m OverlayConfig
loadConfigOrDie override = do
  result <- liftIO (loadConfig override)
  case result of
    Left err  -> dieError (configErrorMessage err)
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
