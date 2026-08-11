{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | On-disk check cache for successful outdated/plan network results.
--
-- Layout: @${XDG_CACHE_HOME}/mndz/overlay-manager/check-cache/<friendly>-<hash12>.json@
-- (or @~/.cache/...@). Exclusive flock on a sibling @.lock@ file; atomic
-- write via temp + rename. Schema @version: 1@.
module Update.CheckCache
  ( -- * Path helpers
    defaultCheckCacheDirFromEnv,
    defaultCheckCacheDir,
    friendlyOverlayName,
    overlayPathHash12,
    checkCacheFileName,
    checkCacheFilePath,

    -- * Source id + fingerprint
    updateSourceId,
    CacheFingerprint (..),
    computeFingerprint,
    computeFingerprintFromDir,

    -- * Document / entries
    CachePayload (..),
    CacheEntry (..),
    CheckCacheDoc (..),
    encodeCheckCacheDoc,
    decodeCheckCacheDoc,

    -- * Handle
    CheckCacheHandle,
    openCheckCache,
    openCheckCacheAt,
    lookupLatest,
    lookupDeps,
    storeLatest,
    storeDeps,
    recordHit,
    recordFetch,
    flushCheckCache,
    cacheSummaryLine,
    cacheStats,
    CacheStats (..),
  )
where

import Config.Types (CheckCacheTtl (..))
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (bracket, try)
import Crypto.Hash (Digest, SHA256 (..), hash, hashFinalize, hashInit, hashUpdate)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Types (Ebuild (..))
import Overlay.Version
  ( EbuildVersion,
    parseEbuildVersion,
    renderPV,
  )
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getHomeDirectory,
    listDirectory,
    makeAbsolute,
    renameFile,
  )
import System.Environment (lookupEnv)
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.Posix.IO
  ( LockRequest (WriteLock),
    OpenFileFlags (..),
    OpenMode (ReadWrite),
    closeFd,
    defaultFileFlags,
    openFd,
    waitToSetLock,
  )
import System.Posix.Types (Fd)
import Update.Go.Lanes
  ( LaneId (..),
    LaneTarget (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
  )
import Update.Go.Plan (isLivePackageVersion)
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Types
  ( PackageKey (..),
    UpdateSource (..),
    packageKeyText,
  )

------------------------------------------------------------------------
-- Path helpers
------------------------------------------------------------------------

-- | Pure XDG check-cache directory from env values.
defaultCheckCacheDirFromEnv :: Maybe FilePath -> FilePath -> FilePath
defaultCheckCacheDirFromEnv mXdgCache home =
  case mXdgCache of
    Just dir
      | not (null dir) ->
          dir </> "mndz" </> "overlay-manager" </> "check-cache"
    _ ->
      home </> ".cache" </> "mndz" </> "overlay-manager" </> "check-cache"

defaultCheckCacheDir :: IO FilePath
defaultCheckCacheDir = do
  xdg <- lookupEnv "XDG_CACHE_HOME"
  defaultCheckCacheDirFromEnv xdg <$> getHomeDirectory

-- | Sanitize basename of absolute overlay path for the friendly filename prefix.
friendlyOverlayName :: FilePath -> Text
friendlyOverlayName absPath =
  let base = T.pack (takeBaseName absPath)
      mapped =
        T.pack $
          map
            ( \c ->
                if c `elem` (['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ "._-")
                  then c
                  else '-'
            )
            (T.unpack base)
      collapsed = T.intercalate "-" . filter (not . T.null) $ T.splitOn "-" mapped
      trimmed = T.dropWhile (== '-') . T.dropWhileEnd (== '-') $ collapsed
      capped =
        if T.length trimmed > 64
          then T.take 64 trimmed
          else trimmed
   in if T.null capped then "overlay" else capped

-- | First 12 lowercase hex chars of SHA-256 of the absolute overlay path.
overlayPathHash12 :: FilePath -> Text
overlayPathHash12 absPath =
  T.take 12 $ sha256HexText (T.pack absPath)

checkCacheFileName :: FilePath -> FilePath
checkCacheFileName absPath =
  T.unpack (friendlyOverlayName absPath)
    <> "-"
    <> T.unpack (overlayPathHash12 absPath)
    <> ".json"

checkCacheFilePath :: FilePath -> FilePath -> FilePath
checkCacheFilePath cacheDir absOverlay =
  cacheDir </> checkCacheFileName absOverlay

sha256HexText :: Text -> Text
sha256HexText t =
  T.toLower . decodeUtf8 $
    convertToBase Base16 (hash (encodeUtf8 t) :: Digest SHA256)

------------------------------------------------------------------------
-- Source id + fingerprint
------------------------------------------------------------------------

-- | Stable update-source identifier for fingerprinting.
updateSourceId :: UpdateSource -> Text
updateSourceId = \case
  GitHub owner repo _prefix -> "github:" <> owner <> "/" <> repo
  Npm pkg -> "npm:" <> pkg
  Http primary _fb -> "http:" <> primary

data CacheFingerprint = CacheFingerprint
  { cfLocalPvs :: [Text],
    cfSourceId :: Text,
    cfContentHash :: Text
  }
  deriving (Eq, Show)

instance ToJSON CacheFingerprint where
  toJSON fp =
    object
      [ "local_pvs" .= cfLocalPvs fp,
        "source_id" .= cfSourceId fp,
        "content_hash" .= cfContentHash fp
      ]

instance FromJSON CacheFingerprint where
  parseJSON = withObject "CacheFingerprint" $ \o ->
    CacheFingerprint
      <$> o .: "local_pvs"
      <*> o .: "source_id"
      <*> o .: "content_hash"

-- | Fingerprint from discovered ebuild records for a package.
computeFingerprint :: UpdateSource -> [Ebuild] -> IO CacheFingerprint
computeFingerprint src ebuilds = do
  let nonLive =
        [ e
        | e <- ebuilds,
          not (isLivePackageVersion (parseEbuildVersion (ebuildVersion e)))
        ]
      pvs =
        sort
          [ renderPV (parseEbuildVersion (ebuildVersion e))
          | e <- nonLive
          ]
      paths = sort (map ebuildPath nonLive)
  ebuildBodies <- mapM readFileBytesStrict paths
  let pkgDir =
        case ebuilds of
          (e : _) -> takeDirectory (ebuildPath e)
          [] -> "."
      manPath = pkgDir </> "Manifest"
  manBody <- do
    exists <- doesFileExist manPath
    if exists then Just <$> BS.readFile manPath else pure Nothing
  pure
    CacheFingerprint
      { cfLocalPvs = pvs,
        cfSourceId = updateSourceId src,
        cfContentHash = hashPackageContents ebuildBodies manBody
      }

-- | Fingerprint by scanning a package directory for non-live ebuilds + Manifest.
computeFingerprintFromDir :: UpdateSource -> FilePath -> Text -> IO CacheFingerprint
computeFingerprintFromDir src pkgDir pn = do
  names <- listDirectory pkgDir
  let ebuildNames =
        sort
          [ name
          | name <- names,
            Just (pkg, verStr) <- [parseEbuildFileName name],
            T.pack pkg == pn,
            let v = parseEbuildVersion (T.pack verStr),
            not (isLivePackageVersion v)
          ]
      pvs =
        [ renderPV (parseEbuildVersion (T.pack verStr))
        | name <- ebuildNames,
          Just (_pkg, verStr) <- [parseEbuildFileName name]
        ]
  ebuildBodies <- mapM (\n -> readFileBytesStrict (pkgDir </> n)) ebuildNames
  manBody <- do
    let manPath = pkgDir </> "Manifest"
    exists <- doesFileExist manPath
    if exists then Just <$> readFileBytesStrict manPath else pure Nothing
  pure
    CacheFingerprint
      { cfLocalPvs = pvs,
        cfSourceId = updateSourceId src,
        cfContentHash = hashPackageContents ebuildBodies manBody
      }

readFileBytesStrict :: FilePath -> IO BS.ByteString
readFileBytesStrict path = do
  exists <- doesFileExist path
  if exists then BS.readFile path else pure BS.empty

hashPackageContents :: [BS.ByteString] -> Maybe BS.ByteString -> Text
hashPackageContents ebuildBodies mMan =
  let ctx0 = hashInit @SHA256
      ctx1 = foldl' hashUpdate ctx0 ebuildBodies
      ctx2 = case mMan of
        Nothing -> ctx1
        Just man -> hashUpdate ctx1 man
   in T.toLower . decodeUtf8 $
        convertToBase Base16 (hashFinalize ctx2)

------------------------------------------------------------------------
-- Document / entries (JSON schema version 1)
------------------------------------------------------------------------

data CachePayload
  = LatestPayload {cpRemotePv :: Text}
  | DepsPayload {cpPlan :: RuntimeLanePlan}
  deriving (Eq, Show)

data CacheEntry = CacheEntry
  { ceCheckedAt :: UTCTime,
    ceFingerprint :: CacheFingerprint,
    cePayload :: CachePayload
  }
  deriving (Eq, Show)

data CheckCacheDoc = CheckCacheDoc
  { ccdVersion :: Int,
    ccdOverlay :: FilePath,
    ccdPackages :: Map Text CacheEntry
  }
  deriving (Eq, Show)

instance ToJSON CacheEntry where
  toJSON e =
    case cePayload e of
      LatestPayload remote ->
        object
          [ "checked_at" .= iso8601Show (ceCheckedAt e),
            "fingerprint" .= ceFingerprint e,
            "kind" .= ("latest" :: Text),
            "remote_pv" .= remote
          ]
      DepsPayload plan ->
        object
          [ "checked_at" .= iso8601Show (ceCheckedAt e),
            "fingerprint" .= ceFingerprint e,
            "kind" .= ("deps" :: Text),
            "plan" .= planToJSON plan
          ]

instance FromJSON CacheEntry where
  parseJSON = withObject "CacheEntry" $ \o -> do
    checkedAtTxt <- o .: "checked_at"
    checkedAt <-
      case iso8601ParseM checkedAtTxt of
        Just t -> pure t
        Nothing -> fail $ "invalid checked_at: " <> checkedAtTxt
    fp <- o .: "fingerprint"
    kind <- o .: "kind" :: Parser Text
    payload <- case kind of
      "latest" -> LatestPayload <$> o .: "remote_pv"
      "deps" -> do
        planVal <- o .: "plan"
        case parseEither planFromJSON planVal of
          Left err -> fail err
          Right plan -> pure (DepsPayload plan)
      other -> fail $ "unknown cache entry kind: " <> T.unpack other
    pure
      CacheEntry
        { ceCheckedAt = checkedAt,
          ceFingerprint = fp,
          cePayload = payload
        }

instance ToJSON CheckCacheDoc where
  toJSON doc =
    object
      [ "version" .= ccdVersion doc,
        "overlay" .= ccdOverlay doc,
        "packages" .= ccdPackages doc
      ]

instance FromJSON CheckCacheDoc where
  parseJSON = withObject "CheckCacheDoc" $ \o -> do
    ver <- o .: "version" :: Parser Int
    overlay <- o .: "overlay"
    pkgs <- o .:? "packages" .!= Map.empty
    pure
      CheckCacheDoc
        { ccdVersion = ver,
          ccdOverlay = overlay,
          ccdPackages = pkgs
        }

encodeCheckCacheDoc :: CheckCacheDoc -> LBS.ByteString
encodeCheckCacheDoc = encode

decodeCheckCacheDoc :: BS.ByteString -> Either String CheckCacheDoc
decodeCheckCacheDoc bs = do
  doc <- eitherDecodeStrict' bs
  if ccdVersion doc /= 1
    then Left $ "unsupported check-cache version: " <> show (ccdVersion doc)
    else Right doc

------------------------------------------------------------------------
-- RuntimeLanePlan JSON (schema-local, not a public API)
------------------------------------------------------------------------

planToJSON :: RuntimeLanePlan -> Value
planToJSON plan =
  object
    [ "lanes" .= map laneTargetToJSON (glpLanes plan),
      "ebuilds" .= map plannedEbuildToJSON (glpEbuilds plan),
      "unique_pvs" .= map renderPV (glpUniquePVs plan),
      "runtime_atom" .= glpRuntimeAtom plan
    ]

planFromJSON :: Value -> Parser RuntimeLanePlan
planFromJSON = withObject "RuntimeLanePlan" $ \o -> do
  lanes <- o .: "lanes" >>= mapM laneTargetFromJSON
  ebuilds <- o .: "ebuilds" >>= mapM plannedEbuildFromJSON
  uniqueTxt <- o .: "unique_pvs" :: Parser [Text]
  atom <- o .: "runtime_atom"
  pure
    RuntimeLanePlan
      { glpLanes = lanes,
        glpEbuilds = ebuilds,
        glpUniquePVs = map parseEbuildVersion uniqueTxt,
        glpRuntimeAtom = atom
      }

laneTargetToJSON :: LaneTarget -> Value
laneTargetToJSON lt =
  object
    [ "lane" .= laneIdToJSON (ltLane lt),
      "ceiling" .= fmap renderPV (ltCeiling lt),
      "package_pv" .= fmap renderPV (ltPackagePV lt),
      "go_req" .= ltGoReq lt
    ]

laneTargetFromJSON :: Value -> Parser LaneTarget
laneTargetFromJSON = withObject "LaneTarget" $ \o -> do
  lane <- o .: "lane" >>= laneIdFromJSON
  mCeil <- o .:? "ceiling"
  mPkg <- o .:? "package_pv"
  goReq <- o .:? "go_req"
  pure
    LaneTarget
      { ltLane = lane,
        ltCeiling = parseEbuildVersion <$> mCeil,
        ltPackagePV = parseEbuildVersion <$> mPkg,
        ltGoReq = goReq
      }

plannedEbuildToJSON :: PlannedEbuild -> Value
plannedEbuildToJSON pe =
  object
    [ "pv" .= renderPV (pePV pe),
      "keywords" .= peKeywords pe,
      "lanes" .= map laneIdToJSON (peLanes pe)
    ]

plannedEbuildFromJSON :: Value -> Parser PlannedEbuild
plannedEbuildFromJSON = withObject "PlannedEbuild" $ \o -> do
  pvTxt <- o .: "pv"
  kws <- o .: "keywords"
  lanes <- o .: "lanes" >>= mapM laneIdFromJSON
  pure
    PlannedEbuild
      { pePV = parseEbuildVersion pvTxt,
        peKeywords = kws,
        peLanes = lanes
      }

laneIdToJSON :: LaneId -> Value
laneIdToJSON (LaneId arch tier) =
  object
    [ "arch" .= arch,
      "tier" .= tierToText tier
    ]

laneIdFromJSON :: Value -> Parser LaneId
laneIdFromJSON = withObject "LaneId" $ \o -> do
  arch <- o .: "arch"
  tierTxt <- o .: "tier"
  tier <- tierFromText tierTxt
  pure (LaneId arch tier)

tierToText :: KeywordTier -> Text
tierToText Plain = "plain"
tierToText Tilde = "tilde"

tierFromText :: Text -> Parser KeywordTier
tierFromText "plain" = pure Plain
tierFromText "tilde" = pure Tilde
tierFromText t = fail $ "unknown keyword tier: " <> T.unpack t

------------------------------------------------------------------------
-- Handle
------------------------------------------------------------------------

data CacheStats = CacheStats
  { csHits :: !Int,
    csFetches :: !Int
  }
  deriving (Eq, Show)

data HandleState = HandleState
  { hsPackages :: !(Map Text CacheEntry),
    -- | Keys written or rewritten this run (for merge on flush).
    hsTouched :: !(Map Text CacheEntry),
    hsHits :: !Int,
    hsFetches :: !Int,
    hsDirty :: !Bool
  }

data CheckCacheHandle = CheckCacheHandle
  { cchTtl :: CheckCacheTtl,
    cchRefresh :: Bool,
    cchEnabled :: Bool,
    cchPath :: FilePath,
    cchOverlayAbs :: FilePath,
    cchClock :: IO UTCTime,
    cchState :: MVar HandleState
  }

emptyState :: HandleState
emptyState =
  HandleState
    { hsPackages = Map.empty,
      hsTouched = Map.empty,
      hsHits = 0,
      hsFetches = 0,
      hsDirty = False
    }

-- | Open cache for an overlay; returns handle and optional load warning.
openCheckCache ::
  CheckCacheTtl ->
  Bool ->
  FilePath ->
  IO (CheckCacheHandle, Maybe Text)
openCheckCache = openCheckCacheAt getCurrentTime Nothing

-- | Full open: injectable clock and optional cache directory override (tests).
openCheckCacheAt ::
  IO UTCTime ->
  Maybe FilePath ->
  CheckCacheTtl ->
  Bool ->
  FilePath ->
  IO (CheckCacheHandle, Maybe Text)
openCheckCacheAt clock mCacheDir ttl refresh overlayPath = do
  absOverlay <- makeAbsolute overlayPath
  case ttl of
    CacheDisabled -> do
      st <- newMVar emptyState
      pure
        ( CheckCacheHandle
            { cchTtl = CacheDisabled,
              cchRefresh = refresh,
              cchEnabled = False,
              cchPath = "",
              cchOverlayAbs = absOverlay,
              cchClock = clock,
              cchState = st
            },
          Nothing
        )
    CacheTtl _ -> do
      cacheDir <- maybe defaultCheckCacheDir pure mCacheDir
      createDirectoryIfMissing True cacheDir
      let path = checkCacheFilePath cacheDir absOverlay
      (pkgs, warn) <- loadPackagesSoft path
      st <-
        newMVar
          emptyState
            { hsPackages = pkgs
            }
      pure
        ( CheckCacheHandle
            { cchTtl = ttl,
              cchRefresh = refresh,
              cchEnabled = True,
              cchPath = path,
              cchOverlayAbs = absOverlay,
              cchClock = clock,
              cchState = st
            },
          warn
        )

loadPackagesSoft :: FilePath -> IO (Map Text CacheEntry, Maybe Text)
loadPackagesSoft path = do
  exists <- doesFileExist path
  if not exists
    then pure (Map.empty, Nothing)
    else do
      result <- try @IOError (BS.readFile path)
      case result of
        Left e ->
          pure
            ( Map.empty,
              Just $
                "check cache unreadable ("
                  <> T.pack path
                  <> "): "
                  <> T.pack (show e)
                  <> "; treating as empty"
            )
        Right bs ->
          case decodeCheckCacheDoc bs of
            Left err ->
              pure
                ( Map.empty,
                  Just $
                    "check cache corrupt or unknown version ("
                      <> T.pack path
                      <> "): "
                      <> T.pack err
                      <> "; treating as empty"
                )
            Right doc -> pure (ccdPackages doc, Nothing)

entryValid ::
  CheckCacheTtl ->
  Bool ->
  UTCTime ->
  CacheFingerprint ->
  CacheEntry ->
  Bool
entryValid ttl refresh now wantFp entry
  | refresh = False
  | ceFingerprint entry /= wantFp = False
  | otherwise =
      case ttl of
        CacheDisabled -> False
        CacheTtl maxAge ->
          let age = diffUTCTime now (ceCheckedAt entry)
           in age >= 0 && age <= maxAge

lookupLatest ::
  CheckCacheHandle ->
  PackageKey ->
  CacheFingerprint ->
  IO (Maybe EbuildVersion)
lookupLatest h key fp = do
  if not (cchEnabled h) || cchRefresh h
    then pure Nothing
    else do
      now <- cchClock h
      st <- readMVar (cchState h)
      pure $ case Map.lookup (packageKeyText key) (hsPackages st) of
        Just e
          | entryValid (cchTtl h) False now fp e,
            LatestPayload remote <- cePayload e ->
              Just (parseEbuildVersion remote)
        _ -> Nothing

lookupDeps ::
  CheckCacheHandle ->
  PackageKey ->
  CacheFingerprint ->
  IO (Maybe RuntimeLanePlan)
lookupDeps h key fp = do
  if not (cchEnabled h) || cchRefresh h
    then pure Nothing
    else do
      now <- cchClock h
      st <- readMVar (cchState h)
      pure $ case Map.lookup (packageKeyText key) (hsPackages st) of
        Just e
          | entryValid (cchTtl h) False now fp e,
            DepsPayload plan <- cePayload e ->
              Just plan
        _ -> Nothing

bumpHit :: CheckCacheHandle -> IO ()
bumpHit h =
  modifyMVar_ (cchState h) $ \st ->
    pure st {hsHits = hsHits st + 1}

bumpFetch :: CheckCacheHandle -> IO ()
bumpFetch h =
  modifyMVar_ (cchState h) $ \st ->
    pure st {hsFetches = hsFetches st + 1}

-- | Record a cache hit (valid entry used). Call after successful 'lookup*'.
recordHit :: CheckCacheHandle -> IO ()
recordHit = bumpHit

-- | Record a live fetch/plan (miss, refresh, or disabled path that still did work).
recordFetch :: CheckCacheHandle -> IO ()
recordFetch = bumpFetch

storeLatest ::
  CheckCacheHandle ->
  PackageKey ->
  CacheFingerprint ->
  EbuildVersion ->
  IO ()
storeLatest h key fp remote =
  storeEntry h key fp (LatestPayload (renderPV remote))

storeDeps ::
  CheckCacheHandle ->
  PackageKey ->
  CacheFingerprint ->
  RuntimeLanePlan ->
  IO ()
storeDeps h key fp plan =
  storeEntry h key fp (DepsPayload plan)

storeEntry ::
  CheckCacheHandle ->
  PackageKey ->
  CacheFingerprint ->
  CachePayload ->
  IO ()
storeEntry h key fp payload
  | not (cchEnabled h) = pure ()
  | otherwise = do
      now <- cchClock h
      let k = packageKeyText key
          entry =
            CacheEntry
              { ceCheckedAt = now,
                ceFingerprint = fp,
                cePayload = payload
              }
      modifyMVar_ (cchState h) $ \st ->
        pure
          st
            { hsPackages = Map.insert k entry (hsPackages st),
              hsTouched = Map.insert k entry (hsTouched st),
              hsDirty = True
            }

-- | Flush dirty entries under exclusive lock with atomic rename.
flushCheckCache :: CheckCacheHandle -> IO ()
flushCheckCache h
  | not (cchEnabled h) = pure ()
  | otherwise = do
      st <- readMVar (cchState h)
      if not (hsDirty st) || Map.null (hsTouched st)
        then pure ()
        else withExclusiveLock (cchPath h <> ".lock") $ do
          (diskPkgs, _) <- loadPackagesSoft (cchPath h)
          st' <- readMVar (cchState h)
          let merged = Map.union (hsTouched st') diskPkgs
              doc =
                CheckCacheDoc
                  { ccdVersion = 1,
                    ccdOverlay = cchOverlayAbs h,
                    ccdPackages = merged
                  }
          atomicWriteDoc (cchPath h) doc
          modifyMVar_ (cchState h) $ \s ->
            pure
              s
                { hsPackages = merged,
                  hsTouched = Map.empty,
                  hsDirty = False
                }

atomicWriteDoc :: FilePath -> CheckCacheDoc -> IO ()
atomicWriteDoc path doc = do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
      body = LBS.toStrict (encodeCheckCacheDoc doc)
  BS.writeFile tmp body
  renameFile tmp path

withExclusiveLock :: FilePath -> IO a -> IO a
withExclusiveLock lockPath action = do
  createDirectoryIfMissing True (takeDirectory lockPath)
  bracket acquire release (const action)
  where
    acquire :: IO Fd
    acquire = do
      fd <-
        openFd
          lockPath
          ReadWrite
          defaultFileFlags {creat = Just 0o600}
      waitToSetLock fd (WriteLock, AbsoluteSeek, 0, 0)
      pure fd
    release :: Fd -> IO ()
    release = closeFd

cacheStats :: CheckCacheHandle -> IO CacheStats
cacheStats h = do
  st <- readMVar (cchState h)
  pure CacheStats {csHits = hsHits st, csFetches = hsFetches st}

-- | Info summary line: @check cache: N hit, M fetch@.
cacheSummaryLine :: CheckCacheHandle -> IO (Maybe Text)
cacheSummaryLine h
  | not (cchEnabled h) && not (cchRefresh h) = pure Nothing
  | otherwise = do
      st <- cacheStats h
      pure $
        Just $
          "check cache: "
            <> T.pack (show (csHits st))
            <> " hit, "
            <> T.pack (show (csFetches st))
            <> " fetch"
