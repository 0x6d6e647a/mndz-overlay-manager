{-# LANGUAGE OverloadedStrings #-}

-- | Integration coverage for gated publishing over fakes: the gate before
-- any publish or commit, overlay push after each commit, the halt on push
-- failure, held units, published-asset verification, and the new hard-fail
-- messages.
module Test.GatedPublish (tests) where

import CLI.Jobs (newWorkBudget)
import CLI.Progress (MultiHandle (..), noopMultiHandle)
import Control.Concurrent.MVar (newMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Overlay.Version (parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse)
import Test.Support
  ( mkTestApplyEnv,
    unusedReleaseOps,
    unusedVendorOps,
    writeMatchingCachesForPackage,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Apply
  ( ApplyEnv (..),
    HoldRequest (..),
    PublishControl (..),
    foldExitHardFail,
    newPublishControl,
  )
import Update.Apply.Errors (ApplyUnitError (..), applyUnitErrorMessage)
import Update.Apply.TestSupport (applyPackagePhase1, goPublishAndOverlay)
import Update.Assets.Hash (digestSHA512, hashBytes)
import Update.Assets.Layout (vendorTarballName)
import Update.Assets.Release (ReleaseAsset (..), ReleaseInfo (..), ReleaseOps (..))
import Update.Assets.Verify
  ( ManifestDist (..),
    assetsDownloadPrefix,
    parseManifestDist,
    verifyPublishedAsset,
    verifyUnitAssets,
  )
import Update.Check (PackageEntry (..))
import Update.Distfiles (seedManagerDistfiles)
import Update.Gate (GateFailure (..), GateHandle (..), GateRequest (..), GateResult (..), passThroughGate)
import Update.Git (GitOps (..))
import Update.Go.Plan (PlanOps (..))
import Update.Go.Vendor (VendorOps (..))
import Update.Held (AssetRecord (..), GateRunRecord (..), HeldReason (..), renderHeldReason)
import Update.Types (ApplyOutcome (..), SuccessLine (..), mkPackageKey, packageKeyText)

tests :: TestTree
tests =
  testGroup
    "GatedPublish"
    [ testGroup
        "overlay push"
        [ testCase "commit and push alternate across two units" testCommitPushOrder,
          testCase "push failure keeps the commit, prints no success" testPushFailureNoSuccess,
          testCase "Git Operations outage stops the push and halts" testGitOperationsBeforePush,
          testCase "second push fails: first pushed, second kept, third held halted" testHaltAcrossThree
        ],
      testGroup
        "gate"
        [ testCase "GitMv gate failure: no commit, held" testGitMvGateFailureHeld,
          testCase "full path: nothing published before the gate" testFullPathNothingBeforeGate,
          testCase "full path gate failure publishes nothing and holds" testFullPathGateFailure,
          testCase "reuse gate failure is held with assets published" testReuseGateFailureHeld,
          testCase "verification failure is held as verify" testVerifyFailureHeld
        ],
      testGroup
        "verification"
        [ testCase "asset matches its Manifest entry" testVerifyMatch,
          testCase "HTTP 404 fails naming the status" testVerify404,
          testCase "hash mismatch fails naming the hash" testVerifyMismatch,
          testCase "URL comes from the md5-cache SRC_URI" testVerifyUnitUrl,
          testCase "reuse path skips verification" testReuseSkipsVerify
        ],
      testGroup
        "messages"
        [ testCase "one message per new hard-fail class" testMessages,
          testCase "held units are not half-applied" testHeldNotHalfApplied
        ],
      testGroup
        "progress"
        [ testCase "GitMv row: smoke testing after the Manifest, then commit and push" testGitMvStatuses
        ]
    ]

------------------------------------------------------------------------
-- Fixtures

-- | Ordered record of commits, pushes, holds, gates, and publishes.
type Events = IORef [Text]

note :: Events -> Text -> IO ()
note ev e = modifyIORef' ev (++ [e])

-- | A GitMv package at @1.0@ with matching md5-cache; the fetcher reports
-- @1.1@.
seedGitMv :: FilePath -> Text -> Text -> IO PackageEntry
seedGitMv overlayRoot cat pn = do
  let pkgDir = overlayRoot </> T.unpack cat </> T.unpack pn
      name = T.unpack pn <> "-1.0.ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> name) "EAPI=8\nKEYWORDS=\"~amd64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
  writeMatchingCachesForPackage overlayRoot cat pn pkgDir
  pure
    PackageEntry
      { peKey = mkPackageKey cat pn,
        pePN = pn,
        peLocal = parseEbuildVersion "1.0",
        pePath = pkgDir </> name
      }

recordingGit :: Events -> FilePath -> GitOps
recordingGit ev assetsRoot =
  GitOps
    { goIsWorkTree = \_ -> pure True,
      goPathsDirty = \_ _ -> pure (Right False),
      goAddAndCommit = \root _ msg -> do
        note ev ((if root == assetsRoot then "assets-commit " else "commit ") <> msg)
        pure (Right ()),
      goPush = \_ -> note ev "assets-push" >> pure (Right ()),
      goRevParseHead = \_ -> pure (Right "test-head")
    }

-- | Base env: recording git, gate, hold, and overlay push. @pushFails@
-- lists commit messages whose push fails.
gatedEnv ::
  Events ->
  FilePath ->
  FilePath ->
  (FilePath -> FilePath -> IO (Either Text ())) ->
  ReleaseOps ->
  VendorOps ->
  (GateRequest -> IO GateResult) ->
  IO ApplyEnv
gatedEnv ev _overlayRoot assetsRoot ebuildRun releaseOps vendorOps gateFn = do
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
  budget <- newWorkBudget 2
  ceilings <- newMVar Nothing
  let planOps =
        PlanOps
          { poGentooTree = "/nonexistent/gentoo-tree",
            poListVersions = \_ -> pure (Left "unused"),
            poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
            poWorkBudget = budget,
            poCeilingsCache = ceilings
          }
  env0 <-
    mkTestApplyEnv
      (recordingGit ev assetsRoot)
      planOps
      ebuildRun
      releaseOps
      vendorOps
      (Just assetsRoot)
      assetsLock
      overlayLock
  publish <-
    newPublishControl
      (\_ -> note ev "push" >> pure (Right ()))
      (\_ _ key _ _ -> note ev ("verify " <> packageKeyText key) >> pure (Right ()))
  pure
    env0
      { aeFetcher = \_ -> pure (Right (parseEbuildVersion "1.1")),
        aeGate = passThroughGate {ghGate = \req -> note ev ("gate " <> packageKeyText (grKey req)) >> gateFn req},
        aeHold = \req -> do
          note ev ("hold " <> packageKeyText (hrKey req) <> " " <> renderHeldReason (hrReason req))
          pure (Right ("/held/" <> T.unpack (packageKeyText (hrKey req)))),
        aePublish = publish
      }

manifestWriter :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
manifestWriter _overlay pkgDir name = do
  TIO.writeFile (pkgDir </> "Manifest") ("DIST " <> T.pack name <> " 1\n")
  pure (Right ())

passGate :: GateRequest -> IO GateResult
passGate _ = pure (GatePassed [GateRunRecord Nothing "pass"] [])

failGate :: GateRequest -> IO GateResult
failGate req =
  pure . GateFailed $
    GateFailure
      { gfReason = HeldGate,
        gfMessage = packageKeyText (grKey req) <> "-1.1: fail: build (log: /logs/r1/build.log)",
        gfRuns = [GateRunRecord Nothing "fail: build"],
        gfLogDirs = ["/logs/r1"]
      }

-- | Real GitMv policy keys.
deno, kiroCli, grokBuild :: (Text, Text)
deno = ("dev-lang", "deno-bin")
kiroCli = ("dev-util", "kiro-cli-bin")
grokBuild = ("dev-util", "grok-build-bin")

withGitMv :: [(Text, Text)] -> (FilePath -> [PackageEntry] -> IO a) -> IO a
withGitMv pkgs k =
  withSystemTempDirectory "om-gated-gitmv" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
    entries <- mapM (uncurry (seedGitMv overlayRoot)) pkgs
    k overlayRoot entries

------------------------------------------------------------------------
-- Overlay push

testCommitPushOrder :: IO ()
testCommitPushOrder = withGitMv [deno, kiroCli] $ \overlayRoot entries -> do
  ev <- newIORef []
  env <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps passGate
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  assertTrue "both succeed" (all isSuccess outs && length outs == 2)
  events <- readIORef ev
  assertEq
    "gate, commit, push per unit, in order"
    [ "gate dev-lang/deno-bin",
      "commit dev-lang/deno-bin: 1.1",
      "push",
      "gate dev-util/kiro-cli-bin",
      "commit dev-util/kiro-cli-bin: 1.1",
      "push"
    ]
    events

testPushFailureNoSuccess :: IO ()
testPushFailureNoSuccess = withGitMv [deno] $ \overlayRoot entries -> do
  ev <- newIORef []
  env0 <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps passGate
  let env = env0 {aePublish = (aePublish env0) {pcPushOverlay = \_ -> pure (Left "git push failed: network unreachable")}}
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  case outs of
    [ApplyHardFail _ msg half _] -> do
      assertTrue "names git push" (("git -C " <> T.pack overlayRoot <> " push") `T.isInfixOf` msg)
      assertTrue "commit kept" ("commit is kept" `T.isInfixOf` msg)
      assertTrue "not half-applied" (not half)
    other -> assertFailure ("expected one hard fail, got " <> show other)
  events <- readIORef ev
  assertTrue "commit happened" ("commit dev-lang/deno-bin: 1.1" `elem` events)
  halted <- readIORef (pcHalted (aePublish env))
  assertTrue "publishing halted" (isJust halted)

testGitOperationsBeforePush :: IO ()
testGitOperationsBeforePush = withGitMv [deno] $ \overlayRoot entries -> do
  ev <- newIORef []
  env0 <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps passGate
  let env = env0 {aeGitOperationsHealth = pure (Left "GitHub Git Operations is major_outage")}
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  events <- readIORef ev
  assertTrue "push not attempted" ("push" `notElem` events)
  assertTrue "hard fail names the outage" (any (\case ApplyHardFail _ m _ _ -> "major_outage" `T.isInfixOf` m; _ -> False) outs)
  halted <- readIORef (pcHalted (aePublish env))
  assertTrue "publishing halted" (isJust halted)

testHaltAcrossThree :: IO ()
testHaltAcrossThree = withGitMv [deno, kiroCli, grokBuild] $ \overlayRoot entries -> do
  ev <- newIORef []
  pushes <- newIORef (0 :: Int)
  env0 <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps passGate
  let push _ = do
        modifyIORef' pushes (+ 1)
        n <- readIORef pushes
        if n == 2
          then pure (Left "git push failed: rejected")
          else note ev "push" >> pure (Right ())
      env = env0 {aePublish = (aePublish env0) {pcPushOverlay = push}}
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  events <- readIORef ev
  case outs of
    [ApplySuccess {}, ApplyHardFail _ pushMsg _ _, ApplyHardFail _ haltMsg half _] -> do
      assertTrue "second names git push" ("push" `T.isInfixOf` pushMsg && "git -C" `T.isInfixOf` pushMsg)
      assertTrue "third says halted" ("publishing halted" `T.isInfixOf` haltMsg)
      assertTrue "third names the failed push" ("dev-util/kiro-cli-bin: 1.1" `T.isInfixOf` haltMsg)
      assertTrue "third is not half-applied" (not half)
    other -> assertFailure ("unexpected outcomes " <> show other)
  assertTrue "second committed" ("commit dev-util/kiro-cli-bin: 1.1" `elem` events)
  assertTrue "third not committed" ("commit dev-util/grok-build-bin: 1.1" `notElem` events)
  assertTrue "third gated" ("gate dev-util/grok-build-bin" `elem` events)
  assertTrue "third held halted" ("hold dev-util/grok-build-bin halted" `elem` events)
  assertEq "one successful push" 1 (length (filter (== "push") events))
  assertTrue "exit 1" (foldExitHardFail outs)

------------------------------------------------------------------------
-- Gate

testGitMvGateFailureHeld :: IO ()
testGitMvGateFailureHeld = withGitMv [deno] $ \overlayRoot entries -> do
  ev <- newIORef []
  env <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps failGate
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  events <- readIORef ev
  assertEq "gate then hold, no commit" ["gate dev-lang/deno-bin", "hold dev-lang/deno-bin gate"] events
  case outs of
    [ApplyHardFail _ msg half published] -> do
      assertTrue "smoke gate failed" ("smoke gate failed" `T.isInfixOf` msg)
      assertTrue "names the stage" ("fail: build" `T.isInfixOf` msg)
      assertTrue "names the log" ("/logs/r1/build.log" `T.isInfixOf` msg)
      assertTrue "names the held entry" ("/held/dev-lang/deno-bin" `T.isInfixOf` msg)
      assertTrue "no half-applied warning" (not half)
      assertTrue "nothing published" (not published)
    other -> assertFailure ("expected one hard fail, got " <> show other)

-- | A crush full-path unit over fakes, as in the apply progress tests.
withFullPath ::
  (FilePath -> FilePath -> PackageEntry -> (Events -> (GateRequest -> IO GateResult) -> ReleaseOps -> IO ApplyEnv) -> IO a) ->
  IO a
withFullPath k =
  withSystemTempDirectory "om-gated-full" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        ebuildName = "crush-0.84.0.ebuild"
        tarballName = vendorTarballName "crush" "0.84.0"
        assetBytes = fullPathAssetBytes
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = "crush",
              peLocal = parseEbuildVersion "0.84.0",
              pePath = pkgDir </> ebuildName
            }
        distDir = fullPathDistDir overlayRoot
        -- Like Portage: hash the DISTDIR copy, or note that it was fetched.
        ebuildRun _pkg _name = do
          seeded <- doesFileExist (distDir </> tarballName)
          bytes <-
            if seeded
              then BS.readFile (distDir </> tarballName)
              else appendFile (fullPathFetchedMarker overlayRoot) tarballName >> pure assetBytes
          TIO.writeFile
            (pkgDir </> "Manifest")
            ("DIST " <> T.pack tarballName <> " 1 SHA512 " <> digestSHA512 (hashBytes bytes) <> "\n")
          pure (Right ())
        vendorOps =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_ _ outPath -> BS.writeFile outPath assetBytes >> pure (Right ())
            }
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    createDirectoryIfMissing True distDir
    TIO.writeFile
      (pkgDir </> ebuildName)
      ( T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
      )
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "app-misc" "crush" pkgDir
    k overlayRoot assetsRoot entry $ \ev gateFn releaseOps -> do
      env <- gatedEnv ev overlayRoot assetsRoot ebuildRun releaseOps vendorOps gateFn
      pure env {aeSeedDistfiles = seedManagerDistfiles distDir}

-- | The manager @DISTDIR@ of a 'withFullPath' fixture.
fullPathDistDir :: FilePath -> FilePath
fullPathDistDir overlayRoot = takeDirectory overlayRoot </> "distfiles"

-- | Written when the fake @ebuild manifest@ had to fetch a distfile.
fullPathFetchedMarker :: FilePath -> FilePath
fullPathFetchedMarker overlayRoot = takeDirectory overlayRoot </> "manifest-fetched"

fullPathAssetBytes :: BS.ByteString
fullPathAssetBytes = encodeUtf8 "vendor-tarball-bytes-for-gated"

runFullPath :: ApplyEnv -> FilePath -> PackageEntry -> IO ApplyOutcome
runFullPath env overlayRoot entry = do
  steps <- newIORef 0
  goPublishAndOverlay
    env
    overlayRoot
    entry
    "charmbracelet"
    "crush"
    "v"
    Nothing
    ["~amd64"]
    [SuccessLine (parseEbuildVersion "0.80.0") (parseEbuildVersion "0.84.0") (Just "(dev-lang/go ~amd64)") False]
    (parseEbuildVersion "0.84.0")
    steps
    1

-- | No release exists yet: the full path; creating one is recorded.
recordingRelease :: Events -> ReleaseOps
recordingRelease ev =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "should not download"),
      roCreateReleaseWithAssets = \_ _ -> note ev "release" >> pure (Right ())
    }

-- | The release and its asset exist: the reuse path.
reuseRelease :: BS.ByteString -> ReleaseOps
reuseRelease bytes =
  ReleaseOps
    { roGetReleaseByTag = \_ _ tag ->
        pure . Right . Just $
          ReleaseInfo
            { riId = 1,
              riTag = tag,
              riAssets =
                [ ReleaseAsset
                    { raName = T.pack (vendorTarballName "crush" "0.84.0"),
                      raBrowserDownloadUrl = "https://example/vendor",
                      raSize = Nothing
                    }
                ]
            },
      roDownloadAsset = \_ dest -> BS.writeFile dest bytes >> pure (Right ()),
      roCreateReleaseWithAssets = \_ _ -> pure (Left "should not create on reuse")
    }

testFullPathNothingBeforeGate :: IO ()
testFullPathNothingBeforeGate = withFullPath $ \overlayRoot assetsRoot entry mkEnv -> do
  ev <- newIORef []
  sidecarsAtGate <- newIORef (Nothing :: Maybe [FilePath])
  let gateFn req = do
        exists <- doesDirectoryExist (assetsRoot </> "app-misc")
        listed <- if exists then listDirectory (assetsRoot </> "app-misc") else pure []
        modifyIORef' sidecarsAtGate (const (Just listed))
        assertEq "staged tarball" ["crush-0.84.0-vendor.tar.xz"] (map (reverse . takeWhile (/= '/') . reverse) (grStaged req))
        passGate req
  env <- mkEnv ev gateFn (recordingRelease ev)
  outcome <- runFullPath env overlayRoot entry
  assertTrue "success" (isSuccess outcome)
  events <- readIORef ev
  assertEq
    "gate, then assets commit/push/release, verify, overlay commit, push"
    [ "gate app-misc/crush",
      "assets-commit app-misc/crush: 0.84.0",
      "assets-push",
      "release",
      "verify app-misc/crush",
      "commit app-misc/crush: 0.84.0",
      "push"
    ]
    events
  atGate <- readIORef sidecarsAtGate
  assertEq "no sidecar before the gate" (Just []) atGate
  fetched <- doesFileExist (fullPathFetchedMarker overlayRoot)
  assertTrue "the Manifest hashed the seeded distfile, fetching nothing" (not fetched)
  seededBytes <- BS.readFile (fullPathDistDir overlayRoot </> "crush-0.84.0-vendor.tar.xz")
  assertEq "DISTDIR holds the built tarball" fullPathAssetBytes seededBytes

testFullPathGateFailure :: IO ()
testFullPathGateFailure = withFullPath $ \overlayRoot assetsRoot entry mkEnv -> do
  ev <- newIORef []
  env <- mkEnv ev failGate (recordingRelease ev)
  outcome <- runFullPath env overlayRoot entry
  events <- readIORef ev
  assertEq "gate then hold only" ["gate app-misc/crush", "hold app-misc/crush gate"] events
  sidecars <- doesDirectoryExist (assetsRoot </> "app-misc")
  assertTrue "no sidecar" (not sidecars)
  case outcome of
    ApplyHardFail _ msg _ published -> do
      assertTrue "smoke gate failed" ("smoke gate failed" `T.isInfixOf` msg)
      assertTrue "nothing published" (not published)
    other -> assertFailure ("expected a hard fail, got " <> show other)

testReuseGateFailureHeld :: IO ()
testReuseGateFailureHeld = withFullPath $ \overlayRoot _ entry mkEnv -> do
  ev <- newIORef []
  held <- newIORef ([] :: [HoldRequest])
  env0 <- mkEnv ev failGate (reuseRelease fullPathAssetBytes)
  let env = env0 {aeHold = \req -> modifyIORef' held (++ [req]) >> pure (Right "/held/crush")}
  outcome <- runFullPath env overlayRoot entry
  events <- readIORef ev
  assertTrue "no commit at all" (not (any ("commit" `T.isInfixOf`) events))
  reqs <- readIORef held
  case (outcome, reqs) of
    (ApplyHardFail _ _ half published, [req]) -> do
      assertTrue "assets were already published" published
      assertTrue "not half-applied" (not half)
      assertEq "reason" HeldGate (hrReason req)
      assertEq "reuse path" (Just "reuse") (hrPath req)
      assertTrue "assets recorded as published" (not (null (hrAssets req)) && all arPublished (hrAssets req))
      assertEq "nothing staged" [] (hrDistfiles req)
    other -> assertFailure ("unexpected " <> show (fst other))

testVerifyFailureHeld :: IO ()
testVerifyFailureHeld = withFullPath $ \overlayRoot _ entry mkEnv -> do
  ev <- newIORef []
  held <- newIORef ([] :: [HoldRequest])
  env0 <- mkEnv ev passGate (recordingRelease ev)
  let env =
        env0
          { aePublish = (aePublish env0) {pcVerify = \_ _ _ _ _ -> pure (Left ("https://github.com/o/a/releases/download/crush-0.84.0/crush-0.84.0-vendor.tar.xz", "HTTP 404"))},
            aeHold = \req -> modifyIORef' held (++ [req]) >> pure (Right "/held/crush")
          }
  outcome <- runFullPath env overlayRoot entry
  events <- readIORef ev
  assertTrue "no overlay commit" (not (any ("commit app-misc" `T.isPrefixOf`) events))
  reqs <- readIORef held
  case (outcome, reqs) of
    (ApplyHardFail _ msg _ published, [req]) -> do
      assertTrue "names the URL" ("crush-0.84.0-vendor.tar.xz" `T.isInfixOf` msg)
      assertTrue "names the mismatch" ("HTTP 404" `T.isInfixOf` msg)
      assertTrue "assets were published" published
      assertEq "held as verify" HeldVerify (hrReason req)
      assertTrue "assets recorded as published" (not (null (hrAssets req)) && all arPublished (hrAssets req))
    other -> assertFailure ("unexpected " <> show (fst other))

------------------------------------------------------------------------
-- Verification

assetDist :: BS.ByteString -> ManifestDist
assetDist b =
  ManifestDist
    { mdSize = fromIntegral (BS.length b),
      mdHashes = [("SHA512", digestSHA512 (hashBytes b))]
    }

testVerifyMatch :: IO ()
testVerifyMatch = do
  let body = "the published tarball"
  got <- verifyPublishedAsset (\_ -> pure (Right (fakeResponse 200 (LBS.fromStrict body)))) "https://github.com/o/a/releases/download/t/x.tar.xz" (assetDist body)
  assertEq "match" (Right ()) got

testVerify404 :: IO ()
testVerify404 = do
  err <- assertLeft "404" =<< verifyPublishedAsset (\_ -> pure (Right (fakeResponse 404 ""))) "https://github.com/o/a/releases/download/t/x.tar.xz" (assetDist "x")
  assertTrue "names the status" ("404" `T.isInfixOf` err)

testVerifyMismatch :: IO ()
testVerifyMismatch = do
  let expected = assetDist "the published tarball"
  err <- assertLeft "mismatch" =<< verifyPublishedAsset (\_ -> pure (Right (fakeResponse 200 "the published tarbalL"))) "https://github.com/o/a/releases/download/t/x.tar.xz" expected
  assertTrue "names the hash" ("SHA512" `T.isInfixOf` err)
  errSize <- assertLeft "size" =<< verifyPublishedAsset (\_ -> pure (Right (fakeResponse 200 "short"))) "https://github.com/o/a/releases/download/t/x.tar.xz" expected
  assertTrue "names the size" ("size" `T.isInfixOf` errSize)

testVerifyUnitUrl :: IO ()
testVerifyUnitUrl =
  withSystemTempDirectory "om-verify-unit" $ \root -> do
    let body = "tarball bytes" :: BS.ByteString
        prefix = assetsDownloadPrefix "o" "mndz-overlay-assets"
        url = prefix <> "hk-2.13.0/hk-2.13.0-crates.tar.xz"
        dist = assetDist body
    createDirectoryIfMissing True (root </> "dev-util" </> "hk")
    createDirectoryIfMissing True (root </> "metadata" </> "md5-cache" </> "dev-util")
    TIO.writeFile
      (root </> "dev-util" </> "hk" </> "Manifest")
      ( "DIST hk-2.13.0-crates.tar.xz "
          <> T.pack (show (mdSize dist))
          <> T.concat [" " <> n <> " " <> v | (n, v) <- mdHashes dist]
          <> "\n"
      )
    TIO.writeFile
      (root </> "metadata" </> "md5-cache" </> "dev-util" </> "hk-2.13.0")
      ("EAPI=8\nSRC_URI=https://github.com/jdx/hk/archive/v2.13.0.tar.gz -> hk-2.13.0.tar.gz " <> url <> "\n")
    seen <- newIORef []
    let verifyOne u d = modifyIORef' seen (++ [(u, d)]) >> pure (Right ())
    assertRight "verified" =<< verifyUnitAssets verifyOne prefix root (mkPackageKey "dev-util" "hk") "2.13.0" ["hk-2.13.0-crates.tar.xz"]
    calls <- readIORef seen
    assertEq "exact URL and Manifest entry" [(url, dist)] calls
    assertEq "Manifest parse" (Just dist) . flip parseManifestDist "hk-2.13.0-crates.tar.xz" =<< TIO.readFile (root </> "dev-util" </> "hk" </> "Manifest")
    (failedUrl, why) <- assertLeft "unnamed asset" =<< verifyUnitAssets verifyOne prefix root (mkPackageKey "dev-util" "hk") "2.13.0" ["hk-2.13.0-crate.tar.xz"]
    assertEq "names the asset" "hk-2.13.0-crate.tar.xz" failedUrl
    assertTrue "says not named" ("does not name" `T.isInfixOf` why)

testReuseSkipsVerify :: IO ()
testReuseSkipsVerify = withFullPath $ \overlayRoot _ entry mkEnv -> do
  ev <- newIORef []
  env <- mkEnv ev passGate (reuseRelease fullPathAssetBytes)
  outcome <- runFullPath env overlayRoot entry
  assertTrue "reuse succeeds" (isSuccess outcome)
  events <- readIORef ev
  assertEq "gate, overlay commit, push; no verification" ["gate app-misc/crush", "commit app-misc/crush: 0.84.0", "push"] events

------------------------------------------------------------------------
-- Messages

testMessages :: IO ()
testMessages = do
  let gate = applyUnitErrorMessage (ApplyGateFailed "dev-util/hk-2.13.0: fail: build (log: /l/build.log)")
      verify = applyUnitErrorMessage (ApplyVerifyFailed "https://x/hk.tar.xz" "HTTP 404")
      push = applyUnitErrorMessage (ApplyOverlayPushFailed "/ov" "rejected")
      halted = applyUnitErrorMessage (ApplyPublishingHalted "the overlay push of \"dev-util/hk: 2.13.0\" failed: rejected")
  assertTrue "gate" ("smoke gate failed" `T.isInfixOf` gate && "fail: build" `T.isInfixOf` gate && "/l/build.log" `T.isInfixOf` gate)
  assertTrue "verify" ("verification failed" `T.isInfixOf` verify && "https://x/hk.tar.xz" `T.isInfixOf` verify && "HTTP 404" `T.isInfixOf` verify)
  assertTrue "push" ("git -C /ov push" `T.isInfixOf` push && "commit is kept" `T.isInfixOf` push)
  assertTrue "halted" ("publishing halted" `T.isInfixOf` halted && "dev-util/hk: 2.13.0" `T.isInfixOf` halted)

testHeldNotHalfApplied :: IO ()
testHeldNotHalfApplied = withGitMv [deno] $ \overlayRoot entries -> do
  ev <- newIORef []
  env <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps failGate
  outs <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  assertTrue "held outcome is not half-applied" (all (\case ApplyHardFail _ _ half _ -> not half; _ -> True) outs)

isSuccess :: ApplyOutcome -> Bool
isSuccess = \case
  ApplySuccess {} -> True
  _ -> False

testGitMvStatuses :: IO ()
testGitMvStatuses = withGitMv [deno] $ \overlayRoot entries -> do
  ev <- newIORef []
  statuses <- newIORef []
  env0 <- gatedEnv ev overlayRoot (overlayRoot </> "assets") (manifestWriter overlayRoot) unusedReleaseOps unusedVendorOps passGate
  let env = env0 {aeMulti = noopMultiHandle {mhStatus = \_ s -> modifyIORef' statuses (++ [s])}}
  _ <- concat <$> mapM (applyPackagePhase1 env overlayRoot) entries
  got <- readIORef statuses
  assertEq
    "status order after the Manifest"
    ["smoke testing", "committing", "pushing overlay"]
    (drop 1 (dropWhile (not . ("manifest" `T.isInfixOf`) . T.toLower) got))
