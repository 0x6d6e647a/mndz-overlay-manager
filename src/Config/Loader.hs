{-# LANGUAGE OverloadedStrings #-}

module Config.Loader
  ( loadConfig,
    loadConfigAllowPlaintextToken,
    defaultConfigPath,
    ConfigError (..),
    configErrorMessage,
    spliceGitHubToken,
    writeConfigAtomic,
  )
where

import Config.TokenEnvelope (isMndz1Envelope)
import Config.Types (OverlayConfig (..))
import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Numeric (showOct)
import System.Directory (getHomeDirectory, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (openTempFile)
import System.Posix.Files (FileStatus, fileMode, getFileStatus, setFileMode)
import System.Posix.Types (FileMode)
import Toml (Result (..), decode)

data ConfigError
  = ConfigNotFound FilePath
  | DecodeError String
  | -- | Wrong mode ('Just' observed bits) or 'stat' failed ('Nothing').
    ConfigModeError FilePath (Maybe FileMode)
  | -- | Present @github-token@ is not a @mndz1.@ envelope. The secret is not stored.
    ConfigPlaintextGitHubToken FilePath
  deriving (Eq, Show)

-- | Whether a present non-envelope @github-token@ is a load error.
data TokenLoadMode
  = RejectPlaintextToken
  | AllowPlaintextToken
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
loadConfig = loadConfigWith RejectPlaintextToken

-- | Load for @github-token --force@ migrate: plaintext on disk is still a present key.
loadConfigAllowPlaintextToken :: Maybe FilePath -> IO (Either ConfigError OverlayConfig)
loadConfigAllowPlaintextToken = loadConfigWith AllowPlaintextToken

loadConfigWith :: TokenLoadMode -> Maybe FilePath -> IO (Either ConfigError OverlayConfig)
loadConfigWith tokenMode override = do
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
                Success _ cfg -> classifyGitHubToken tokenMode path cfg

classifyGitHubToken ::
  TokenLoadMode ->
  FilePath ->
  OverlayConfig ->
  Either ConfigError OverlayConfig
classifyGitHubToken mode path cfg =
  case githubToken cfg of
    Nothing -> Right cfg
    Just raw ->
      let stripped = T.strip raw
       in if T.null stripped
            then Right cfg {githubToken = Nothing}
            else
              if isMndz1Envelope stripped
                then Right cfg {githubToken = Just stripped}
                else case mode of
                  RejectPlaintextToken ->
                    Left (ConfigPlaintextGitHubToken path)
                  AllowPlaintextToken ->
                    Right cfg {githubToken = Just stripped}

-- | Replace or append a top-level @github-token@ quoted string. Other keys and
-- comments are left in place. Re-decode the result before writing.
spliceGitHubToken :: Text -> Text -> Either Text Text
spliceGitHubToken content envelope =
  let lns = T.lines content
      (pre, post) = break isGitHubTokenLine lns
      quoted = "github-token = \"" <> escapeTomlString envelope <> "\""
      spliced = case post of
        [] ->
          let body = T.unlines lns
              withNl =
                if T.null body || T.isSuffixOf "\n" content
                  then body
                  else body <> "\n"
           in withNl <> quoted <> "\n"
        (_old : rest) -> T.unlines (pre <> [quoted] <> rest)
   in case decode spliced of
        Failure errs ->
          Left ("spliced github-token is not valid config: " <> T.pack (unlines errs))
        Success _ (_ :: OverlayConfig) -> Right spliced

isGitHubTokenLine :: Text -> Bool
isGitHubTokenLine ln =
  let s = T.dropWhile isSpace ln
   in not ("#" `T.isPrefixOf` s)
        && "github-token" `T.isPrefixOf` s
        && case T.uncons (T.dropWhile isSpace (T.drop (T.length ("github-token" :: Text)) s)) of
          Just ('=', _) -> True
          _ -> False

escapeTomlString :: Text -> Text
escapeTomlString = T.replace "\\" "\\\\" . T.replace "\"" "\\\""

-- | Atomic replace of @path@ with @content@, mode @0600@.
writeConfigAtomic :: FilePath -> Text -> IO (Either Text ())
writeConfigAtomic path content = do
  let dir = takeDirectory path
  eTmp <- try $ openTempFile dir (takeFileName path <> ".tmp")
  case eTmp of
    Left (err :: IOException) ->
      pure (Left ("cannot write config: " <> T.pack (show err)))
    Right (tmpPath, h) -> do
      hClose h
      T.writeFile tmpPath content
      setFileMode tmpPath expectedConfigMode
      eRen <- try (renameFile tmpPath path)
      pure $ case eRen of
        Left (err :: IOException) ->
          Left ("cannot replace config: " <> T.pack (show err))
        Right () -> Right ()

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
  ConfigPlaintextGitHubToken path ->
    "config file "
      <> path
      <> " github-token is not an encrypted mndz1. envelope; "
      <> "run github-token --force to store a fine-grained PAT"
