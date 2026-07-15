{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Update.Assets.Hash
  ( FileDigests (..),
    hashFile,
    hashBytes,
    sidecarLine,
    writeSidecars,
  )
where

import BLAKE3 qualified as B3
import Crypto.Hash (Context, Digest, SHA256 (..), SHA512 (..), hash, hashFinalize, hashInit, hashUpdate)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import System.FilePath (takeFileName)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | Digests for a single distfile (lowercase hex).
data FileDigests = FileDigests
  { digestSHA256 :: Text,
    digestSHA512 :: Text,
    digestBLAKE3 :: Text
  }
  deriving (Eq, Show)

-- | Single streaming pass over the file updating three digesters.
hashFile :: FilePath -> IO FileDigests
hashFile path =
  withBinaryFile path ReadMode $ \h ->
    go h hashInit hashInit (B3.init Nothing)
  where
    go h (c256 :: Context SHA256) (c512 :: Context SHA512) b3 = do
      chunk <- BS.hGetSome h (64 * 1024)
      if BS.null chunk
        then
          pure
            FileDigests
              { digestSHA256 = digestHex (hashFinalize c256),
                digestSHA512 = digestHex (hashFinalize c512),
                digestBLAKE3 = blake3HexFinalize b3
              }
        else
          go
            h
            (hashUpdate c256 chunk)
            (hashUpdate c512 chunk)
            (B3.update b3 [chunk])

-- | Hash an in-memory buffer (tests / small fixtures).
hashBytes :: ByteString -> FileDigests
hashBytes bs =
  FileDigests
    { digestSHA256 = digestHex (hash bs :: Digest SHA256),
      digestSHA512 = digestHex (hash bs :: Digest SHA512),
      digestBLAKE3 = blake3HexBytes bs
    }

digestHex :: Digest a -> Text
digestHex d =
  T.toLower . decodeUtf8 $ convertToBase Base16 d

blake3HexBytes :: ByteString -> Text
blake3HexBytes bs =
  let d = B3.hash Nothing [bs] :: B3.Digest B3.DEFAULT_DIGEST_LEN
   in T.toLower (T.pack (show d))

blake3HexFinalize :: B3.Hasher -> Text
blake3HexFinalize h =
  let d = B3.finalize h :: B3.Digest B3.DEFAULT_DIGEST_LEN
   in T.toLower (T.pack (show d))

-- | @{hex}  {basename}@ (two spaces).
sidecarLine :: Text -> FilePath -> Text
sidecarLine hex path =
  hex <> "  " <> T.pack (takeFileName path)

-- | Write @.sha256@, @.sha512@, and @.b3@ sidecar files.
writeSidecars ::
  FilePath ->
  FileDigests ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO ()
writeSidecars distPath digests sha256Path sha512Path b3Path = do
  let base = takeFileName distPath
      write p hex = TIO.writeFile p (sidecarLine hex base <> "\n")
  write sha256Path (digestSHA256 digests)
  write sha512Path (digestSHA512 digests)
  write b3Path (digestBLAKE3 digests)
