{-# LANGUAGE OverloadedStrings #-}

module Update.Assets.Release
  ( createReleaseWithAsset,
    createReleaseWithAssetHttp,
    ReleaseMeta (..),
    deleteReleaseBestEffort,
    -- Lookup / download (reuse path)
    ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseOps (..),
    productionReleaseOps,
    getReleaseByTagHttp,
    findAssetByName,
    downloadReleaseAssetHttp,
    lookupNamedAsset,
    parseReleaseInfo,
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
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, takeFileName)

data ReleaseMeta = ReleaseMeta
  { rmOwner :: Text,
    rmRepo :: Text,
    rmTag :: Text,
    rmName :: Text,
    rmBody :: Text,
    rmTargetCommitish :: Text
  }
  deriving (Eq, Show)

-- | One asset attached to a GitHub release.
data ReleaseAsset = ReleaseAsset
  { raName :: Text,
    raBrowserDownloadUrl :: Text
  }
  deriving (Eq, Show)

-- | Release metadata needed for lookup/download.
data ReleaseInfo = ReleaseInfo
  { riId :: Int,
    riTag :: Text,
    riAssets :: [ReleaseAsset]
  }
  deriving (Eq, Show)

-- | Injectable release lookup + download (tests / production).
data ReleaseOps = ReleaseOps
  { -- | @owner repo tag@ → hard error | not found | release body.
    roGetReleaseByTag :: Text -> Text -> Text -> IO (Either Text (Maybe ReleaseInfo)),
    -- | Download asset body from a browser_download_url to a local path.
    roDownloadAsset :: Text -> FilePath -> IO (Either Text ())
  }

-- | Production ops using the same Bearer token headers as create-release.
productionReleaseOps :: Text -> IO ReleaseOps
productionReleaseOps token = do
  mgr <- newManager tlsManagerSettings
  pure
    ReleaseOps
      { roGetReleaseByTag = getReleaseByTagHttp mgr token,
        roDownloadAsset = downloadReleaseAssetHttp mgr token
      }

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

------------------------------------------------------------------------
-- Lookup release by tag + download named asset
------------------------------------------------------------------------

-- | GET @/repos/{owner}/{repo}/releases/tags/{tag}@.
--
-- @Right Nothing@ = release tag not found (HTTP 404).
-- @Left@ = network / auth / parse hard errors.
getReleaseByTagHttp ::
  Manager ->
  Text ->
  Text ->
  Text ->
  Text ->
  IO (Either Text (Maybe ReleaseInfo))
getReleaseByTagHttp mgr token owner repo tag = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases/tags/"
          <> T.unpack tag
      headers = authHeaders token
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
       in if code == 404
            then Right Nothing
            else
              if code >= 200 && code < 300
                then case eitherDecode (responseBody resp) of
                  Left e -> Left (T.pack e)
                  Right val ->
                    case parseMaybe parseReleaseInfo val of
                      Nothing -> Left "could not parse get release by tag response"
                      Just info -> Right (Just info)
                else
                  Left $
                    "HTTP "
                      <> T.pack (show code)
                      <> " getting release by tag: "
                      <> T.pack (take 500 (show (responseBody resp)))

-- | Pure parser for a GitHub release JSON object (tests + HTTP path).
parseReleaseInfo :: Value -> Parser ReleaseInfo
parseReleaseInfo =
  withObject "release" $ \o -> do
    rid <- o .: "id"
    tag <- o .: "tag_name"
    assetsRaw <- o .: "assets" :: Parser [Value]
    assets <- mapM parseReleaseAsset assetsRaw
    pure
      ReleaseInfo
        { riId = rid,
          riTag = tag,
          riAssets = assets
        }

parseReleaseAsset :: Value -> Parser ReleaseAsset
parseReleaseAsset =
  withObject "asset" $ \o -> do
    name <- o .: "name"
    url <- o .: "browser_download_url"
    pure ReleaseAsset {raName = name, raBrowserDownloadUrl = url}

-- | Find an asset by exact filename.
findAssetByName :: ReleaseInfo -> Text -> Maybe ReleaseAsset
findAssetByName info name =
  case [a | a <- riAssets info, raName a == name] of
    (a : _) -> Just a
    [] -> Nothing

-- | Download asset bytes from @browser_download_url@ to @destPath@.
downloadReleaseAssetHttp ::
  Manager ->
  Text ->
  Text ->
  FilePath ->
  IO (Either Text ())
downloadReleaseAssetHttp mgr token downloadUrl destPath = do
  req0 <- parseRequest (T.unpack downloadUrl)
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/octet-stream"),
                ("Authorization", encodeUtf8 ("Bearer " <> token))
              ]
          }
  eres <- tryHttp (httpLbs req mgr)
  case eres of
    Left err -> pure (Left err)
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then do
              createDirectoryIfMissing True (takeDirectory destPath)
              LBS.writeFile destPath (responseBody resp)
              pure (Right ())
            else
              pure $
                Left $
                  "HTTP "
                    <> T.pack (show code)
                    <> " downloading release asset"

-- | Lookup release by tag and resolve exact asset name to a download URL.
--
-- @Right Nothing@ when the tag is missing or the asset name is not present
-- (not-found, not a hard publish failure).
lookupNamedAsset ::
  ReleaseOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  IO (Either Text (Maybe Text))
lookupNamedAsset ops owner repo tag assetName = do
  eres <- roGetReleaseByTag ops owner repo tag
  pure $ case eres of
    Left err -> Left err
    Right Nothing -> Right Nothing
    Right (Just info) ->
      Right (raBrowserDownloadUrl <$> findAssetByName info assetName)

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
