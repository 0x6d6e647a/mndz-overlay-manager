{-# LANGUAGE OverloadedStrings #-}

-- | Statuspage + @GET /rate_limit@ preflight before live @api.github.com@ work.
module Update.GitHubHealth
  ( GitHubHealthScope (..),
    GitHubHealthOutcome (..),
    statuspageSummaryUrl,
    gitHubRateLimitUrl,
    runGitHubHealthPreflight,
    runGitOperationsHealth,
    productionGitHubHealthHttp,
    interpretHealthOutcome,
  )
where

import Data.Aeson (Value, eitherDecode, withArray, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (method, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Update.GitHub
  ( GitHubLatch,
    formatGitHubHttpError,
    gitHubAbortLog,
    gitHubErrorIsTokenRejected,
    githubGetJson,
    peekGitHubLatch,
  )
import Update.Http (HttpLbs, httpLbsEither)

productionGitHubHealthHttp :: IO HttpLbs
productionGitHubHealthHttp = httpLbsEither <$> newManager tlsManagerSettings

interpretHealthOutcome :: GitHubHealthOutcome -> Either Text [Text]
interpretHealthOutcome = \case
  GitHubHealthFailed err -> Left err
  GitHubHealthOk warns -> Right warns

statuspageSummaryUrl :: String
statuspageSummaryUrl = "https://www.githubstatus.com/api/v2/summary.json"

gitHubRateLimitUrl :: String
gitHubRateLimitUrl = "https://api.github.com/rate_limit"

-- | Which Statuspage components this preflight inspects.
data GitHubHealthScope = GitHubHealthScope
  { -- | Always when this run will call @api.github.com@.
    ghsCheckApiRequests :: Bool,
    -- | Only when this @update@ will @git push@ assets.
    ghsCheckGitOperations :: Bool
  }
  deriving (Eq, Show)

data GitHubHealthOutcome
  = GitHubHealthOk [Text]
  | GitHubHealthFailed Text
  deriving (Eq, Show)

-- | Statuspage (API Requests, optional Git Operations) then @GET /rate_limit@.
runGitHubHealthPreflight ::
  GitHubLatch ->
  HttpLbs ->
  Maybe Text ->
  GitHubHealthScope ->
  IO GitHubHealthOutcome
runGitHubHealthPreflight latch http mToken scope = do
  page <- runStatuspageCheck http (requiredComponents scope)
  case page of
    GitHubHealthFailed err -> pure (GitHubHealthFailed err)
    GitHubHealthOk pageWarns -> do
      quota <- runRateLimitCheck latch http mToken
      pure $ case quota of
        GitHubHealthFailed err -> GitHubHealthFailed err
        GitHubHealthOk quotaWarns -> GitHubHealthOk (pageWarns <> quotaWarns)

-- | Git Operations Statuspage check immediately before assets @git push@.
runGitOperationsHealth :: HttpLbs -> IO GitHubHealthOutcome
runGitOperationsHealth http =
  runStatuspageCheck http ["Git Operations"]

requiredComponents :: GitHubHealthScope -> [Text]
requiredComponents scope =
  ["API Requests" | ghsCheckApiRequests scope]
    <> ["Git Operations" | ghsCheckGitOperations scope]

runStatuspageCheck :: HttpLbs -> [Text] -> IO GitHubHealthOutcome
runStatuspageCheck _ [] = pure (GitHubHealthOk [])
runStatuspageCheck http names = do
  req0 <- parseRequest statuspageSummaryUrl
  let req = req0 {method = "GET"}
  eres <- http req
  case eres of
    Left err ->
      pure $
        GitHubHealthOk
          ["GitHub Statuspage could not be fetched: " <> err]
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code < 200 || code >= 300
            then
              pure $
                GitHubHealthOk
                  [ "GitHub Statuspage could not be fetched: HTTP "
                      <> T.pack (show code)
                  ]
            else pure $
              case eitherDecode (responseBody resp) of
                Left _ ->
                  GitHubHealthOk
                    ["GitHub Statuspage could not be fetched: invalid JSON"]
                Right val ->
                  classifyStatuspage names val

classifyStatuspage :: [Text] -> Value -> GitHubHealthOutcome
classifyStatuspage names val =
  let comps = fromMaybe [] (parseMaybe parseComponents val)
      inspected = [c | c <- comps, ccName c `elem` names]
      outages =
        [ ccName c <> " is " <> ccStatus c
        | c <- inspected,
          ccStatus c == "partial_outage" || ccStatus c == "major_outage"
        ]
      degraded =
        [ "GitHub "
            <> ccName c
            <> " is degraded_performance"
        | c <- inspected,
          ccStatus c == "degraded_performance"
        ]
   in case outages of
        (o : _) ->
          GitHubHealthFailed ("GitHub Statuspage: " <> o)
        [] -> GitHubHealthOk degraded

data StatusComponent = StatusComponent
  { ccName :: Text,
    ccStatus :: Text
  }

parseComponents :: Value -> Parser [StatusComponent]
parseComponents = withObject "statuspage" $ \o -> do
  arr <- o .: "components"
  withArray "components" (mapM parseComponent . toList) arr

parseComponent :: Value -> Parser StatusComponent
parseComponent = withObject "component" $ \o ->
  StatusComponent <$> o .: "name" <*> o .: "status"

runRateLimitCheck ::
  GitHubLatch ->
  HttpLbs ->
  Maybe Text ->
  IO GitHubHealthOutcome
runRateLimitCheck latch http mToken = do
  eres <- githubGetJson latch http mToken gitHubRateLimitUrl
  case eres of
    Left err -> do
      mAbort <- peekGitHubLatch latch
      pure $
        case mAbort of
          Just ghe
            | gitHubErrorIsTokenRejected ghe ->
                GitHubHealthFailed (gitHubAbortLog ghe)
            | otherwise ->
                GitHubHealthFailed (formatGitHubHttpError ghe)
          Nothing ->
            GitHubHealthFailed ("GitHub /rate_limit could not be fetched: " <> err)
    Right val ->
      pure $
        case parseMaybe parseCoreQuota val of
          Nothing ->
            GitHubHealthFailed
              "GitHub /rate_limit could not be fetched: missing core.remaining"
          Just (remaining, mReset)
            | remaining == 0 ->
                GitHubHealthFailed $
                  "GitHub API rate limit remaining is 0"
                    <> maybe "" (\r -> " (reset=" <> T.pack (show r) <> ")") mReset
            | otherwise -> GitHubHealthOk []

parseCoreQuota :: Value -> Parser (Int, Maybe Int)
parseCoreQuota = withObject "rate_limit" $ \o -> do
  resources <- o .: "resources"
  core <- withObject "resources" (.: "core") resources
  withObject
    "core"
    ( \c -> do
        remaining <- c .: "remaining"
        reset <- c .:? "reset"
        pure (remaining, reset)
    )
    core
