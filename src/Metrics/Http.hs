{-# LANGUAGE OverloadedStrings #-}

-- | HTTP request spans (design D9).
--
-- Production instruments each HTTP 'Manager' it creates, so every request
-- (through 'Update.Http.HttpLbs' or a direct @httpLbs@) is one @http@ span:
-- method, host, path (GitHub routes templated, query dropped), status, and
-- response body bytes. Request headers are never read, so tokens never reach
-- the span.
module Metrics.Http
  ( httpRequestAttrs,
    githubRouteTemplate,
    instrumentManagerSettings,
  )
where

import Control.Exception (SomeException, mask, throwIO, try)
import Control.Monad (when, (>=>))
import Data.Aeson (Value (..), (.=))
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Metrics.Core (Attrs, Metrics (..), Outcome (..))
import Network.HTTP.Client
  ( ManagerSettings (..),
    Request,
    host,
    method,
    path,
  )
import Network.HTTP.Client.Internal (Response (..))
import Network.HTTP.Types.Status (statusCode)
import Text.Read (readMaybe)

-- | Span attributes from the request line only (no headers, no query).
httpRequestAttrs :: Request -> Attrs
httpRequestAttrs req =
  [ "method" .= utf8 (method req),
    "host" .= h,
    "path" .= templatePath h (utf8 (path req))
  ]
  where
    h = utf8 (host req)

utf8 :: BS.ByteString -> Text
utf8 = TE.decodeUtf8With TE.lenientDecode

templatePath :: Text -> Text -> Text
templatePath h p
  | h `elem` ["api.github.com", "uploads.github.com"] = githubRouteTemplate p
  | otherwise = p

-- | Replace owner, repository, tag, ref, path, and numeric ids in a GitHub
-- REST path with placeholders, e.g.
-- @/repos/o/r/releases/latest@ → @/repos/{owner}/{repo}/releases/latest@.
githubRouteTemplate :: Text -> Text
githubRouteTemplate p =
  case T.splitOn "/" p of
    ("" : "repos" : _owner : _repo : rest) ->
      T.intercalate "/" (["", "repos", "{owner}", "{repo}"] <> go rest)
    segs -> T.intercalate "/" (go segs)
  where
    go = \case
      [] -> []
      ("contents" : _ : _) -> ["contents", "{path}"]
      ("tags" : _ : rest) -> "tags" : "{tag}" : go rest
      ("assets" : _ : rest) -> "assets" : "{asset_id}" : go rest
      ("commits" : _ : rest) -> "commits" : "{sha}" : go rest
      ("branches" : _ : rest) -> "branches" : "{branch}" : go rest
      ("heads" : _ : rest) -> "heads" : "{branch}" : go rest
      (s : rest)
        | not (T.null s) && T.all (`elem` ['0' .. '9']) s -> "{id}" : go rest
        | otherwise -> s : go rest

-- | Record an @http@ span for every request made through a manager built
-- from these settings. The span opens when the request starts and closes
-- when the response body is fully read (or the request fails). GitHub API
-- requests also bump @github.api_calls@ and set
-- @github.rate_limit_remaining@ from the response.
instrumentManagerSettings :: Metrics -> ManagerSettings -> ManagerSettings
instrumentManagerSettings m s
  | not (mEnabled m) = s
  | otherwise =
      s
        { managerWrapException = \req act -> managerWrapException s req (spanned req act),
          managerModifyResponse = managerModifyResponse s >=> countBody
        }
  where
    spanned :: Request -> IO a -> IO a
    spanned req act = mask $ \restore -> do
      sid <- mSpanStart m "http" (httpRequestAttrs req)
      when (host req == "api.github.com") $ mBump m "github.api_calls" 1
      r <- try @SomeException (restore act)
      case r of
        Left e -> do
          mSpanEnd m sid OutcomeFail ["error" .= T.pack (takeWhile (/= '\n') (show e))]
          throwIO e
        -- The span stays open until 'countBody' sees the end of the body.
        Right a -> pure a
    countBody res = do
      -- Runs inside 'spanned' on the requesting thread: the open @http@ span
      -- is the innermost one.
      mSid <- mCurrentSpan m
      case mSid of
        Nothing -> pure res
        Just sid -> do
          let status = statusCode (responseStatus res)
              orig = responseOriginalRequest res
          when (host orig == "api.github.com") $
            for_ (lookup "x-ratelimit-remaining" (responseHeaders res) >>= readMaybe . T.unpack . utf8) $ \(n :: Integer) ->
              mSetCounter m "github.rate_limit_remaining" (Number (fromIntegral n))
          state <- newIORef (0 :: Int, False)
          let finish outcome extra = do
                (bytes, already) <- atomicModifyIORef' state (\(b, d) -> ((b, True), (b, d)))
                if already
                  then pure ()
                  else
                    mSpanEnd
                      m
                      sid
                      outcome
                      (["status" .= status, "body_bytes" .= bytes] <> extra)
              reader = do
                r <- try @SomeException (responseBody res)
                case r of
                  Left e -> do
                    finish OutcomeFail ["error" .= T.pack (takeWhile (/= '\n') (show e))]
                    throwIO e
                  Right chunk
                    | BS.null chunk -> do
                        finish (if status < 400 then OutcomeOk else OutcomeFail) []
                        pure chunk
                    | otherwise -> do
                        atomicModifyIORef' state (\(b, d) -> ((b + BS.length chunk, d), ()))
                        pure chunk
          pure res {responseBody = reader}
