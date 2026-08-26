{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | XDG sidecar for the one current materialize image (@image.json@).
module Update.Materialize.Sidecar
  ( ImageSidecar (..),
    imageSidecarSchemaVersion,
    materializeGeneratorId,
    defaultMaterializeSidecarDirFromEnv,
    sidecarImageJsonPath,
    sidecarDockerfilePath,
    encodeImageSidecar,
    decodeImageSidecar,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import System.FilePath ((</>))
import Update.Materialize.Floors (NeededFloors (..))

-- | Sidecar schema version. Unknown versions are a miss.
imageSidecarSchemaVersion :: Int
imageSidecarSchemaVersion = 1

-- | Identity of the Dockerfile generator recorded in @image.json@.
materializeGeneratorId :: Text
materializeGeneratorId = "mndz-overlay-manager-materialize-6"

-- | Record of the current product materialize image.
data ImageSidecar = ImageSidecar
  { isVersion :: Int,
    isId :: Text,
    isTag :: Text,
    isSatisfies :: NeededFloors,
    isGenerator :: Text,
    isBuiltAt :: UTCTime
  }
  deriving (Eq, Show)

-- | Pure default under XDG cache:
-- @${XDG_CACHE_HOME}/mndz/overlay-manager/materialize@ when set and non-empty,
-- else @${HOME}/.cache/mndz/overlay-manager/materialize@.
defaultMaterializeSidecarDirFromEnv :: Maybe FilePath -> FilePath -> FilePath
defaultMaterializeSidecarDirFromEnv mXdgCache home =
  case mXdgCache of
    Just dir
      | not (null dir) ->
          dir </> "mndz" </> "overlay-manager" </> "materialize"
    _ ->
      home </> ".cache" </> "mndz" </> "overlay-manager" </> "materialize"

sidecarImageJsonPath :: FilePath -> FilePath
sidecarImageJsonPath dir = dir </> "image.json"

sidecarDockerfilePath :: FilePath -> FilePath
sidecarDockerfilePath dir = dir </> "Dockerfile"

instance ToJSON ImageSidecar where
  toJSON s =
    object
      [ "version" .= isVersion s,
        "id" .= isId s,
        "tag" .= isTag s,
        "satisfies" .= isSatisfies s,
        "generator" .= isGenerator s,
        "built_at" .= iso8601Show (isBuiltAt s)
      ]

instance FromJSON ImageSidecar where
  parseJSON = withObject "image.json" $ \o -> do
    ver <- o .: "version" :: Parser Int
    sid <- o .: "id"
    tag <- o .: "tag"
    sat <- o .: "satisfies"
    gen <- o .: "generator"
    builtRaw <- o .: "built_at" :: Parser Text
    built <- case iso8601ParseM (T.unpack builtRaw) of
      Just t -> pure t
      Nothing -> fail "unparseable built_at"
    pure
      ImageSidecar
        { isVersion = ver,
          isId = sid,
          isTag = tag,
          isSatisfies = sat,
          isGenerator = gen,
          isBuiltAt = built
        }

encodeImageSidecar :: ImageSidecar -> LBS.ByteString
encodeImageSidecar = encode

-- | Decode @image.json@. Missing required fields, bad JSON, or an unsupported
-- schema version is a miss ('Left').
decodeImageSidecar :: BS.ByteString -> Either String ImageSidecar
decodeImageSidecar bs = do
  doc <- eitherDecodeStrict' bs
  if isVersion doc /= imageSidecarSchemaVersion
    then Left $ "unsupported image.json version: " <> show (isVersion doc)
    else Right doc
