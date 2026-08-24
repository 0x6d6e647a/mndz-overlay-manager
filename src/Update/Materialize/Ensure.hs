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
import Data.Containers.ListUtils (nubOrd)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
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
import Update.Runtime.Ceilings
  ( RuntimeEbuildMeta,
    discoverBunBinMetas,
    discoverQlotMetas,
    discoverRuntimeMetasInDir,
    goBinPackageDir,
    goPackageDir,
    nodejsBinPackageDir,
    nodejsPackageDir,
    rustBinPackageDir,
    rustPackageDir,
    sbclBinPackageDir,
    sbclPackageDir,
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
    -- | Gentoo repository root (@portageq get_repo_path / gentoo@ in production).
    ecGentooRoot :: IO (Either Text FilePath)
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

imageDiskInsufficientSplitMessage :: [VolumeNeed] -> Text
imageDiskInsufficientSplitMessage vols =
  "insufficient free space to docker build the materialize image:\n"
    <> T.intercalate "\n" (map splitVolumeLine vols)

splitVolumeLine :: VolumeNeed -> Text
splitVolumeLine v =
  "  "
    <> volumeRoleLabel (vnRoles v)
    <> "  "
    <> T.pack (vnPath v)
    <> "  free: "
    <> formatBytesHuman (vnFree v)
    <> "  need: "
    <> formatBytesHuman (vnNeed v)

volumeRoleLabel :: [ImageDiskRole] -> Text
volumeRoleLabel roles
  | ImageRoleLayers `elem` roles && ImageRoleCache `elem` roles =
      "image layers + build cache"
  | ImageRoleLayers `elem` roles = "image layers"
  | otherwise = "build cache"

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
  metas <- loadBunMetas overlayRoot
  pure (overlayBunFloorFromMetas metas)

readOverlayQlotFloor :: FilePath -> IO (Maybe Text)
readOverlayQlotFloor overlayRoot = do
  metas <- loadQlotMetas overlayRoot
  pure (overlayBunFloorFromMetas metas)

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

loadBunMetas :: FilePath -> IO [RuntimeEbuildMeta]
loadBunMetas overlayRoot = do
  eMetas <- discoverBunBinMetas overlayRoot
  pure $ case eMetas of
    Left _ -> []
    Right metas -> metas

loadQlotMetas :: FilePath -> IO [RuntimeEbuildMeta]
loadQlotMetas overlayRoot = do
  eMetas <- discoverQlotMetas overlayRoot
  pure $ case eMetas of
    Left _ -> []
    Right metas -> metas

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
          eRoot <- ecGentooRoot cfg
          case eRoot of
            Left err ->
              pure (Left (ensureFailedMessage err))
            Right gentooRoot -> do
              metas <- loadGentooToolchainMetas gentooRoot
              bunMetas <- loadBunMetas (ecOverlayRoot cfg)
              qlotMetas <- loadQlotMetas (ecOverlayRoot cfg)
              case resolveNeededInstalls (raKeywords arch) unioned metas bunMetas qlotMetas of
                Left err ->
                  pure (Left (ensureFailedMessage err))
                Right installs -> do
                  eDisk <- imageDiskGate cfg (isFirstImage mSide eId)
                  case eDisk of
                    Left err -> pure (Left (ensureFailedMessage err))
                    Right () ->
                      buildAndRecord cfg tag oldId unioned arch installs
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
  [ResolvedInstall] ->
  IO (Either Text EnsureOutcome)
buildAndRecord cfg tag oldId unioned arch installs = do
  let sidecarDir = ecSidecarDir cfg
      dfPath = sidecarDockerfilePath sidecarDir
      ctxDir = sidecarDir </> "context"
      overlay = ecOverlayRoot cfg
      dockerfile =
        renderMaterializeDockerfile arch overlay installs
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

data ImageDiskRole
  = ImageRoleLayers
  | ImageRoleCache
  deriving (Eq, Ord, Show)

data VolumeNeed = VolumeNeed
  { vnPath :: FilePath,
    vnRoles :: [ImageDiskRole],
    vnFree :: Integer,
    vnNeed :: Integer
  }
  deriving (Eq, Show)

imageDiskGate :: EnsureConfig -> Bool -> IO (Either Text ())
imageDiskGate cfg firstImage = do
  eLayout <- discoverImageStoreLayout (ecRun cfg)
  case eLayout of
    Left err -> pure (Left err)
    Right layout -> do
      layout' <- addBuildkitIfPresent layout
      evalImageDisk (ecProbe cfg) firstImage layout'

-- | @docker info --format '{{json .}}'@, then @containerd config dump@ when
-- layers live on a system snapshotter (never the containerd gRPC socket).
discoverImageStoreLayout :: CommandRunner -> IO (Either Text ImageStoreLayout)
discoverImageStoreLayout run = do
  res <- docker run ["info", "--format", "{{json .}}"]
  let out = T.strip (T.pack (prStdout res))
  if prExitCode res /= ExitSuccess || T.null out
    then pure (Left (imageStoreUnresolvedMessage "docker info failed"))
    else case parseDockerInfoJson out of
      Left err -> pure (Left err)
      Right facts
        | containerdDumpNeeded facts -> discoverSystemSnapshotter run facts
        | otherwise -> pure (imageStoreLayout facts Nothing)

discoverSystemSnapshotter ::
  CommandRunner ->
  DockerInfoFacts ->
  IO (Either Text ImageStoreLayout)
discoverSystemSnapshotter run facts = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "containerd" ["config", "dump"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  let out = T.strip (T.pack (prStdout res))
  if prExitCode res /= ExitSuccess || T.null out
    then pure (Left containerdRootUnresolvedMessage)
    else case parseContainerdDump out of
      Left _ -> pure (Left containerdRootUnresolvedMessage)
      Right root -> do
        exists <- doesDirectoryExist root
        if not exists
          then pure (Left containerdRootUnresolvedMessage)
          else pure (imageStoreLayout facts (Just root))

addBuildkitIfPresent :: ImageStoreLayout -> IO ImageStoreLayout
addBuildkitIfPresent layout =
  case islCachePaths layout of
    [] -> pure layout
    (root : _) -> do
      let bk = root </> "buildkit"
      exists <- doesDirectoryExist bk
      pure $
        if exists && bk `notElem` islCachePaths layout
          then layout {islCachePaths = islCachePaths layout ++ [bk]}
          else layout

evalImageDisk ::
  DiskSpaceProbe ->
  Bool ->
  ImageStoreLayout ->
  IO (Either Text ())
evalImageDisk probe firstImage layout = do
  let paths = nubOrd (islLayerPaths layout ++ islCachePaths layout)
  eMeasured <- probePaths probe paths
  pure $ do
    measured <- eMeasured
    let measuredMap = Map.fromList [(p, (f, d)) | (p, f, d) <- measured]
        entries =
          expand ImageRoleLayers (islLayerPaths layout) measuredMap
            ++ expand ImageRoleCache (islCachePaths layout) measuredMap
        grouped =
          Map.fromListWith
            (++)
            [(d, [(p, r, f)]) | (p, r, f, d) <- entries]
        vols =
          sortOn
            volumeSortKey
            (map reduceDevice (Map.elems grouped))
    checkVolumes firstImage vols

probePaths ::
  DiskSpaceProbe ->
  [FilePath] ->
  IO (Either Text [(FilePath, Integer, Integer)])
probePaths probe = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc (p : ps) = do
      eFree <- dspFreeBytes probe p
      eDev <- dspDeviceId probe p
      case (,) <$> eFree <*> eDev of
        Left err -> pure (Left err)
        Right (free, dev) -> go ((p, free, dev) : acc) ps

expand ::
  ImageDiskRole ->
  [FilePath] ->
  Map.Map FilePath (Integer, Integer) ->
  [(FilePath, ImageDiskRole, Integer, Integer)]
expand role paths measured =
  [ (p, role, free, dev)
  | p <- paths,
    Just (free, dev) <- [Map.lookup p measured]
  ]

reduceDevice :: [(FilePath, ImageDiskRole, Integer)] -> VolumeNeed
reduceDevice xs =
  let roles = nubOrd [r | (_, r, _) <- xs]
      free = minimum [f | (_, _, f) <- xs]
      path = case [p | (p, ImageRoleCache, _) <- xs] of
        (p : _) -> p
        [] -> case [p | (p, ImageRoleLayers, _) <- xs] of
          (p : _) -> p
          [] -> case xs of
            ((p, _, _) : _) -> p
            [] -> ""
   in VolumeNeed
        { vnPath = path,
          vnRoles = roles,
          vnFree = free,
          vnNeed = 0
        }

volumeNeed :: Bool -> [ImageDiskRole] -> Integer
volumeNeed firstImage roles
  | ImageRoleLayers `elem` roles && ImageRoleCache `elem` roles =
      if firstImage then firstImageNeedBytes else addToolchainNeedBytes
  | ImageRoleLayers `elem` roles =
      if firstImage then firstImageLayerNeedBytes else addToolchainLayerNeedBytes
  | otherwise =
      if firstImage then firstImageCacheNeedBytes else addToolchainCacheNeedBytes

volumeSortKey :: VolumeNeed -> Int
volumeSortKey v
  | ImageRoleLayers `elem` vnRoles v = 0
  | otherwise = 1

checkVolumes :: Bool -> [VolumeNeed] -> Either Text ()
checkVolumes firstImage vols =
  let withNeed =
        [ v {vnNeed = volumeNeed firstImage (vnRoles v)}
        | v <- vols
        ]
      short = any (\v -> vnFree v < vnNeed v) withNeed
   in if not short
        then Right ()
        else case withNeed of
          [v] ->
            Left (imageDiskInsufficientMessage (vnPath v) (vnFree v) (vnNeed v))
          vs -> Left (imageDiskInsufficientSplitMessage vs)

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
