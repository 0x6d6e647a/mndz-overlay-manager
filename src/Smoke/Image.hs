{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Ensure the smoke image: its sidecar, the build decision, the Docker
-- storage gate, @docker build@, and removal of the replaced image.
module Smoke.Image
  ( smokeImageTag,
    smokeCacheDirFromEnv,
    defaultSmokeCacheDir,
    SmokeSidecar (..),
    smokeSidecarSchemaVersion,
    smokeSidecarPath,
    smokeDockerfilePath,
    encodeSmokeSidecar,
    decodeSmokeSidecar,
    SmokeImageConfig (..),
    SmokeImageOutcome (..),
    smokeImageBounds,
    ensureSmokeImage,
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
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (NominalDiffTime, UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Smoke.Recipe (renderSmokeDockerfile, smokeGeneratorId)
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.DiskSpace (DiskSpaceProbe)
import Update.Materialize.ImageLayout
  ( addToolchainCacheNeedBytes,
    addToolchainLayerNeedBytes,
    addToolchainNeedBytes,
  )
import Update.Materialize.ImageOps
  ( BaseCheck (..),
    BaseCheckEnv (..),
    DiskBounds (..),
    baseMoved,
    buildBase,
    checkBaseFreshness,
    docker,
    imageDiskGate,
    inspectImageId,
    removePreviousImage,
  )
import Update.Materialize.Recipe (lookupRecipeArch)
import Update.Process (CommandRunner, ProcessResult (..))

-- | Tag of the smoke image. Not affected by @MNDZ_MATERIALIZE_IMAGE@.
smokeImageTag :: String
smokeImageTag = "mndz-overlay-manager/smoke:local"

-- | @${XDG_CACHE_HOME}/mndz/overlay-manager/smoke@ when set and non-empty,
-- else @${HOME}/.cache/mndz/overlay-manager/smoke@.
smokeCacheDirFromEnv :: Maybe FilePath -> FilePath -> FilePath
smokeCacheDirFromEnv mXdgCache home =
  case mXdgCache of
    Just dir | not (null dir) -> dir </> "mndz" </> "overlay-manager" </> "smoke"
    _ -> home </> ".cache" </> "mndz" </> "overlay-manager" </> "smoke"

defaultSmokeCacheDir :: IO FilePath
defaultSmokeCacheDir = smokeCacheDirFromEnv <$> lookupEnv "XDG_CACHE_HOME" <*> getHomeDirectory

smokeSidecarSchemaVersion :: Int
smokeSidecarSchemaVersion = 1

-- | Record of the current smoke image (@smoke/image.json@).
data SmokeSidecar = SmokeSidecar
  { ssVersion :: Int,
    ssId :: Text,
    ssTag :: Text,
    ssGenerator :: Text,
    ssStage3Digest :: Text,
    -- | Managed tree commit the image was built from. Informational.
    ssTreeCommit :: Text,
    ssBuiltAt :: UTCTime,
    ssLastBaseCheck :: Maybe UTCTime
  }
  deriving (Eq, Show)

instance ToJSON SmokeSidecar where
  toJSON s =
    object $
      [ "version" .= ssVersion s,
        "id" .= ssId s,
        "tag" .= ssTag s,
        "generator" .= ssGenerator s,
        "stage3_digest" .= ssStage3Digest s,
        "tree_commit" .= ssTreeCommit s,
        "built_at" .= iso8601Show (ssBuiltAt s)
      ]
        <> ["last_base_check" .= iso8601Show t | Just t <- [ssLastBaseCheck s]]

instance FromJSON SmokeSidecar where
  parseJSON = withObject "smoke image.json" $ \o -> do
    ver <- o .: "version"
    sid <- o .: "id"
    tag <- o .: "tag"
    gen <- o .: "generator"
    digest <- o .: "stage3_digest"
    tree <- o .: "tree_commit"
    built <- o .: "built_at" >>= time
    lastCheck <- o .:? "last_base_check" >>= traverse time
    pure (SmokeSidecar ver sid tag gen digest tree built lastCheck)
    where
      time :: Text -> Parser UTCTime
      time raw = maybe (fail "unparseable time") pure (iso8601ParseM (T.unpack raw))

smokeSidecarPath :: FilePath -> FilePath
smokeSidecarPath dir = dir </> "image.json"

smokeDockerfilePath :: FilePath -> FilePath
smokeDockerfilePath dir = dir </> "Dockerfile"

encodeSmokeSidecar :: SmokeSidecar -> LBS.ByteString
encodeSmokeSidecar = encode

-- | Bad JSON, a missing field, or another schema version is a miss.
decodeSmokeSidecar :: BS.ByteString -> Either String SmokeSidecar
decodeSmokeSidecar bs = do
  doc <- eitherDecodeStrict' bs
  if ssVersion doc /= smokeSidecarSchemaVersion
    then Left ("unsupported smoke image.json version: " <> show (ssVersion doc))
    else Right doc

data SmokeImageConfig = SmokeImageConfig
  { sicRun :: CommandRunner,
    sicProbe :: DiskSpaceProbe,
    -- | @smoke/@ cache directory (sidecar, recipe, empty build context).
    sicCacheDir :: FilePath,
    -- | Host @uname -m@.
    sicUname :: String,
    -- | Managed tree root, the build's @gentoo@ context.
    sicGentooTree :: FilePath,
    sicGentooCommit :: Text,
    sicNow :: IO UTCTime,
    sicStage3Digest :: Text -> IO (Either Text Text),
    -- | @materialize-base-check-interval@ (shared with the materialize image).
    sicBaseCheckInterval :: NominalDiffTime,
    sicWarn :: Text -> IO ()
  }

data SmokeImageOutcome
  = SmokeImageReused
  | SmokeImageBuilt
  deriving (Eq, Show)

-- | Base-only image bounds.
smokeImageBounds :: DiskBounds
smokeImageBounds = DiskBounds addToolchainNeedBytes addToolchainLayerNeedBytes addToolchainCacheNeedBytes

failed :: Text -> Either Text a
failed = Left . ("failed to ensure smoke image: " <>)

-- | Reuse the recorded image, or build it when none is recorded, the
-- recorded id is gone, the generator differs, or the stage3 digest moved.
-- A moved managed tree alone does not build.
ensureSmokeImage :: SmokeImageConfig -> IO (Either Text SmokeImageOutcome)
ensureSmokeImage cfg = do
  let dir = sicCacheDir cfg
  eId <- inspectImageId (sicRun cfg) smokeImageTag
  mSide <- readSidecar dir
  base <-
    checkBaseFreshness
      BaseCheckEnv
        { bceUname = sicUname cfg,
          bceNow = sicNow cfg,
          bceInterval = sicBaseCheckInterval cfg,
          bceStage3Digest = sicStage3Digest cfg,
          bceWarn = sicWarn cfg,
          bceImageLabel = "smoke"
        }
      (ssStage3Digest <$> mSide)
      (mSide >>= ssLastBaseCheck)
  case (eId, mSide) of
    (Right iid, Just side)
      | T.unpack (ssId side) == iid,
        ssGenerator side == smokeGeneratorId,
        not (baseMoved base) -> do
          case base of
            BaseSame _ at -> writeSidecar dir side {ssLastBaseCheck = Just at}
            _ -> pure ()
          pure (Right SmokeImageReused)
    _ -> case lookupRecipeArch (sicUname cfg) of
      Nothing ->
        pure (failed ("no official gentoo/stage3 OpenRC flavor for host architecture " <> T.pack (sicUname cfg)))
      Just arch ->
        case buildBase base (ssStage3Digest <$> mSide) (mSide >>= ssLastBaseCheck) of
          Nothing -> pure (failed "no gentoo/stage3 digest is recorded and the registry check failed")
          Just (digest, lastCheck) -> do
            eDisk <- imageDiskGate (sicRun cfg) (sicProbe cfg) "smoke" smokeImageBounds
            case eDisk of
              Left err -> pure (failed err)
              Right () -> do
                let dockerfile = renderSmokeDockerfile arch digest
                    ctxDir = dir </> "context"
                    dfPath = smokeDockerfilePath dir
                createDirectoryIfMissing True ctxDir
                TIO.writeFile dfPath dockerfile
                res <-
                  docker
                    (sicRun cfg)
                    [ "build",
                      "-t",
                      smokeImageTag,
                      "-f",
                      dfPath,
                      "--build-context",
                      "gentoo=" <> sicGentooTree cfg,
                      ctxDir
                    ]
                if prExitCode res /= ExitSuccess
                  then pure (failed (T.strip (T.pack (prStderr res <> prStdout res))))
                  else do
                    eNew <- inspectImageId (sicRun cfg) smokeImageTag
                    case eNew of
                      Left err -> pure (failed err)
                      Right newId -> do
                        now <- sicNow cfg
                        writeSidecar
                          dir
                          SmokeSidecar
                            { ssVersion = smokeSidecarSchemaVersion,
                              ssId = T.pack newId,
                              ssTag = T.pack smokeImageTag,
                              ssGenerator = smokeGeneratorId,
                              ssStage3Digest = digest,
                              ssTreeCommit = sicGentooCommit cfg,
                              ssBuiltAt = now,
                              ssLastBaseCheck = lastCheck
                            }
                        case eId of
                          Right oldId | oldId /= newId -> removePreviousImage (sicRun cfg) smokeImageTag oldId
                          _ -> pure ()
                        pure (Right SmokeImageBuilt)

readSidecar :: FilePath -> IO (Maybe SmokeSidecar)
readSidecar dir = do
  let path = smokeSidecarPath dir
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else either (const Nothing) Just . decodeSmokeSidecar <$> BS.readFile path

writeSidecar :: FilePath -> SmokeSidecar -> IO ()
writeSidecar dir side = do
  createDirectoryIfMissing True dir
  BS.writeFile (smokeSidecarPath dir) (LBS.toStrict (encodeSmokeSidecar side))
