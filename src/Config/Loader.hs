{-# LANGUAGE OverloadedStrings #-}

module Config.Loader
  ( loadConfig,
    loadConfigWithWarn,
    configPermissionWarning,
    expectedConfigMode,
    ConfigError (..),
    configErrorMessage,
  )
where

import Config.Types (OverlayConfig (..))
import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Numeric (showOct)
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Posix.Files (FileStatus, fileMode, getFileStatus)
import System.Posix.Types (FileMode)
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
    Nothing -> home </> ".config" </> "mndz" </> "overlay-manager.toml"

-- | Owner read\/write only (@0600@).
expectedConfigMode :: FileMode
expectedConfigMode = 0o600

-- | Warning when @path@ exists and is not mode @0600@. @Nothing@ on @0600@
-- or when the mode cannot be read.
configPermissionWarning :: FilePath -> IO (Maybe Text)
configPermissionWarning path = do
  estat <- try (getFileStatus path) :: IO (Either IOException FileStatus)
  pure $ case estat of
    Left _ -> Nothing
    Right st ->
      let mode = fileMode st .&. 0o777
       in if mode == expectedConfigMode
            then Nothing
            else
              Just
                ( "config file "
                    <> T.pack path
                    <> " is mode 0"
                    <> T.pack (showOct mode "")
                    <> "; expected mode 0600"
                )

-- | Load config, emitting a permission warning via @warn@.
loadConfigWithWarn ::
  (Text -> IO ()) ->
  Maybe FilePath ->
  IO (Either ConfigError OverlayConfig)
loadConfigWithWarn warn override = do
  path <- maybe defaultConfigPath pure override
  exists <- doesFileExist path
  if not exists
    then pure (Left (ConfigNotFound path))
    else do
      mWarn <- configPermissionWarning path
      mapM_ warn mWarn
      content <- T.readFile path
      pure $ case decode content of
        Failure errs -> Left (DecodeError (unlines errs))
        Success _ cfg -> Right cfg

loadConfig :: Maybe FilePath -> IO (Either ConfigError OverlayConfig)
loadConfig = loadConfigWithWarn (T.hPutStrLn stderr)

configErrorMessage :: ConfigError -> String
configErrorMessage = \case
  ConfigNotFound path ->
    "config file not found: " <> path
  DecodeError err ->
    "failed to decode config: " <> err
