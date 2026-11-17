{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Docker image helpers shared by the materialize and smoke image ensures:
-- image id inspect, the stage3 base freshness check, the Docker storage
-- free-space gate, and previous-image removal.
module Update.Materialize.ImageOps
  ( docker,
    dockerIgnore,
    inspectImageId,
    BaseCheckEnv (..),
    BaseCheck (..),
    baseMoved,
    checkBaseFreshness,
    buildBase,
    DiskBounds (..),
    imageDiskGate,
    imageDiskInsufficientMessage,
    removePreviousImage,
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.DiskSpace
  ( DiskSpaceProbe (..),
    formatBytesHuman,
  )
import Update.Materialize.ImageLayout
  ( DockerInfoFacts (..),
    ImageStoreLayout (..),
    containerdDumpNeeded,
    containerdRootUnresolvedMessage,
    imageStoreLayout,
    imageStoreUnresolvedMessage,
    parseContainerdDump,
    parseDockerInfoJson,
  )
import Update.Materialize.Recipe (RecipeArch (..), lookupRecipeArch)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )

docker :: CommandRunner -> [String] -> IO ProcessResult
docker run args =
  run
    ProcessRequest
      { prMode = ExecCmd "docker" args,
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = "",
        prMeasure = Timed
      }

dockerIgnore :: CommandRunner -> [String] -> IO ()
dockerIgnore run args = do
  _ <- docker run args
  pure ()

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

-- | Inputs of one stage3 base freshness check.
data BaseCheckEnv = BaseCheckEnv
  { -- | Host @uname -m@.
    bceUname :: String,
    bceNow :: IO UTCTime,
    -- | @materialize-base-check-interval@.
    bceInterval :: NominalDiffTime,
    -- | Current registry digest of a @gentoo/stage3@ tag (no pull).
    bceStage3Digest :: Text -> IO (Either Text Text),
    bceWarn :: Text -> IO (),
    -- | Image named in the warning (@materialize@, @smoke@).
    bceImageLabel :: Text
  }

-- | Outcome of the stage3 base freshness check.
data BaseCheck
  = -- | Interval not elapsed (or no mapped arch to check).
    BaseNotDue
  | -- | Registry digest equals the recorded one.
    BaseSame Text UTCTime
  | -- | Registry digest differs from the recorded one (or none recorded).
    BaseMoved Text UTCTime
  | -- | Registry request failed; warned, the check stays due.
    BaseCheckFailed
  deriving (Eq, Show)

baseMoved :: BaseCheck -> Bool
baseMoved = \case
  BaseMoved {} -> True
  _ -> False

-- | Due when no digest or check time is recorded, or the interval passed.
checkBaseFreshness ::
  BaseCheckEnv ->
  -- | Recorded stage3 digest.
  Maybe Text ->
  -- | Recorded last base check.
  Maybe UTCTime ->
  IO BaseCheck
checkBaseFreshness env recorded lastCheck =
  case lookupRecipeArch (bceUname env) of
    Nothing -> pure BaseNotDue
    Just arch -> do
      now <- bceNow env
      let due = case (recorded, lastCheck) of
            (Just _, Just at) -> diffUTCTime now at >= bceInterval env
            _ -> True
      if not due
        then pure BaseNotDue
        else do
          eDigest <- bceStage3Digest env (raHubTag arch)
          case eDigest of
            Left err -> do
              bceWarn env ("gentoo/stage3 base check failed (" <> err <> "); keeping the current " <> bceImageLabel env <> " image")
              pure BaseCheckFailed
            Right digest
              | Just digest == recorded -> pure (BaseSame digest now)
              | otherwise -> pure (BaseMoved digest now)

-- | Digest and base check time a build pins and records, falling back to
-- the recorded digest and check time.
buildBase :: BaseCheck -> Maybe Text -> Maybe UTCTime -> Maybe (Text, Maybe UTCTime)
buildBase base recorded lastCheck = case base of
  BaseSame d at -> Just (d, Just at)
  BaseMoved d at -> Just (d, Just at)
  _ -> (,lastCheck) <$> recorded

-- | Free bytes a build needs: layers and cache on one device, or each alone.
data DiskBounds = DiskBounds
  { dbCombined :: Integer,
    dbLayers :: Integer,
    dbCache :: Integer
  }
  deriving (Eq, Show)

imageDiskInsufficientMessage :: Text -> FilePath -> Integer -> Integer -> Text
imageDiskInsufficientMessage label path free need =
  "insufficient free space to docker build the "
    <> label
    <> " image:\n  "
    <> T.pack path
    <> "  free: "
    <> formatBytesHuman free
    <> "  need: "
    <> formatBytesHuman need

imageDiskInsufficientSplitMessage :: Text -> [VolumeNeed] -> Text
imageDiskInsufficientSplitMessage label vols =
  "insufficient free space to docker build the "
    <> label
    <> " image:\n"
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

-- | Free space on the filesystems backing image layers and the BuildKit
-- cache, against @bounds@. @label@ names the image in the error.
imageDiskGate :: CommandRunner -> DiskSpaceProbe -> Text -> DiskBounds -> IO (Either Text ())
imageDiskGate run probe label bounds = do
  eLayout <- discoverImageStoreLayout run
  case eLayout of
    Left err -> pure (Left err)
    Right layout -> do
      layout' <- addBuildkitIfPresent layout
      evalImageDisk probe label bounds layout'

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
          prStdin = "",
          prMeasure = Timed
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
  Text ->
  DiskBounds ->
  ImageStoreLayout ->
  IO (Either Text ())
evalImageDisk probe label bounds layout = do
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
    checkVolumes label bounds vols

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

volumeNeed :: DiskBounds -> [ImageDiskRole] -> Integer
volumeNeed bounds roles
  | ImageRoleLayers `elem` roles && ImageRoleCache `elem` roles = dbCombined bounds
  | ImageRoleLayers `elem` roles = dbLayers bounds
  | otherwise = dbCache bounds

volumeSortKey :: VolumeNeed -> Int
volumeSortKey v
  | ImageRoleLayers `elem` vnRoles v = 0
  | otherwise = 1

checkVolumes :: Text -> DiskBounds -> [VolumeNeed] -> Either Text ()
checkVolumes label bounds vols =
  let withNeed =
        [ v {vnNeed = volumeNeed bounds (vnRoles v)}
        | v <- vols
        ]
      short = any (\v -> vnFree v < vnNeed v) withNeed
   in if not short
        then Right ()
        else case withNeed of
          [v] ->
            Left (imageDiskInsufficientMessage label (vnPath v) (vnFree v) (vnNeed v))
          vs -> Left (imageDiskInsufficientSplitMessage label vs)

-- | @docker rmi@ of @oldId@ unless it is still what @tag@ names. Docker
-- refuses while a container uses the image; that refusal is ignored.
removePreviousImage :: CommandRunner -> String -> String -> IO ()
removePreviousImage run tag oldId = do
  eCur <- inspectImageId run tag
  let stillCurrent = either (const False) (== oldId) eCur
  if stillCurrent then pure () else dockerIgnore run ["rmi", oldId]
