{-# LANGUAGE OverloadedStrings #-}

-- | Docker Hub digest lookup for the @gentoo/stage3@ base (no pull).
module Update.Materialize.Registry
  ( stage3DigestWith,
    stage3TokenUrl,
    stage3ManifestUrl,
    manifestAcceptTypes,
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as B8
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.HTTP.Client
  ( method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseHeaders,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Update.Http (HttpLbs)

-- | Anonymous pull token for @gentoo/stage3@.
stage3TokenUrl :: String
stage3TokenUrl =
  "https://auth.docker.io/token?service=registry.docker.io&scope=repository:gentoo/stage3:pull"

stage3ManifestUrl :: Text -> String
stage3ManifestUrl tag =
  "https://registry-1.docker.io/v2/gentoo/stage3/manifests/" <> T.unpack tag

-- | OCI index and Docker manifest list first, so the digest is the
-- multi-arch tag's (what @FROM tag\@digest@ resolves).
manifestAcceptTypes :: [B8.ByteString]
manifestAcceptTypes =
  [ "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json"
  ]

-- | Current @sha256:…@ digest of @gentoo/stage3:\<tag\>@: anonymous token,
-- then @HEAD@ the manifest and read @Docker-Content-Digest@.
stage3DigestWith :: HttpLbs -> Text -> IO (Either Text Text)
stage3DigestWith http tag = do
  tokenReq <- parseRequest stage3TokenUrl
  eTok <- http tokenReq
  case eTok >>= okBody "registry token" >>= tokenOf of
    Left err -> pure (Left err)
    Right tok -> do
      req0 <- parseRequest (stage3ManifestUrl tag)
      let req =
            req0
              { method = "HEAD",
                requestHeaders =
                  [ ("Authorization", "Bearer " <> encodeUtf8 tok),
                    ("Accept", B8.intercalate ", " manifestAcceptTypes)
                  ]
              }
      eRes <- http req
      pure $ case eRes of
        Left err -> Left ("gentoo/stage3:" <> tag <> " manifest: " <> err)
        Right resp
          | statusCode (responseStatus resp) /= 200 ->
              Left ("gentoo/stage3:" <> tag <> " manifest: HTTP " <> T.pack (show (statusCode (responseStatus resp))))
          | otherwise ->
              case lookup "Docker-Content-Digest" (responseHeaders resp) of
                Just d
                  | "sha256:" `B8.isPrefixOf` d -> Right (decodeUtf8 d)
                _ -> Left ("gentoo/stage3:" <> tag <> " manifest: no Docker-Content-Digest header")
  where
    okBody what resp
      | statusCode (responseStatus resp) == 200 = Right (responseBody resp)
      | otherwise = Left (what <> ": HTTP " <> T.pack (show (statusCode (responseStatus resp))))
    tokenOf body = case eitherDecode body of
      Right (Object o)
        | Just (String t) <- KeyMap.lookup "token" o, not (T.null t) -> Right t
      _ -> Left "registry token: no token in response"
