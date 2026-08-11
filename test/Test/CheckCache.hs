{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for check-cache path naming, JSON round-trip, TTL, fingerprint,
-- disable, and atomic replace.
module Test.CheckCache (tests) where

import Config.Types (CheckCacheTtl (..))
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Overlay.Version (parseEbuildVersion)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    makeAbsolute,
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.CheckCache
  ( CacheStats (..),
    CheckCacheHandle,
    cacheStats,
    checkCacheFileName,
    computeFingerprintFromDir,
    defaultCheckCacheDirFromEnv,
    flushCheckCache,
    friendlyOverlayName,
    lookupLatest,
    openCheckCacheAt,
    overlayPathHash12,
    storeLatest,
    updateSourceId,
  )
import Update.Types
  ( PackageKey (..),
    UpdateSource (..),
  )

tests :: TestTree
tests =
  testGroup
    "CheckCache"
    [ testCase "XDG cache dir from env" testXdgDir,
      testCase "Friendly name sanitize" testFriendlyName,
      testCase "Distinct paths distinct hashes" testPathHashDistinct,
      testCase "File name shape" testFileNameShape,
      testCase "Source id" testSourceId,
      testCase "JSON round-trip latest" testRoundTripLatest,
      testCase "TTL expiry" testTtlExpiry,
      testCase "Fingerprint miss" testFingerprintMiss,
      testCase "Disabled never writes" testDisabledNoWrite,
      testCase "Atomic replace" testAtomicReplace,
      testCase "Corrupt is empty" testCorruptEmpty
    ]

testXdgDir :: IO ()
testXdgDir = do
  assertEq
    "xdg set"
    "/tmp/cache/mndz/overlay-manager/check-cache"
    (defaultCheckCacheDirFromEnv (Just "/tmp/cache") "/home/op")
  assertEq
    "xdg unset"
    "/home/op/.cache/mndz/overlay-manager/check-cache"
    (defaultCheckCacheDirFromEnv Nothing "/home/op")
  assertEq
    "xdg empty"
    "/home/op/.cache/mndz/overlay-manager/check-cache"
    (defaultCheckCacheDirFromEnv (Just "") "/home/op")

testFriendlyName :: IO ()
testFriendlyName = do
  assertEq "simple" "mndz" (friendlyOverlayName "/home/op/overlays/mndz")
  assertEq "spaces" "my-overlay" (friendlyOverlayName "/tmp/my overlay")
  assertEq "empty-ish" "overlay" (friendlyOverlayName "/tmp/!!!")

testPathHashDistinct :: IO ()
testPathHashDistinct = do
  let h1 = overlayPathHash12 "/home/a/mndz"
      h2 = overlayPathHash12 "/home/b/mndz"
  assertTrue "same basename different hash" (h1 /= h2)
  assertEq "hash12 length" 12 (T.length h1)

testFileNameShape :: IO ()
testFileNameShape = do
  let name = T.pack (checkCacheFileName "/home/op/overlays/mndz")
  assertTrue "starts with friendly" ("mndz-" `T.isPrefixOf` name)
  assertTrue "ends with json" (".json" `T.isSuffixOf` name)
  let mid = T.dropEnd 5 (T.drop 5 name)
  assertEq "hash segment len" 12 (T.length mid)

testSourceId :: IO ()
testSourceId = do
  assertEq
    "github"
    "github:owner/repo"
    (updateSourceId (GitHub "owner" "repo" "v"))
  assertEq "npm" "npm:pkg" (updateSourceId (Npm "pkg"))
  assertEq
    "http"
    "http:https://example.com/x"
    (updateSourceId (Http "https://example.com/x" Nothing))

setupPkg :: FilePath -> IO FilePath
setupPkg overlay = do
  let pkgDir = overlay </> "dev-lang" </> "foo"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> "foo-1.0.0.ebuild") "EAPI=8\nKEYWORDS=\"~amd64\"\n"
  pure pkgDir

openAt ::
  IO UTCTime ->
  FilePath ->
  CheckCacheTtl ->
  Bool ->
  FilePath ->
  IO (CheckCacheHandle, Maybe T.Text)
openAt clock cacheDir = openCheckCacheAt clock (Just cacheDir)

testRoundTripLatest :: IO ()
testRoundTripLatest =
  withSystemTempDirectory "om-cc-rt" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        src = GitHub "o" "r" "v"
        key = PackageKey "dev-lang/foo"
        remote = parseEbuildVersion "1.2.3"
    pkgDir <- setupPkg overlay
    now <- getCurrentTime
    clock <- newIORef now
    (h, _) <- openAt (readIORef clock) cacheDir (CacheTtl (5 * 60)) False overlay
    fp <- computeFingerprintFromDir src pkgDir "foo"
    storeLatest h key fp remote
    flushCheckCache h
    (h2, warn) <- openAt (readIORef clock) cacheDir (CacheTtl (5 * 60)) False overlay
    assertEq "no warn" Nothing warn
    m <- lookupLatest h2 key fp
    assertEq "hit" (Just remote) m

testTtlExpiry :: IO ()
testTtlExpiry =
  withSystemTempDirectory "om-cc-ttl" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        src = GitHub "o" "r" "v"
        key = PackageKey "dev-lang/foo"
        remote = parseEbuildVersion "2.0.0"
    pkgDir <- setupPkg overlay
    now <- getCurrentTime
    clock <- newIORef now
    (h, _) <- openAt (readIORef clock) cacheDir (CacheTtl 30) False overlay
    fp <- computeFingerprintFromDir src pkgDir "foo"
    storeLatest h key fp remote
    flushCheckCache h
    writeIORef clock (addUTCTime 60 now)
    (h2, _) <- openAt (readIORef clock) cacheDir (CacheTtl 30) False overlay
    m <- lookupLatest h2 key fp
    assertEq "expired miss" Nothing m

testFingerprintMiss :: IO ()
testFingerprintMiss =
  withSystemTempDirectory "om-cc-fp" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        src = GitHub "o" "r" "v"
        key = PackageKey "dev-lang/foo"
        remote = parseEbuildVersion "2.0.0"
    pkgDir <- setupPkg overlay
    now <- getCurrentTime
    (h, _) <- openAt (pure now) cacheDir (CacheTtl (5 * 60)) False overlay
    fp0 <- computeFingerprintFromDir src pkgDir "foo"
    storeLatest h key fp0 remote
    flushCheckCache h
    TIO.writeFile (pkgDir </> "foo-1.0.0.ebuild") "EAPI=8\n# changed\n"
    fp1 <- computeFingerprintFromDir src pkgDir "foo"
    assertTrue "fingerprint changed" (fp0 /= fp1)
    (h2, _) <- openAt (pure now) cacheDir (CacheTtl (5 * 60)) False overlay
    m <- lookupLatest h2 key fp1
    assertEq "content change miss" Nothing m

testDisabledNoWrite :: IO ()
testDisabledNoWrite =
  withSystemTempDirectory "om-cc-off" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        src = GitHub "o" "r" "v"
        key = PackageKey "dev-lang/foo"
    pkgDir <- setupPkg overlay
    now <- getCurrentTime
    (h, _) <- openAt (pure now) cacheDir CacheDisabled False overlay
    fp <- computeFingerprintFromDir src pkgDir "foo"
    storeLatest h key fp (parseEbuildVersion "9.9.9")
    flushCheckCache h
    exists <- doesDirectoryExist cacheDir
    -- Disabled open never creates the cache dir (cchEnabled False).
    assertTrue "disabled never creates cache dir" (not exists)

testAtomicReplace :: IO ()
testAtomicReplace =
  withSystemTempDirectory "om-cc-atom" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        src = GitHub "o" "r" "v"
        key = PackageKey "dev-lang/foo"
    pkgDir <- setupPkg overlay
    now <- getCurrentTime
    (h, _) <- openAt (pure now) cacheDir (CacheTtl (5 * 60)) False overlay
    fp <- computeFingerprintFromDir src pkgDir "foo"
    storeLatest h key fp (parseEbuildVersion "1.0.0")
    flushCheckCache h
    storeLatest h key fp (parseEbuildVersion "1.1.0")
    flushCheckCache h
    (h2, _) <- openAt (pure now) cacheDir (CacheTtl (5 * 60)) False overlay
    m <- lookupLatest h2 key fp
    assertEq "last write wins" (Just (parseEbuildVersion "1.1.0")) m
    st <- cacheStats h2
    assertEq "fresh handle zero hits" 0 (csHits st)

testCorruptEmpty :: IO ()
testCorruptEmpty =
  withSystemTempDirectory "om-cc-bad" $ \tmp -> do
    let overlay0 = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
    createDirectoryIfMissing True overlay0
    absOverlay <- makeAbsolute overlay0
    let path = cacheDir </> checkCacheFileName absOverlay
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile path "{not valid json"
    now <- getCurrentTime
    (h, warn) <- openAt (pure now) cacheDir (CacheTtl (5 * 60)) False overlay0
    assertTrue "warn present" (maybe False (not . T.null) warn)
    st <- cacheStats h
    assertEq "no packages loaded as hits" 0 (csHits st)
