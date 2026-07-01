module Config.Loader
  ( loadConfig
  , ConfigError(..)
  ) where

import Config.Types (OverlayConfig (..))
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

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
    else pure (Right (OverlayConfig path))
