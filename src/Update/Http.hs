{-# LANGUAGE OverloadedStrings #-}

module Update.Http
  ( fetchHttp,
    fetchHttpWith,
  )
where

import Control.Exception (SomeException, catch)
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Update.Types (UpdateSource (..))

-- | Fetch version from Http source (primary then fallback). Uses a fresh manager.
fetchHttp :: UpdateSource -> IO (Either Text EbuildVersion)
fetchHttp src = do
  mgr <- newManager tlsManagerSettings
  fetchHttpWith mgr src

fetchHttpWith :: Manager -> UpdateSource -> IO (Either Text EbuildVersion)
fetchHttpWith mgr = \case
  Http primary mFallback -> do
    primaryResult <- tryUrl mgr primary
    case primaryResult of
      Right v -> pure (Right v)
      Left _ ->
        case mFallback of
          Nothing -> pure primaryResult
          Just fb -> tryUrl mgr fb
  other ->
    pure (Left ("Update.Http: not an Http source: " <> T.pack (show other)))

tryUrl :: Manager -> Text -> IO (Either Text EbuildVersion)
tryUrl mgr urlText = do
  req0 <- parseRequest (T.unpack urlText)
  let req = req0 {method = "GET"}
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then
              let body = T.strip (T.pack (L8.unpack (responseBody resp)))
               in if T.null body
                    then Left ("empty version body from " <> urlText)
                    else Right (parseEbuildVersion body)
            else Left ("HTTP " <> T.pack (show code) <> " from " <> urlText)

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
