{-# LANGUAGE OverloadedStrings #-}

module Update.Auth
  ( TokenResolution (..),
    resolveGitHubToken,
    resolveGitHubTokenWith,
    resolveTokenSource,
    envTokenWarnings,
    fineGrainedPatPrefix,
    isFineGrainedPat,
    decryptConfigEnvelope,
    SecretPrompt (..),
    productionSecretPrompt,
    promptSecretOnTty,
  )
where

import Config.TokenEnvelope (isMndz1Envelope, unwrapToken)
import Config.Types (OverlayConfig (..))
import Control.Exception (IOException, bracket_, finally, try)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.IO
  ( Handle,
    IOMode (ReadWriteMode),
    hFlush,
    hGetEcho,
    hGetLine,
    hPutStr,
    hSetEcho,
    withFile,
  )

-- | Fine-grained PAT prefix required by the @github-token@ setter.
fineGrainedPatPrefix :: Text
fineGrainedPatPrefix = "github_pat_"

isFineGrainedPat :: Text -> Bool
isFineGrainedPat t = fineGrainedPatPrefix `T.isPrefixOf` T.strip t

-- | Outcome of env-then-config classification (no decrypt).
data TokenResolution
  = -- | Environment token wins; Bool is whether it starts with @github_pat_@.
    ResolvedEnv Text Bool
  | -- | Config holds a @mndz1.@ envelope; decrypt only when a token is required.
    NeedsDecrypt Text
  | NoToken
  deriving (Eq, Show)

-- | Resolve a live GitHub API token from the environment only.
--
-- Config envelopes are not returned as tokens. Callers that need a config
-- token must decrypt via 'decryptConfigEnvelope' after 'resolveTokenSource'.
resolveGitHubToken :: OverlayConfig -> IO (Maybe Text)
resolveGitHubToken cfg = do
  ght <- lookupEnv "GITHUB_TOKEN"
  gh <- lookupEnv "GH_TOKEN"
  pure $ case resolveTokenSource ght gh (githubToken cfg) of
    ResolvedEnv tok _ -> Just tok
    _ -> Nothing

-- | Pure env resolver. The config argument is ignored as a live secret
-- (envelopes are not API tokens). Kept so existing tests can pass three sources.
resolveGitHubTokenWith ::
  Maybe String ->
  Maybe String ->
  Maybe Text ->
  Maybe Text
resolveGitHubTokenWith mGithubToken mGhToken _mConfig =
  firstNonEmpty
    [ fmap T.pack mGithubToken,
      fmap T.pack mGhToken
    ]
  where
    firstNonEmpty [] = Nothing
    firstNonEmpty (Nothing : xs) = firstNonEmpty xs
    firstNonEmpty (Just t : xs)
      | T.null (T.strip t) = firstNonEmpty xs
      | otherwise = Just (T.strip t)

-- | Classify env vs config envelope without decrypting.
resolveTokenSource ::
  Maybe String ->
  Maybe String ->
  Maybe Text ->
  TokenResolution
resolveTokenSource mGithubToken mGhToken mConfig =
  case firstNonEmpty [fmap T.pack mGithubToken, fmap T.pack mGhToken] of
    Just tok -> ResolvedEnv tok (isFineGrainedPat tok)
    Nothing ->
      case fmap T.strip mConfig of
        Just env | not (T.null env) && isMndz1Envelope env -> NeedsDecrypt env
        _ -> NoToken
  where
    firstNonEmpty [] = Nothing
    firstNonEmpty (Nothing : xs) = firstNonEmpty xs
    firstNonEmpty (Just t : xs)
      | T.null (T.strip t) = firstNonEmpty xs
      | otherwise = Just (T.strip t)

-- | Warnings when an environment token wins. Empty otherwise.
envTokenWarnings :: TokenResolution -> [Text]
envTokenWarnings = \case
  ResolvedEnv _ fine ->
    "using GITHUB_TOKEN or GH_TOKEN instead of an encrypted config github-token"
      : ["environment GitHub token is not a fine-grained PAT (github_pat_)" | not fine]
  _ -> []

-- | Injectable TTY secret prompt (unit tests supply fakes; no live TTY).
data SecretPrompt = SecretPrompt
  { spControllingTty :: IO (Maybe FilePath),
    -- | Prompt on the given TTY path (no echo).
    spReadSecret :: FilePath -> Text -> IO (Either Text Text),
    spPauseUi :: IO (),
    spResumeUi :: IO ()
  }

productionSecretPrompt :: IO () -> IO () -> SecretPrompt
productionSecretPrompt pause resume =
  SecretPrompt
    { spControllingTty = controllingTtyPath,
      spReadSecret = promptSecretOnTty,
      spPauseUi = pause,
      spResumeUi = resume
    }

controllingTtyPath :: IO (Maybe FilePath)
controllingTtyPath = do
  ok <- doesFileExist "/dev/tty"
  if not ok
    then pure Nothing
    else do
      opened <- try openOk
      pure $ case opened of
        Left (_ :: IOException) -> Nothing
        Right () -> Just "/dev/tty"
  where
    openOk = withFile "/dev/tty" ReadWriteMode $ \(_ :: Handle) -> pure ()

-- | Write @prompt@ to the TTY, read a line with echo off.
promptSecretOnTty :: FilePath -> Text -> IO (Either Text Text)
promptSecretOnTty tty prompt = do
  result <-
    try $
      withFile tty ReadWriteMode $ \h -> do
        hPutStr h (T.unpack prompt)
        hFlush h
        old <- hGetEcho h
        hSetEcho h False
        line <-
          hGetLine h
            `finally` (hSetEcho h old >> hPutStr h "\n" >> hFlush h)
        pure (T.pack line)
  pure $ case result of
    Left (e :: IOException) ->
      Left ("failed to prompt on controlling TTY: " <> T.pack (show e))
    Right t
      | T.null (T.strip t) -> Left "empty secret is not allowed"
      | otherwise -> Right (T.strip t)

-- | Decrypt a config envelope on a controlling TTY. Caches the plaintext for
-- the 'IORef' lifetime (one @update@ process).
decryptConfigEnvelope ::
  SecretPrompt ->
  IORef (Maybe Text) ->
  Text ->
  IO (Either Text Text)
decryptConfigEnvelope prompt cache envelope = do
  cached <- readIORef cache
  case cached of
    Just tok -> pure (Right tok)
    Nothing -> do
      mTty <- spControllingTty prompt
      case mTty of
        Nothing ->
          pure $
            Left
              "GitHub token decrypt requires a controlling TTY; \
              \set GITHUB_TOKEN or GH_TOKEN for unattended runs"
        Just tty ->
          bracket_ (spPauseUi prompt) (spResumeUi prompt) $ do
            ePass <- spReadSecret prompt tty "Wrap password for github-token: "
            case ePass of
              Left err -> pure (Left err)
              Right pw ->
                case unwrapToken pw envelope of
                  Left err -> pure (Left err)
                  Right tok -> do
                    writeIORef cache (Just tok)
                    pure (Right tok)
