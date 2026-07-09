module Config.Loader
  ( loadConfig
  , ConfigError(..)
  , configErrorMessage
  ) where

import Config.Types (OverlayConfig (..))
import Data.Text.IO qualified as T
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Toml (Result (..), decode)

data ConfigError
  = ConfigNotFound FilePath
  | DecodeError String
  deriving (Eq, Show)

defaultConfigPath :: IO FilePath
defaultConfigPath = do
  xdg <- lookupEnv "XDG_CONFIG_HOME"
  home <- getHomeDirectory
  pure $ case xdg of
    Just dir -> dir </> "mndz" </> "overlay-manager.toml"
    Nothing  -> home </> ".config" </> "mndz" </> "overlay-manager.toml"

loadConfig :: Maybe FilePath -> IO (Either ConfigError OverlayConfig)
loadConfig override = do
  path <- maybe defaultConfigPath pure override
  exists <- doesFileExist path
  if not exists
    then pure (Left (ConfigNotFound path))
    else do
      content <- T.readFile path
      pure $ case decode content of
        Failure errs -> Left (DecodeError (unlines errs))
        Success _ cfg -> Right cfg

configErrorMessage :: ConfigError -> String
configErrorMessage = \case
  ConfigNotFound path ->
    "config file not found: " <> path
  DecodeError err ->
    "failed to decode config: " <> err
