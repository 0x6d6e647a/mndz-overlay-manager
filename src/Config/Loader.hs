{-# LANGUAGE OverloadedStrings #-}

module Config.Loader
  ( loadConfig,
    ConfigError (..),
    configErrorMessage,
  )
where

import Config.Types (OverlayConfig (..))
import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.Text.IO qualified as T
import Numeric (showOct)
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, fileMode, getFileStatus)
import System.Posix.Types (FileMode)
import Toml (Result (..), decode)

data ConfigError
  = ConfigNotFound FilePath
  | DecodeError String
  | -- | Wrong mode ('Just' observed bits) or 'stat' failed ('Nothing').
    ConfigModeError FilePath (Maybe FileMode)
  deriving (Eq, Show)

defaultConfigPath :: IO FilePath
defaultConfigPath = do
  xdg <- lookupEnv "XDG_CONFIG_HOME"
  home <- getHomeDirectory
  pure $ case xdg of
    Just dir -> dir </> "mndz" </> "overlay-manager.toml"
    Nothing -> home </> ".config" </> "mndz" </> "overlay-manager.toml"

-- | Owner read\/write only (@0600@).
expectedConfigMode :: FileMode
expectedConfigMode = 0o600

loadConfig :: Maybe FilePath -> IO (Either ConfigError OverlayConfig)
loadConfig override = do
  path <- maybe defaultConfigPath pure override
  estat <- try (getFileStatus path) :: IO (Either IOException FileStatus)
  case estat of
    Left exc
      | isDoesNotExistError exc ->
          pure (Left (ConfigNotFound path))
      | otherwise ->
          pure (Left (ConfigModeError path Nothing))
    Right st ->
      let mode = fileMode st .&. 0o777
       in if mode /= expectedConfigMode
            then pure (Left (ConfigModeError path (Just mode)))
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
  ConfigModeError path (Just mode) ->
    "config file "
      <> path
      <> " is mode 0"
      <> showOct mode ""
      <> "; expected mode 0600"
  ConfigModeError path Nothing ->
    "config file "
      <> path
      <> ": cannot read permission bits; expected mode 0600"
