{-# LANGUAGE OverloadedStrings #-}

module Update.Http
  ( HttpLbs,
    httpLbsEither,
    fetchHttpWith,
    fetchHttpWithHttp,
    tryHttp,
  )
where

import Control.Exception (SomeException, catch)
import Data.ByteString.Lazy.Char8 qualified as L8
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
import Overlay.Version (EbuildVersion, parseEbuildVersion)
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
  req0 <- parseRequest (T.unpack urlText)
  let req = req0 {method = "GET"}
  eres <- http req
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

-- | Run an HTTP (or other) IO action, mapping any exception to 'Left' with 'show'.
tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
