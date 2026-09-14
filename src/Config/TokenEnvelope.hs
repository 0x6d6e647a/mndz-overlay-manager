{-# LANGUAGE OverloadedStrings #-}

-- | Password-wrapped @mndz1.@ ciphertext for the on-disk @github-token@ key.
module Config.TokenEnvelope
  ( EnvelopeParams (..),
    defaultEnvelopeParams,
    testEnvelopeParams,
    isMndz1Envelope,
    encodeEnvelope,
    decodeEnvelope,
    wrapToken,
    wrapTokenWith,
    unwrapToken,
  )
where

import Crypto.Cipher.ChaChaPoly1305
  ( decrypt,
    encrypt,
    finalize,
    finalizeAAD,
    initializeX,
    nonce24,
  )
import Crypto.Error (CryptoFailable (..))
import Crypto.KDF.Argon2 qualified as Argon2
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteArray (constEq, convert)
import Data.ByteArray.Encoding
  ( Base (Base64URLUnpadded),
    convertFromBase,
    convertToBase,
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Word (Word32)

-- | On-disk prefix. A later @mndz2.@ can version the payload independently.
envelopePrefix :: Text
envelopePrefix = "mndz1."

saltLen :: Int
saltLen = 16

nonceLen :: Int
nonceLen = 24

tagLen :: Int
tagLen = 16

keyLen :: Int
keyLen = 32

-- | Argon2id parameters stored inside each envelope.
data EnvelopeParams = EnvelopeParams
  { epIterations :: Word32,
    epMemoryKib :: Word32,
    epParallelism :: Word32
  }
  deriving (Eq, Show)

-- | Interactive wrap defaults: 64 MiB, 3 iterations, single lane.
defaultEnvelopeParams :: EnvelopeParams
defaultEnvelopeParams =
  EnvelopeParams
    { epIterations = 3,
      epMemoryKib = 64 * 1024,
      epParallelism = 1
    }

-- | Fast parameters for unit tests (values are stored in the envelope).
testEnvelopeParams :: EnvelopeParams
testEnvelopeParams =
  EnvelopeParams
    { epIterations = 1,
      epMemoryKib = 32,
      epParallelism = 1
    }

-- | True when a stripped config value is a @mndz1.@ envelope (not a live PAT).
isMndz1Envelope :: Text -> Bool
isMndz1Envelope t = envelopePrefix `T.isPrefixOf` T.strip t

-- | Encrypt @plaintext@ under @password@ with caller-supplied salt and nonce.
encodeEnvelope ::
  EnvelopeParams ->
  ByteString ->
  ByteString ->
  Text ->
  Text ->
  Either Text Text
encodeEnvelope params salt nonce password plaintext
  | BS.length salt /= saltLen =
      Left "internal: wrap salt must be 16 bytes"
  | BS.length nonce /= nonceLen =
      Left "internal: wrap nonce must be 24 bytes"
  | otherwise = do
      key <- deriveKey params password salt
      (ct, tag) <- aeadEncrypt key nonce (encodeUtf8 plaintext)
      let payload =
            putU32BE (epIterations params)
              <> putU32BE (epMemoryKib params)
              <> BS.singleton (fromIntegral (epParallelism params))
              <> salt
              <> nonce
              <> ct
              <> tag
          b64 = convertToBase Base64URLUnpadded payload :: ByteString
      Right (envelopePrefix <> decodeUtf8 b64)

-- | Decrypt a @mndz1.@ envelope with @password@.
decodeEnvelope :: Text -> Text -> Either Text Text
decodeEnvelope password envelope = do
  payload <- parsePayload envelope
  (params, salt, nonce, ctAndTag) <- splitPayload payload
  key <- deriveKey params password salt
  let (ct, tag) = BS.splitAt (BS.length ctAndTag - tagLen) ctAndTag
  pt <- aeadDecrypt key nonce ct tag
  Right (decodeUtf8 pt)

-- | Production wrap: fresh salt and XChaCha nonce from the system CSPRNG.
wrapToken :: Text -> Text -> IO (Either Text Text)
wrapToken = wrapTokenWith defaultEnvelopeParams

-- | Wrap with explicit KDF parameters (unit tests use 'testEnvelopeParams').
wrapTokenWith :: EnvelopeParams -> Text -> Text -> IO (Either Text Text)
wrapTokenWith params password plaintext = do
  salt <- getRandomBytes saltLen
  nonce <- getRandomBytes nonceLen
  pure (encodeEnvelope params salt nonce password plaintext)

-- | Unwrap a stored envelope (alias of 'decodeEnvelope').
unwrapToken :: Text -> Text -> Either Text Text
unwrapToken = decodeEnvelope

parsePayload :: Text -> Either Text ByteString
parsePayload raw =
  let t = T.strip raw
   in case T.stripPrefix envelopePrefix t of
        Nothing -> Left "github-token is not a mndz1. envelope"
        Just rest
          | T.null rest -> Left "github-token envelope is empty"
          | otherwise ->
              case convertFromBase Base64URLUnpadded (encodeUtf8 rest) of
                Left _ -> Left "github-token envelope is not valid base64url"
                Right bs -> Right bs

splitPayload :: ByteString -> Either Text (EnvelopeParams, ByteString, ByteString, ByteString)
splitPayload bs
  | BS.length bs < headerLen + tagLen =
      Left "github-token envelope is truncated"
  | otherwise =
      let (iterBs, r0) = BS.splitAt 4 bs
          (memBs, r1) = BS.splitAt 4 r0
          (parBs, r2) = BS.splitAt 1 r1
          (salt, r3) = BS.splitAt saltLen r2
          (nonce, ctAndTag) = BS.splitAt nonceLen r3
          params =
            EnvelopeParams
              { epIterations = getU32BE iterBs,
                epMemoryKib = getU32BE memBs,
                epParallelism = fromIntegral (BS.head parBs)
              }
       in if BS.length ctAndTag < tagLen
            then Left "github-token envelope is truncated"
            else Right (params, salt, nonce, ctAndTag)
  where
    headerLen = 4 + 4 + 1 + saltLen + nonceLen

deriveKey :: EnvelopeParams -> Text -> ByteString -> Either Text ByteString
deriveKey params password salt =
  case Argon2.hash opts (encodeUtf8 password) salt keyLen of
    CryptoPassed key -> Right key
    CryptoFailed err -> Left ("wrap key derivation failed: " <> T.pack (show err))
  where
    opts =
      Argon2.Options
        { Argon2.iterations = epIterations params,
          Argon2.memory = epMemoryKib params,
          Argon2.parallelism = epParallelism params,
          Argon2.variant = Argon2.Argon2id,
          Argon2.version = Argon2.Version13
        }

aeadEncrypt ::
  ByteString ->
  ByteString ->
  ByteString ->
  Either Text (ByteString, ByteString)
aeadEncrypt key nonce plaintext = do
  xn <- crypto "nonce" (nonce24 nonce)
  st0 <- crypto "aead" (initializeX key xn)
  let st1 = finalizeAAD st0
      (ct, st2) = encrypt plaintext st1
      tag = convert (finalize st2) :: ByteString
  Right (ct, tag)

aeadDecrypt ::
  ByteString ->
  ByteString ->
  ByteString ->
  ByteString ->
  Either Text ByteString
aeadDecrypt key nonce ciphertext tag = do
  xn <- crypto "nonce" (nonce24 nonce)
  st0 <- crypto "aead" (initializeX key xn)
  let st1 = finalizeAAD st0
      (pt, st2) = decrypt ciphertext st1
      computed = convert (finalize st2) :: ByteString
  if constEq computed tag
    then Right pt
    else Left "incorrect wrap password or corrupted github-token envelope"

crypto :: Text -> CryptoFailable a -> Either Text a
crypto what = \case
  CryptoPassed a -> Right a
  CryptoFailed err ->
    Left ("wrap " <> what <> " failed: " <> T.pack (show err))

putU32BE :: Word32 -> ByteString
putU32BE n =
  BS.pack
    [ fromIntegral (n `shiftR` 24),
      fromIntegral (n `shiftR` 16),
      fromIntegral (n `shiftR` 8),
      fromIntegral n
    ]

getU32BE :: ByteString -> Word32
getU32BE bs =
  let b i = fromIntegral (BS.index bs i) :: Word32
   in (b 0 `shiftL` 24)
        .|. (b 1 `shiftL` 16)
        .|. (b 2 `shiftL` 8)
        .|. b 3
