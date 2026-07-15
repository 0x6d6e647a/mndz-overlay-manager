{-# LANGUAGE OverloadedStrings #-}

module Update.Auth
  ( resolveGitHubToken,
    resolveGitHubTokenWith,
  )
where

import Config.Types (OverlayConfig (..))
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)

-- | Resolve GitHub API token: env GITHUB_TOKEN, then GH_TOKEN, then config.
resolveGitHubToken :: OverlayConfig -> IO (Maybe Text)
resolveGitHubToken cfg = do
  ght <- lookupEnv "GITHUB_TOKEN"
  gh <- lookupEnv "GH_TOKEN"
  pure $ resolveGitHubTokenWith ght gh (githubToken cfg)

-- | Pure resolver for tests.
resolveGitHubTokenWith ::
  Maybe String ->
  Maybe String ->
  Maybe Text ->
  Maybe Text
resolveGitHubTokenWith mGithubToken mGhToken mConfig =
  firstNonEmpty
    [ fmap T.pack mGithubToken,
      fmap T.pack mGhToken,
      mConfig
    ]
  where
    firstNonEmpty [] = Nothing
    firstNonEmpty (Nothing : xs) = firstNonEmpty xs
    firstNonEmpty (Just t : xs)
      | T.null (T.strip t) = firstNonEmpty xs
      | otherwise = Just (T.strip t)
