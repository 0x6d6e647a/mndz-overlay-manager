{-# LANGUAGE OverloadedStrings #-}

-- | Integration coverage for held units: entry location, capture with an
-- atomic rename, patch round-trip, metadata, rollback of exactly the unit's
-- paths, and eclean leaving held entries alone.
module Test.Held (tests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), decode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Metrics.Core (noopMetrics)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    renameFile,
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess, readProcess)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Distfiles (cleanManagerDistfilesKeeping)
import Update.Held
import Update.Process (ProcessMode (..), ProcessRequest (..), ProcessResult (..), productionCommandRunner)
import Update.Types (mkPackageKey)

tests :: TestTree
tests =
  testGroup
    "Held"
    [ testCase "entry path under the cache home" testEntryPath,
      testCase "patch round-trips with git apply" testRoundTrip,
      testCase "held.json has every field" testMetadata,
      testCase "failed write leaves no complete-looking entry" testFailedWrite,
      testCase "rollback restores the rename and leaves other dirt" testRollback,
      testCase "capture failure leaves the unit's changes in place" testCaptureFailure,
      testCase "a second run's entry sits beside the first" testTwoRuns,
      testCase "eclean leaves held entries" testEcleanKeepsHeld
    ]

testEntryPath :: IO ()
testEntryPath = do
  let root = heldRootFromEnv Nothing "/home/op"
  assertEq
    "spec example"
    "/home/op/.cache/mndz/overlay-manager/held/20261117T101500-0800-4242.a8f3/dev-util/hk-2.13.0"
    (heldEntryPath root "20261117T101500-0800-4242.a8f3" (mkPackageKey "dev-util" "hk") "2.13.0")
  assertEq "xdg" "/x/mndz/overlay-manager/held" (heldRootFromEnv (Just "/x") "/home/op")
  assertEq "empty xdg" "/home/op/.cache/mndz/overlay-manager/held" (heldRootFromEnv (Just "") "/home/op")

-- | Overlay with @dev-util/hk-2.12.0@ and @dev-util/beads@ committed; @hk@
-- then renamed to 2.13.0 with Manifest, md5-cache, and a binary file, and
-- @beads@ dirtied. Returns the unit's paths.
seedUnit :: FilePath -> IO [FilePath]
seedUnit repo = do
  let git args = callProcess "git" (["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"] <> args)
      write p body = do
        createDirectoryIfMissing True (takeDirectory (repo </> p))
        TIO.writeFile (repo </> p) body
  createDirectoryIfMissing True repo
  git ["init", "-q"]
  write "dev-util/hk/hk-2.12.0.ebuild" "EAPI=8\nSRC_URI=\"x\"\n"
  write "dev-util/hk/Manifest" "DIST hk-2.12.0-crates.tar.xz 1 BLAKE2B aa\n"
  write "metadata/md5-cache/dev-util/hk-2.12.0" "EAPI=8\n_md5_=old\n"
  write "dev-util/beads/metadata.xml" "<pkgmetadata/>\n"
  git ["add", "."]
  git ["commit", "-q", "-m", "seed"]
  renameFile (repo </> "dev-util/hk/hk-2.12.0.ebuild") (repo </> "dev-util/hk/hk-2.13.0.ebuild")
  write "dev-util/hk/Manifest" "DIST hk-2.13.0-crates.tar.xz 2 BLAKE2B bb\n"
  renameFile (repo </> "metadata/md5-cache/dev-util/hk-2.12.0") (repo </> "metadata/md5-cache/dev-util/hk-2.13.0")
  write "metadata/md5-cache/dev-util/hk-2.13.0" "EAPI=8\n_md5_=new\n"
  BL.writeFile (repo </> "dev-util/hk/blob.bin") (BL.pack [0, 1, 2, 255, 254, 0, 10])
  write "dev-util/beads/metadata.xml" "<pkgmetadata>dirt</pkgmetadata>\n"
  pure
    [ "dev-util/hk/hk-2.12.0.ebuild",
      "dev-util/hk/hk-2.13.0.ebuild",
      "dev-util/hk/Manifest",
      "dev-util/hk/blob.bin",
      "metadata/md5-cache/dev-util/hk-2.12.0",
      "metadata/md5-cache/dev-util/hk-2.13.0"
    ]

meta :: [FilePath] -> Text -> HeldMeta
meta paths runId =
  HeldMeta
    { hmPackage = mkPackageKey "dev-util" "hk",
      hmPv = "2.13.0",
      hmTechnique = "DepsAndAssets Cargo",
      hmPath = Just "full",
      hmRuns = [GateRunRecord Nothing "fail: check version"],
      hmReason = HeldGate,
      hmDetail = "smoke gate failed",
      hmBaseHead = "0123abcd",
      hmRelease = Just "hk-2.13.0",
      hmAssets = [AssetRecord "hk-2.13.0-crates.tar.xz" False],
      hmPaths = paths,
      hmRunId = runId,
      hmTime = UTCTime (fromGregorian 2026 11 17) 0
    }

-- | Every file under the unit's directories, with contents.
unitState :: FilePath -> IO [(FilePath, BL.ByteString)]
unitState repo = do
  hk <- listDirectory (repo </> "dev-util/hk")
  cache <- listDirectory (repo </> "metadata/md5-cache/dev-util")
  let files = ["dev-util/hk" </> f | f <- hk] <> ["metadata/md5-cache/dev-util" </> f | f <- cache]
  mapM (\f -> (f,) <$> BL.readFile (repo </> f)) (sort files)

withUnit :: (FilePath -> FilePath -> HeldInput -> IO ()) -> IO ()
withUnit k =
  withSystemTempDirectory "om-held" $ \tmp -> do
    let repo = tmp </> "overlay"
        root = tmp </> "held"
    paths <- seedUnit repo
    let dist = tmp </> "distfiles" </> "hk-2.13.0-crates.tar.xz"
        logs = tmp </> "logs" </> "dev-util-hk-2.13.0"
    createDirectoryIfMissing True (takeDirectory dist)
    createDirectoryIfMissing True logs
    TIO.writeFile dist "tarball"
    TIO.writeFile (logs </> "build.log") "build output"
    let input =
          HeldInput
            { hiOverlay = repo,
              hiEntry = heldEntryPath root "r1" (mkPackageKey "dev-util" "hk") "2.13.0",
              hiMeta = meta paths "r1",
              hiDistfiles = [dist],
              hiLogDirs = [logs]
            }
    k tmp repo input

testRoundTrip :: IO ()
testRoundTrip = withUnit $ \_ repo input -> do
  before <- unitState repo
  entry <- assertRight "hold" =<< holdUnit productionCommandRunner input
  status <- readProcess "git" ["-C", repo, "status", "--porcelain", "--", "dev-util/hk", "metadata"] ""
  assertEq "unit matches HEAD" "" status
  callProcess "git" ["-C", repo, "apply", entry </> heldPatchName]
  after <- unitState repo
  assertEq "byte-identical after git apply" before after
  dist <- TIO.readFile (entry </> "distfiles" </> "hk-2.13.0-crates.tar.xz")
  assertEq "distfile kept" "tarball" dist
  logBody <- TIO.readFile (entry </> "logs" </> "dev-util-hk-2.13.0" </> "build.log")
  assertEq "log copied" "build output" logBody
  tmpLeft <- doesDirectoryExist (entry <> ".tmp")
  assertTrue "no tmp" (not tmpLeft)

testMetadata :: IO ()
testMetadata = withUnit $ \_ _ input -> do
  _ <- assertRight "capture" =<< captureHeld productionCommandRunner input
  raw <- BL.readFile (hiEntry input </> "held.json")
  case decode raw of
    Just (Object o) -> do
      forM_ ["version", "package", "pv", "technique", "path", "runs", "reason", "detail", "base_head", "release", "assets", "paths", "run_id", "time"] $ \k ->
        assertTrue ("field " <> show k) (KM.member k o)
      assertEq "version" (Just (Number 1)) (KM.lookup "version" o)
      assertEq "reason" (Just (String "gate")) (KM.lookup "reason" o)
      assertEq "package" (Just (String "dev-util/hk")) (KM.lookup "package" o)
    other -> assertFailure ("held.json is not an object: " <> show other)

testFailedWrite :: IO ()
testFailedWrite = withUnit $ \tmp repo input -> do
  let bad = input {hiDistfiles = [tmp </> "missing.tar.xz"]}
  before <- unitState repo
  err <- assertLeft "hold fails" =<< holdUnit productionCommandRunner bad
  assertTrue "not rolled back" ("not rolled back" `T.isInfixOf` err)
  assertTrue "names a path" ("dev-util/hk/hk-2.13.0.ebuild" `T.isInfixOf` err)
  entry <- doesDirectoryExist (hiEntry input)
  partial <- doesDirectoryExist (hiEntry input <> ".tmp")
  assertTrue "no entry" (not entry)
  assertTrue "no partial" (not partial)
  after <- unitState repo
  assertEq "unit changes still in place" before after
  staged <- readProcess "git" ["-C", repo, "diff", "--cached", "--name-only"] ""
  assertEq "no intent-to-add left behind" "" staged

testRollback :: IO ()
testRollback = withUnit $ \_ repo input -> do
  _ <- assertRight "hold" =<< holdUnit productionCommandRunner input
  old <- doesFileExist (repo </> "dev-util/hk/hk-2.12.0.ebuild")
  new <- doesFileExist (repo </> "dev-util/hk/hk-2.13.0.ebuild")
  blob <- doesFileExist (repo </> "dev-util/hk/blob.bin")
  oldCache <- doesFileExist (repo </> "metadata/md5-cache/dev-util/hk-2.12.0")
  newCache <- doesFileExist (repo </> "metadata/md5-cache/dev-util/hk-2.13.0")
  assertTrue "old ebuild restored" old
  assertTrue "new ebuild removed" (not new)
  assertTrue "new file removed" (not blob)
  assertTrue "old cache restored" oldCache
  assertTrue "new cache removed" (not newCache)
  beads <- TIO.readFile (repo </> "dev-util/beads/metadata.xml")
  assertEq "other package's dirt untouched" "<pkgmetadata>dirt</pkgmetadata>\n" beads

testCaptureFailure :: IO ()
testCaptureFailure = withUnit $ \_ repo input -> do
  before <- unitState repo
  let failingDiff req = case prMode req of
        ExecCmd "git" args | "diff" `elem` args -> pure (ProcessResult (ExitFailure 128) "" "fatal: injected")
        _ -> productionCommandRunner req
  err <- assertLeft "hold fails" =<< holdUnit failingDiff input
  assertTrue "says not rolled back" ("not rolled back" `T.isInfixOf` err)
  forM_ (hmPaths (hiMeta input)) $ \p -> assertTrue ("names " <> p) (T.pack p `T.isInfixOf` err)
  assertTrue "names the cause" ("injected" `T.isInfixOf` err)
  after <- unitState repo
  assertEq "unit changes in place" before after
  staged <- readProcess "git" ["-C", repo, "diff", "--cached", "--name-only"] ""
  assertEq "intent-to-add undone" "" staged

testTwoRuns :: IO ()
testTwoRuns = withUnit $ \tmp _ input -> do
  _ <- assertRight "first" =<< captureHeld productionCommandRunner input
  let root = tmp </> "held"
      second = input {hiEntry = heldEntryPath root "r2" (mkPackageKey "dev-util" "hk") "2.13.0", hiMeta = (hiMeta input) {hmRunId = "r2"}}
  _ <- assertRight "second" =<< captureHeld productionCommandRunner second
  runs <- listDirectory root
  assertEq "both kept" ["r1", "r2"] (sort runs)
  again <- captureHeld productionCommandRunner input
  case again of
    Left e -> assertTrue "existing entry not overwritten" ("already exists" `T.isInfixOf` e)
    Right () -> assertFailure "overwrote an existing held entry"

testEcleanKeepsHeld :: IO ()
testEcleanKeepsHeld =
  withSystemTempDirectory "om-held-eclean" $ \tmp -> do
    let base = tmp </> "mndz" </> "overlay-manager"
        held = base </> "held"
        entry = held </> "r1" </> "dev-util" </> "hk-2.13.0"
        noPortage _ _ _ = pure (ExitFailure 1, "", "")
    createDirectoryIfMissing True entry
    TIO.writeFile (entry </> "held.json") "{}"
    createDirectoryIfMissing True (base </> "distfiles")
    TIO.writeFile (base </> "distfiles" </> "x.tar.xz") "x"
    -- Default layout: held is a sibling of the distfiles cache.
    _ <- assertRight "clean distfiles" =<< cleanManagerDistfilesKeeping noopMetrics noPortage [held] (base </> "distfiles")
    kept1 <- doesFileExist (entry </> "held.json")
    assertTrue "held survives default eclean" kept1
    -- distfiles-path set to the manager cache root itself.
    TIO.writeFile (base </> "stray") "x"
    _ <- assertRight "clean root" =<< cleanManagerDistfilesKeeping noopMetrics noPortage [held] base
    kept2 <- doesFileExist (entry </> "held.json")
    left <- listDirectory base
    assertTrue "held survives a root eclean" kept2
    assertEq "everything else removed" ["held"] left
    -- distfiles-path inside held is refused.
    refused <- assertLeft "inside held" =<< cleanManagerDistfilesKeeping noopMetrics noPortage [held] (held </> "r1")
    assertTrue "names held" ("held" `T.isInfixOf` refused)
    kept3 <- doesFileExist (entry </> "held.json")
    assertTrue "held survives a refused eclean" kept3
