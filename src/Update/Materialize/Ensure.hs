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
    firstImageLayerNeedBytes,
    firstImageCacheNeedBytes,
    addToolchainLayerNeedBytes,
    addToolchainCacheNeedBytes,
    DockerInfoFacts (..),
    ImageStoreLayout (..),
    parseDockerInfoJson,
    parseContainerdDump,
    imageStoreLayout,
    containerdDumpNeeded,
    isBundledContainerdAddress,
    imageStoreUnresolvedMessage,
    containerdRootUnresolvedMessage,
    readOverlayBunFloor,
    readOverlayQlotFloor,
    readOverlayNodeGypFloor,
    ensureMaterializeImage,
    ensureToolsImage,
    prunePreviousMaterializeImage,
    defaultMaterializeSidecarDir,
    hostMachineArch,
    unmappedArchMessage,
    productionEnsureNow,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (MVar, modifyMVar, withMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getHomeDirectory,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Unistd (SystemID (..), getSystemID)
import Update.DiskSpace (DiskSpaceProbe)
import Update.Materialize.Floors
  ( NeededFloors,
    emptyFloors,
    floorsIsEmpty,
    floorsSatisfy,
    overlayBunFloorFromMetas,
    unionFloors,
  )
import Update.Materialize.ImageLayout
  ( DockerInfoFacts (..),
    ImageStoreLayout (..),
    addToolchainCacheNeedBytes,
    addToolchainLayerNeedBytes,
    addToolchainNeedBytes,
    containerdDumpNeeded,
    containerdRootUnresolvedMessage,
    firstImageCacheNeedBytes,
    firstImageLayerNeedBytes,
    firstImageNeedBytes,
    imageStoreLayout,
    imageStoreUnresolvedMessage,
    isBundledContainerdAddress,
    parseContainerdDump,
    parseDockerInfoJson,
  )
import Update.Materialize.ImageOps
  ( BaseCheck (..),
    BaseCheckEnv (..),
    DiskBounds (..),
    baseMoved,
    buildBase,
    checkBaseFreshness,
    docker,
    dockerIgnore,
    inspectImageId,
  )
import Update.Materialize.ImageOps qualified as Ops
import Update.Materialize.Recipe
  ( RecipeArch (..),
    lookupRecipeArch,
    renderMaterializeDockerfile,
  )
import Update.Materialize.Resolve
  ( GentooToolchainMetas (..),
    ResolvedInstall,
    resolveNeededInstalls,
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
import Update.OverlayTree (InTree, TreeLock, withOverlayTreeChecked)
import Update.Process
  ( CommandRunner,
    ProcessResult (..),
  )
import Update.Process.Docker
  ( defaultMaterializeImage,
    materializeImageEnvVar,
  )
import Update.Runtime.Ceilings
  ( RuntimeEbuildMeta,
    discoverBunBinMetas,
    discoverNodeGypMetas,
    discoverQlotMetas,
    discoverRuntimeMetasInDir,
    goBinPackageDir,
    goPackageDir,
    nodejsBinPackageDir,
    nodejsPackageDir,
    pdmPackageDir,
    pythonPackageDir,
    rustBinPackageDir,
    rustPackageDir,
    sbclBinPackageDir,
    sbclPackageDir,
    uvBinPackageDir,
    uvPackageDir,
  )

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
    ecPrevImageId :: MVar (Maybe String),
    -- | Managed Gentoo tree root (atom choice and the build's @gentoo@ context).
    ecGentooTree :: FilePath,
    -- | Managed tree commit recorded on a built image.
    ecGentooCommit :: Text,
    -- | Current registry digest of a @gentoo/stage3@ tag (no pull).
    ecStage3Digest :: Text -> IO (Either Text Text),
    -- | @materialize-base-check-interval@.
    ecBaseCheckInterval :: NominalDiffTime,
    ecWarn :: Text -> IO (),
    -- | Serializes default-tag ensures of one run (full-path prepare and the
    -- Portage tools image).
    ecBuildLock :: MVar ()
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
imageDiskInsufficientMessage = Ops.imageDiskInsufficientMessage "materialize"

productionEnsureNow :: IO UTCTime
productionEnsureNow = getCurrentTime

defaultMaterializeSidecarDir :: IO FilePath
defaultMaterializeSidecarDir = do
  xdg <- lookupEnv "XDG_CACHE_HOME"
  defaultMaterializeSidecarDirFromEnv xdg <$> getHomeDirectory

hostMachineArch :: IO String
hostMachineArch = machine <$> getSystemID

readOverlayBunFloor :: InTree -> FilePath -> IO (Either Text (Maybe Text))
readOverlayBunFloor tree overlayRoot = do
  eMetas <- loadBunMetas tree overlayRoot
  pure $ overlayBunFloorFromMetas <$> eMetas

readOverlayQlotFloor :: InTree -> FilePath -> IO (Either Text (Maybe Text))
readOverlayQlotFloor tree overlayRoot = do
  eMetas <- loadQlotMetas tree overlayRoot
  pure $ overlayBunFloorFromMetas <$> eMetas

readOverlayNodeGypFloor :: InTree -> FilePath -> IO (Either Text (Maybe Text))
readOverlayNodeGypFloor tree overlayRoot = do
  eMetas <- loadNodeGypMetas tree overlayRoot
  pure $ overlayBunFloorFromMetas <$> eMetas

-- | Missing package dir (including @-bin@) is an empty meta list, not a fail.
loadGentooToolchainMetas :: FilePath -> IO GentooToolchainMetas
loadGentooToolchainMetas gentooRoot =
  GentooToolchainMetas
    <$> metasOrEmpty (goPackageDir gentooRoot) (Just "go-")
    <*> metasOrEmpty (goBinPackageDir gentooRoot) (Just "go-bin-")
    <*> metasOrEmpty (nodejsPackageDir gentooRoot) (Just "nodejs-")
    <*> metasOrEmpty (nodejsBinPackageDir gentooRoot) (Just "nodejs-bin-")
    <*> metasOrEmpty (rustPackageDir gentooRoot) (Just "rust-")
    <*> metasOrEmpty (rustBinPackageDir gentooRoot) (Just "rust-bin-")
    <*> metasOrEmpty (sbclPackageDir gentooRoot) (Just "sbcl-")
    <*> metasOrEmpty (sbclBinPackageDir gentooRoot) (Just "sbcl-bin-")
    <*> metasOrEmpty (pythonPackageDir gentooRoot) (Just "python-")
    <*> metasOrEmpty (uvPackageDir gentooRoot) (Just "uv-")
    <*> metasOrEmpty (uvBinPackageDir gentooRoot) (Just "uv-bin-")
    <*> metasOrEmpty (pdmPackageDir gentooRoot) (Just "pdm-")

loadBunMetas :: InTree -> FilePath -> IO (Either Text [RuntimeEbuildMeta])
loadBunMetas tree overlayRoot =
  tolerateMissingDir <$> discoverBunBinMetas tree overlayRoot

loadQlotMetas :: InTree -> FilePath -> IO (Either Text [RuntimeEbuildMeta])
loadQlotMetas tree overlayRoot =
  tolerateMissingDir <$> discoverQlotMetas tree overlayRoot

loadNodeGypMetas :: InTree -> FilePath -> IO (Either Text [RuntimeEbuildMeta])
loadNodeGypMetas tree overlayRoot =
  tolerateMissingDir <$> discoverNodeGypMetas tree overlayRoot

-- | A missing package directory is an empty meta list. An unreadable ebuild is not.
tolerateMissingDir :: Either Text [a] -> Either Text [a]
tolerateMissingDir (Left err)
  | "directory not found:" `T.isPrefixOf` err = Right []
  | otherwise = Left err
tolerateMissingDir other = other

metasOrEmpty ::
  FilePath ->
  Maybe Text ->
  IO [RuntimeEbuildMeta]
metasOrEmpty pkgDir mPrefix = do
  result <- discoverRuntimeMetasInDir pkgDir mPrefix
  pure $ case result of
    Left _ -> []
    Right metas -> metas

-- | Inspect/satisfy or generate+build the default tag. Override tags are
-- inspect-only (never built or deleted).
ensureMaterializeImage ::
  TreeLock ->
  EnsureConfig ->
  NeededFloors ->
  IO (Either Text EnsureOutcome)
ensureMaterializeImage lock cfg needed
  | floorsIsEmpty needed = pure (Right EnsureSkipped)
  | otherwise =
      case ecOverrideTag cfg of
        Just tag -> inspectOnly cfg tag needed
        Nothing -> ensureDefault lock cfg needed

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
  TreeLock ->
  EnsureConfig ->
  NeededFloors ->
  IO (Either Text EnsureOutcome)
ensureDefault lock cfg needed = withMVar (ecBuildLock cfg) $ \() -> do
  let tag = defaultMaterializeImage
      sidecarDir = ecSidecarDir cfg
  eId <- inspectImageId (ecRun cfg) tag
  mSide <- readSidecar sidecarDir
  base <- materializeBaseCheck cfg mSide
  case (eId, mSide) of
    (Right iid, Just side)
      | T.unpack (isId side) == iid,
        floorsSatisfy (isSatisfies side) needed,
        isGenerator side == materializeGeneratorId,
        not (baseMoved base) -> do
          recordBaseCheck sidecarDir side base
          pure (Right EnsureSkipped)
    _ ->
      case lookupRecipeArch (ecUname cfg) of
        Nothing ->
          pure (Left (ensureFailedMessage (unmappedArchMessage (ecUname cfg))))
        Just arch -> do
          let oldSatisfies = maybe emptyFloors isSatisfies mSide
              unioned = unionFloors oldSatisfies needed
              oldId = either (const Nothing) Just eId
          do
            metas <- loadGentooToolchainMetas (ecGentooTree cfg)
            eOverlay <-
              withOverlayTreeChecked lock $ \tree -> do
                bun <- loadBunMetas tree (ecOverlayRoot cfg)
                qlot <- loadQlotMetas tree (ecOverlayRoot cfg)
                nodeGyp <- loadNodeGypMetas tree (ecOverlayRoot cfg)
                pure ((,,) <$> bun <*> qlot <*> nodeGyp)
            case eOverlay of
              Left err -> pure (Left (ensureFailedMessage err))
              Right (Left err) -> pure (Left (ensureFailedMessage err))
              Right (Right (bunMetas, qlotMetas, nodeGypMetas)) ->
                case resolveNeededInstalls (raKeywords arch) unioned metas bunMetas qlotMetas nodeGypMetas of
                  Left err ->
                    pure (Left (ensureFailedMessage err))
                  Right installs -> do
                    eDisk <- imageDiskGate cfg (isFirstImage mSide eId)
                    case (eDisk, buildBase base (mSide >>= isStage3Digest) (mSide >>= isLastBaseCheck)) of
                      (Left err, _) -> pure (Left (ensureFailedMessage err))
                      (Right (), Nothing) ->
                        pure (Left (ensureFailedMessage "no gentoo/stage3 digest is recorded and the registry check failed"))
                      (Right (), Just pinned) ->
                        buildAndRecord cfg tag oldId unioned arch pinned installs
  where
    isFirstImage mSide' eId' = case (eId', mSide') of
      (Right _, Just _) -> False
      _ -> True

-- | Image for the Portage tools container: the override tag when set, else
-- the recorded current image while it exists, else the image ensure builds
-- for an empty floor set (base-only on a host with no recorded image).
ensureToolsImage :: TreeLock -> EnsureConfig -> IO (Either Text String)
ensureToolsImage lock cfg =
  case ecOverrideTag cfg of
    Just tag -> pure (Right tag)
    Nothing -> do
      current <- recordedImage
      case current of
        Just iid -> pure (Right iid)
        Nothing -> do
          built <- ensureDefault lock cfg emptyFloors
          case built of
            Left err -> pure (Left err)
            Right _ ->
              maybe (Left (ensureFailedMessage "no image recorded after build")) Right
                <$> recordedImage
  where
    recordedImage = do
      mSide <- readSidecar (ecSidecarDir cfg)
      case mSide of
        Nothing -> pure Nothing
        Just side -> do
          let iid = T.unpack (isId side)
          present <- inspectImageId (ecRun cfg) iid
          pure (either (const Nothing) (const (Just iid)) present)

-- | Base freshness check of the materialize sidecar's stage3 pin.
materializeBaseCheck :: EnsureConfig -> Maybe ImageSidecar -> IO BaseCheck
materializeBaseCheck cfg mSide =
  checkBaseFreshness
    BaseCheckEnv
      { bceUname = ecUname cfg,
        bceNow = ecNow cfg,
        bceInterval = ecBaseCheckInterval cfg,
        bceStage3Digest = ecStage3Digest cfg,
        bceWarn = ecWarn cfg,
        bceImageLabel = "materialize"
      }
    (mSide >>= isStage3Digest)
    (mSide >>= isLastBaseCheck)

-- | A same-digest check without a build resets the interval.
recordBaseCheck :: FilePath -> ImageSidecar -> BaseCheck -> IO ()
recordBaseCheck sidecarDir side = \case
  BaseSame _ at ->
    BS.writeFile
      (sidecarImageJsonPath sidecarDir)
      (LBS.toStrict (encodeImageSidecar side {isLastBaseCheck = Just at}))
  _ -> pure ()

buildAndRecord ::
  EnsureConfig ->
  String ->
  Maybe String ->
  NeededFloors ->
  RecipeArch ->
  (Text, Maybe UTCTime) ->
  [ResolvedInstall] ->
  IO (Either Text EnsureOutcome)
buildAndRecord cfg tag oldId unioned arch (digest, lastCheck) installs = do
  let sidecarDir = ecSidecarDir cfg
      dfPath = sidecarDockerfilePath sidecarDir
      ctxDir = sidecarDir </> "context"
      overlay = ecOverlayRoot cfg
      dockerfile =
        renderMaterializeDockerfile arch digest installs
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
        "--build-context",
        "gentoo=" <> ecGentooTree cfg,
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
                    isBuiltAt = now,
                    isTreeCommit = Just (ecGentooCommit cfg),
                    isStage3Digest = Just digest,
                    isLastBaseCheck = lastCheck
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

-- | Materialize image bounds: a first image, or one that adds toolchains.
imageDiskGate :: EnsureConfig -> Bool -> IO (Either Text ())
imageDiskGate cfg firstImage =
  Ops.imageDiskGate (ecRun cfg) (ecProbe cfg) "materialize" bounds
  where
    bounds
      | firstImage = DiskBounds firstImageNeedBytes firstImageLayerNeedBytes firstImageCacheNeedBytes
      | otherwise = DiskBounds addToolchainNeedBytes addToolchainLayerNeedBytes addToolchainCacheNeedBytes

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
