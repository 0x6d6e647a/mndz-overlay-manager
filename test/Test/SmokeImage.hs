{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for the smoke image recipe, sidecar, and build decision
-- with a scripted Docker fake (no daemon).
module Test.SmokeImage (tests) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Smoke.Image
  ( SmokeImageConfig (..),
    SmokeImageOutcome (..),
    SmokeSidecar (..),
    decodeSmokeSidecar,
    encodeSmokeSidecar,
    ensureSmokeImage,
    smokeCacheDirFromEnv,
    smokeImageTag,
    smokeSidecarPath,
    smokeSidecarSchemaVersion,
  )
import Smoke.Preflight (checkDockerVersion, checkImageStore, smokePreflight)
import Smoke.Recipe (renderSmokeDockerfile, smokeGeneratorId)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.DiskSpace (DiskSpaceProbe (..))
import Update.Materialize (DockerInfoFacts (..), RecipeArch (..), lookupRecipeArch, renderMaterializeDockerfile)
import Update.Process (ProcessMode (..), ProcessRequest (..), ProcessResult (..))

tests :: TestTree
tests =
  testGroup
    "SmokeImage"
    [ testGroup
        "recipe"
        [ testCase "FROM is digest-pinned to the OpenRC stage3" testRecipeFrom,
          testCase "Portage RUN binds the managed tree" testRecipeTreeBind,
          testCase "updates @world and installs GNU time and ccache only" testRecipeContents,
          testCase "builds binary packages into a smoke-only cache" testRecipeBinpkgs,
          testCase "no sandbox opt-out" testRecipeSandboxes,
          testCase "no cache id shared with materialize" testRecipeCacheIds
        ],
      testGroup
        "ensure"
        [ testCase "first build records the sidecar" testFirstBuild,
          testCase "recorded image is reused" testReuse,
          testCase "tree moved alone does not build" testTreeMoved,
          testCase "generator mismatch builds" testGeneratorMismatch,
          testCase "missing image id builds" testMissingImage,
          testCase "newer stage3 builds from the new digest" testNewerStage3,
          testCase "registry failure keeps the recorded image" testRegistryFailureKeeps,
          testCase "registry failure with no image fails" testRegistryFailureNoImage,
          testCase "build failure fails" testBuildFailure,
          testCase "unmapped arch fails" testUnmappedArch,
          testCase "disk gate fails before docker build" testDiskGate,
          testCase "same-digest check records its time" testSameDigestRecords,
          testCase "cache dir under XDG and HOME" testCacheDir
        ],
      testGroup
        "preflight"
        [ testCase "Docker version parsing" testDockerVersion,
          testCase "classic storage driver is rejected" testClassicDriver,
          testCase "preflight order: tools, git, version, store" testPreflightOrder
        ]
    ]

amd64 :: RecipeArch
amd64 = case lookupRecipeArch "x86_64" of
  Just a -> a
  Nothing -> error "x86_64 maps"

recipe :: Text
recipe = renderSmokeDockerfile amd64 "sha256:abc"

testRecipeFrom :: IO ()
testRecipeFrom =
  assertTrue "FROM" ("FROM gentoo/stage3:amd64-openrc@sha256:abc" `elem` T.lines recipe)

testRecipeTreeBind :: IO ()
testRecipeTreeBind = do
  let runs = [l | l <- T.lines recipe, "RUN " `T.isPrefixOf` l]
  assertEq "one RUN" 1 (length runs)
  assertTrue
    "tree bind"
    (all ("--mount=type=bind,from=gentoo,target=/var/db/repos/gentoo" `T.isInfixOf`) runs)
  assertTrue "no sync" (not ("emerge --sync" `T.isInfixOf` recipe || "emaint" `T.isInfixOf` recipe))

testRecipeContents :: IO ()
testRecipeContents = do
  assertTrue "@world" ("emerge --update --deep --newuse @world" `T.isInfixOf` recipe)
  assertTrue "portage" ("emerge --oneshot sys-apps/portage" `T.isInfixOf` recipe)
  assertTrue "time and ccache" ("emerge -n sys-process/time dev-util/ccache" `T.isInfixOf` recipe)
  let forbidden =
        [ "dev-lang/go",
          "net-libs/nodejs",
          "dev-lang/rust",
          "dev-lisp/sbcl",
          "bun-bin",
          "dev-vcs/git",
          "net-misc/wget",
          "net-misc/aria2",
          "app-arch/unzip",
          "gentoolkit",
          "::mndz"
        ]
  assertEq "no toolchain or fetch-tool atom" [] (filter (`T.isInfixOf` recipe) forbidden)

testRecipeBinpkgs :: IO ()
testRecipeBinpkgs = do
  assertTrue "buildpkg" ("ENV FEATURES=\"getbinpkg buildpkg\"" `elem` T.lines recipe)
  assertTrue
    "binpkgs cache mount on the Portage RUN"
    ("--mount=type=cache,id=mndz-smoke-build-binpkgs,target=/var/cache/binpkgs" `T.isInfixOf` recipe)
  assertEq "generator id" "mndz-overlay-manager-smoke-2" smokeGeneratorId

testRecipeSandboxes :: IO ()
testRecipeSandboxes = do
  assertTrue "no opt-out" (not ("-sandbox" `T.isInfixOf` recipe || "-usersandbox" `T.isInfixOf` recipe || "-userpriv" `T.isInfixOf` recipe))
  assertTrue "no package.env FEATURES" (not ("package.env" `T.isInfixOf` recipe))

testRecipeCacheIds :: IO ()
testRecipeCacheIds = do
  let materialize = renderMaterializeDockerfile amd64 "sha256:abc" []
      ids t = [w | w <- T.splitOn "," t, "id=" `T.isPrefixOf` w]
      smokeIds = concatMap ids (T.words recipe)
      matIds = concatMap ids (T.words materialize)
  assertTrue "smoke has cache ids" (not (null smokeIds))
  assertEq "disjoint" [] (filter (`elem` matIds) smokeIds)

------------------------------------------------------------------------
-- Scripted Docker

data Fake = Fake
  { fImage :: IORef (Maybe String),
    fBuildOk :: Bool,
    fCalls :: IORef [[String]],
    fNextId :: String
  }

newFake :: Maybe String -> Bool -> IO Fake
newFake img ok = Fake <$> newIORef img <*> pure ok <*> newIORef [] <*> pure "sha256:new"

run :: Fake -> ProcessRequest -> IO ProcessResult
run fake req = case prMode req of
  ExecCmd "docker" args -> do
    modifyIORef' (fCalls fake) (++ [args])
    case args of
      ["image", "inspect", "--format", "{{.Id}}", ref] -> do
        img <- readIORef (fImage fake)
        pure $ case img of
          Just iid | ref == smokeImageTag || ref == iid -> ok iid
          _ -> bad "No such image"
      ["info", "--format", "{{json .}}"] ->
        pure (ok "{\"DockerRootDir\":\"/nonexistent-docker-root\",\"DriverStatus\":[[\"driver-type\",\"io.containerd.snapshotter.v1\"]],\"Containerd\":{\"Address\":\"/var/run/docker/containerd/containerd.sock\"}}")
      "build" : _
        | fBuildOk fake -> do
            writeIORef (fImage fake) (Just (fNextId fake))
            pure (ok "")
        | otherwise -> pure (bad "emerge failed")
      "rmi" : _ -> pure (ok "")
      _ -> pure (bad ("unexpected docker " <> unwords args))
  _ -> pure (bad "unexpected command")
  where
    ok out = ProcessResult ExitSuccess out ""
    bad = ProcessResult (ExitFailure 1) ""

plenty :: DiskSpaceProbe
plenty = DiskSpaceProbe (\_ -> pure (Right (100 * 1024 * 1024 * 1024))) (\_ -> pure (Right 1))

tiny :: DiskSpaceProbe
tiny = DiskSpaceProbe (\_ -> pure (Right (1024 * 1024))) (\_ -> pure (Right 1))

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 11 1) 0

mkCfg :: FilePath -> Fake -> DiskSpaceProbe -> (Text -> IO (Either Text Text)) -> IORef [Text] -> SmokeImageConfig
mkCfg dir fake probe digest warns =
  SmokeImageConfig
    { sicRun = run fake,
      sicProbe = probe,
      sicCacheDir = dir,
      sicUname = "x86_64",
      sicGentooTree = "/tree",
      sicGentooCommit = "c0ffee",
      sicNow = pure (addUTCTime (10 * 24 * 3600) epoch),
      sicStage3Digest = digest,
      sicBaseCheckInterval = 3 * 24 * 3600,
      sicWarn = \w -> modifyIORef' warns (++ [w])
    }

registry :: Text -> Text -> IO (Either Text Text)
registry d _ = pure (Right d)

registryDown :: Text -> IO (Either Text Text)
registryDown _ = pure (Left "connection refused")

sidecar :: String -> Text -> Text -> Maybe UTCTime -> SmokeSidecar
sidecar iid gen digest lastCheck =
  SmokeSidecar
    { ssVersion = smokeSidecarSchemaVersion,
      ssId = T.pack iid,
      ssTag = T.pack smokeImageTag,
      ssGenerator = gen,
      ssStage3Digest = digest,
      ssTreeCommit = "old-commit",
      ssBuiltAt = epoch,
      ssLastBaseCheck = lastCheck
    }

writeSide :: FilePath -> SmokeSidecar -> IO ()
writeSide dir s = do
  createDirectoryIfMissing True dir
  BS.writeFile (smokeSidecarPath dir) (LBS.toStrict (encodeSmokeSidecar s))

readSide :: FilePath -> IO SmokeSidecar
readSide dir = do
  bs <- BS.readFile (smokeSidecarPath dir)
  either assertFailure pure (decodeSmokeSidecar bs)

builds :: Fake -> IO [[String]]
builds fake = filter (\a -> take 1 a == ["build"]) <$> readIORef (fCalls fake)

-- | A recent base check, so the registry is not consulted.
recent :: Maybe UTCTime
recent = Just (addUTCTime (9 * 24 * 3600) epoch)

withDir :: (FilePath -> IORef [Text] -> IO ()) -> IO ()
withDir k = withSystemTempDirectory "om-smoke-image" $ \tmp -> newIORef [] >>= k (tmp </> "smoke")

testFirstBuild :: IO ()
testFirstBuild = withDir $ \dir warns -> do
  fake <- newFake Nothing True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns)
  assertEq "built" (Right SmokeImageBuilt) got
  side <- readSide dir
  assertEq "id" "sha256:new" (ssId side)
  assertEq "digest" "sha256:d1" (ssStage3Digest side)
  assertEq "generator" smokeGeneratorId (ssGenerator side)
  assertEq "tree commit" "c0ffee" (ssTreeCommit side)
  df <- doesFileExist (dir </> "Dockerfile")
  assertTrue "recipe kept" df
  bs <- builds fake
  case bs of
    [b] -> do
      assertTrue "tag" ("-t" `elem` b && smokeImageTag `elem` b)
      assertTrue "gentoo context" ("gentoo=/tree" `elem` b)
      assertTrue "no overlay context" (not (any ("overlay=" `isPrefixOf`) b))
    other -> assertFailure ("expected one build, got " <> show other)

testReuse :: IO ()
testReuse = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" smokeGeneratorId "sha256:d1" recent)
  fake <- newFake (Just "sha256:cur") True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d2") warns)
  assertEq "reused" (Right SmokeImageReused) got
  bs <- builds fake
  assertEq "no build" [] bs

testTreeMoved :: IO ()
testTreeMoved = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" smokeGeneratorId "sha256:d1" recent)
  fake <- newFake (Just "sha256:cur") True
  -- The config's tree commit is c0ffee; the sidecar's is old-commit.
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns)
  assertEq "reused" (Right SmokeImageReused) got
  bs <- builds fake
  assertEq "no build" [] bs

testGeneratorMismatch :: IO ()
testGeneratorMismatch = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" "mndz-overlay-manager-smoke-0" "sha256:d1" recent)
  fake <- newFake (Just "sha256:cur") True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns)
  assertEq "built" (Right SmokeImageBuilt) got
  calls <- readIORef (fCalls fake)
  assertTrue "previous image removed" (["rmi", "sha256:cur"] `elem` calls)
  assertTrue "never prunes the build cache" (not (any (\a -> "builder" `elem` a || "prune" `elem` a) calls))

testMissingImage :: IO ()
testMissingImage = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:gone" smokeGeneratorId "sha256:d1" recent)
  fake <- newFake Nothing True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns)
  assertEq "built" (Right SmokeImageBuilt) got
  side <- readSide dir
  assertEq "keeps recorded digest" "sha256:d1" (ssStage3Digest side)

testNewerStage3 :: IO ()
testNewerStage3 = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" smokeGeneratorId "sha256:d1" (Just epoch))
  fake <- newFake (Just "sha256:cur") True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d2") warns)
  assertEq "built" (Right SmokeImageBuilt) got
  side <- readSide dir
  assertEq "new digest" "sha256:d2" (ssStage3Digest side)
  df <- T.pack <$> readFile (dir </> "Dockerfile")
  assertTrue "pinned to new digest" ("@sha256:d2" `T.isInfixOf` df)

testRegistryFailureKeeps :: IO ()
testRegistryFailureKeeps = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" smokeGeneratorId "sha256:d1" (Just epoch))
  fake <- newFake (Just "sha256:cur") True
  got <- ensureSmokeImage (mkCfg dir fake plenty registryDown warns)
  assertEq "reused" (Right SmokeImageReused) got
  ws <- readIORef warns
  assertTrue "warned" (any ("smoke image" `T.isInfixOf`) ws)
  side <- readSide dir
  assertEq "check stays due" (Just epoch) (ssLastBaseCheck side)

testRegistryFailureNoImage :: IO ()
testRegistryFailureNoImage = withDir $ \dir warns -> do
  fake <- newFake Nothing True
  got <- ensureSmokeImage (mkCfg dir fake plenty registryDown warns)
  err <- assertLeft "fails" got
  assertTrue "names registry" ("registry" `T.isInfixOf` err)
  bs <- builds fake
  assertEq "no build" [] bs

testBuildFailure :: IO ()
testBuildFailure = withDir $ \dir warns -> do
  fake <- newFake Nothing False
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns)
  err <- assertLeft "fails" got
  assertTrue "names cause" ("emerge failed" `T.isInfixOf` err)
  exists <- doesFileExist (smokeSidecarPath dir)
  assertTrue "no sidecar" (not exists)

testUnmappedArch :: IO ()
testUnmappedArch = withDir $ \dir warns -> do
  fake <- newFake Nothing True
  got <- ensureSmokeImage (mkCfg dir fake plenty (registry "sha256:d1") warns) {sicUname = "sparc64"}
  err <- assertLeft "fails" got
  assertTrue "names arch" ("sparc64" `T.isInfixOf` err)

testDiskGate :: IO ()
testDiskGate = withDir $ \dir warns -> do
  fake <- newFake Nothing True
  got <- ensureSmokeImage (mkCfg dir fake tiny (registry "sha256:d1") warns)
  err <- assertLeft "fails" got
  assertTrue "names free and need" ("free:" `T.isInfixOf` err && "need:" `T.isInfixOf` err)
  assertTrue "names smoke image" ("smoke image" `T.isInfixOf` err)
  bs <- builds fake
  assertEq "no build" [] bs

testSameDigestRecords :: IO ()
testSameDigestRecords = withDir $ \dir warns -> do
  writeSide dir (sidecar "sha256:cur" smokeGeneratorId "sha256:d1" (Just epoch))
  fake <- newFake (Just "sha256:cur") True
  let cfg = mkCfg dir fake tiny (registry "sha256:d1") warns
  got <- ensureSmokeImage cfg
  assertEq "reused despite small disk" (Right SmokeImageReused) got
  now <- sicNow cfg
  side <- readSide dir
  assertEq "check time recorded" (Just now) (ssLastBaseCheck side)

testCacheDir :: IO ()
testCacheDir = do
  assertEq "xdg" "/x/mndz/overlay-manager/smoke" (smokeCacheDirFromEnv (Just "/x") "/home/u")
  assertEq "home" "/home/u/.cache/mndz/overlay-manager/smoke" (smokeCacheDirFromEnv (Just "") "/home/u")

testDockerVersion :: IO ()
testDockerVersion = do
  case checkDockerVersion "27.5.1" of
    Left err -> assertTrue "names 28.0" ("28.0" `T.isInfixOf` err)
    Right () -> assertFailure "27.5.1 should be rejected"
  assertEq "28.0.0" (Right ()) (checkDockerVersion "28.0.0\n")
  assertEq "29.8.1" (Right ()) (checkDockerVersion "29.8.1")
  assertEq "suffix" (Right ()) (checkDockerVersion "28.1.1-ce")
  assertTrue "garbage" (either (const True) (const False) (checkDockerVersion "unknown"))

testClassicDriver :: IO ()
testClassicDriver = do
  case checkImageStore (DockerInfoFacts "/var/lib/docker" False Nothing) of
    Left err -> assertTrue "names containerd image store" ("containerd image store" `T.isInfixOf` err)
    Right () -> assertFailure "classic driver should be rejected"
  assertEq "snapshotter" (Right ()) (checkImageStore (DockerInfoFacts "/var/lib/docker" True Nothing))

testPreflightOrder :: IO ()
testPreflightOrder = do
  let found t = pure (if t == "gpg" then Nothing else Just ("/usr/bin/" <> t))
  calls <- newIORef []
  let runner info req = do
        modifyIORef' calls (++ [prMode req])
        pure $ case prMode req of
          ExecCmd "git" _ -> ProcessResult ExitSuccess "true\n" ""
          ExecCmd "docker" ("version" : _) -> ProcessResult ExitSuccess "29.8.1\n" ""
          ExecCmd "docker" ("info" : _) -> ProcessResult ExitSuccess info ""
          _ -> ProcessResult (ExitFailure 1) "" ""
      classic = "{\"DockerRootDir\":\"/var/lib/docker\",\"DriverStatus\":[[\"Backing Filesystem\",\"extfs\"]]}"
  missingGpg <- smokePreflight found (runner classic) "/ov"
  case missingGpg of
    Left err -> assertTrue "names gpg" ("gpg" `T.isInfixOf` err)
    Right () -> assertFailure "missing gpg should fail"
  before <- readIORef calls
  assertEq "no process before tools pass" [] before
  classicRes <- smokePreflight (pure . Just) (runner classic) "/ov"
  case classicRes of
    Left err -> assertTrue "image store" ("containerd image store" `T.isInfixOf` err)
    Right () -> assertFailure "classic store should fail"
