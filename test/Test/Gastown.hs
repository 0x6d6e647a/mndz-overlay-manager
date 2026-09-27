{-# LANGUAGE OverloadedStrings #-}

module Test.Gastown (tests) where

import CLI.Jobs (newWorkBudget)
import Control.Concurrent.MVar (newMVar)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Overlay.Version (parseEbuildVersion, renderPV)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    removePathForcibly,
  )
import System.FilePath ((</>))
import System.Process (callProcess)
import Test.Assert (assertEq, assertTrue)
import Test.Support (mkTestApplyEnv, unusedReleaseOps, unusedVendorOps)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Apply.TestSupport (overlayAfterAssets)
import Update.Assets.Hash (hashBytes)
import Update.Check (PackageEntry (..))
import Update.Gastown.Gates (prepareGastownEbuild)
import Update.Git (GitOps (..))
import Update.Go.Plan (PlanOps (..))
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    PackageKey (..),
    mkPackageKey,
  )

tests :: TestTree
tests =
  testGroup
    "Gastown"
    [ testCase "v1.1.0 gate is a 0.57.0 floor and Dolt 1.82.4" testV110,
      testCase "v1.2.1 raises the Dolt floor and keeps the pin quietly" testV121,
      testCase "v1.2.0 ceiling keeps the pin and notices the window" testV120Notice,
      testCase "renamed Beads constant is an unrecognized gate" testRenamed,
      testCase "missing MinDoltVersion hard-fails" testMissingDolt,
      testCase "floor newer than the pin hard-fails" testFloorTooNew,
      testCase "ceiling other than 1.0.4 hard-fails" testCeilingOther,
      testCase "unrecognized gate does not write the ebuild" testNoWrite
    ]

fixture :: FilePath -> FilePath
fixture name = "test/fixtures/gastown-gates" </> name

seedBody :: T.Text
seedBody =
  T.unlines
    [ "EAPI=8",
      "inherit go-module shell-completion",
      "BDEPEND=\">=dev-lang/go-1.25.8:=\"",
      "DESCRIPTION=\"Gas Town\"",
      "SRC_URI=\"https://github.com/gastownhall/gastown/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/gastown-${PV}/gastown-${PV}-vendor.tar.xz\"",
      "LICENSE=\"MIT\"",
      "SLOT=\"0\"",
      "KEYWORDS=\"~amd64\"",
      "IUSE=\"bash-completion fish-completion +tmux test zsh-completion\"",
      "RESTRICT=\"!test? ( test )\"",
      "# gastown-beads-window: min=0.57.0 max=none",
      "RDEPEND=\"",
      "\t~dev-util/beads-1.0.4",
      "\t>=dev-db/dolt-1.82.4",
      "\tdev-vcs/git",
      "\ttmux? ( app-misc/tmux )",
      "\""
    ]

testV110 :: IO ()
testV110 = do
  (body, notice) <- assertPrepared (fixture "v1.1.0") seedBody
  assertTrue "keeps 1.82.4" (">=dev-db/dolt-1.82.4" `T.isInfixOf` body)
  assertTrue "keeps pin" ("~dev-util/beads-1.0.4" `T.isInfixOf` body)
  assertEq "quiet" Nothing notice

testV121 :: IO ()
testV121 = do
  (body, notice) <- assertPrepared (fixture "v1.2.1") seedBody
  assertTrue "dolt floor 2.0.7" (">=dev-db/dolt-2.0.7" `T.isInfixOf` body)
  assertTrue "old floor gone" (not (">=dev-db/dolt-1.82.4" `T.isInfixOf` body))
  assertTrue "pin kept" ("~dev-util/beads-1.0.4" `T.isInfixOf` body)
  assertTrue
    "pin not replaced by the declared floor"
    (not (">=dev-util/beads-0.57.0" `T.isInfixOf` body))
  assertTrue
    "window unchanged"
    ("# gastown-beads-window: min=0.57.0 max=none" `T.isInfixOf` body)
  assertEq "no window notice" Nothing notice

testV120Notice :: IO ()
testV120Notice = do
  (body, notice) <- assertPrepared (fixture "v1.2.0") seedBody
  assertTrue "pin kept" ("~dev-util/beads-1.0.4" `T.isInfixOf` body)
  assertTrue
    "window records the ceiling"
    ("# gastown-beads-window: min=1.0.4 max=1.0.4" `T.isInfixOf` body)
  case notice of
    Nothing -> assertFailure "expected a Beads window notice"
    Just line -> do
      assertTrue "names gastown" ("dev-util/gastown" `T.isInfixOf` line)
      assertTrue "names previous" ("min=0.57.0 max=none" `T.isInfixOf` line)
      assertTrue "names new" ("min=1.0.4 max=1.0.4" `T.isInfixOf` line)
      assertTrue "names kept pin" ("~dev-util/beads-1.0.4 was kept" `T.isInfixOf` line)
  (again, second) <- assertPrepared (fixture "v1.2.0") body
  assertTrue "second write keeps the ceiling window" ("max=1.0.4" `T.isInfixOf` again)
  assertEq "second apply is silent" Nothing second

testRenamed :: IO ()
testRenamed = do
  err <- assertRejected (fixture "renamed") seedBody
  assertTrue "unrecognized" ("unrecognized" `T.isInfixOf` err)
  assertTrue "plain update" ("plain update is not sufficient" `T.isInfixOf` err)
  assertTrue "names the package" ("dev-util/gastown" `T.isInfixOf` err)

testMissingDolt :: IO ()
testMissingDolt =
  withCopied "v1.1.0" "missing-dolt" $ \dir -> do
    TIO.writeFile (dir </> "internal/deps/dolt.go") "package deps\n"
    err <- assertRejected dir seedBody
    assertTrue "names MinDoltVersion" ("MinDoltVersion" `T.isInfixOf` err)
    assertTrue "missing" ("missing" `T.isInfixOf` err)

testFloorTooNew :: IO ()
testFloorTooNew =
  withCopied "v1.1.0" "floor-too-new" $ \dir -> do
    rewriteFile (dir </> "internal/deps/beads.go") (T.replace "\"0.57.0\"" "\"1.2.0\"")
    err <- assertRejected dir seedBody
    assertTrue "names the pin" ("~dev-util/beads-1.0.4" `T.isInfixOf` err)
    assertTrue "names the floor" ("1.2.0" `T.isInfixOf` err)
    assertTrue "no success line" (not ("1.1.0 -> 1.2.1" `T.isInfixOf` err))

testCeilingOther :: IO ()
testCeilingOther =
  withCopied "v1.2.0" "ceiling-other" $ \dir -> do
    rewriteFile (dir </> "internal/deps/beads.go") (T.replace "\"1.0.4\"" "\"1.2.2\"")
    err <- assertRejected dir seedBody
    assertTrue "names the pin" ("~dev-util/beads-1.0.4" `T.isInfixOf` err)
    assertTrue "names the ceiling" ("1.2.2" `T.isInfixOf` err)
    assertTrue "no success line" (not ("1.1.0 -> 1.2.1" `T.isInfixOf` err))

testNoWrite :: IO ()
testNoWrite = do
  let root = "/tmp/gastown-gate-nowrite"
      pkgDir = root </> "dev-util" </> "gastown"
      donor = pkgDir </> "gastown-1.1.0.ebuild"
      written = pkgDir </> "gastown-1.2.1.ebuild"
      key = mkPackageKey "dev-util" "gastown"
  removePathForcibly root
  createDirectoryIfMissing True pkgDir
  TIO.writeFile donor seedBody
  before <- TIO.readFile donor
  budget <- newWorkBudget 1
  ceilings <- newMVar Nothing
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
  let planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Left "unused"),
            poFetchGoMod = \_ -> pure (Left "unused"),
            poWorkBudget = budget,
            poCeilingsCache = ceilings
          }
  env <-
    mkTestApplyEnv
      cleanGit
      planOps
      (\_ _ -> assertFailure "ebuild manifest ran")
      unusedReleaseOps
      unusedVendorOps
      Nothing
      assetsLock
      overlayLock
  let entry =
        PackageEntry
          { peKey = key,
            pePN = "gastown",
            peLocal = parseEbuildVersion "1.1.0",
            pePath = donor
          }
  outcome <-
    overlayAfterAssets
      env
      root
      entry
      (Go Nothing)
      ["~amd64"]
      []
      (parseEbuildVersion "1.2.1")
      [("gastown-1.2.1-vendor.tar.xz", hashBytes (encodeUtf8 "unused"))]
      (Just "1.25.8")
      Nothing
      Nothing
      (Just (fixture "renamed"))
  case outcome of
    ApplyHardFail k msg half _ -> do
      assertEq "key" key k
      assertEq "not half-applied" False half
      assertTrue "unrecognized" ("unrecognized" `T.isInfixOf` msg)
      assertTrue "plain update" ("plain update is not sufficient" `T.isInfixOf` msg)
      assertTrue
        "not a success line"
        ( not
            ( (renderPV (parseEbuildVersion "1.1.0") <> " -> ")
                `T.isInfixOf` msg
            )
        )
    other -> assertFailure ("expected hard-fail, got " <> show other)
  after <- TIO.readFile donor
  assertEq "donor unchanged" before after
  exists <- doesFileExist written
  assertEq "target ebuild absent" False exists
  removePathForcibly root

assertPrepared :: FilePath -> T.Text -> IO (T.Text, Maybe T.Text)
assertPrepared dir body = do
  result <- prepareGastownEbuild dir body
  case result of
    Right pair -> pure pair
    Left err -> assertFailure (T.unpack err)

assertRejected :: FilePath -> T.Text -> IO T.Text
assertRejected dir body = do
  result <- prepareGastownEbuild dir body
  case result of
    Left err -> pure err
    Right _ -> assertFailure "expected the gate to hard-fail"

withCopied :: String -> FilePath -> (FilePath -> IO ()) -> IO ()
withCopied src name act = do
  let dest = "/tmp/gastown-gate-" <> name
  removePathForcibly dest
  callProcess "cp" ["-a", fixture src, dest]
  act dest
  removePathForcibly dest

rewriteFile :: FilePath -> (T.Text -> T.Text) -> IO ()
rewriteFile path f = do
  body <- TIO.readFile path
  TIO.writeFile path (f body)

cleanGit :: GitOps
cleanGit =
  GitOps
    { goIsWorkTree = \_ -> pure True,
      goPathsDirty = \_ _ -> pure (Right False),
      goAddAndCommit = \_ _ _ -> pure (Right ()),
      goPush = \_ -> pure (Right ()),
      goRevParseHead = \_ -> pure (Right "test-head")
    }
