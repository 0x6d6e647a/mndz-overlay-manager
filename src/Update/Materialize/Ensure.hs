{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Ensure a host-arch Gentoo materialize image for full-path update units.
module Update.Materialize.Ensure
  ( EnsureOutcome (..),
    EnsureConfig (..),
    waitingOnMaterializeImage,
    ensuringMaterializeImageStatus,
    overrideUnusableMessage,
    ensureFailedMessage,
    imageDiskInsufficientMessage,
    firstImageNeedBytes,
    addToolchainNeedBytes,
    readOverlayBunFloor,
    ensureMaterializeImage,
    prunePreviousMaterializeImage,
    defaultMaterializeSidecarDir,
    hostMachineArch,
    unmappedArchMessage,
    productionEnsureNow,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (MVar, modifyMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getHomeDirectory,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Unistd (SystemID (..), getSystemID)
import Update.DiskSpace
  ( DiskSpaceProbe (..),
    formatBytesHuman,
  )
import Update.Materialize.Floors
  ( NeededFloors,
    emptyFloors,
    floorsIsEmpty,
    floorsSatisfy,
    overlayBunFloorFromMetas,
    unionFloors,
  )
import Update.Materialize.Recipe
  ( RecipeArch,
    lookupRecipeArch,
    renderMaterializeDockerfile,
  )
import Update.Materialize.Sidecar
  ( ImageSidecar (..),
    decodeImageSidecar,
    defaultMaterializeSidecarDirFromEnv,
    encodeImageSidecar,
    imageSidecarSchemaVersion,
    materializeGeneratorId,
    sidecarDockerfilePath,
    sidecarImageJsonPath,
  )
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker
  ( defaultMaterializeImage,
    materializeImageEnvVar,
  )
import Update.Runtime.Ceilings (discoverBunBinMetas)

-- | Result of a successful ensure (no docker build vs built).
data EnsureOutcome
  = EnsureSkipped
  | EnsureBuilt
  deriving (Eq, Show)

-- | Waiting-row reason for full-path packages blocked on ensure.
waitingOnMaterializeImage :: Text
waitingOnMaterializeImage = "waiting on materialize image"

-- | Re-entry / in-row status while ensure runs.
ensuringMaterializeImageStatus :: Text
ensuringMaterializeImageStatus = "ensuring materialize image"

-- | Conservative free-space bound for a first full image (stage3 + toolchains).
firstImageNeedBytes :: Integer
firstImageNeedBytes = 20 * 1024 * 1024 * 1024

-- | Conservative bound when adding toolchain layers to an existing image.
addToolchainNeedBytes :: Integer
addToolchainNeedBytes = 8 * 1024 * 1024 * 1024

-- | Injectable production/test configuration for ensure.
data EnsureConfig = EnsureConfig
  { ecRun :: CommandRunner,
    ecProbe :: DiskSpaceProbe,
    ecOverlayRoot :: FilePath,
    ecSidecarDir :: FilePath,
    ecNow :: IO UTCTime,
    -- | Host @uname -m@. Mapped when ensure is about to generate/build.
    ecUname :: String,
    -- | Non-empty @MNDZ_MATERIALIZE_IMAGE@ override, if set.
    ecOverrideTag :: Maybe String,
    -- | Previous default-tag image id remembered for prune-after-mutate.
    ecPrevImageId :: MVar (Maybe String)
  }

overrideUnusableMessage :: String -> Text
overrideUnusableMessage image =
  "materialize image override is not usable: "
    <> T.pack image
    <> " (set "
    <> T.pack materializeImageEnvVar
    <> " to an existing tag that satisfies this prepare; the CLI does not build or delete override tags)"

ensureFailedMessage :: Text -> Text
ensureFailedMessage err =
  "failed to ensure materialize image: " <> err

-- | Default-tag generate path when @uname -m@ has no official OpenRC stage3.
unmappedArchMessage :: String -> Text
unmappedArchMessage uname =
  "no official gentoo/stage3 OpenRC flavor for host architecture "
    <> T.pack uname

imageDiskInsufficientMessage :: FilePath -> Integer -> Integer -> Text
imageDiskInsufficientMessage path free need =
  "insufficient free space to docker build the materialize image:\n  "
    <> T.pack path
    <> "  free: "
    <> formatBytesHuman free
    <> "  need: "
    <> formatBytesHuman need

productionEnsureNow :: IO UTCTime
productionEnsureNow = getCurrentTime

defaultMaterializeSidecarDir :: IO FilePath
defaultMaterializeSidecarDir = do
  xdg <- lookupEnv "XDG_CACHE_HOME"
  defaultMaterializeSidecarDirFromEnv xdg <$> getHomeDirectory

hostMachineArch :: IO String
hostMachineArch = machine <$> getSystemID

readOverlayBunFloor :: FilePath -> IO (Maybe Text)
readOverlayBunFloor overlayRoot = do
  eMetas <- discoverBunBinMetas overlayRoot
  pure $ case eMetas of
    Left _ -> Nothing
    Right metas -> overlayBunFloorFromMetas metas

-- | Inspect/satisfy or generate+build the default tag. Override tags are
-- inspect-only (never built or deleted).
ensureMaterializeImage ::
  EnsureConfig ->
  NeededFloors ->
  IO (Either Text EnsureOutcome)
ensureMaterializeImage cfg needed
  | floorsIsEmpty needed = pure (Right EnsureSkipped)
  | otherwise =
      case ecOverrideTag cfg of
        Just tag -> inspectOnly cfg tag needed
        Nothing -> ensureDefault cfg needed

inspectOnly ::
  EnsureConfig ->
  String ->
  NeededFloors ->
  IO (Either Text EnsureOutcome)
inspectOnly cfg tag needed = do
  eId <- inspectImageId (ecRun cfg) tag
  case eId of
    Left _ -> pure (Left (overrideUnusableMessage tag))
    Right _iid -> do
      mSide <- readSidecar (ecSidecarDir cfg)
      case mSide of
        Just side
          | floorsSatisfy (isSatisfies side) needed ->
              pure (Right EnsureSkipped)
          | otherwise ->
              pure (Left (overrideUnusableMessage tag))
        -- No sidecar: operator-provided tag is inspect-only; existence is enough.
        Nothing -> pure (Right EnsureSkipped)

ensureDefault ::
  EnsureConfig ->
  NeededFloors ->
  IO (Either Text EnsureOutcome)
ensureDefault cfg needed = do
  let tag = defaultMaterializeImage
      sidecarDir = ecSidecarDir cfg
  eId <- inspectImageId (ecRun cfg) tag
  mSide <- readSidecar sidecarDir
  case (eId, mSide) of
    (Right iid, Just side)
      | T.unpack (isId side) == iid,
        floorsSatisfy (isSatisfies side) needed,
        isGenerator side == materializeGeneratorId ->
          pure (Right EnsureSkipped)
    _ ->
      case lookupRecipeArch (ecUname cfg) of
        Nothing ->
          pure (Left (ensureFailedMessage (unmappedArchMessage (ecUname cfg))))
        Just arch -> do
          let oldSatisfies = maybe emptyFloors isSatisfies mSide
              unioned = unionFloors oldSatisfies needed
              oldId = either (const Nothing) Just eId
          eDisk <- imageDiskGate cfg (isFirstImage mSide eId)
          case eDisk of
            Left err -> pure (Left (ensureFailedMessage err))
            Right () ->
              buildAndRecord cfg tag oldId unioned arch
  where
    isFirstImage mSide eId = case (eId, mSide) of
      (Right _, Just _) -> False
      _ -> True

buildAndRecord ::
  EnsureConfig ->
  String ->
  Maybe String ->
  NeededFloors ->
  RecipeArch ->
  IO (Either Text EnsureOutcome)
buildAndRecord cfg tag oldId unioned arch = do
  let sidecarDir = ecSidecarDir cfg
      dfPath = sidecarDockerfilePath sidecarDir
      ctxDir = sidecarDir </> "context"
      overlay = ecOverlayRoot cfg
      dockerfile =
        renderMaterializeDockerfile unioned arch overlay
  createDirectoryIfMissing True ctxDir
  TIO.writeFile dfPath dockerfile
  -- Remember previous id before retag.
  modifyMVar (ecPrevImageId cfg) $ \cur ->
    pure (cur <|> oldId, ())
  buildRes <-
    docker
      (ecRun cfg)
      [ "build",
        "-t",
        tag,
        "-f",
        dfPath,
        "--build-context",
        "overlay=" <> overlay,
        ctxDir
      ]
  if prExitCode buildRes /= ExitSuccess
    then
      pure $
        Left $
          ensureFailedMessage $
            T.pack (prStderr buildRes <> prStdout buildRes)
    else do
      eNewId <- inspectImageId (ecRun cfg) tag
      case eNewId of
        Left err -> pure (Left (ensureFailedMessage err))
        Right newId -> do
          now <- ecNow cfg
          let side =
                ImageSidecar
                  { isVersion = imageSidecarSchemaVersion,
                    isId = T.pack newId,
                    isTag = T.pack tag,
                    isSatisfies = unioned,
                    isGenerator = materializeGeneratorId,
                    isBuiltAt = now
                  }
          BS.writeFile
            (sidecarImageJsonPath sidecarDir)
            (LBS.toStrict (encodeImageSidecar side))
          -- Keep the generated recipe next to image.json.
          TIO.writeFile dfPath dockerfile
          pure (Right EnsureBuilt)

-- | After mutate: rmi the previous default-tag id if unused, then
-- @docker image prune -f@ (never @-a@, never builder prune, never override).
prunePreviousMaterializeImage :: EnsureConfig -> IO ()
prunePreviousMaterializeImage cfg =
  case ecOverrideTag cfg of
    Just _ -> pure ()
    Nothing -> do
      mOld <- modifyMVar (ecPrevImageId cfg) $ \v -> pure (Nothing, v)
      case mOld of
        Nothing ->
          dockerIgnore (ecRun cfg) ["image", "prune", "-f"]
        Just oldId -> do
          eCur <- inspectImageId (ecRun cfg) defaultMaterializeImage
          let stillCurrent = case eCur of
                Right cur -> cur == oldId
                Left _ -> False
          if stillCurrent
            then dockerIgnore (ecRun cfg) ["image", "prune", "-f"]
            else do
              dockerIgnore (ecRun cfg) ["rmi", oldId]
              dockerIgnore (ecRun cfg) ["image", "prune", "-f"]

imageDiskGate :: EnsureConfig -> Bool -> IO (Either Text ())
imageDiskGate cfg firstImage = do
  dockerRoot <- discoverDockerRoot (ecRun cfg)
  let need =
        if firstImage
          then firstImageNeedBytes
          else addToolchainNeedBytes
      overlay = ecOverlayRoot cfg
      probe = ecProbe cfg
  eDockerFree <- dspFreeBytes probe dockerRoot
  case eDockerFree of
    Left err -> pure (Left err)
    Right dockerFree ->
      if dockerFree < need
        then
          pure $
            Left $
              imageDiskInsufficientMessage dockerRoot dockerFree need
        else do
          eOverDev <- dspDeviceId probe overlay
          eDockDev <- dspDeviceId probe dockerRoot
          let distinct =
                case (eOverDev, eDockDev) of
                  (Right a, Right b) -> a /= b
                  _ -> False
          if not distinct
            then pure (Right ())
            else do
              eOverFree <- dspFreeBytes probe overlay
              case eOverFree of
                Left err -> pure (Left err)
                Right overFree
                  | overFree < need ->
                      pure $
                        Left $
                          imageDiskInsufficientMessage overlay overFree need
                  | otherwise -> pure (Right ())

discoverDockerRoot :: CommandRunner -> IO FilePath
discoverDockerRoot run = do
  res <-
    docker run ["info", "--format", "{{.DockerRootDir}}"]
  let out = strip (prStdout res)
  if prExitCode res == ExitSuccess && not (null out)
    then pure out
    else pure "/var/lib/docker"
  where
    strip = T.unpack . T.strip . T.pack

inspectImageId :: CommandRunner -> String -> IO (Either Text String)
inspectImageId run image = do
  res <-
    docker run ["image", "inspect", "--format", "{{.Id}}", image]
  let out = T.unpack (T.strip (T.pack (prStdout res)))
  if prExitCode res == ExitSuccess && not (null out)
    then pure (Right out)
    else
      pure $
        Left $
          "docker image inspect failed for "
            <> T.pack image
            <> ": "
            <> T.pack (prStderr res)

readSidecar :: FilePath -> IO (Maybe ImageSidecar)
readSidecar dir = do
  let path = sidecarImageJsonPath dir
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bs <- BS.readFile path
      pure $ case decodeImageSidecar bs of
        Right s -> Just s
        Left _ -> Nothing

docker :: CommandRunner -> [String] -> IO ProcessResult
docker run args =
  run
    ProcessRequest
      { prMode = ExecCmd "docker" args,
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

dockerIgnore :: CommandRunner -> [String] -> IO ()
dockerIgnore run args = do
  _ <- docker run args
  pure ()
