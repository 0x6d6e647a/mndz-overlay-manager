{-# LANGUAGE OverloadedStrings #-}

module Update.GitHub
  ( fetchGitHub,
    fetchGitHubWith,
  )
where

import Control.Exception (SomeException, catch)
import Data.Aeson (Value, eitherDecode, withArray, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (toList)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (RequestHeaders)
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import Update.Types (UpdateSource (..))

-- | Fetch latest version from GitHub (releases/latest, then tags fallback).
-- Uses unauthenticated API when @mToken@ is 'Nothing'.
fetchGitHub :: UpdateSource -> IO (Either Text EbuildVersion)
fetchGitHub src = do
  mgr <- newManager tlsManagerSettings
  fetchGitHubWith mgr Nothing src

fetchGitHubWith ::
  Manager ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWith mgr mToken = \case
  GitHub owner repo prefix -> do
    let authHeaders = case mToken of
          Just t
            | not (T.null t) ->
                [ ("Authorization", encodeUtf8 ("Bearer " <> t))
                ]
          _ -> []
        commonHeaders =
          [ ("User-Agent", "mndz-overlay-manager"),
            ("Accept", "application/vnd.github+json")
          ]
            <> authHeaders
    releaseResult <- fetchLatestRelease mgr commonHeaders owner repo prefix
    case releaseResult of
      Right v -> pure (Right v)
      Left _ ->
        fetchMaxTag mgr commonHeaders owner repo prefix
  other ->
    pure (Left ("Update.GitHub: not a GitHub source: " <> T.pack (show other)))

fetchLatestRelease ::
  Manager ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either Text EbuildVersion)
fetchLatestRelease mgr headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases/latest"
  eres <- httpGetJson mgr headers url
  pure $ case eres of
    Left err -> Left err
    Right val ->
      case parseMaybe parseTagName val of
        Nothing -> Left "could not parse releases/latest tag_name"
        Just tag -> stripAndParse prefix tag

fetchMaxTag ::
  Manager ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either Text EbuildVersion)
fetchMaxTag mgr headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/tags?per_page=100"
  eres <- httpGetJson mgr headers url
  pure $ case eres of
    Left err -> Left err
    Right val ->
      case parseMaybe parseTagNames val of
        Nothing -> Left "could not parse tags list"
        Just tags ->
          let versions =
                mapMaybe
                  ( \tag ->
                      case stripAndParse prefix tag of
                        Right v@(Numeric {}) -> Just v
                        _ -> Nothing
                  )
                  tags
           in case maximumByPV versions of
                Nothing -> Left "no comparable tags after prefix strip"
                Just v -> Right v

parseTagName :: Value -> Parser Text
parseTagName = withObject "release" $ \o -> o .: "tag_name"

parseTagNames :: Value -> Parser [Text]
parseTagNames = withArray "tags" $ \arr ->
  mapM (withObject "tag" (.: "name")) (toList arr)

stripAndParse :: Text -> Text -> Either Text EbuildVersion
stripAndParse prefix tag =
  let stripped
        | T.null prefix = tag
        | prefix `T.isPrefixOf` tag = T.drop (T.length prefix) tag
        | otherwise = tag
   in if T.null stripped
        then Left ("empty version after stripping prefix from tag " <> tag)
        else Right (parseEbuildVersion stripped)

maximumByPV :: [EbuildVersion] -> Maybe EbuildVersion
maximumByPV [] = Nothing
maximumByPV (x : xs) = Just (foldl' maxPV x xs)
  where
    maxPV a b =
      case comparePV a b of
        Just LT -> b
        Just _ -> a
        Nothing -> a

httpGetJson ::
  Manager ->
  RequestHeaders ->
  String ->
  IO (Either Text Value)
httpGetJson mgr headers url = do
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders = headers
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then case eitherDecode (responseBody resp) of
              Left e -> Left (T.pack e)
              Right v -> Right v
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
