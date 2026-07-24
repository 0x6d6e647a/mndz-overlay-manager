{-# LANGUAGE OverloadedStrings #-}

module Update.Npm
  ( fetchNpmWith,
  )
where

import Data.Aeson (Value, eitherDecode, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Update.Http (tryHttp)
import Update.Types (UpdateSource (..))

-- | Fetch latest version from the npm registry.
fetchNpmWith :: Manager -> UpdateSource -> IO (Either Text EbuildVersion)
fetchNpmWith mgr = \case
  Npm pkg -> do
    let url = "https://registry.npmjs.org/" <> T.unpack pkg <> "/latest"
    req0 <- parseRequest url
    let req =
          req0
            { method = "GET",
              requestHeaders =
                [ ("User-Agent", "mndz-overlay-manager"),
                  ("Accept", "application/json")
                ]
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
                  case parseMaybe parseVersion val of
                    Nothing -> Left "could not parse npm latest version field"
                    Just ver -> Right (parseEbuildVersion ver)
              else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)
  other ->
    pure (Left ("Update.Npm: not an Npm source: " <> T.pack (show other)))

parseVersion :: Value -> Parser Text
parseVersion = withObject "npm-latest" (.: "version")
