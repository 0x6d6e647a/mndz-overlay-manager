{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Pure Docker/containerd image-store layout: parse @docker info@ JSON and
-- @containerd config dump@, then map layers vs BuildKit cache paths.
module Update.Materialize.ImageLayout
  ( DockerInfoFacts (..),
    ImageStoreLayout (..),
    parseDockerInfoJson,
    parseContainerdDump,
    imageStoreLayout,
    containerdDumpNeeded,
    isBundledContainerdAddress,
    firstImageNeedBytes,
    addToolchainNeedBytes,
    firstImageLayerNeedBytes,
    firstImageCacheNeedBytes,
    addToolchainLayerNeedBytes,
    addToolchainCacheNeedBytes,
    imageStoreUnresolvedMessage,
    containerdRootUnresolvedMessage,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Object,
    Value (..),
    eitherDecodeStrict',
    withObject,
    (.:?),
  )
import Data.Aeson.Types (Parser)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

giB :: Integer
giB = 1024 * 1024 * 1024

-- | Combined first-image bound when layers and cache share a device.
firstImageNeedBytes :: Integer
firstImageNeedBytes = 20 * giB

-- | Combined add-toolchain bound when layers and cache share a device.
addToolchainNeedBytes :: Integer
addToolchainNeedBytes = 8 * giB

-- | First-image bound for the image-layers filesystem when distinct.
firstImageLayerNeedBytes :: Integer
firstImageLayerNeedBytes = 16 * giB

-- | First-image bound for the BuildKit cache filesystem when distinct.
firstImageCacheNeedBytes :: Integer
firstImageCacheNeedBytes = 6 * giB

-- | Add-toolchain bound for the image-layers filesystem when distinct.
addToolchainLayerNeedBytes :: Integer
addToolchainLayerNeedBytes = 6 * giB

-- | Add-toolchain bound for the BuildKit cache filesystem when distinct.
addToolchainCacheNeedBytes :: Integer
addToolchainCacheNeedBytes = 2 * giB

snapshotterDriverKey :: Text
snapshotterDriverKey = "driver-type"

snapshotterDriverType :: Text
snapshotterDriverType = "io.containerd.snapshotter.v1"

bundledContainerdFragment :: FilePath
bundledContainerdFragment = "/docker/containerd/"

-- | Parsed @docker info --format '{{json .}}'@ fields used for layout.
data DockerInfoFacts = DockerInfoFacts
  { difDockerRootDir :: FilePath,
    difUsesSnapshotter :: Bool,
    difContainerdAddress :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | Directories that back image layers vs BuildKit cache.
data ImageStoreLayout = ImageStoreLayout
  { islLayerPaths :: [FilePath],
    islCachePaths :: [FilePath]
  }
  deriving (Eq, Show)

data DockerInfoJson = DockerInfoJson
  { dijRoot :: Maybe Text,
    dijStatus :: [(Text, Text)],
    dijAddress :: Maybe Text
  }

instance FromJSON DockerInfoJson where
  parseJSON = withObject "docker info" $ \o -> do
    root <- o .:? "DockerRootDir"
    status <- parseDriverStatus =<< o .:? "DriverStatus"
    addr <- parseContainerdAddress o
    pure
      DockerInfoJson
        { dijRoot = emptyToNothing root,
          dijStatus = status,
          dijAddress = emptyToNothing addr
        }

emptyToNothing :: Maybe Text -> Maybe Text
emptyToNothing = \case
  Just t | T.null (T.strip t) -> Nothing
  other -> fmap T.strip other

parseDriverStatus :: Maybe Value -> Parser [(Text, Text)]
parseDriverStatus = \case
  Nothing -> pure []
  Just Null -> pure []
  Just v -> do
    rows <- parseJSON v
    pure [(k, val) | (k : val : _) <- rows]

parseContainerdAddress :: Object -> Parser (Maybe Text)
parseContainerdAddress o = do
  mVal <- o .:? "Containerd"
  case mVal of
    Nothing -> pure Nothing
    Just Null -> pure Nothing
    Just v ->
      withObject
        "Containerd"
        ( \c -> do
            mAddr <- c .:? "Address"
            pure (emptyToNothing mAddr)
        )
        v

-- | Discovery error prefix. @detail@ is appended after a colon when non-empty.
imageStoreUnresolvedMessage :: Text -> Text
imageStoreUnresolvedMessage detail =
  let prefix = "could not resolve the image store for the materialize docker build"
   in if T.null detail
        then prefix
        else prefix <> ": " <> detail

-- | System-snapshotter miss: dump failed, unparsable, or root path missing.
containerdRootUnresolvedMessage :: Text
containerdRootUnresolvedMessage =
  imageStoreUnresolvedMessage "containerd config dump must yield a root"

-- | Decode @docker info@ JSON. Missing @DockerRootDir@ is a discovery error.
parseDockerInfoJson :: Text -> Either Text DockerInfoFacts
parseDockerInfoJson raw =
  case eitherDecodeStrict' (encodeUtf8 (T.strip raw)) of
    Left err ->
      Left $
        imageStoreUnresolvedMessage ("docker info JSON: " <> T.pack err)
    Right parsed ->
      case dijRoot parsed of
        Nothing ->
          Left $
            imageStoreUnresolvedMessage "docker info did not report DockerRootDir"
        Just root ->
          Right
            DockerInfoFacts
              { difDockerRootDir = T.unpack root,
                difUsesSnapshotter = isSnapshotter (dijStatus parsed),
                difContainerdAddress = T.unpack <$> dijAddress parsed
              }

isSnapshotter :: [(Text, Text)] -> Bool
isSnapshotter =
  any
    ( \(k, v) ->
        k == snapshotterDriverKey && v == snapshotterDriverType
    )

-- | Engine-bundled containerd keeps data under Docker's runtime dir.
isBundledContainerdAddress :: FilePath -> Bool
isBundledContainerdAddress addr =
  T.pack bundledContainerdFragment `T.isInfixOf` T.pack addr

-- | System snapshotter (not docker-bundled) needs @containerd config dump@.
containerdDumpNeeded :: DockerInfoFacts -> Bool
containerdDumpNeeded facts =
  difUsesSnapshotter facts
    && not (maybe False isBundledContainerdAddress (difContainerdAddress facts))

-- | Classic / bundled → layers and cache under Docker data-root.
-- System snapshotter → layers at containerd root, cache at Docker data-root.
imageStoreLayout ::
  DockerInfoFacts ->
  Maybe FilePath ->
  Either Text ImageStoreLayout
imageStoreLayout facts mContainerdRoot
  | null (difDockerRootDir facts) =
      Left $
        imageStoreUnresolvedMessage "docker info did not report DockerRootDir"
  | not (containerdDumpNeeded facts) =
      Right
        ImageStoreLayout
          { islLayerPaths = [root],
            islCachePaths = [root]
          }
  | otherwise =
      case mContainerdRoot of
        Just cr
          | not (null cr) ->
              Right
                ImageStoreLayout
                  { islLayerPaths = [cr],
                    islCachePaths = [root]
                  }
        _ -> Left containerdRootUnresolvedMessage
  where
    root = difDockerRootDir facts

-- | Top-level @root@, overridden by a non-empty snapshotter plugin @root_path@.
parseContainerdDump :: Text -> Either Text FilePath
parseContainerdDump txt =
  let lns = T.lines txt
   in case topLevelRoot lns of
        Nothing -> Left containerdRootUnresolvedMessage
        Just r
          | T.null (T.strip r) -> Left containerdRootUnresolvedMessage
          | otherwise ->
              Right (T.unpack (fromMaybe r (snapshotterRootPath lns)))

topLevelRoot :: [Text] -> Maybe Text
topLevelRoot =
  firstJust
    ( \ln ->
        if isIndented ln
          then Nothing
          else case assignment ln of
            Just ("root", val) -> Just val
            _ -> Nothing
    )

snapshotterRootPath :: [Text] -> Maybe Text
snapshotterRootPath = go False
  where
    go _ [] = Nothing
    go inSnap (ln : rest)
      | isTableHeader ln = go (isSnapshotterPluginHeader ln) rest
      | inSnap,
        Just ("root_path", val) <- assignment ln,
        not (T.null val) =
          Just val
      | otherwise = go inSnap rest

isIndented :: Text -> Bool
isIndented t = case T.uncons t of
  Just (c, _) -> c == ' ' || c == '\t'
  Nothing -> False

isTableHeader :: Text -> Bool
isTableHeader ln =
  let s = T.strip ln
   in "[" `T.isPrefixOf` s && "]" `T.isSuffixOf` s

isSnapshotterPluginHeader :: Text -> Bool
isSnapshotterPluginHeader ln =
  isTableHeader ln && snapshotterDriverType `T.isInfixOf` ln

assignment :: Text -> Maybe (Text, Text)
assignment ln =
  let s = T.strip ln
   in case T.break (== '=') s of
        (k, rest)
          | not (T.null rest) ->
              let key = T.strip k
                  raw = T.strip (T.drop 1 rest)
               in if T.null key then Nothing else Just (key, unquote raw)
        _ -> Nothing

unquote :: Text -> Text
unquote t =
  case T.uncons t of
    Just (q, rest)
      | (q == '\'' || q == '"')
          && T.takeEnd 1 t == T.singleton q ->
          T.dropEnd 1 rest
    _ -> t

firstJust :: (a -> Maybe b) -> [a] -> Maybe b
firstJust f = \case
  [] -> Nothing
  (x : xs) -> case f x of
    Just y -> Just y
    Nothing -> firstJust f xs
