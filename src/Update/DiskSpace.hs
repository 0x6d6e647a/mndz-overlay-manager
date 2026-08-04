{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Free-space estimation and command-level feasibility gate for @update@.
--
-- Pure need math (baselines × ecosystem factors + fixed margin), multi-unit
-- max / concurrent-sum under @--jobs@, same-device merge, injectable free-space
-- probes (production uses POSIX @statvfs@), and Portage DISTDIR warn-only.
module Update.DiskSpace
  ( -- * Constants
    safetyMarginBytes,
    factorGoFull,
    factorCargo,
    factorNpmBun,
    factorSbcl,
    factorReuse,
    factorDistDirFetch,
    floorGoTemp,
    floorCargoTemp,
    floorNpmBunTemp,
    floorSbclTemp,
    floorReuseTemp,
    floorGitMvDist,
    portageWarnFreeThreshold,

    -- * Classification
    MaterializeClass (..),
    materializeClassForEcosystem,
    materializeClassFull,

    -- * Pure estimates
    estimateNeedBytes,
    maxNeed,
    concurrentSumNeed,
    combineSameDeviceNeeds,

    -- * Manifest baselines
    ManifestDistEntry (..),
    parseManifestDistEntries,
    lookupManifestBaselineBySuffix,
    lookupManifestBaselineForClass,

    -- * Roots and free space
    resolveTempRoot,
    getFreeBytes,
    getDeviceId,
    directoryTreeBytes,

    -- * Unit plans and gate
    FsRole (..),
    UnitDiskPlan (..),
    DiskSpaceProbe (..),
    productionDiskSpaceProbe,
    DiskGateOk (..),
    evaluateDiskFeasibility,
    runDiskSpaceGate,
    formatBytesHuman,
    checkTempNeedAtAdmit,
    checkPostCloneSpace,
    checkPostCloneForClass,
    postCloneRemainingEstimate,
    presentDistfileNeed,
    readManifestMaybe,
  )
where

import Control.Exception (try)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Ratio (denominator, numerator, (%))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Foreign (Ptr, allocaBytes, peekByteOff)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CULong (..))
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    getTemporaryDirectory,
    listDirectory,
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files
  ( deviceID,
    fileSize,
    getFileStatus,
    isDirectory,
    isRegularFile,
    isSymbolicLink,
  )
import System.Posix.Types (DeviceID)
import Update.Types
  ( EcosystemSpec (..),
    PackageKey (..),
  )

------------------------------------------------------------------------
-- Constants (named product values; calibrate without changing formula)
------------------------------------------------------------------------

-- | Fixed safety margin added to every filesystem need estimate.
safetyMarginBytes :: Integer
safetyMarginBytes = 256 * 1024 * 1024

factorGoFull :: Rational
factorGoFull = 5

factorCargo :: Rational
factorCargo = 12

factorNpmBun :: Rational
factorNpmBun = 4

factorSbcl :: Rational
factorSbcl = 10

-- | Near-exact reuse / DISTDIR fetch growth (≤ ~10%).
factorReuse :: Rational
factorReuse = 11 % 10

factorDistDirFetch :: Rational
factorDistDirFetch = 11 % 10

floorGoTemp :: Integer
floorGoTemp = 3 * giB

floorCargoTemp :: Integer
floorCargoTemp = (3 * giB) `div` 2

floorNpmBunTemp :: Integer
floorNpmBunTemp = (3 * giB) `div` 2

floorSbclTemp :: Integer
floorSbclTemp = 2 * giB

floorReuseTemp :: Integer
floorReuseTemp = 512 * 1024 * 1024

-- | Manager DISTDIR floor for GitMv / unknown missing distfile fetches.
floorGitMvDist :: Integer
floorGitMvDist = 512 * 1024 * 1024

-- | Portage DISTDIR free-space warn threshold (distinct path only).
portageWarnFreeThreshold :: Integer
portageWarnFreeThreshold = giB

giB :: Integer
giB = 1024 * 1024 * 1024

------------------------------------------------------------------------
-- Classification
------------------------------------------------------------------------

-- | How a unit will write to temp / distfiles.
data MaterializeClass
  = FullGo
  | FullCargo
  | FullNpmBun
  | FullSbcl
  | ReusePath
  | GitMvFetch
  deriving (Eq, Show)

materializeClassForEcosystem :: EcosystemSpec -> MaterializeClass
materializeClassForEcosystem eco =
  case eco of
    Go _ -> FullGo
    Cargo {} -> FullCargo
    NpmEco -> FullNpmBun
    Bun -> FullNpmBun
    Sbcl -> FullSbcl

-- | Full-path class for an ecosystem (never reuse).
materializeClassFull :: EcosystemSpec -> MaterializeClass
materializeClassFull = materializeClassForEcosystem

------------------------------------------------------------------------
-- Pure estimates
------------------------------------------------------------------------

-- | @floor_or (baseline × factor) + margin@; no baseline → ecosystem floor + margin.
estimateNeedBytes :: MaterializeClass -> Maybe Integer -> Integer
estimateNeedBytes cls mBaseline =
  let body = case mBaseline of
        Just b | b > 0 -> scaleUp b (factorFor cls)
        _ -> floorFor cls
   in body + safetyMarginBytes

factorFor :: MaterializeClass -> Rational
factorFor = \case
  FullGo -> factorGoFull
  FullCargo -> factorCargo
  FullNpmBun -> factorNpmBun
  FullSbcl -> factorSbcl
  ReusePath -> factorReuse
  GitMvFetch -> factorDistDirFetch

floorFor :: MaterializeClass -> Integer
floorFor = \case
  FullGo -> floorGoTemp
  FullCargo -> floorCargoTemp
  FullNpmBun -> floorNpmBunTemp
  FullSbcl -> floorSbclTemp
  ReusePath -> floorReuseTemp
  GitMvFetch -> floorGitMvDist

scaleUp :: Integer -> Rational -> Integer
scaleUp n r =
  let num = numerator r
      den = denominator r
   in (n * num + den - 1) `div` den

-- | Largest single-unit need (0 when empty).
maxNeed :: [Integer] -> Integer
maxNeed [] = 0
maxNeed xs = maximum xs

-- | Sum of the up to @n@ largest unit needs (package job concurrency).
concurrentSumNeed :: Int -> [Integer] -> Integer
concurrentSumNeed n xs
  | n <= 0 = 0
  | otherwise =
      let top = take n (sortBy (comparing Down) xs)
       in sum top

-- | When two path need lists share a device, combine unit needs for that device.
-- Each list entry is one unit's need on that path; same-index units that write to
-- both paths on the same device contribute the sum of their path needs as one unit.
combineSameDeviceNeeds :: [Integer] -> [Integer] -> [Integer]
combineSameDeviceNeeds as bs =
  case (as, bs) of
    ([], ys) -> ys
    (xs, []) -> xs
    _ ->
      -- Pairwise max-length zip: unit i contributes a_i + b_i when both present.
      let len = max (length as) (length bs)
          aPad = as ++ replicate (len - length as) 0
          bPad = bs ++ replicate (len - length bs) 0
       in zipWith (+) aPad bPad

------------------------------------------------------------------------
-- Manifest DIST parse
------------------------------------------------------------------------

data ManifestDistEntry = ManifestDistEntry
  { mdeName :: Text,
    mdeSize :: Integer
  }
  deriving (Eq, Show)

-- | Parse @DIST \<name\> \<size\> …@ lines from Manifest content.
parseManifestDistEntries :: Text -> [ManifestDistEntry]
parseManifestDistEntries content =
  mapMaybe parseLine (T.lines content)
  where
    parseLine ln =
      case T.words ln of
        ("DIST" : name : sizeTxt : _)
          | Just sz <- readInteger sizeTxt,
            sz >= 0 ->
              Just ManifestDistEntry {mdeName = name, mdeSize = sz}
        _ -> Nothing

readInteger :: Text -> Maybe Integer
readInteger t =
  case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

-- | Largest DIST size whose basename contains @suffix@ (e.g. @-vendor.tar.xz@).
lookupManifestBaselineBySuffix :: Text -> Text -> Maybe Integer
lookupManifestBaselineBySuffix content suffix =
  let matching =
        [ mdeSize e
        | e <- parseManifestDistEntries content,
          suffix `T.isInfixOf` mdeName e,
          mdeSize e > 0
        ]
   in case matching of
        [] -> Nothing
        xs -> Just (maximum xs)

lookupManifestBaselineForClass :: Text -> MaterializeClass -> Maybe Integer
lookupManifestBaselineForClass content cls =
  case cls of
    FullGo -> lookupManifestBaselineBySuffix content "-vendor.tar.xz"
    FullCargo -> lookupManifestBaselineBySuffix content "-crates.tar.xz"
    FullNpmBun -> lookupManifestBaselineBySuffix content "-deps.tar.xz"
    FullSbcl -> lookupManifestBaselineBySuffix content "-deps.tar.xz"
    ReusePath ->
      firstJust
        [ lookupManifestBaselineBySuffix content "-vendor.tar.xz",
          lookupManifestBaselineBySuffix content "-deps.tar.xz",
          lookupManifestBaselineBySuffix content "-crates.tar.xz"
        ]
    GitMvFetch ->
      case [mdeSize e | e <- parseManifestDistEntries content, mdeSize e > 0] of
        [] -> Nothing
        xs -> Just (maximum xs)

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just x : _) = Just x
firstJust (Nothing : xs) = firstJust xs

------------------------------------------------------------------------
-- Roots + free space (production + injectable)
------------------------------------------------------------------------

-- | Effective temp root: usable @TMPDIR@, else process temporary directory.
resolveTempRoot :: IO FilePath
resolveTempRoot = do
  mTmp <- lookupEnv "TMPDIR"
  case mTmp of
    Just p | not (null p) -> do
      ok <- doesDirectoryExist p
      if ok then pure p else getTemporaryDirectory
    _ -> getTemporaryDirectory

-- | Free bytes available to non-root on the filesystem backing @path@.
getFreeBytes :: FilePath -> IO (Either Text Integer)
getFreeBytes path = do
  result <- try @IOError $ getFreeBytesStatvfs path
  pure $ case result of
    Left e ->
      Left $
        "failed to measure free space for "
          <> T.pack path
          <> ": "
          <> T.pack (show e)
    Right n -> Right n

-- | Linux glibc @struct statvfs@ is 112 bytes on x86_64; we only read
-- @f_frsize@ (offset 8) and @f_bavail@ (offset 32).
statvfsBufSize :: Int
statvfsBufSize = 112

getFreeBytesStatvfs :: FilePath -> IO Integer
getFreeBytesStatvfs path =
  withCString path $ \cpath ->
    allocaBytes statvfsBufSize $ \pst -> do
      rc <- c_statvfs cpath pst
      if rc /= 0
        then ioError (userError ("statvfs failed for " <> path))
        else do
          frsize <- peekByteOff pst 8 :: IO CULong
          bavail <- peekByteOff pst 32 :: IO CULong
          pure (toInteger bavail * toInteger frsize)

foreign import ccall unsafe "statvfs"
  c_statvfs :: CString -> Ptr () -> IO CInt

-- | Filesystem device id for same-device merge (via @stat@).
getDeviceId :: FilePath -> IO (Either Text DeviceID)
getDeviceId path = do
  result <- try @IOError $ deviceID <$> getFileStatus path
  pure $ case result of
    Left e ->
      Left $
        "failed to resolve device for "
          <> T.pack path
          <> ": "
          <> T.pack (show e)
    Right d -> Right d

-- | Best-effort sum of regular file sizes under a directory (symlink-safe skip).
directoryTreeBytes :: FilePath -> IO (Either Text Integer)
directoryTreeBytes root = do
  result <- try @IOError $ go root
  pure $ case result of
    Left e ->
      Left $
        "failed to measure directory size for "
          <> T.pack root
          <> ": "
          <> T.pack (show e)
    Right n -> Right n
  where
    go dir = do
      names <- listDirectory dir
      foldl' (\acc n -> (+) <$> acc <*> entry (dir </> n)) (pure 0) names
    entry p = do
      st <- getFileStatus p
      if isSymbolicLink st
        then pure 0
        else
          if isDirectory st
            then go p
            else
              if isRegularFile st
                then pure (fromIntegral (fileSize st) :: Integer)
                else pure 0

------------------------------------------------------------------------
-- Unit plans
------------------------------------------------------------------------

data FsRole
  = RoleTemp
  | RoleManagerDist
  deriving (Eq, Show)

-- | Per-package concurrent unit (multi-PV sequential → one unit at peak).
data UnitDiskPlan = UnitDiskPlan
  { udpKey :: PackageKey,
    udpClass :: MaterializeClass,
    -- | Peak temp reservation for this unit (0 if none).
    udpTempNeed :: Integer,
    -- | Peak manager DISTDIR reservation (0 if present / none).
    udpDistNeed :: Integer
  }
  deriving (Eq, Show)

-- | Injectable free-space / device probes for tests.
data DiskSpaceProbe = DiskSpaceProbe
  { dspFreeBytes :: FilePath -> IO (Either Text Integer),
    dspDeviceId :: FilePath -> IO (Either Text Integer)
  }

productionDiskSpaceProbe :: DiskSpaceProbe
productionDiskSpaceProbe =
  DiskSpaceProbe
    { dspFreeBytes = getFreeBytes,
      dspDeviceId = fmap (fmap fromIntegral) . getDeviceId
    }

-- | Already-present distfile under manager path contributes 0 need.
presentDistfileNeed ::
  (FilePath -> IO Bool) ->
  FilePath ->
  FilePath ->
  Integer ->
  IO Integer
presentDistfileNeed fileExists distDir basename compressedSize = do
  exists <- fileExists (distDir </> basename)
  pure $
    if exists
      then 0
      else estimateNeedBytes GitMvFetch (Just compressedSize)

-- | Best-effort Manifest read under a package directory.
readManifestMaybe :: FilePath -> IO (Maybe Text)
readManifestMaybe dir = do
  let man = dir </> "Manifest"
  exists <- doesFileExist man
  if not exists
    then pure Nothing
    else do
      result <- try @IOError (TIO.readFile man)
      pure $ case result of
        Left _ -> Nothing
        Right t -> Just t

------------------------------------------------------------------------
-- Feasibility evaluation
------------------------------------------------------------------------

newtype DiskGateOk = DiskGateOk
  { dgoWarnings :: [Text]
  }
  deriving (Eq, Show)

-- | Pure-ish evaluation given free maps and unit plans.
evaluateDiskFeasibility ::
  Int ->
  FilePath ->
  Integer ->
  Integer ->
  FilePath ->
  Integer ->
  Integer ->
  -- | temp and manager on same device
  Bool ->
  -- | optional Portage path + free (warn only when distinct)
  Maybe (FilePath, Integer) ->
  [UnitDiskPlan] ->
  Either Text DiskGateOk
evaluateDiskFeasibility
  jobs
  tempRoot
  tempFree
  tempDev
  distPath
  distFree
  distDev
  sameDevice
  mPortage
  units =
    let tempNeeds = map udpTempNeed units
        distNeeds = map udpDistNeed units
        warnings = portageWarnings mPortage distPath
     in if sameDevice || tempDev == distDev
          then
            let combined = combineSameDeviceNeeds tempNeeds distNeeds
                free = min tempFree distFree
                pathLabel =
                  T.pack tempRoot
                    <> " + manager distfiles "
                    <> T.pack distPath
                    <> " (same device)"
             in checkOne jobs pathLabel free combined warnings
          else case checkOne jobs ("temp root " <> T.pack tempRoot) tempFree tempNeeds warnings of
            Left err -> Left err
            Right (DiskGateOk w1) ->
              case checkOne
                jobs
                ("manager distfiles " <> T.pack distPath)
                distFree
                distNeeds
                w1 of
                Left err -> Left err
                Right ok -> Right ok

checkOne :: Int -> Text -> Integer -> [Integer] -> [Text] -> Either Text DiskGateOk
checkOne jobs label free needs warnings =
  let mx = maxNeed needs
      conc = concurrentSumNeed jobs needs
   in if mx <= 0 && conc <= 0
        then Right (DiskGateOk warnings)
        else
          if free < mx
            then
              Left $
                insufficientMsg
                  jobs
                  label
                  free
                  mx
                  "max unit need"
            else
              if free < conc
                then
                  Left $
                    insufficientMsg
                      jobs
                      label
                      free
                      conc
                      "concurrent sum"
                else Right (DiskGateOk warnings)

portageWarnings :: Maybe (FilePath, Integer) -> FilePath -> [Text]
portageWarnings Nothing _ = []
portageWarnings (Just (pPath, pFree)) managerPath
  | pPath == managerPath = []
  | pFree < portageWarnFreeThreshold =
      [ "Portage DISTDIR free space is low ("
          <> formatBytesHuman pFree
          <> " free at "
          <> T.pack pPath
          <> "); manager distfiles path is separate — continuing (warn only)"
      ]
  | otherwise = []

insufficientMsg :: Int -> Text -> Integer -> Integer -> Text -> Text
insufficientMsg jobs label free need reason =
  "insufficient free space for update under --jobs "
    <> T.pack (show jobs)
    <> ":\n  "
    <> label
    <> "  free: "
    <> formatBytesHuman free
    <> "  need: "
    <> formatBytesHuman need
    <> " ("
    <> reason
    <> ")\n  hint: free space, or TMPDIR=$HOME/local/tmp, or lower --jobs"

formatBytesHuman :: Integer -> Text
formatBytesHuman n
  | n < 0 = "-" <> formatBytesHuman (-n)
  | n >= giB =
      let (q, r) = n `divMod` giB
          tenths = (r * 10) `div` giB
       in T.pack (show q)
            <> if tenths == 0
              then "G"
              else "." <> T.pack (show tenths) <> "G"
  | n >= 1024 * 1024 =
      T.pack (show (n `div` (1024 * 1024))) <> "M"
  | n >= 1024 =
      T.pack (show (n `div` 1024)) <> "K"
  | otherwise = T.pack (show n) <> "B"

-- | Measure free space and evaluate the command-level gate.
runDiskSpaceGate ::
  DiskSpaceProbe ->
  Int ->
  FilePath ->
  FilePath ->
  Maybe FilePath ->
  [UnitDiskPlan] ->
  IO (Either Text DiskGateOk)
runDiskSpaceGate probe jobs tempRoot distPath mPortage units = do
  if null units
    then pure (Right (DiskGateOk []))
    else do
      eTempFree <- dspFreeBytes probe tempRoot
      eDistFree <- dspFreeBytes probe distPath
      eTempDev <- dspDeviceId probe tempRoot
      eDistDev <- dspDeviceId probe distPath
      mPortageFree <- case mPortage of
        Nothing -> pure Nothing
        Just pp -> do
          ef <- dspFreeBytes probe pp
          pure $ case ef of
            Right f -> Just (pp, f)
            Left _ -> Nothing
      pure $ do
        tempFree <- eTempFree
        distFree <- eDistFree
        tempDev <- eTempDev
        distDev <- eDistDev
        evaluateDiskFeasibility
          jobs
          tempRoot
          tempFree
          tempDev
          distPath
          distFree
          distDev
          (tempDev == distDev)
          mPortageFree
          units

------------------------------------------------------------------------
-- Unit-level rechecks
------------------------------------------------------------------------

-- | At full-path admit: re-measure temp free space vs this unit's need.
checkTempNeedAtAdmit ::
  (FilePath -> IO (Either Text Integer)) ->
  FilePath ->
  Integer ->
  IO (Either Text ())
checkTempNeedAtAdmit freeBytes tempRoot need =
  if need <= 0
    then pure (Right ())
    else do
      ef <- freeBytes tempRoot
      pure $ case ef of
        Left err -> Left err
        Right free ->
          if free < need
            then
              Left $
                "insufficient free space at full-path admit for temp root "
                  <> T.pack tempRoot
                  <> ": free "
                  <> formatBytesHuman free
                  <> ", need "
                  <> formatBytesHuman need
                  <> " (hint: free space or TMPDIR on roomier storage)"
            else Right ()

-- | Conservative remaining-phase estimate after clone (download/pack peak).
postCloneRemainingEstimate :: MaterializeClass -> Integer
postCloneRemainingEstimate cls =
  -- Remaining work is roughly on the order of the ecosystem floor body
  -- (not including the command-level margin, which is reapplied here once).
  floorFor cls + safetyMarginBytes

-- | Production helper: resolve temp root and recheck after clone for @cls@.
checkPostCloneForClass :: MaterializeClass -> FilePath -> IO (Either Text ())
checkPostCloneForClass cls workTree = do
  tempRoot <- resolveTempRoot
  checkPostCloneSpace
    getFreeBytes
    tempRoot
    workTree
    (postCloneRemainingEstimate cls)

-- | After clone: when tree size is known, fail if measured + remaining > free.
checkPostCloneSpace ::
  (FilePath -> IO (Either Text Integer)) ->
  FilePath ->
  FilePath ->
  -- | remaining phase estimate (bytes)
  Integer ->
  IO (Either Text ())
checkPostCloneSpace freeBytes tempRoot workTree remainingEstimate = do
  mMeasured <- directoryTreeBytes workTree
  case mMeasured of
    Left _ ->
      -- Measurement unavailable: skip cleanly (command gate + admit still apply).
      pure (Right ())
    Right measured -> do
      ef <- freeBytes tempRoot
      pure $ case ef of
        Left _ -> Right ()
        Right free ->
          let need = measured + remainingEstimate
           in if free < need
                then
                  Left $
                    "work tree after clone exceeds free temp space: measured "
                      <> formatBytesHuman measured
                      <> " + remaining "
                      <> formatBytesHuman remainingEstimate
                      <> " > free "
                      <> formatBytesHuman free
                      <> " under "
                      <> T.pack tempRoot
                else Right ()
