{-# LANGUAGE OverloadedStrings #-}

module Update.GitHub
  ( GitHubHttpError (..),
    GitHubLatch,
    newGitHubLatch,
    peekGitHubLatch,
    githubLatchAbortedMessage,
    formatGitHubHttpError,
    gitHubAbortLog,
    gitHubErrorIsRateLimitClass,
    gitHubErrorIsTokenRejected,
    tripsGitHubLatch,
    fetchGitHubWithLatch,
    fetchGitHubWithHttpLbs,
    fetchGitHubWithHttpLbsOn,
    listGitHubVersionsWithLatch,
    listGitHubVersionsWithHttpLbs,
    listGitHubVersionsWithHttpLbsOn,
    githubHeaders,
    githubGetJson,
    latchedHttp,
    stripAndParse,
    parseGitHubOrigin,
    gitRemoteOriginUrl,
  )
where

import Data.Aeson (Value, eitherDecode, withArray, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager,
    Response,
    getUri,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseHeaders,
    responseStatus,
  )
import Network.HTTP.Types (HeaderName, RequestHeaders, ResponseHeaders)
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)
import Update.Http (HttpLbs, httpLbsEither)
import Update.Types (UpdateSource (..))

-- | Structured @api.github.com@ HTTP error (status, URL, JSON message, quota).
data GitHubHttpError = GitHubHttpError
  { gheStatus :: Int,
    gheUrl :: Text,
    gheMessage :: Maybe Text,
    gheRemaining :: Maybe Int,
    gheReset :: Maybe Int
  }
  deriving (Eq, Show)

-- | Run-scoped abort flag: first rate-limit class or 401 stops new REST.
newtype GitHubLatch = GitHubLatch (IORef (Maybe GitHubHttpError))

newGitHubLatch :: IO GitHubLatch
newGitHubLatch = GitHubLatch <$> newIORef Nothing

peekGitHubLatch :: GitHubLatch -> IO (Maybe GitHubHttpError)
peekGitHubLatch (GitHubLatch r) = readIORef r

-- | Returned when a new request is refused because the latch already tripped.
githubLatchAbortedMessage :: Text
githubLatchAbortedMessage =
  "GitHub API work stopped after rate-limit or token rejection"

tripGitHubLatch :: GitHubLatch -> GitHubHttpError -> IO ()
tripGitHubLatch (GitHubLatch r) err =
  atomicModifyIORef' r $ \case
    Nothing -> (Just err, ())
    Just old -> (Just old, ())

-- | Operator log line: status, URL, JSON message, remaining, reset.
formatGitHubHttpError :: GitHubHttpError -> Text
formatGitHubHttpError e =
  let status = "HTTP " <> T.pack (show (gheStatus e)) <> " from " <> gheUrl e
      msg = case gheMessage e of
        Just m | not (T.null m) -> ": " <> m
        _ -> ""
      quota =
        case (gheRemaining e, gheReset e) of
          (Nothing, Nothing) -> ""
          (mr, mreset) ->
            " (remaining="
              <> maybe "?" (T.pack . show) mr
              <> ", reset="
              <> maybe "?" (T.pack . show) mreset
              <> ")"
   in status <> msg <> quota

-- | Command-level abort text (401 names token rejection).
gitHubAbortLog :: GitHubHttpError -> Text
gitHubAbortLog e
  | gitHubErrorIsTokenRejected e =
      "GitHub token was rejected: " <> formatGitHubHttpError e
  | otherwise = formatGitHubHttpError e

-- | Primary/secondary rate limit: remaining 0, or GitHub's rate-limit message.
gitHubErrorIsRateLimitClass :: GitHubHttpError -> Bool
gitHubErrorIsRateLimitClass e =
  (gheStatus e == 403 || gheStatus e == 429)
    && (gheRemaining e == Just 0 || messageIndicatesRateLimit (gheMessage e))

gitHubErrorIsTokenRejected :: GitHubHttpError -> Bool
gitHubErrorIsTokenRejected e = gheStatus e == 401

tripsGitHubLatch :: GitHubHttpError -> Bool
tripsGitHubLatch e =
  gitHubErrorIsRateLimitClass e || gitHubErrorIsTokenRejected e

messageIndicatesRateLimit :: Maybe Text -> Bool
messageIndicatesRateLimit = \case
  Nothing -> False
  Just msg ->
    let lower = T.toLower msg
     in "rate limit exceeded" `T.isInfixOf` lower
          || "secondary rate limit" `T.isInfixOf` lower

fetchGitHubWithLatch ::
  GitHubLatch ->
  Manager ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWithLatch latch mgr =
  fetchGitHubWithHttpLbsOn latch (httpLbsEither mgr)

-- | Injectable HTTP path for latest release / max-tag fallback (fresh latch).
fetchGitHubWithHttpLbs ::
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWithHttpLbs http mToken src = do
  latch <- newGitHubLatch
  fetchGitHubWithHttpLbsOn latch http mToken src

-- | Same as 'fetchGitHubWithHttpLbs' on a shared run-scoped latch.
fetchGitHubWithHttpLbsOn ::
  GitHubLatch ->
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text EbuildVersion)
fetchGitHubWithHttpLbsOn latch http mToken = \case
  GitHub owner repo prefix -> do
    let commonHeaders = githubHeaders mToken
    releaseResult <-
      fetchLatestRelease latch http commonHeaders owner repo prefix
    case releaseResult of
      Right v -> pure (Right v)
      Left err
        | skipTagsFallback err ->
            pure (Left (formatGitHubGetError err))
        | otherwise -> do
            tagResult <- fetchMaxTag latch http commonHeaders owner repo prefix
            pure (mapLeft formatGitHubGetError tagResult)
  other ->
    pure (Left ("Update.GitHub: not a GitHub source: " <> T.pack (show other)))

-- | GET JSON from @api.github.com@ with headers, latch, and formatted errors.
githubGetJson ::
  GitHubLatch ->
  HttpLbs ->
  Maybe Text ->
  String ->
  IO (Either Text Value)
githubGetJson latch http mToken url =
  mapLeft formatGitHubGetError
    <$> httpGetJson latch http (githubHeaders mToken) url

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

-- | Wrap an HTTP runner so new @api.github.com@ requests stop after a latch trip.
-- @raw.githubusercontent.com@ is left alone.
latchedHttp :: GitHubLatch -> HttpLbs -> HttpLbs
latchedHttp latch http req = do
  let url = T.pack (show (getUri req))
  if not (isApiGitHubUrl url)
    then http req
    else do
      tripped <- peekGitHubLatch latch
      case tripped of
        Just _ -> pure (Left githubLatchAbortedMessage)
        Nothing -> do
          eres <- http req
          case eres of
            Left err -> pure (Left err)
            Right resp -> do
              let code = statusCode (responseStatus resp)
              if code >= 200 && code < 300
                then pure (Right resp)
                else do
                  let ghe = gitHubHttpErrorFromResponse url resp
                  whenLatchClass latch ghe
                  pure (Right resp)

isApiGitHubUrl :: Text -> Bool
isApiGitHubUrl url =
  "api.github.com" `T.isInfixOf` url

whenLatchClass :: GitHubLatch -> GitHubHttpError -> IO ()
whenLatchClass latch ghe =
  when_ (tripsGitHubLatch ghe) (tripGitHubLatch latch ghe)

when_ :: Bool -> IO () -> IO ()
when_ True act = act
when_ False _ = pure ()

-- | List comparable package versions (paginated tags), ordered newest-first by PV.
listGitHubVersionsWithLatch ::
  GitHubLatch ->
  Manager ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text [EbuildVersion])
listGitHubVersionsWithLatch latch mgr =
  listGitHubVersionsWithHttpLbsOn latch (httpLbsEither mgr)

-- | Injectable HTTP path for paginated tag listing (fresh latch).
listGitHubVersionsWithHttpLbs ::
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text [EbuildVersion])
listGitHubVersionsWithHttpLbs http mToken src = do
  latch <- newGitHubLatch
  listGitHubVersionsWithHttpLbsOn latch http mToken src

-- | Same as 'listGitHubVersionsWithHttpLbs' on a shared run-scoped latch.
listGitHubVersionsWithHttpLbsOn ::
  GitHubLatch ->
  HttpLbs ->
  Maybe Text ->
  UpdateSource ->
  IO (Either Text [EbuildVersion])
listGitHubVersionsWithHttpLbsOn latch http mToken = \case
  GitHub owner repo prefix -> do
    let headers = githubHeaders mToken
    tags <- fetchAllTagNames latch http headers owner repo 1 []
    pure $ case tags of
      Left err -> Left (formatGitHubGetError err)
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

data GitHubGetError
  = GitHubErrHttp GitHubHttpError
  | GitHubErrTransport Text
  | GitHubErrParse Text
  | GitHubErrAborted Text

formatGitHubGetError :: GitHubGetError -> Text
formatGitHubGetError = \case
  GitHubErrHttp e -> formatGitHubHttpError e
  GitHubErrTransport t -> t
  GitHubErrParse t -> t
  GitHubErrAborted t -> t

-- | Do not fall back to tags after HTTP 403/429 (or a latch abort).
skipTagsFallback :: GitHubGetError -> Bool
skipTagsFallback = \case
  GitHubErrHttp e -> gheStatus e == 403 || gheStatus e == 429
  GitHubErrAborted _ -> True
  _ -> False

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = \case
  Left a -> Left (f a)
  Right c -> Right c

-- | Paginate tags via @page=@ until a short page is returned.
fetchAllTagNames ::
  GitHubLatch ->
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Int ->
  [Text] ->
  IO (Either GitHubGetError [Text])
fetchAllTagNames latch http headers owner repo page acc = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/tags?per_page=100&page="
          <> show page
  eres <- httpGetJson latch http headers url
  case eres of
    Left err -> pure (Left err)
    Right val ->
      case parseMaybe parseTagNames val of
        Nothing -> pure (Left (GitHubErrParse "could not parse tags list"))
        Just tags ->
          let acc' = acc <> tags
           in if length tags < 100
                then pure (Right acc')
                else fetchAllTagNames latch http headers owner repo (page + 1) acc'

fetchLatestRelease ::
  GitHubLatch ->
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either GitHubGetError EbuildVersion)
fetchLatestRelease latch http headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases/latest"
  eres <- httpGetJson latch http headers url
  pure $ case eres of
    Left err -> Left err
    Right val ->
      case parseMaybe parseTagName val of
        Nothing ->
          Left (GitHubErrParse "could not parse releases/latest tag_name")
        Just tag ->
          case stripAndParse prefix tag of
            Left e -> Left (GitHubErrParse e)
            Right v -> Right v

fetchMaxTag ::
  GitHubLatch ->
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  Text ->
  IO (Either GitHubGetError EbuildVersion)
fetchMaxTag latch http headers owner repo prefix = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/tags?per_page=100"
  eres <- httpGetJson latch http headers url
  pure $ case eres of
    Left err -> Left err
    Right val ->
      case parseMaybe parseTagNames val of
        Nothing -> Left (GitHubErrParse "could not parse tags list")
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
                Nothing ->
                  Left (GitHubErrParse "no comparable tags after prefix strip")
                Just v -> Right v

parseTagName :: Value -> Parser Text
parseTagName = withObject "release" $ \o -> o .: "tag_name"

parseTagNames :: Value -> Parser [Text]
parseTagNames = withArray "tags" $ \arr ->
  mapM (withObject "tag" (.: "name")) (toList arr)

-- | Parse @github.com/{owner}/{repo}@ from an origin remote URL.
--
-- Accepts SSH (@git\@github.com:owner/repo.git@), @ssh://git\@github.com/…@,
-- and HTTPS, with an optional @.git@ suffix. Other hosts and unparsable
-- strings fail.
parseGitHubOrigin :: Text -> Either Text (Text, Text)
parseGitHubOrigin raw =
  let t = T.strip raw
   in case extractOwnerRepo t of
        Just (owner, repo)
          | validGitHubName owner && validGitHubName repo ->
              Right (owner, repo)
        _ ->
          Left
            "assets-path origin is not a github.com owner/repo URL \
            \(SSH or HTTPS, optional .git)"

extractOwnerRepo :: Text -> Maybe (Text, Text)
extractOwnerRepo t
  | "git@github.com:" `T.isPrefixOf` t =
      splitOwnerRepo (T.drop (T.length ("git@github.com:" :: Text)) t)
  | "ssh://git@github.com/" `T.isPrefixOf` t =
      splitOwnerRepo (T.drop (T.length ("ssh://git@github.com/" :: Text)) t)
  | "ssh://github.com/" `T.isPrefixOf` t =
      splitOwnerRepo (T.drop (T.length ("ssh://github.com/" :: Text)) t)
  | "https://github.com/" `T.isPrefixOf` t =
      splitOwnerRepo (T.drop (T.length ("https://github.com/" :: Text)) t)
  | "http://github.com/" `T.isPrefixOf` t =
      splitOwnerRepo (T.drop (T.length ("http://github.com/" :: Text)) t)
  | otherwise = Nothing

splitOwnerRepo :: Text -> Maybe (Text, Text)
splitOwnerRepo rest =
  let trimmed = T.dropWhileEnd (== '/') (stripDotGit rest)
      (owner, slashRepo) = T.breakOn "/" trimmed
   in case T.uncons slashRepo of
        Just ('/', repo)
          | not (T.null owner),
            not (T.null repo),
            not ("/" `T.isInfixOf` repo) ->
              Just (owner, repo)
        _ -> Nothing

stripDotGit :: Text -> Text
stripDotGit t
  | ".git" `T.isSuffixOf` t = T.dropEnd 4 t
  | otherwise = t

validGitHubName :: Text -> Bool
validGitHubName name =
  not (T.null name)
    && T.all ok name
  where
    ok c =
      isAsciiLower c
        || isAsciiUpper c
        || isDigit c
        || c == '-'
        || c == '_'
        || c == '.'

-- | @git remote get-url origin@ in @dir@.
gitRemoteOriginUrl :: FilePath -> IO (Either Text Text)
gitRemoteOriginUrl dir = do
  (code, out, err) <-
    readProcessWithExitCode
      "git"
      ["-C", dir, "remote", "get-url", "origin"]
      ""
  let stdoutT = T.strip (T.pack out)
      errT = T.strip (T.pack err)
  pure $
    if code /= ExitSuccess
      then
        Left
          ( "assets-path origin remote is missing or unreadable"
              <> if T.null errT then "" else ": " <> errT
          )
      else
        if T.null stdoutT
          then Left "assets-path origin remote URL is empty"
          else Right stdoutT

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
  GitHubLatch ->
  HttpLbs ->
  RequestHeaders ->
  String ->
  IO (Either GitHubGetError Value)
httpGetJson latch http headers url = do
  tripped <- peekGitHubLatch latch
  case tripped of
    Just _ -> pure (Left (GitHubErrAborted githubLatchAbortedMessage))
    Nothing -> do
      req0 <- parseRequest url
      let req =
            req0
              { method = "GET",
                requestHeaders = headers
              }
      eres <- http req
      case eres of
        Left err -> pure (Left (GitHubErrTransport err))
        Right resp -> do
          let code = statusCode (responseStatus resp)
          if code >= 200 && code < 300
            then pure $
              case eitherDecode (responseBody resp) of
                Left e -> Left (GitHubErrParse (T.pack e))
                Right v -> Right v
            else do
              let ghe = gitHubHttpErrorFromResponse (T.pack url) resp
              whenLatchClass latch ghe
              pure (Left (GitHubErrHttp ghe))

gitHubHttpErrorFromResponse :: Text -> Response LBS.ByteString -> GitHubHttpError
gitHubHttpErrorFromResponse url resp =
  let hs = responseHeaders resp
   in GitHubHttpError
        { gheStatus = statusCode (responseStatus resp),
          gheUrl = url,
          gheMessage = githubJsonMessage (responseBody resp),
          gheRemaining = headerInt hs "x-ratelimit-remaining",
          gheReset = headerInt hs "x-ratelimit-reset"
        }

githubJsonMessage :: LBS.ByteString -> Maybe Text
githubJsonMessage body =
  case eitherDecode body of
    Right val ->
      parseMaybe (withObject "github-error" (.: "message")) val
    Left _ -> Nothing

headerInt :: ResponseHeaders -> HeaderName -> Maybe Int
headerInt hs name = do
  raw <- lookup name hs
  readMaybe (BS8.unpack raw)
