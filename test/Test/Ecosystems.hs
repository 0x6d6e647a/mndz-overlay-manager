{-# LANGUAGE OverloadedStrings #-}

-- | Unit (and light Integration) coverage for npm / bun / cargo DepsAndAssets
-- builders via injectable Ops — no live registry or GitHub network.
module Test.Ecosystems (unitTests, integrationTests) where

import Control.Concurrent.MVar (newMVar)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Support
  ( mkTestApplyEnv,
    unusedReleaseOps,
    unusedVendorOps,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply (ApplyEnv (..))
import Update.Bun.Cache
  ( BunCacheOps (..),
    BunCacheProgress (..),
    buildBunDepsTarball,
    bunVersionTooOldMessage,
    hostMeetsBunRequirement,
    parseEnginesBunFromPackageJson,
  )
import Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    buildCargoCratesTarball,
    crateTarballPrefix,
    maxRustVersionInTree,
  )
import Update.Git (GitOps (..))
import Update.Go.Plan (PlanOps (..))
import Update.Npm.Cache
  ( NpmCacheOps (..),
    NpmCacheProgress (..),
    buildNpmDepsTarball,
    hostMeetsNodeRequirement,
    nodeVersionTooOldMessage,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "Ecosystems"
    [ testGroup
        "npm pure"
        [ testCase "hostMeetsNodeRequirement" testHostMeetsNodeRequirement,
          testCase "nodeVersionTooOldMessage" testNodeVersionTooOldMessage
        ],
      testGroup
        "bun pure"
        [ testCase "parseEnginesBunFromPackageJson" testParseEnginesBun,
          testCase "hostMeetsBunRequirement" testHostMeetsBunRequirement,
          testCase "bunVersionTooOldMessage" testBunVersionTooOldMessage
        ],
      testGroup
        "cargo pure"
        [ testCase "crateTarballPrefix" testCrateTarballPrefix,
          testCase "maxRustVersionInTree" testMaxRustVersionInTree
        ],
      testGroup
        "npm builder"
        [ testCase "buildNpmDepsTarball success + progress" testNpmBuilderSuccess,
          testCase "buildNpmDepsTarball host too old" testNpmBuilderHostTooOld,
          testCase "buildNpmDepsTarball pack failure" testNpmBuilderPackFail
        ],
      testGroup
        "bun builder"
        [ testCase "buildBunDepsTarball success + progress" testBunBuilderSuccess,
          testCase "buildBunDepsTarball host too old" testBunBuilderHostTooOld,
          testCase "buildBunDepsTarball missing lock" testBunBuilderMissingLock,
          testCase "buildBunDepsTarball install failure" testBunBuilderInstallFail
        ],
      testGroup
        "cargo builder"
        [ testCase "buildCargoCratesTarball success + progress" testCargoBuilderSuccess,
          testCase "buildCargoCratesTarball clone failure" testCargoBuilderCloneFail,
          testCase "buildCargoCratesTarball missing Cargo.lock" testCargoBuilderMissingLock,
          testCase "buildCargoCratesTarball pycargo failure" testCargoBuilderPycargoFail
        ]
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "Ecosystems"
    [ testCase "ApplyEnv carries injectable eco ops" testApplyEnvFakeEcoOps
    ]

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

testHostMeetsNodeRequirement :: IO ()
testHostMeetsNodeRequirement = do
  assertEq "equal ok" (Just True) (hostMeetsNodeRequirement "20.19.0" "20.19.0")
  assertEq "newer ok" (Just True) (hostMeetsNodeRequirement "22.0.0" "20.19.0")
  assertEq "older fail" (Just False) (hostMeetsNodeRequirement "18.0.0" "20.19.0")
  assertEq "garbage" Nothing (hostMeetsNodeRequirement "not-a-ver" "20.19.0")

testNodeVersionTooOldMessage :: IO ()
testNodeVersionTooOldMessage = do
  let msg = nodeVersionTooOldMessage "18.0.0" "20.19.0"
  assertTrue "names host" ("18.0.0" `T.isInfixOf` msg)
  assertTrue "names required" ("20.19.0" `T.isInfixOf` msg)
  assertTrue "mentions Node" ("Node" `T.isInfixOf` msg)

testParseEnginesBun :: IO ()
testParseEnginesBun = do
  assertEq
    "bare engines.bun"
    (Just "1.2.3")
    (parseEnginesBunFromPackageJson "{\"engines\":{\"bun\":\"1.2.3\"}}")
  assertEq
    ">= engines.bun"
    (Just "1.2.3")
    (parseEnginesBunFromPackageJson "{\"engines\":{\"bun\":\">=1.2.3\"}}")
  assertEq
    "missing engines"
    Nothing
    (parseEnginesBunFromPackageJson "{\"name\":\"x\"}")
  assertEq
    "invalid json"
    Nothing
    (parseEnginesBunFromPackageJson "not-json")
  assertEq
    "complex range rejected"
    Nothing
    (parseEnginesBunFromPackageJson "{\"engines\":{\"bun\":\"^1.2.3\"}}")

testHostMeetsBunRequirement :: IO ()
testHostMeetsBunRequirement = do
  assertEq "equal ok" (Just True) (hostMeetsBunRequirement "1.2.3" "1.2.3")
  assertEq "newer ok" (Just True) (hostMeetsBunRequirement "1.3.0" "1.2.3")
  assertEq "older fail" (Just False) (hostMeetsBunRequirement "1.0.0" "1.2.3")
  assertEq "garbage" Nothing (hostMeetsBunRequirement "x" "1.2.3")

testBunVersionTooOldMessage :: IO ()
testBunVersionTooOldMessage = do
  let msg = bunVersionTooOldMessage "1.0.0" "1.2.3"
  assertTrue "names host" ("1.0.0" `T.isInfixOf` msg)
  assertTrue "names required" ("1.2.3" `T.isInfixOf` msg)
  assertTrue "mentions Bun" ("Bun" `T.isInfixOf` msg)

testCrateTarballPrefix :: IO ()
testCrateTarballPrefix =
  assertEq "cargo.eclass prefix" "cargo_home/gentoo" crateTarballPrefix

testMaxRustVersionInTree :: IO ()
testMaxRustVersionInTree =
  withSystemTempDirectory "mndz-cargo-tree-" $ \root -> do
    createDirectoryIfMissing True (root </> "sub")
    TIO.writeFile
      (root </> "Cargo.toml")
      "[package]\nname = \"root\"\nrust-version = \"1.80\"\n"
    TIO.writeFile
      (root </> "sub" </> "Cargo.toml")
      "[package]\nname = \"sub\"\nrust-version = \"1.88.0\"\n"
    -- skip noise dirs
    createDirectoryIfMissing True (root </> "target")
    TIO.writeFile
      (root </> "target" </> "Cargo.toml")
      "[package]\nrust-version = \"9.9.9\"\n"
    m <- maxRustVersionInTree root
    assertEq "max across tree (skips target)" (Just "1.88.0") m
    emptyM <- maxRustVersionInTree (root </> "missing")
    assertEq "missing root" Nothing emptyM

------------------------------------------------------------------------
-- Progress helpers
------------------------------------------------------------------------

noopNpmProgress :: NpmCacheProgress
noopNpmProgress =
  NpmCacheProgress
    { ncpOnPackStart = pure (),
      ncpOnPackDone = pure (),
      ncpOnInstallStart = pure (),
      ncpOnInstallDone = pure (),
      ncpOnCompressStart = pure (),
      ncpOnCompressDone = pure ()
    }

noopBunProgress :: BunCacheProgress
noopBunProgress =
  BunCacheProgress
    { bcpOnCloneStart = pure (),
      bcpOnCloneDone = pure (),
      bcpOnInstallStart = pure (),
      bcpOnInstallDone = pure (),
      bcpOnCompressStart = pure (),
      bcpOnCompressDone = pure ()
    }

noopCargoProgress :: CargoProgress
noopCargoProgress =
  CargoProgress
    { cgpOnCloneStart = pure (),
      cgpOnCloneDone = pure (),
      cgpOnPycargoStart = pure (),
      cgpOnPycargoDone = pure ()
    }

------------------------------------------------------------------------
-- npm builders
------------------------------------------------------------------------

fakeNpmSuccessOps :: NpmCacheOps
fakeNpmSuccessOps =
  NpmCacheOps
    { ncoHostNodeVersion = pure (Right "20.19.0"),
      ncoNpmPack = \_pkg _pv workDir -> do
        let tgz = workDir </> "pkg.tgz"
        writeFile tgz "packed"
        pure (Right tgz),
      ncoNpmInstallCache = \_tgz _cache -> pure (Right ()),
      ncoTarXz = \_work _entry outPath -> do
        writeFile outPath "npm-cache-tarball"
        pure (Right ())
    }

testNpmBuilderSuccess :: IO ()
testNpmBuilderSuccess =
  withSystemTempDirectory "mndz-npm-ok-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        progress =
          NpmCacheProgress
            { ncpOnPackStart = logEv "pack-start",
              ncpOnPackDone = logEv "pack-done",
              ncpOnInstallStart = logEv "install-start",
              ncpOnInstallDone = logEv "install-done",
              ncpOnCompressStart = logEv "compress-start",
              ncpOnCompressDone = logEv "compress-done"
            }
    path <-
      assertRight "npm success"
        =<< buildNpmDepsTarball
          fakeNpmSuccessOps
          progress
          "left-pad"
          "1.0.0"
          "18.0.0"
          outDir
          "left-pad-1.0.0-npm-cache.tar.xz"
    assertEq "out path" (outDir </> "left-pad-1.0.0-npm-cache.tar.xz") path
    exists <- doesFileExist path
    assertTrue "tarball written" exists
    evs <- reverse <$> readIORef events
    assertEq
      "npm progress order"
      [ "pack-start",
        "pack-done",
        "install-start",
        "install-done",
        "compress-start",
        "compress-done"
      ]
      evs
    -- noop progress still succeeds
    void $
      assertRight "noop progress"
        =<< buildNpmDepsTarball
          fakeNpmSuccessOps
          noopNpmProgress
          "left-pad"
          "1.0.0"
          "18.0.0"
          outDir
          "left-pad-1.0.0-npm-cache-noop.tar.xz"

testNpmBuilderHostTooOld :: IO ()
testNpmBuilderHostTooOld = do
  packCalls <- newIORef (0 :: Int)
  let ops =
        fakeNpmSuccessOps
          { ncoHostNodeVersion = pure (Right "16.0.0"),
            ncoNpmPack = \_ _ _ -> do
              atomicModifyIORef' packCalls (\n -> (n + 1, ()))
              pure (Left "should not pack")
          }
  err <-
    assertLeft "host too old"
      =<< buildNpmDepsTarball
        ops
        noopNpmProgress
        "pkg"
        "1.0.0"
        "20.19.0"
        "/tmp"
        "x.tar.xz"
  assertTrue "mentions host" ("16.0.0" `T.isInfixOf` err)
  assertTrue "mentions required" ("20.19.0" `T.isInfixOf` err)
  n <- readIORef packCalls
  assertEq "pack not called" 0 n

testNpmBuilderPackFail :: IO ()
testNpmBuilderPackFail = do
  let ops =
        fakeNpmSuccessOps
          { ncoNpmPack = \_ _ _ -> pure (Left "npm pack failed: boom")
          }
  err <-
    assertLeft "pack fail"
      =<< buildNpmDepsTarball
        ops
        noopNpmProgress
        "pkg"
        "1.0.0"
        "18.0.0"
        "/tmp"
        "x.tar.xz"
  assertTrue "error bubbled" ("boom" `T.isInfixOf` err)

------------------------------------------------------------------------
-- bun builders
------------------------------------------------------------------------

fakeBunSuccessOps :: BunCacheOps
fakeBunSuccessOps =
  BunCacheOps
    { bcoClone = \_url _tag dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "bun.lock") "{}"
        pure (Right ()),
      bcoHostBunVersion = pure (Right "1.2.3"),
      bcoBunInstall = \_clone _cache -> pure (Right ()),
      bcoTarXz = \_work _entry outPath -> do
        writeFile outPath "bun-cache-tarball"
        pure (Right ())
    }

testBunBuilderSuccess :: IO ()
testBunBuilderSuccess =
  withSystemTempDirectory "mndz-bun-ok-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        progress =
          BunCacheProgress
            { bcpOnCloneStart = logEv "clone-start",
              bcpOnCloneDone = logEv "clone-done",
              bcpOnInstallStart = logEv "install-start",
              bcpOnInstallDone = logEv "install-done",
              bcpOnCompressStart = logEv "compress-start",
              bcpOnCompressDone = logEv "compress-done"
            }
    path <-
      assertRight "bun success"
        =<< buildBunDepsTarball
          fakeBunSuccessOps
          progress
          "owner"
          "repo"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          "repo-0.1.0-bun-cache.tar.xz"
    assertEq "out path" (outDir </> "repo-0.1.0-bun-cache.tar.xz") path
    exists <- doesFileExist path
    assertTrue "tarball written" exists
    evs <- reverse <$> readIORef events
    assertEq
      "bun progress order"
      [ "clone-start",
        "clone-done",
        "install-start",
        "install-done",
        "compress-start",
        "compress-done"
      ]
      evs
    void $
      assertRight "noop progress"
        =<< buildBunDepsTarball
          fakeBunSuccessOps
          noopBunProgress
          "owner"
          "repo"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          "repo-0.1.0-bun-cache-noop.tar.xz"

testBunBuilderHostTooOld :: IO ()
testBunBuilderHostTooOld = do
  cloneCalls <- newIORef (0 :: Int)
  let ops =
        fakeBunSuccessOps
          { bcoHostBunVersion = pure (Right "0.9.0"),
            bcoClone = \_ _ _ -> do
              atomicModifyIORef' cloneCalls (\n -> (n + 1, ()))
              pure (Left "should not clone")
          }
  err <-
    assertLeft "host too old"
      =<< buildBunDepsTarball
        ops
        noopBunProgress
        "o"
        "r"
        "v"
        "0.1.0"
        "1.2.3"
        "/tmp"
        "x.tar.xz"
  assertTrue "names host" ("0.9.0" `T.isInfixOf` err)
  assertTrue "names required" ("1.2.3" `T.isInfixOf` err)
  n <- readIORef cloneCalls
  assertEq "clone not called" 0 n

testBunBuilderMissingLock :: IO ()
testBunBuilderMissingLock = do
  let ops =
        fakeBunSuccessOps
          { bcoClone = \_ _ dest -> do
              createDirectoryIfMissing True dest
              -- no bun.lock
              pure (Right ())
          }
  err <-
    assertLeft "missing lock"
      =<< buildBunDepsTarball
        ops
        noopBunProgress
        "o"
        "r"
        "v"
        "0.1.0"
        "1.0.0"
        "/tmp"
        "x.tar.xz"
  assertTrue "mentions bun.lock" ("bun.lock" `T.isInfixOf` err)

testBunBuilderInstallFail :: IO ()
testBunBuilderInstallFail = do
  let ops =
        fakeBunSuccessOps
          { bcoBunInstall = \_ _ -> pure (Left "bun install failed: offline")
          }
  err <-
    assertLeft "install fail"
      =<< buildBunDepsTarball
        ops
        noopBunProgress
        "o"
        "r"
        "v"
        "0.1.0"
        "1.0.0"
        "/tmp"
        "x.tar.xz"
  assertTrue "error bubbled" ("offline" `T.isInfixOf` err)

------------------------------------------------------------------------
-- cargo builders
------------------------------------------------------------------------

donorEbuild :: T.Text
donorEbuild =
  T.unlines
    [ "EAPI=8",
      "inherit cargo",
      "RUST_MIN_VER=\"1.80.0\"",
      "DESCRIPTION=\"test\""
    ]

fakeCargoSuccessOps :: CargoOps
fakeCargoSuccessOps =
  CargoOps
    { coClone = \_url _tag dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "Cargo.lock") "# lock\n"
        TIO.writeFile
          (dest </> "Cargo.toml")
          "[package]\nname = \"pkg\"\nrust-version = \"1.85.0\"\n"
        pure (Right ()),
      coPycargoebuild = \ebuildPath _lockRoot outPath _dist -> do
        -- Simulate inplace ebuild update + crate tarball emit.
        TIO.writeFile ebuildPath (donorEbuild <> "\n# pycargoebuild\n")
        writeFile outPath "crates-tarball"
        pure (Right ())
    }

testCargoBuilderSuccess :: IO ()
testCargoBuilderSuccess =
  withSystemTempDirectory "mndz-cargo-ok-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        progress =
          CargoProgress
            { cgpOnCloneStart = logEv "clone-start",
              cgpOnCloneDone = logEv "clone-done",
              cgpOnPycargoStart = logEv "pycargo-start",
              cgpOnPycargoDone = logEv "pycargo-done"
            }
    res <-
      assertRight "cargo success"
        =<< buildCargoCratesTarball
          fakeCargoSuccessOps
          progress
          "owner"
          "repo"
          "v"
          "0.1.0"
          Nothing
          Nothing
          donorEbuild
          "pkg"
          outDir
          "pkg-0.1.0-crates.tar.xz"
    assertEq
      "tarball path"
      (outDir </> "pkg-0.1.0-crates.tar.xz")
      (crTarballPath res)
    exists <- doesFileExist (crTarballPath res)
    assertTrue "tarball written" exists
    assertEq "msrv from package.rust-version" "1.85.0" (crMsrv res)
    assertTrue "ebuild body updated" ("pycargoebuild" `T.isInfixOf` crEbuildBody res)
    evs <- reverse <$> readIORef events
    assertEq
      "cargo progress order"
      [ "clone-start",
        "clone-done",
        "pycargo-start",
        "pycargo-done"
      ]
      evs
    void $
      assertRight "noop progress"
        =<< buildCargoCratesTarball
          fakeCargoSuccessOps
          noopCargoProgress
          "owner"
          "repo"
          "v"
          "0.1.0"
          Nothing
          Nothing
          donorEbuild
          "pkg"
          outDir
          "pkg-0.1.0-crates-noop.tar.xz"

testCargoBuilderCloneFail :: IO ()
testCargoBuilderCloneFail = do
  let ops =
        CargoOps
          { coClone = \_ _ _ -> pure (Left "git clone failed: offline"),
            coPycargoebuild = \_ _ _ _ -> pure (Left "should not run")
          }
  result <-
    buildCargoCratesTarball
      ops
      noopCargoProgress
      "o"
      "r"
      "v"
      "0.1.0"
      Nothing
      Nothing
      donorEbuild
      "pkg"
      "/tmp"
      "x.tar.xz"
  case result of
    Left err -> assertTrue "error bubbled" ("offline" `T.isInfixOf` err)
    Right _ -> fail "expected clone failure"

testCargoBuilderMissingLock :: IO ()
testCargoBuilderMissingLock = do
  let ops =
        CargoOps
          { coClone = \_ _ dest -> do
              createDirectoryIfMissing True dest
              pure (Right ()),
            coPycargoebuild = \_ _ _ _ -> pure (Left "should not run")
          }
  result <-
    buildCargoCratesTarball
      ops
      noopCargoProgress
      "o"
      "r"
      "v"
      "0.1.0"
      Nothing
      Nothing
      donorEbuild
      "pkg"
      "/tmp"
      "x.tar.xz"
  case result of
    Left err -> assertTrue "mentions Cargo.lock" ("Cargo.lock" `T.isInfixOf` err)
    Right _ -> fail "expected missing Cargo.lock failure"

testCargoBuilderPycargoFail :: IO ()
testCargoBuilderPycargoFail = do
  let ops =
        fakeCargoSuccessOps
          { coPycargoebuild = \_ _ _ _ -> pure (Left "pycargoebuild failed: boom")
          }
  result <-
    buildCargoCratesTarball
      ops
      noopCargoProgress
      "o"
      "r"
      "v"
      "0.1.0"
      Nothing
      Nothing
      donorEbuild
      "pkg"
      "/tmp"
      "x.tar.xz"
  case result of
    Left err -> assertTrue "error bubbled" ("boom" `T.isInfixOf` err)
    Right _ -> fail "expected pycargoebuild failure"

------------------------------------------------------------------------
-- Light Integration: ApplyEnv eco ops wiring (not full Materialize)
------------------------------------------------------------------------

testApplyEnvFakeEcoOps :: IO ()
testApplyEnvFakeEcoOps =
  withSystemTempDirectory "mndz-eco-env-" $ \tmp -> do
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Left "unused"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    let env =
          env0
            { aeNpmCacheOps = fakeNpmSuccessOps,
              aeBunCacheOps = fakeBunSuccessOps,
              aeCargoOps = fakeCargoSuccessOps
            }
        outDir = tmp </> "out"
    createDirectoryIfMissing True outDir
    -- Drive builders only through ApplyEnv fields (Wave 4 does full apply).
    npmPath <-
      assertRight "env npm"
        =<< buildNpmDepsTarball
          (aeNpmCacheOps env)
          noopNpmProgress
          "pkg"
          "1.0.0"
          "18.0.0"
          outDir
          "pkg-npm.tar.xz"
    bunPath <-
      assertRight "env bun"
        =<< buildBunDepsTarball
          (aeBunCacheOps env)
          noopBunProgress
          "o"
          "r"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          "pkg-bun.tar.xz"
    cargoRes <-
      assertRight "env cargo"
        =<< buildCargoCratesTarball
          (aeCargoOps env)
          noopCargoProgress
          "o"
          "r"
          "v"
          "0.1.0"
          Nothing
          Nothing
          donorEbuild
          "pkg"
          outDir
          "pkg-crates.tar.xz"
    assertTrue "npm via env" =<< doesFileExist npmPath
    assertTrue "bun via env" =<< doesFileExist bunPath
    assertTrue "cargo via env" =<< doesFileExist (crTarballPath cargoRes)
