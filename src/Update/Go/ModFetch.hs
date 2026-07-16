{-# LANGUAGE OverloadedStrings #-}

module Update.Go.ModFetch
  ( GoModKey (..),
    GoModFetcher,
    productionGoModFetcher,
    fetchGoModAtTag,
    parseGoReqFromMod,
    withGoModCache,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception (SomeException, catch)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
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
import Network.HTTP.Types.Status (statusCode)
import System.FilePath (normalise)
import Update.Go.Version (parseGoModGoDirective)

-- | Cache key for go.mod at a repository ref.
data GoModKey = GoModKey
  { gmkOwner :: Text,
    gmkRepo :: Text,
    gmkTag :: Text,
    gmkSubdir :: Maybe FilePath
  }
  deriving (Eq, Ord, Show)

-- | Fetch go.mod body text (or error). Injectable for tests.
type GoModFetcher = GoModKey -> IO (Either Text Text)

-- | Parse @go@ directive version from go.mod body.
parseGoReqFromMod :: Text -> Maybe Text
parseGoReqFromMod = parseGoModGoDirective

-- | Process-local cache wrapper around a base fetcher.
--
-- The cache lock is not held across the network fetch on miss, so concurrent
-- fetches for distinct keys can proceed in parallel.
withGoModCache :: GoModFetcher -> IO GoModFetcher
withGoModCache base = do
  cacheVar <- newMVar (Map.empty :: Map GoModKey (Either Text Text))
  pure (cachedFetch cacheVar base)

cachedFetch ::
  MVar (Map GoModKey (Either Text Text)) ->
  GoModFetcher ->
  GoModKey ->
  IO (Either Text Text)
cachedFetch cacheVar base key = do
  mHit <- withMVar cacheVar (pure . Map.lookup key)
  case mHit of
    Just hit -> pure hit
    Nothing -> do
      result <- base key
      modifyMVar cacheVar $ \cache ->
        case Map.lookup key cache of
          -- First insert wins on same-key races (return cached value).
          Just hit -> pure (cache, hit)
          Nothing -> pure (Map.insert key result cache, result)

-- | Production fetcher using raw.githubusercontent.com with optional token.
productionGoModFetcher :: Maybe Text -> IO GoModFetcher
productionGoModFetcher mToken = do
  mgr <- newManager tlsManagerSettings
  pure (fetchGoModAtTag mgr mToken)

-- | Fetch go.mod at tag via raw.githubusercontent.com (token optional).
fetchGoModAtTag :: Manager -> Maybe Text -> GoModKey -> IO (Either Text Text)
fetchGoModAtTag mgr mToken key = do
  let subPath = case gmkSubdir key of
        Nothing -> "go.mod"
        Just sub ->
          let cleaned = dropWhile (== '/') (normalise sub)
           in if null cleaned then "go.mod" else cleaned <> "/go.mod"
      rawUrl =
        "https://raw.githubusercontent.com/"
          <> T.unpack (gmkOwner key)
          <> "/"
          <> T.unpack (gmkRepo key)
          <> "/"
          <> T.unpack (gmkTag key)
          <> "/"
          <> subPath
  httpGetText mgr mToken rawUrl

httpGetText :: Manager -> Maybe Text -> String -> IO (Either Text Text)
httpGetText mgr mToken url = do
  req0 <- parseRequest url
  let authHeaders = case mToken of
        Just t
          | not (T.null t) ->
              [("Authorization", encodeUtf8 ("Bearer " <> t))]
        _ -> []
      req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/vnd.github.raw")
              ]
                <> authHeaders
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then
              Right
                ( decodeUtf8With
                    lenientDecode
                    (LBS.toStrict (responseBody resp))
                )
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
