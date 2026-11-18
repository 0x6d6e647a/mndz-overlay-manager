{-# LANGUAGE OverloadedStrings #-}

-- | Verification of a published asset at the exact URL an ebuild names:
-- download it (following redirects) and compare its size and every
-- Manifest hash.
module Update.Assets.Verify
  ( ManifestDist (..),
    parseManifestDist,
    assetsDownloadPrefix,
    assetsUrlsIn,
    verifyPublishedAsset,
    verifyBytes,
    verifyUnitAssets,
  )
where

import Control.Exception (SomeException, try)
import Crypto.Hash (Blake2b_512, Digest, SHA512, hashlazy)
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import System.FilePath ((</>))
import Update.Http (HttpLbs)
import Update.Types (PackageKey, packageKeyText, splitPackageKey)

-- | One Manifest @DIST@ entry: size and @(hash name, hex)@ pairs.
data ManifestDist = ManifestDist
  { mdSize :: Integer,
    mdHashes :: [(Text, Text)]
  }
  deriving (Eq, Show)

-- | The @DIST@ line for @name@ in a Manifest.
parseManifestDist :: Text -> Text -> Maybe ManifestDist
parseManifestDist manifest name =
  case [ws | l <- T.lines manifest, ws@("DIST" : n : _) <- [T.words l], n == name] of
    ("DIST" : _ : size : rest) : _
      | [(n, "")] <- reads (T.unpack size) -> Just (ManifestDist n (pairs rest))
    _ -> Nothing
  where
    pairs = \case
      k : v : more -> (k, T.toLower v) : pairs more
      _ -> []

-- | @https://github.com/\<owner\>/\<repo\>/releases/download/@.
assetsDownloadPrefix :: Text -> Text -> Text
assetsDownloadPrefix owner repo = "https://github.com/" <> owner <> "/" <> repo <> "/releases/download/"

-- | URLs under @prefix@ in a @SRC_URI@ (or md5-cache @SRC_URI=@) text, in
-- order, without @->@ renames.
assetsUrlsIn :: Text -> Text -> [Text]
assetsUrlsIn prefix body = nub [w | w <- T.words body, prefix `T.isPrefixOf` w]

-- | Download @url@ and compare it with its Manifest entry. A non-200
-- status, a size difference, or any hash difference is a 'Left' naming it.
verifyPublishedAsset :: HttpLbs -> Text -> ManifestDist -> IO (Either Text ())
verifyPublishedAsset http url expected = do
  parsed <- try @SomeException (parseRequest (T.unpack url))
  case parsed of
    Left err -> pure (Left ("invalid URL: " <> T.pack (show err)))
    Right req -> do
      res <- http req
      pure $ case res of
        Left err -> Left ("download failed: " <> err)
        Right r
          | statusCode (responseStatus r) /= 200 ->
              Left ("HTTP " <> T.pack (show (statusCode (responseStatus r))))
          | otherwise -> verifyBytes (responseBody r) expected

-- | Compare downloaded bytes with a Manifest entry.
verifyBytes :: BL.ByteString -> ManifestDist -> Either Text ()
verifyBytes body expected
  | size /= mdSize expected =
      Left ("size " <> tshow size <> " does not match the Manifest's " <> tshow (mdSize expected))
  | null known = Left "the Manifest entry has no BLAKE2B or SHA512 hash to compare"
  | otherwise = case [n | (n, want, got) <- known, got /= want] of
      [] -> Right ()
      bad -> Left (T.intercalate ", " bad <> " does not match the Manifest")
  where
    size = fromIntegral (BL.length body) :: Integer
    known = [(n, want, got) | (n, want) <- mdHashes expected, Just got <- [digestFor n]]
    digestFor = \case
      "BLAKE2B" -> Just (T.pack (show (hashlazy body :: Digest Blake2b_512)))
      "SHA512" -> Just (T.pack (show (hashlazy body :: Digest SHA512)))
      _ -> Nothing

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Verify each published asset @name@ of a unit at the URL its
-- regenerated md5-cache entry (@SRC_URI@, fully expanded) names under
-- @prefix@, against the package Manifest. 'Left' is the URL (or name) and
-- the mismatch.
verifyUnitAssets ::
  (Text -> ManifestDist -> IO (Either Text ())) ->
  Text ->
  FilePath ->
  PackageKey ->
  Text ->
  [Text] ->
  IO (Either (Text, Text) ())
verifyUnitAssets verifyOne prefix overlayRoot key pvr names =
  case splitPackageKey key of
    Nothing -> pure (Left (packageKeyText key, "invalid package key"))
    Just (cat, pn) -> do
      let pkgDir = overlayRoot </> T.unpack cat </> T.unpack pn
          cachePath = overlayRoot </> "metadata" </> "md5-cache" </> T.unpack cat </> T.unpack (pn <> "-" <> pvr)
      cache <- TIO.readFile cachePath
      manifest <- TIO.readFile (pkgDir </> "Manifest")
      let srcUri = T.unwords [T.drop (T.length "SRC_URI=") l | l <- T.lines cache, "SRC_URI=" `T.isPrefixOf` l]
          urls = assetsUrlsIn prefix srcUri
          checkOne name =
            case ([u | u <- urls, snd (T.breakOnEnd "/" u) == name], parseManifestDist manifest name) of
              ([], _) -> pure (Left (name, "the ebuild does not name this asset under " <> prefix))
              (url : _, Nothing) -> pure (Left (url, "the Manifest has no DIST entry for it"))
              (url : _, Just dist) -> either (Left . (url,)) Right <$> verifyOne url dist
          go [] = pure (Right ())
          go (n : rest) = checkOne n >>= either (pure . Left) (const (go rest))
      go names
