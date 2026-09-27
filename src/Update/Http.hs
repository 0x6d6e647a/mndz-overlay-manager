{-# LANGUAGE OverloadedStrings #-}

module Update.Http
  ( HttpLbs,
    httpLbsEither,
    fetchHttpWith,
    fetchHttpWithHttp,
    fetchHttpJsonWith,
    fetchHttpJsonWithHttp,
    resolveGrokBotCommit,
    tryHttp,
  )
where

import Control.Exception (SomeException, catch)
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( Manager,
    Request,
    Response,
    httpLbs,
    method,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version
  ( EbuildVersion (..),
    parseEbuildVersion,
    renderPVNoRev,
  )
import Update.Types (UpdateSource (..))

-- | Injectable HTTP GET/POST runner for tests (no live network).
type HttpLbs = Request -> IO (Either Text (Response L8.ByteString))

-- | Production runner: @tryHttp (httpLbs req mgr)@.
httpLbsEither :: Manager -> HttpLbs
httpLbsEither mgr req = tryHttp (httpLbs req mgr)

fetchHttpWith :: Manager -> UpdateSource -> IO (Either Text EbuildVersion)
fetchHttpWith mgr = fetchHttpWithHttp (httpLbsEither mgr)

-- | Fetch version body from an Http primary (and optional fallback) URL.
fetchHttpWithHttp :: HttpLbs -> UpdateSource -> IO (Either Text EbuildVersion)
fetchHttpWithHttp http = \case
  Http primary mFallback -> do
    primaryResult <- tryUrl http primary
    case primaryResult of
      Right v -> pure (Right v)
      Left _ ->
        case mFallback of
          Nothing -> pure primaryResult
          Just fb -> tryUrl http fb
  other ->
    pure (Left ("Update.Http: not an Http source: " <> T.pack (show other)))

tryUrl :: HttpLbs -> Text -> IO (Either Text EbuildVersion)
tryUrl http urlText = do
  ebody <- getUrlBody http urlText
  pure $ case ebody of
    Left err -> Left err
    Right raw ->
      let body = T.strip (T.pack (L8.unpack raw))
       in if T.null body
            then Left ("empty version body from " <> urlText)
            else Right (parseEbuildVersion body)

-- | GET a URL and return the raw 2xx body.
getUrlBody :: HttpLbs -> Text -> IO (Either Text L8.ByteString)
getUrlBody http urlText = do
  req0 <- parseRequest (T.unpack urlText)
  let req = req0 {method = "GET"}
  eres <- http req
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then Right (responseBody resp)
            else Left ("HTTP " <> T.pack (show code) <> " from " <> urlText)

fetchHttpJsonWith :: Manager -> UpdateSource -> IO (Either Text EbuildVersion)
fetchHttpJsonWith mgr = fetchHttpJsonWithHttp (httpLbsEither mgr)

-- | Read @httpJsonField@ from each URL. Differing values are a fetch error.
fetchHttpJsonWithHttp :: HttpLbs -> UpdateSource -> IO (Either Text EbuildVersion)
fetchHttpJsonWithHttp http = \case
  HttpJson urls field
    | null urls -> pure (Left "HttpJson: no feed URL")
    | otherwise -> do
        eVers <- mapM (fetchJsonVersion http field) urls
        pure $ case sequence eVers of
          Left err -> Left err
          Right vers -> agreeVersions vers
  other ->
    pure (Left ("Update.Http: not an HttpJson source: " <> T.pack (show other)))

fetchJsonVersion :: HttpLbs -> Text -> Text -> IO (Either Text Text)
fetchJsonVersion http field url = do
  ebody <- getUrlBody http url
  pure $ case ebody of
    Left err -> Left err
    Right body -> jsonVersionField url field body

jsonVersionField :: Text -> Text -> L8.ByteString -> Either Text Text
jsonVersionField url field body =
  case decodeObject url body of
    Left err -> Left err
    Right obj ->
      case lookupStringField url field obj of
        Left err -> Left err
        Right stripped ->
          case parseEbuildVersion stripped of
            Numeric {} -> Right stripped
            Raw _ ->
              Left
                ( "HttpJson: field "
                    <> field
                    <> " is not a version string from "
                    <> url
                )

agreeVersions :: [Text] -> Either Text EbuildVersion
agreeVersions vers =
  case vers of
    [] -> Left "HttpJson: no feed URL"
    (v : rest)
      | all (== v) rest -> Right (parseEbuildVersion v)
      | otherwise -> Left "HttpJson: feed versions disagree"

-- | One stable-feed document used to pin @GROK_BOT_COMMIT@.
data GrokBotFeed = GrokBotFeed
  { gbfUrl :: Text,
    gbfVersion :: Text,
    gbfCommit :: Text,
    gbfDebUrl :: Text
  }

-- | GET both feeds again and return the shared @commitSha@.
-- The planned remote PV, both versions, both commits, and each @debUrl@
-- template must agree. This does not trust a version cached earlier.
resolveGrokBotCommit ::
  HttpLbs ->
  UpdateSource ->
  EbuildVersion ->
  IO (Either Text Text)
resolveGrokBotCommit http src planned =
  case src of
    HttpJson urls field -> do
      eFeeds <- mapM (fetchGrokBotFeed http field) urls
      pure $ case sequence eFeeds of
        Left err -> Left err
        Right feeds -> validateGrokBotFeeds feeds planned
    other ->
      pure
        ( Left
            ( "grok-bot-bin: expected HttpJson feeds, got "
                <> T.pack (show other)
            )
        )

fetchGrokBotFeed :: HttpLbs -> Text -> Text -> IO (Either Text GrokBotFeed)
fetchGrokBotFeed http field url = do
  ebody <- getUrlBody http url
  pure $ case ebody of
    Left err -> Left err
    Right body -> parseGrokBotFeed url field body

parseGrokBotFeed :: Text -> Text -> L8.ByteString -> Either Text GrokBotFeed
parseGrokBotFeed url field body = do
  obj <- decodeObject url body
  version <- jsonVersionField url field body
  commit <- lookupStringField url "commitSha" obj
  debUrl <- lookupStringField url "debUrl" obj
  pure
    GrokBotFeed
      { gbfUrl = url,
        gbfVersion = version,
        gbfCommit = commit,
        gbfDebUrl = debUrl
      }

decodeObject :: Text -> L8.ByteString -> Either Text (KeyMap.KeyMap Value)
decodeObject url body =
  case eitherDecode body of
    Right (Object obj) -> Right obj
    _ -> Left ("HttpJson: body is not a JSON object from " <> url)

lookupStringField :: Text -> Text -> KeyMap.KeyMap Value -> Either Text Text
lookupStringField url field obj =
  case KeyMap.lookup (Key.fromText field) obj of
    Nothing -> Left ("HttpJson: missing field " <> field <> " from " <> url)
    Just (String t) -> Right (T.strip t)
    Just _ ->
      Left
        ( "HttpJson: field "
            <> field
            <> " is not a version string from "
            <> url
        )

validateGrokBotFeeds :: [GrokBotFeed] -> EbuildVersion -> Either Text Text
validateGrokBotFeeds feeds planned = do
  let plannedText = renderPVNoRev planned
      x64s = [f | f <- feeds, archOf (gbfUrl f) == Just FeedX64]
      arms = [f | f <- feeds, archOf (gbfUrl f) == Just FeedArm64]
      other = [gbfUrl f | f <- feeds, isNothing (archOf (gbfUrl f))]
  case (x64s, arms, other) of
    ([x64], [arm], []) -> do
      mapM_ (checkVersion plannedText) [x64, arm]
      commit <- sharedCommit x64 arm
      mapM_ (checkDebUrl commit) [x64, arm]
      pure commit
    _ ->
      Left "grok-bot-bin: expected one linux-x64 feed and one linux-arm64 feed"

checkVersion :: Text -> GrokBotFeed -> Either Text ()
checkVersion planned feed
  | gbfVersion feed == planned = Right ()
  | otherwise =
      Left
        ( "grok-bot-bin: feed version "
            <> gbfVersion feed
            <> " does not match planned PV "
            <> planned
        )

sharedCommit :: GrokBotFeed -> GrokBotFeed -> Either Text Text
sharedCommit x64 arm
  | T.null (gbfCommit x64) || T.null (gbfCommit arm) =
      Left "grok-bot-bin: feed commitSha is empty"
  | gbfCommit x64 /= gbfCommit arm =
      Left "grok-bot-bin: feed commitSha values differ"
  | otherwise = Right (gbfCommit x64)

checkDebUrl :: Text -> GrokBotFeed -> Either Text ()
checkDebUrl commit feed =
  case archOf (gbfUrl feed) of
    Nothing ->
      Left "grok-bot-bin: expected one linux-x64 feed and one linux-arm64 feed"
    Just arch ->
      let expected = expectedDebUrl commit arch (gbfVersion feed)
       in if gbfDebUrl feed == expected
            then Right ()
            else
              Left
                ("grok-bot-bin: debUrl does not match " <> expected)

data FeedArch = FeedX64 | FeedArm64
  deriving (Eq, Show)

archOf :: Text -> Maybe FeedArch
archOf url
  | "linux-arm64" `T.isInfixOf` url = Just FeedArm64
  | "linux-x64" `T.isInfixOf` url = Just FeedX64
  | otherwise = Nothing

expectedDebUrl :: Text -> FeedArch -> Text -> Text
expectedDebUrl commit arch version =
  let (linuxArch, debArch) = case arch of
        FeedX64 -> ("x64", "amd64")
        FeedArm64 -> ("arm64", "arm64")
   in "https://downloads.cursor.com/grokbot/stable/"
        <> commit
        <> "/linux/"
        <> linuxArch
        <> "/grok-bot_"
        <> version
        <> "_"
        <> debArch
        <> ".deb"

-- | Run an HTTP (or other) IO action, mapping any exception to 'Left' with 'show'.
tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
