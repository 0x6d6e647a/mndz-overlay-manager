{-# LANGUAGE OverloadedStrings #-}

-- | Minimal fake HTTP responses for Unit tests (no live network).
module Test.HttpFake
  ( fakeResponse,
  )
where

import Data.ByteString.Lazy qualified as LBS
import Network.HTTP.Client (Request, parseRequest_)
import Network.HTTP.Client.Internal (Response (..), ResponseClose (..))
import Network.HTTP.Types (Status (..), http11)

-- | Build a Response with the given status code and body.
fakeResponse :: Int -> LBS.ByteString -> Response LBS.ByteString
fakeResponse code body =
  Response
    { responseStatus = Status code "",
      responseVersion = http11,
      responseHeaders = [],
      responseBody = body,
      responseCookieJar = mempty,
      responseClose' = ResponseClose (pure ()),
      responseOriginalRequest = dummyRequest,
      responseEarlyHints = []
    }

dummyRequest :: Request
dummyRequest = parseRequest_ "http://example.invalid/"
