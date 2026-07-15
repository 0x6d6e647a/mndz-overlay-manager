{-# LANGUAGE OverloadedStrings #-}

module Update.Assets.Release
  ( createReleaseWithAsset,
    createReleaseWithAssetHttp,
    ReleaseMeta (..),
    deleteReleaseBestEffort,
  )
where

import Control.Exception (SomeException, catch)
import Data.Aeson (Value, eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (RequestHeaders, statusCode)
import System.FilePath (takeFileName)

data ReleaseMeta = ReleaseMeta
  { rmOwner :: Text,
    rmRepo :: Text,
    rmTag :: Text,
    rmName :: Text,
    rmBody :: Text,
    rmTargetCommitish :: Text
  }
  deriving (Eq, Show)

-- | Create a GitHub release and upload one asset. On upload failure after
-- create, best-effort deletes the release.
createReleaseWithAsset ::
  Text ->
  ReleaseMeta ->
  FilePath ->
  IO (Either Text ())
createReleaseWithAsset token meta assetPath = do
  mgr <- newManager tlsManagerSettings
  createReleaseWithAssetHttp mgr token meta assetPath

createReleaseWithAssetHttp ::
  Manager ->
  Text ->
  ReleaseMeta ->
  FilePath ->
  IO (Either Text ())
createReleaseWithAssetHttp mgr token meta assetPath = do
  let headers = authHeaders token
  created <- createRelease mgr headers meta
  case created of
    Left err -> pure (Left err)
    Right (releaseId, uploadUrlTemplate) -> do
      body <- LBS.readFile assetPath
      let assetName = takeFileName assetPath
      uploaded <- uploadAsset mgr headers uploadUrlTemplate assetName body
      case uploaded of
        Right () -> pure (Right ())
        Left err -> do
          _ <- deleteReleaseBestEffort mgr headers (rmOwner meta) (rmRepo meta) releaseId
          pure (Left err)

authHeaders :: Text -> RequestHeaders
authHeaders token =
  [ ("User-Agent", "mndz-overlay-manager"),
    ("Accept", "application/vnd.github+json"),
    ("Authorization", encodeUtf8 ("Bearer " <> token))
  ]

createRelease ::
  Manager ->
  RequestHeaders ->
  ReleaseMeta ->
  IO (Either Text (Int, Text))
createRelease mgr headers meta = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack (rmOwner meta)
          <> "/"
          <> T.unpack (rmRepo meta)
          <> "/releases"
      payload =
        object
          [ "tag_name" .= rmTag meta,
            "name" .= rmName meta,
            "body" .= rmBody meta,
            "target_commitish" .= rmTargetCommitish meta,
            "draft" .= False,
            "prerelease" .= False
          ]
  req0 <- parseRequest url
  let req =
        req0
          { method = "POST",
            requestHeaders = headers <> [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS (encode payload)
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then case eitherDecode (responseBody resp) of
              Left e -> Left (T.pack e)
              Right val ->
                case parseMaybe parseReleaseCreated val of
                  Nothing -> Left "could not parse create release response"
                  Just x -> Right x
            else
              Left $
                "HTTP "
                  <> T.pack (show code)
                  <> " creating release: "
                  <> T.pack (take 500 (show (responseBody resp)))

parseReleaseCreated :: Value -> Parser (Int, Text)
parseReleaseCreated =
  withObject "release" $ \o -> do
    rid <- o .: "id"
    uploadUrl <- o .: "upload_url"
    pure (rid, uploadUrl)

-- | GitHub upload_url looks like
-- @https://uploads.github.com/.../assets{?name,label}@
uploadAsset ::
  Manager ->
  RequestHeaders ->
  Text ->
  FilePath ->
  LBS.ByteString ->
  IO (Either Text ())
uploadAsset mgr headers uploadUrlTemplate assetName body = do
  let base = T.takeWhile (/= '{') uploadUrlTemplate
      url =
        T.unpack base
          <> "?name="
          <> T.unpack (T.pack assetName)
  req0 <- parseRequest url
  let req =
        req0
          { method = "POST",
            requestHeaders =
              headers
                <> [ ("Content-Type", "application/x-xz"),
                     ("Content-Length", encodeUtf8 (T.pack (show (LBS.length body))))
                   ],
            requestBody = RequestBodyLBS body
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then Right ()
            else
              Left $
                "HTTP "
                  <> T.pack (show code)
                  <> " uploading release asset"

deleteReleaseBestEffort ::
  Manager ->
  RequestHeaders ->
  Text ->
  Text ->
  Int ->
  IO ()
deleteReleaseBestEffort mgr headers owner repo releaseId = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases/"
          <> show releaseId
  req0 <- parseRequest url
  let req =
        req0
          { method = "DELETE",
            requestHeaders = headers
          }
  _ <- tryHttp (httpLbs req mgr)
  pure ()

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
