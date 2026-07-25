{-# LANGUAGE OverloadedStrings #-}

module Update.GitHub
  ( fetchGitHubWith,
    fetchGitHubWithHttpLbs,
    listGitHubVersionsWith,
    listGitHubVersionsWithHttpLbs,
    stripAndParse,
  )
where

import Data.Aeson (Value, eitherDecode, withArray, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (toList)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types (RequestHeaders)
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import Update.Http (HttpLbs, httpLbsEither)
import Update.Types (UpdateSource (..))

fetchGitHubWith ::
  Manager ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWith mgr =
  fetchGitHubWithHttpLbs (httpLbsEither mgr)

-- | Injectable HTTP path for latest release / max-tag fallback.
fetchGitHubWithHttpLbs ::
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWithHttpLbs http mToken = \case
  GitHub owner repo prefix -> do
    let commonHeaders = githubHeaders mToken
    releaseResult <- fetchLatestRelease http commonHeaders owner repo prefix
    case releaseResult of
      Right v -> pure (Right v)
      Left _ ->
        fetchMaxTag http commonHeaders owner repo prefix
  other ->
    pure (Left ("Update.GitHub: not a GitHub source: " <> T.pack (show other)))

githubHeaders :: Maybe Text -> RequestHeaders
githubHeaders mToken =
  let authHeaders = case mToken of
        Just t
          | not (T.null t) ->
              [ ("Authorization", encodeUtf8 ("Bearer " <> t))
              ]
        _ -> []
   in [ ("User-Agent", "mndz-overlay-manager"),
        ("Accept", "application/vnd.github+json")
      ]
        <> authHeaders

-- | List comparable package versions (paginated tags), ordered newest-first by PV.
listGitHubVersionsWith ::
  Manager ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text [EbuildVersion])
listGitHubVersionsWith mgr =
  listGitHubVersionsWithHttpLbs (httpLbsEither mgr)

-- | Injectable HTTP path for paginated tag listing.
listGitHubVersionsWithHttpLbs ::
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text [EbuildVersion])
listGitHubVersionsWithHttpLbs http mToken = \case
  GitHub owner repo prefix -> do
    let headers = githubHeaders mToken
    tags <- fetchAllTagNames http headers owner repo 1 []
    pure $ case tags of
      Left err -> Left err
      Right allTags ->
        let versions =
              mapMaybe
                ( \tag ->
                    case stripAndParse prefix tag of
                      Right v@(Numeric {}) -> Just v
                      _ -> Nothing
                )
                allTags
            unique = nubOrd versions
            ordered =
              sortBy
                ( \a b ->
                    case comparePV a b of
                      Just LT -> GT
                      Just GT -> LT
                      Just EQ -> EQ
                      Nothing -> EQ
                )
                unique
         in Right ordered
  other ->
    pure (Left ("Update.GitHub: not a GitHub source: " <> T.pack (show other)))

-- | Paginate tags via @page=@ until a short page is returned.
fetchAllTagNames ::
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Int ->
  [Text] ->
  IO (Either Text [Text])
fetchAllTagNames http headers owner repo page acc = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/tags?per_page=100&page="
          <> show page
  eres <- httpGetJson http headers url
  case eres of
    Left err -> pure (Left err)
    Right val ->
      case parseMaybe parseTagNames val of
        Nothing -> pure (Left "could not parse tags list")
        Just tags ->
          let acc' = acc <> tags
           in if length tags < 100
                then pure (Right acc')
                else fetchAllTagNames http headers owner repo (page + 1) acc'

fetchLatestRelease ::
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either Text EbuildVersion)
fetchLatestRelease http headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases/latest"
  eres <- httpGetJson http headers url
  pure $ case eres of
    Left err -> Left err
    Right val ->
      case parseMaybe parseTagName val of
        Nothing -> Left "could not parse releases/latest tag_name"
        Just tag -> stripAndParse prefix tag

fetchMaxTag ::
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either Text EbuildVersion)
fetchMaxTag http headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/tags?per_page=100"
  eres <- httpGetJson http headers url
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
  HttpLbs ->
  RequestHeaders ->
  String ->
  IO (Either Text Value)
httpGetJson http headers url = do
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders = headers
          }
  eres <- http req
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then case eitherDecode (responseBody resp) of
              Left e -> Left (T.pack e)
              Right v -> Right v
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)
