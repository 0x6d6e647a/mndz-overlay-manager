{-# LANGUAGE OverloadedStrings #-}

-- | Unit (and light Integration) coverage for npm / bun / cargo DepsAndAssets
-- builders via injectable Ops — no live registry or GitHub network.
module Test.Ecosystems (unitTests, integrationTests) where

import Control.Concurrent.MVar (newMVar)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    createFileLink,
    doesFileExist,
    getSymbolicLinkTarget,
    pathIsSymbolicLink,
  )
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Support
  ( mkTestApplyEnv,
    unusedReleaseOps,
    unusedVendorOps,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply (ApplyEnv (..), mkEbuildRunner)
import Update.Bun.Cache
  ( BunCacheOps (..),
    BunCacheProgress (..),
    BunPackagingMode (..),
    buildBunDepsTarball,
    bunPackagingModeFor,
    bunVersionTooOldMessage,
    collectInstallTreeEntries,
    hostMeetsBunRequirement,
    mkBunCacheOps,
    parseEnginesBunFromPackageJson,
    rewriteBunCacheSymlinks,
  )
import Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    RegistryPackage (..),
    buildCargoCratesTarball,
    cargoChecksumJson,
    crateTarballPrefix,
    maxRustVersionInTree,
    mkCargoOps,
    packCratesTarball,
    parseRegistryPackages,
  )
import Update.Git (GitOps (..))
import Update.Go.Plan (PlanOps (..))
import Update.Go.Vendor
  ( VendorResult (..),
    buildVendorTarball,
    mkVendorOps,
    noopVendorProgress,
  )
import Update.Md5Cache
  ( EgencacheRequest (..),
    mkEgencacheRunner,
  )
import Update.Npm.Cache
  ( NpmCacheOps (..),
    NpmCacheProgress (..),
    buildNpmDepsTarball,
    hostMeetsNodeRequirement,
    mkNpmCacheOps,
    nodeVersionTooOldMessage,
    prepareNpmCacheForPack,
  )
import Update.Pack.XzTar
  ( hermeticTarArgs,
    isXzMagic,
    packTarXz,
    packTarXzAtomic,
    verifyXzFile,
    xzMagicPrefix,
    xzOptValue,
  )
import Update.Process
  ( ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Process.Docker
  ( MaterializeDockerCfg (..),
    defaultMaterializeImage,
    materializeBuilderHome,
    wrapMaterializeRequest,
  )
import Update.Runtime.Ceilings (gentooRepoPath, mkPortageqRunner)
import Update.Sbcl.Deps
  ( SbclDepsOps (..),
    SbclDepsProgress (..),
    buildSbclDepsTarball,
    parseSbclVersionFloor,
    sanitizeQlotConfs,
  )
import Update.Types (PackageKey (..))

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
          testCase "bunVersionTooOldMessage" testBunVersionTooOldMessage,
          testCase "bunPackagingModeFor opencode vs others" testBunPackagingModeFor,
          testCase "collectInstallTreeEntries finds node_modules" testCollectInstallTreeEntries
        ],
      testGroup
        "cargo pure"
        [ testCase "crateTarballPrefix" testCrateTarballPrefix,
          testCase "maxRustVersionInTree" testMaxRustVersionInTree,
          testCase "parseRegistryPackages fixtures" testParseRegistryPackages,
          testCase "cargoChecksumJson shape" testCargoChecksumJson
        ],
      testGroup
        "sbcl pure"
        [ testCase "parseSbclVersionFloor" testParseSbclVersionFloor,
          testCase "buildSbclDepsTarball success + progress" testSbclBuilderSuccess,
          testCase "buildSbclDepsTarball clone failure" testSbclBuilderCloneFail,
          testCase "sanitizeQlotConfs rewrites operator home" testSanitizeQlotConfs
        ],
      testGroup
        "npm builder"
        [ testCase "buildNpmDepsTarball success + progress" testNpmBuilderSuccess,
          testCase "buildNpmDepsTarball host too old" testNpmBuilderHostTooOld,
          testCase "buildNpmDepsTarball pack failure" testNpmBuilderPackFail,
          testCase "npm pack omits _logs and _update-notifier" testNpmPackOmitsLogs
        ],
      testGroup
        "bun builder"
        [ testCase "buildBunDepsTarball BunCache success + progress" testBunBuilderSuccess,
          testCase "buildBunDepsTarball InstallTree packs node_modules" testBunBuilderInstallTree,
          testCase "buildBunDepsTarball InstallTree empty tree fails" testBunBuilderInstallTreeEmpty,
          testCase "buildBunDepsTarball host too old" testBunBuilderHostTooOld,
          testCase "buildBunDepsTarball missing lock" testBunBuilderMissingLock,
          testCase "buildBunDepsTarball install failure" testBunBuilderInstallFail,
          testCase "BunCache rewrite unscoped and scoped alias symlinks" testBunCacheRewriteSymlinks,
          testCase "BunCache leftover absolute symlink hard-fails" testBunCacheAbsoluteLeftover
        ],
      testGroup
        "cargo builder"
        [ testCase "buildCargoCratesTarball success + progress" testCargoBuilderSuccess,
          testCase "buildCargoCratesTarball clone failure" testCargoBuilderCloneFail,
          testCase "buildCargoCratesTarball missing Cargo.lock" testCargoBuilderMissingLock,
          testCase "buildCargoCratesTarball pycargo failure" testCargoBuilderPycargoFail,
          testCase "buildCargoCratesTarball pack failure" testCargoBuilderPackFail,
          testCase "packCratesTarball tiny fixture" testPackCratesTarballFixture,
          testCase "packCratesTarball missing crate" testPackCratesTarballMissingCrate,
          testCase "packCratesTarball records XZ_OPT and -J / .xz temp" testPackCratesTarballXzArgv
        ],
      testGroup
        "xz pack helpers"
        [ testCase "verifyXzFile rejects plain tar, accepts xz magic" testVerifyXzFile,
          testCase "packTarXzAtomic temp path is not bare .tmp" testPackTarXzAtomicTempSuffix,
          testCase "packTarXz hermetic owners and XZ_OPT -T1 -9e" testPackTarXzHermetic
        ],
      testGroup
        "production CommandRunner adapters"
        [ testCase "npm mk path success + failure" testNpmMkCommandRunner,
          testCase "bun mk path success + failure" testBunMkCommandRunner,
          testCase "vendor mk path success + failure" testVendorMkCommandRunner,
          testCase "cargo mk path success + failure" testCargoMkCommandRunner,
          testCase "ebuild/egencache/portageq mk runners" testSimpleRunnersMk,
          testCase "docker wrap uses bind-mount HOME and strips secrets" testDockerWrapRequest
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
    "packageManager fallback"
    (Just "1.3.14")
    (parseEnginesBunFromPackageJson "{\"packageManager\":\"bun@1.3.14\"}")
  assertEq
    "packageManager with build metadata"
    (Just "1.3.14")
    (parseEnginesBunFromPackageJson "{\"packageManager\":\"bun@1.3.14+sha512.abc\"}")
  assertEq
    "engines.bun wins over packageManager"
    (Just "1.2.0")
    ( parseEnginesBunFromPackageJson
        "{\"engines\":{\"bun\":\">=1.2.0\"},\"packageManager\":\"bun@1.3.14\"}"
    )
  assertEq
    "missing both"
    Nothing
    (parseEnginesBunFromPackageJson "{\"name\":\"x\"}")
  assertEq
    "invalid json"
    Nothing
    (parseEnginesBunFromPackageJson "not-json")
  assertEq
    "complex range falls through without packageManager"
    Nothing
    (parseEnginesBunFromPackageJson "{\"engines\":{\"bun\":\"^1.2.3\"}}")
  assertEq
    "complex engines falls through to packageManager"
    (Just "1.3.14")
    ( parseEnginesBunFromPackageJson
        "{\"engines\":{\"bun\":\"^1.2.3\"},\"packageManager\":\"bun@1.3.14\"}"
    )

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

testBunPackagingModeFor :: IO ()
testBunPackagingModeFor = do
  assertEq
    "opencode is InstallTree"
    InstallTree
    (bunPackagingModeFor (PackageKey "dev-util/opencode"))
  assertEq
    "ralph-tui is BunCache"
    BunCache
    (bunPackagingModeFor (PackageKey "dev-util/ralph-tui"))
  assertEq
    "unknown bun package defaults to BunCache"
    BunCache
    (bunPackagingModeFor (PackageKey "dev-util/other-bun-pkg"))

testCollectInstallTreeEntries :: IO ()
testCollectInstallTreeEntries =
  withSystemTempDirectory "mndz-install-tree-" $ \root -> do
    createDirectoryIfMissing True (root </> "node_modules" </> "pkg")
    createDirectoryIfMissing
      True
      (root </> "packages" </> "opencode" </> "node_modules" </> "dep")
    -- Nested under node_modules must not appear as a separate entry.
    createDirectoryIfMissing
      True
      (root </> "node_modules" </> "pkg" </> "node_modules" </> "nested")
    entries <- collectInstallTreeEntries root
    assertEq
      "top-level install-tree members only"
      ["node_modules", "packages/opencode/node_modules"]
      entries
    createDirectoryIfMissing True (root </> "empty")
    emptyEntries <- collectInstallTreeEntries (root </> "empty")
    assertEq "no node_modules" ([] :: [FilePath]) emptyEntries

testCrateTarballPrefix :: IO ()
testCrateTarballPrefix =
  assertEq "cargo.eclass prefix" "cargo_home/gentoo" crateTarballPrefix

testParseSbclVersionFloor :: IO ()
testParseSbclVersionFloor = do
  assertEq "plain" (Just "2.6.4") (parseSbclVersionFloor "2.6.4")
  assertEq "trim" (Just "2.6.4") (parseSbclVersionFloor "  2.6.4\n")
  assertEq "empty" Nothing (parseSbclVersionFloor "")
  assertEq "garbage" Nothing (parseSbclVersionFloor "not-a-version")
  assertEq "v prefix rejected" Nothing (parseSbclVersionFloor "v2.6.4")

noopSbclProgress :: SbclDepsProgress
noopSbclProgress =
  SbclDepsProgress
    { sdpOnCloneStart = pure (),
      sdpOnCloneDone = pure (),
      sdpOnQlotStart = pure (),
      sdpOnQlotDone = pure (),
      sdpOnFffStart = pure (),
      sdpOnFffDone = pure (),
      sdpOnCompressStart = pure (),
      sdpOnCompressDone = pure ()
    }

fakeSbclSuccessOps :: FilePath -> SbclDepsOps
fakeSbclSuccessOps _tarballPath =
  SbclDepsOps
    { sdoClone = \_ _ dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "qlfile") "qlot\n"
        TIO.writeFile (dest </> "qlfile.lock") "lock\n"
        createDirectoryIfMissing True (dest </> "native" </> "fff")
        TIO.writeFile (dest </> "native" </> "fff" </> "commit") "abc\n"
        pure (Right ()),
      sdoQlotInstall = \_ _ _ -> pure (Right ()),
      sdoCopyQlot = \_ stage -> do
        createDirectoryIfMissing True (stage </> ".qlot")
        TIO.writeFile (stage </> ".qlot" </> "marker") "ok\n"
        pure (Right ()),
      sdoMaterializeFff = \_ stage -> do
        createDirectoryIfMissing True (stage </> "fff" </> "vendor")
        pure (Right ()),
      sdoPackTarball = \_ outPath -> do
        TIO.writeFile outPath "fake-deps-tarball\n"
        pure (Right ()),
      sdoQuicklispSetup = pure (Right "/tmp/quicklisp/setup.lisp")
    }

testSbclBuilderSuccess :: IO ()
testSbclBuilderSuccess =
  withSystemTempDirectory "mndz-sbcl-build-" $ \tmp -> do
    steps <- newIORef (0 :: Int)
    let progress =
          SbclDepsProgress
            { sdpOnCloneStart = pure (),
              sdpOnCloneDone = atomicModifyIORef' steps (\n -> (n + 1, ())),
              sdpOnQlotStart = pure (),
              sdpOnQlotDone = atomicModifyIORef' steps (\n -> (n + 1, ())),
              sdpOnFffStart = pure (),
              sdpOnFffDone = atomicModifyIORef' steps (\n -> (n + 1, ())),
              sdpOnCompressStart = pure (),
              sdpOnCompressDone = atomicModifyIORef' steps (\n -> (n + 1, ()))
            }
        outDir = tmp </> "out"
        name = "autolith-0.18.0-deps.tar.xz"
    path <-
      assertRight "sbcl build"
        =<< buildSbclDepsTarball
          (fakeSbclSuccessOps (outDir </> name))
          progress
          "luciusmagn"
          "autolith"
          "v"
          "0.18.0"
          outDir
          outDir
          name
    assertTrue "tarball exists" =<< doesFileExist path
    n <- readIORef steps
    assertEq "progress callbacks" 4 n

testSbclBuilderCloneFail :: IO ()
testSbclBuilderCloneFail =
  withSystemTempDirectory "mndz-sbcl-fail-" $ \tmp -> do
    let ops =
          (fakeSbclSuccessOps (tmp </> "x"))
            { sdoClone = \_ _ _ -> pure (Left "clone boom")
            }
    err <-
      assertLeft "clone fail"
        =<< buildSbclDepsTarball
          ops
          noopSbclProgress
          "o"
          "r"
          "v"
          "0.1.0"
          tmp
          tmp
          "x-deps.tar.xz"
    assertTrue "clone err" ("clone boom" `T.isInfixOf` err)

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

testParseRegistryPackages :: IO ()
testParseRegistryPackages = do
  let lock =
        T.unlines
          [ "# This file is automatically @generated by Cargo.",
            "version = 4",
            "",
            "[[package]]",
            "name = \"serde\"",
            "version = \"1.0.200\"",
            "source = \"registry+https://github.com/rust-lang/crates.io-index\"",
            "checksum = \"abc123\"",
            "dependencies = [",
            " \"serde_derive\",",
            "]",
            "",
            "[[package]]",
            "name = \"local-pkg\"",
            "version = \"0.1.0\"",
            "",
            "[[package]]",
            "name = \"git-dep\"",
            "version = \"0.2.0\"",
            "source = \"git+https://github.com/example/git-dep?rev=deadbeef\"",
            "",
            "[[package]]",
            "name = \"bytes\"",
            "version = \"1.6.0\"",
            "source = \"registry+https://github.com/rust-lang/crates.io-index\"",
            "checksum = \"def456\"",
            "",
            "[[package]]",
            "name = \"no-checksum\"",
            "version = \"1.0.0\"",
            "source = \"registry+https://github.com/rust-lang/crates.io-index\""
          ]
  case parseRegistryPackages lock of
    Left err -> assertTrue ("unexpected parse error: " <> T.unpack err) False
    Right pkgs -> do
      assertEq
        "two registry packages with checksums"
        [ RegistryPackage "serde" "1.0.200" "abc123",
          RegistryPackage "bytes" "1.6.0" "def456"
        ]
        pkgs
  case parseRegistryPackages "" of
    Left err -> assertTrue ("empty lock err: " <> T.unpack err) False
    Right pkgs -> assertEq "empty lock" [] pkgs

testCargoChecksumJson :: IO ()
testCargoChecksumJson =
  assertEq
    "checksum json"
    "{\"package\":\"abc123\",\"files\":{}}"
    (cargoChecksumJson "abc123")

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
      cgpOnPycargoDone = pure (),
      cgpOnPackStart = pure (),
      cgpOnPackDone = pure ()
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
          outDir
          "left-pad-1.0.0-npm-cache-noop.tar.xz"

testNpmBuilderHostTooOld :: IO ()
testNpmBuilderHostTooOld = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
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
        tmp
        tmp
        "x.tar.xz"
  assertTrue "mentions host" ("16.0.0" `T.isInfixOf` err)
  assertTrue "mentions required" ("20.19.0" `T.isInfixOf` err)
  n <- readIORef packCalls
  assertEq "pack not called" 0 n

testNpmBuilderPackFail :: IO ()
testNpmBuilderPackFail = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
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
        tmp
        tmp
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
      bcoTarXz = \_work _entries outPath -> do
        writeFile outPath "bun-cache-tarball"
        pure (Right ())
    }

-- | Clone + install that materializes a minimal install tree for InstallTree tests.
fakeBunInstallTreeOps :: IORef [(FilePath, [FilePath])] -> BunCacheOps
fakeBunInstallTreeOps tarCalls =
  BunCacheOps
    { bcoClone = \_url _tag dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "bun.lock") "{}"
        pure (Right ()),
      bcoHostBunVersion = pure (Right "1.2.3"),
      bcoBunInstall = \cloneDir _cache -> do
        createDirectoryIfMissing True (cloneDir </> "node_modules" </> "left-pad")
        createDirectoryIfMissing
          True
          (cloneDir </> "packages" </> "opencode" </> "node_modules" </> "dep")
        pure (Right ()),
      bcoTarXz = \work entries outPath -> do
        atomicModifyIORef' tarCalls (\cs -> ((work, entries) : cs, ()))
        writeFile outPath "install-tree-tarball"
        pure (Right ())
    }

testBunBuilderSuccess :: IO ()
testBunBuilderSuccess =
  withSystemTempDirectory "mndz-bun-ok-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    tarCalls <- newIORef ([] :: [(FilePath, [FilePath])])
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
        ops =
          fakeBunSuccessOps
            { bcoTarXz = \work entries outPath -> do
                atomicModifyIORef' tarCalls (\cs -> ((work, entries) : cs, ()))
                writeFile outPath "bun-cache-tarball"
                pure (Right ())
            }
    path <-
      assertRight "bun success"
        =<< buildBunDepsTarball
          ops
          progress
          BunCache
          "owner"
          "repo"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          outDir
          "repo-0.1.0-deps.tar.xz"
    assertEq "out path" (outDir </> "repo-0.1.0-deps.tar.xz") path
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
    calls <- readIORef tarCalls
    case calls of
      [(_work, entries)] ->
        assertEq "BunCache packs top-level bun-cache only" ["bun-cache"] entries
      other ->
        assertTrue ("expected one tar call, got " <> show other) False
    void $
      assertRight "noop progress"
        =<< buildBunDepsTarball
          fakeBunSuccessOps
          noopBunProgress
          BunCache
          "owner"
          "repo"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          outDir
          "repo-0.1.0-bun-cache-noop.tar.xz"

testBunBuilderInstallTree :: IO ()
testBunBuilderInstallTree =
  withSystemTempDirectory "mndz-bun-it-" $ \outDir -> do
    tarCalls <- newIORef ([] :: [(FilePath, [FilePath])])
    let ops = fakeBunInstallTreeOps tarCalls
    path <-
      assertRight "install-tree success"
        =<< buildBunDepsTarball
          ops
          noopBunProgress
          InstallTree
          "anomalyco"
          "opencode"
          "v"
          "1.18.5"
          "1.0.0"
          outDir
          outDir
          "opencode-1.18.5-deps.tar.xz"
    assertEq "out path" (outDir </> "opencode-1.18.5-deps.tar.xz") path
    exists <- doesFileExist path
    assertTrue "tarball written" exists
    calls <- readIORef tarCalls
    case calls of
      [(_work, entries)] -> do
        assertTrue "includes root node_modules" ("node_modules" `elem` entries)
        assertTrue
          "includes workspace node_modules"
          ("packages/opencode/node_modules" `elem` entries)
        assertTrue "does not pack bun-cache only" (entries /= ["bun-cache"])
      other ->
        assertTrue ("expected one tar call, got " <> show other) False

testBunBuilderInstallTreeEmpty :: IO ()
testBunBuilderInstallTreeEmpty = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  -- Install succeeds but creates no node_modules (pack must hard-fail).
  let ops =
        fakeBunSuccessOps
          { bcoBunInstall = \_ _ -> pure (Right ())
          }
  err <-
    assertLeft "empty install tree"
      =<< buildBunDepsTarball
        ops
        noopBunProgress
        InstallTree
        "o"
        "r"
        "v"
        "0.1.0"
        "1.0.0"
        tmp
        tmp
        "x.tar.xz"
  assertTrue "mentions node_modules" ("node_modules" `T.isInfixOf` err)

testBunBuilderHostTooOld :: IO ()
testBunBuilderHostTooOld = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
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
        BunCache
        "o"
        "r"
        "v"
        "0.1.0"
        "1.2.3"
        tmp
        tmp
        "x.tar.xz"
  assertTrue "names host" ("0.9.0" `T.isInfixOf` err)
  assertTrue "names required" ("1.2.3" `T.isInfixOf` err)
  n <- readIORef cloneCalls
  assertEq "clone not called" 0 n

testBunBuilderMissingLock :: IO ()
testBunBuilderMissingLock = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
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
        BunCache
        "o"
        "r"
        "v"
        "0.1.0"
        "1.0.0"
        tmp
        tmp
        "x.tar.xz"
  assertTrue "mentions bun.lock" ("bun.lock" `T.isInfixOf` err)

testBunBuilderInstallFail :: IO ()
testBunBuilderInstallFail = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  let ops =
        fakeBunSuccessOps
          { bcoBunInstall = \_ _ -> pure (Left "bun install failed: offline")
          }
  err <-
    assertLeft "install fail"
      =<< buildBunDepsTarball
        ops
        noopBunProgress
        BunCache
        "o"
        "r"
        "v"
        "0.1.0"
        "1.0.0"
        tmp
        tmp
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
      coPycargoebuild = \ebuildPath _lockRoot _outPath _dist -> do
        -- Simulate inplace ebuild update; pack step writes the tarball.
        TIO.writeFile ebuildPath (donorEbuild <> "\n# pycargoebuild\n")
        pure (Right ()),
      coPackCrates = \_lock _dist _stage outPath -> do
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
              cgpOnPycargoDone = logEv "pycargo-done",
              cgpOnPackStart = logEv "pack-start",
              cgpOnPackDone = logEv "pack-done"
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
        "pycargo-done",
        "pack-start",
        "pack-done"
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
          outDir
          "pkg-0.1.0-crates-noop.tar.xz"

testCargoBuilderCloneFail :: IO ()
testCargoBuilderCloneFail = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  let ops =
        CargoOps
          { coClone = \_ _ _ -> pure (Left "git clone failed: offline"),
            coPycargoebuild = \_ _ _ _ -> pure (Left "should not run"),
            coPackCrates = \_ _ _ _ -> pure (Left "should not pack")
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
      tmp
      tmp
      "x.tar.xz"
  case result of
    Left err -> assertTrue "error bubbled" ("offline" `T.isInfixOf` err)
    Right _ -> fail "expected clone failure"

testCargoBuilderMissingLock :: IO ()
testCargoBuilderMissingLock = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  let ops =
        CargoOps
          { coClone = \_ _ dest -> do
              createDirectoryIfMissing True dest
              pure (Right ()),
            coPycargoebuild = \_ _ _ _ -> pure (Left "should not run"),
            coPackCrates = \_ _ _ _ -> pure (Left "should not pack")
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
      tmp
      tmp
      "x.tar.xz"
  case result of
    Left err -> assertTrue "mentions Cargo.lock" ("Cargo.lock" `T.isInfixOf` err)
    Right _ -> fail "expected missing Cargo.lock failure"

testCargoBuilderPycargoFail :: IO ()
testCargoBuilderPycargoFail = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  packCalls <- newIORef (0 :: Int)
  let ops =
        fakeCargoSuccessOps
          { coPycargoebuild = \_ _ _ _ -> pure (Left "pycargoebuild failed: boom"),
            coPackCrates = \_ _ _ _ -> do
              atomicModifyIORef' packCalls (\n -> (n + 1, ()))
              pure (Left "should not pack after pycargo fail")
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
      tmp
      tmp
      "x.tar.xz"
  case result of
    Left err -> do
      assertTrue "error bubbled" ("boom" `T.isInfixOf` err)
      assertTrue "pycargo prefix" ("pycargoebuild failed" `T.isInfixOf` err)
      n <- readIORef packCalls
      assertEq "pack not called after pycargo fail" 0 n
    Right _ -> fail "expected pycargoebuild failure"

testCargoBuilderPackFail :: IO ()
testCargoBuilderPackFail = withSystemTempDirectory "mndz-eco-tmp-" $ \tmp -> do
  let ops =
        fakeCargoSuccessOps
          { coPackCrates = \_ _ _ _ ->
              pure (Left "cargo crates pack failed: missing registry crate serde-1.0.0.crate")
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
      tmp
      tmp
      "x.tar.xz"
  case result of
    Left err -> do
      assertTrue "pack prefix" ("cargo crates pack failed" `T.isInfixOf` err)
      assertTrue "not only pycargo" (not ("pycargoebuild failed" `T.isInfixOf` err))
    Right _ -> fail "expected pack failure"

-- | Tiny real pack: one registry crate in a fake distdir (no network).
testPackCratesTarballFixture :: IO ()
testPackCratesTarballFixture =
  withSystemTempDirectory "mndz-cargo-pack-" $ \tmp -> do
    let lockRoot = tmp </> "src"
        distDir = tmp </> "distdir"
        stageDir = tmp </> "stage"
        outPath = tmp </> "pkg-0.1.0-crates.tar.xz"
        crateDir = tmp </> "serde-1.0.200"
        cratePath = distDir </> "serde-1.0.200.crate"
    createDirectoryIfMissing True lockRoot
    createDirectoryIfMissing True distDir
    createDirectoryIfMissing True crateDir
    TIO.writeFile (crateDir </> "Cargo.toml") "[package]\nname = \"serde\"\n"
    -- Build a real .crate (gzipped tar) for extract+pack.
    void $
      productionCommandRunner
        ProcessRequest
          { prMode =
              ExecCmd
                "tar"
                ["-czf", cratePath, "-C", tmp, "serde-1.0.200"],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    TIO.writeFile
      (lockRoot </> "Cargo.lock")
      ( T.unlines
          [ "version = 4",
            "[[package]]",
            "name = \"serde\"",
            "version = \"1.0.200\"",
            "source = \"registry+https://github.com/rust-lang/crates.io-index\"",
            "checksum = \"abc123\""
          ]
      )
    assertRight "pack fixture"
      =<< packCratesTarball productionCommandRunner lockRoot distDir stageDir outPath
    exists <- doesFileExist outPath
    assertTrue "tarball exists" exists
    -- Final body must be real xz (would fail under the old .tmp bare-suffix bug).
    header <- BS.readFile outPath
    assertTrue "xz magic on packed crates" (isXzMagic header)
    assertRight "verifyXzFile on pack fixture" =<< verifyXzFile outPath
    -- Inspect members via tar -tf
    res <-
      productionCommandRunner
        ProcessRequest
          { prMode = ExecCmd "tar" ["-tf", outPath],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    assertEq "tar list exit" ExitSuccess (prExitCode res)
    let listing = T.pack (prStdout res)
    assertTrue
      "checksum member"
      ("cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json" `T.isInfixOf` listing)
    assertTrue
      "crate Cargo.toml member"
      ("cargo_home/gentoo/serde-1.0.200/Cargo.toml" `T.isInfixOf` listing)
    -- Extract checksum JSON and check package field
    void $
      productionCommandRunner
        ProcessRequest
          { prMode =
              ExecCmd
                "tar"
                [ "-xOf",
                  outPath,
                  "cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json"
                ],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    checksumBody <-
      prStdout
        <$> productionCommandRunner
          ProcessRequest
            { prMode =
                ExecCmd
                  "tar"
                  [ "-xOf",
                    outPath,
                    "cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json"
                  ],
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = ""
            }
    assertTrue "package field from lock" ("abc123" `T.isInfixOf` T.pack checksumBody)

testPackCratesTarballMissingCrate :: IO ()
testPackCratesTarballMissingCrate =
  withSystemTempDirectory "mndz-cargo-pack-miss-" $ \tmp -> do
    let lockRoot = tmp </> "src"
        distDir = tmp </> "distdir"
        stageDir = tmp </> "stage"
        outPath = tmp </> "out-crates.tar.xz"
    createDirectoryIfMissing True lockRoot
    createDirectoryIfMissing True distDir
    TIO.writeFile
      (lockRoot </> "Cargo.lock")
      ( T.unlines
          [ "[[package]]",
            "name = \"serde\"",
            "version = \"1.0.200\"",
            "source = \"registry+https://github.com/rust-lang/crates.io-index\"",
            "checksum = \"abc123\""
          ]
      )
    err <-
      assertLeft "missing crate"
        =<< packCratesTarball productionCommandRunner lockRoot distDir stageDir outPath
    assertTrue "pack prefix" ("cargo crates pack failed" `T.isInfixOf` err)
    assertTrue "names crate" ("serde-1.0.200.crate" `T.isInfixOf` err)
    exists <- doesFileExist outPath
    assertTrue "no partial final path" (not exists)

testPackCratesTarballXzArgv :: IO ()
testPackCratesTarballXzArgv =
  withSystemTempDirectory "mndz-cargo-pack-argv-" $ \tmp -> do
    let lockRoot = tmp </> "src"
        distDir = tmp </> "distdir"
        stageDir = tmp </> "stage"
        outPath = tmp </> "pkg-0.1.0-crates.tar.xz"
    createDirectoryIfMissing True lockRoot
    createDirectoryIfMissing True distDir
    TIO.writeFile
      (lockRoot </> "Cargo.lock")
      "version = 4\n"
    reqsRef <- newIORef ([] :: [ProcessRequest])
    let run req = do
          atomicModifyIORef' reqsRef (\rs -> (req : rs, ()))
          case prMode req of
            ExecCmd "tar" args -> do
              for_ (tarArchivePath args) writeFakeXz
              pure (okResult "")
            _ -> pure (failResult ("unexpected: " <> show (prMode req)))
    assertRight "empty registry pack"
      =<< packCratesTarball run lockRoot distDir stageDir outPath
    reqs <- reverse <$> readIORef reqsRef
    let tarReqs =
          [ r
          | r <- reqs,
            case prMode r of
              ExecCmd "tar" _ -> True
              _ -> False
          ]
    assertTrue "at least one tar pack" (not (null tarReqs))
    let packReq = last tarReqs
    case prMode packReq of
      ExecCmd "tar" args -> do
        let hasJ = "-cJf" `elem` args || any ("J" `isInfixOf`) args
            archivePaths = mapMaybe archivePathFromArgs [args]
            allXzOrForced =
              hasJ
                || all
                  ( \p ->
                      ".xz" `T.isSuffixOf` T.pack p
                        || ".xz.partial" `T.isSuffixOf` T.pack p
                  )
                  archivePaths
        assertTrue "forced xz (-J) or archive path ends with .xz" allXzOrForced
        assertTrue
          "no bare .tmp archive path"
          (not (any (\p -> ".tmp" `T.isSuffixOf` T.pack p && not (".xz" `isInfixOf` p)) archivePaths))
      _ -> fail "expected tar ExecCmd"
    case prEnv packReq of
      Nothing -> fail "expected XZ_OPT env on pack tar"
      Just env ->
        case lookup "XZ_OPT" env of
          Nothing -> fail "XZ_OPT missing"
          Just v -> do
            assertTrue "XZ_OPT has -T1" ("-T1" `isInfixOf` v)
            assertTrue "XZ_OPT has -9e" ("-9e" `isInfixOf` v)
            assertEq "XZ_OPT exact preset" xzOptValue v

testVerifyXzFile :: IO ()
testVerifyXzFile =
  withSystemTempDirectory "mndz-xz-verify-" $ \tmp -> do
    let plain = tmp </> "plain.tar.xz"
        good = tmp </> "good.tar.xz"
    -- Minimal POSIX ustar-ish bytes (not xz).
    BS.writeFile plain "ustar\0fake-plain-tar-body"
    writeFakeXz good
    err <- assertLeft "plain tar rejected" =<< verifyXzFile plain
    assertTrue "mentions plain tar / non-xz" ("not xz-compressed" `T.isInfixOf` err)
    assertTrue "mentions plain tar" ("plain tar" `T.isInfixOf` err)
    assertRight "xz magic accepted" =<< verifyXzFile good
    assertTrue "isXzMagic pure" (isXzMagic xzMagicPrefix)
    assertTrue "isXzMagic rejects plain" (not (isXzMagic "ustar"))

testPackTarXzAtomicTempSuffix :: IO ()
testPackTarXzAtomicTempSuffix =
  withSystemTempDirectory "mndz-xz-atomic-" $ \tmp -> do
    let stage = tmp </> "stage"
        outPath = tmp </> "out.tar.xz"
        entryDir = stage </> "cargo_home"
    createDirectoryIfMissing True entryDir
    TIO.writeFile (entryDir </> "marker") "ok\n"
    reqsRef <- newIORef ([] :: [ProcessRequest])
    let run req = do
          atomicModifyIORef' reqsRef (\rs -> (req : rs, ()))
          case prMode req of
            ExecCmd "tar" args -> do
              for_ (tarArchivePath args) writeFakeXz
              pure (okResult "")
            _ -> pure (failResult "unexpected")
    assertRight "atomic pack"
      =<< packTarXzAtomic run "test pack" Nothing (Just stage) ["cargo_home"] outPath
    reqs <- readIORef reqsRef
    let args =
          concat
            [ a
            | r <- reqs,
              ExecCmd "tar" a <- [prMode r]
            ]
    case tarArchivePath args of
      Nothing -> fail "no archive path in tar argv"
      Just p -> do
        assertTrue "temp keeps .xz before .partial" (".xz.partial" `isInfixOf` p || ".xz" `isInfixOf` p)
        assertTrue "not bare .tmp only" (p /= (outPath <> ".tmp"))
        assertTrue "-cJf present" ("-cJf" `elem` args)
    exists <- doesFileExist outPath
    assertTrue "final path exists" exists

testPackTarXzHermetic :: IO ()
testPackTarXzHermetic =
  withSystemTempDirectory "mndz-xz-hermetic-" $ \tmp -> do
    let src = tmp </> "src"
        outPath = tmp </> "out.tar.xz"
    createDirectoryIfMissing True src
    TIO.writeFile (src </> "hello.txt") "hi\n"
    reqsRef <- newIORef ([] :: [ProcessRequest])
    let run req = do
          atomicModifyIORef' reqsRef (\rs -> (req : rs, ()))
          productionCommandRunner req
    assertRight "hermetic pack"
      =<< packTarXz run "hermetic pack" (Just src) Nothing ["hello.txt"] outPath
    assertRight "xz magic" =<< verifyXzFile outPath
    reqs <- readIORef reqsRef
    let tarArgs =
          concat
            [ a
            | r <- reqs,
              ExecCmd "tar" a <- [prMode r]
            ]
        tarEnvs = [env | r <- reqs, Just env <- [prEnv r]]
    assertTrue "hermetic flags present" (all (`elem` tarArgs) hermeticTarArgs)
    case tarEnvs of
      [] -> fail "expected XZ_OPT env"
      (env : _) ->
        case lookup "XZ_OPT" env of
          Nothing -> fail "XZ_OPT missing"
          Just v -> do
            assertTrue "XZ_OPT has -T1" ("-T1" `isInfixOf` v)
            assertTrue "XZ_OPT has -9e" ("-9e" `isInfixOf` v)
            assertEq "XZ_OPT exact" xzOptValue v
    listed <-
      productionCommandRunner
        ProcessRequest
          { prMode = ExecCmd "tar" ["--numeric-owner", "-tvf", outPath],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    assertEq "tar -t exit" ExitSuccess (prExitCode listed)
    assertTrue "members are 0/0" ("0/0" `isInfixOf` prStdout listed)

testNpmPackOmitsLogs :: IO ()
testNpmPackOmitsLogs =
  withSystemTempDirectory "mndz-npm-omit-" $ \tmp -> do
    let cache = tmp </> "npm-cache"
        logs = cache </> "_logs"
        outPath = tmp </> "deps.tar.xz"
    createDirectoryIfMissing True logs
    TIO.writeFile (logs </> "debug.log") "home=/home/operator\n"
    TIO.writeFile (cache </> "_update-notifier-last-checked") "x"
    TIO.writeFile (cache </> "index-v5") "ok\n"
    prepareNpmCacheForPack cache
    assertRight "pack after scrub"
      =<< packTarXz productionCommandRunner "npm omit" (Just tmp) Nothing ["npm-cache"] outPath
    listed <-
      productionCommandRunner
        ProcessRequest
          { prMode = ExecCmd "tar" ["-tf", outPath],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    assertEq "tar -t exit" ExitSuccess (prExitCode listed)
    let members = prStdout listed
    assertTrue "keeps cache index" ("index-v5" `isInfixOf` members)
    assertTrue "omits _logs" (not ("_logs" `isInfixOf` members))
    assertTrue
      "omits _update-notifier"
      (not ("_update-notifier" `isInfixOf` members))

testBunCacheRewriteSymlinks :: IO ()
testBunCacheRewriteSymlinks =
  withSystemTempDirectory "mndz-bun-rewrite-" $ \tmp -> do
    let cache = tmp </> "bun-cache"
        unscopedDest = cache </> "gifwrap@0.10.1@@@1"
        unscopedLinkDir = cache </> "gifwrap"
        unscopedLink = unscopedLinkDir </> "0.10.1@@@1"
        scopedDest = cache </> "@scope" </> "name@1.0.0@@@1"
        scopedLinkDir = cache </> "@scope" </> "name"
        scopedLink = scopedLinkDir </> "1.0.0@@@1"
    createDirectoryIfMissing True unscopedDest
    createDirectoryIfMissing True unscopedLinkDir
    createDirectoryIfMissing True scopedDest
    createDirectoryIfMissing True scopedLinkDir
    TIO.writeFile (unscopedDest </> "pkg.json") "{}"
    TIO.writeFile (scopedDest </> "pkg.json") "{}"
    createFileLink unscopedDest unscopedLink
    createFileLink scopedDest scopedLink
    assertRight "rewrite" =<< rewriteBunCacheSymlinks cache
    unscopedT <- getSymbolicLinkTarget unscopedLink
    scopedT <- getSymbolicLinkTarget scopedLink
    assertTrue "unscoped relative" (not (isAbsolute unscopedT))
    assertTrue "scoped relative" (not (isAbsolute scopedT))
    assertTrue "unscoped points at @ form" ("gifwrap@0.10.1@@@1" `isInfixOf` unscopedT)
    assertTrue "scoped points at @ form" ("name@1.0.0@@@1" `isInfixOf` scopedT)
    assertTrue "unscoped still a link" =<< pathIsSymbolicLink unscopedLink
    assertTrue "scoped still a link" =<< pathIsSymbolicLink scopedLink

testBunCacheAbsoluteLeftover :: IO ()
testBunCacheAbsoluteLeftover =
  withSystemTempDirectory "mndz-bun-abs-" $ \tmp -> do
    let cache = tmp </> "bun-cache"
        link = cache </> "orphan"
    createDirectoryIfMissing True cache
    createFileLink "/no/such/bun-cache/missing@1@@@1" link
    err <- assertLeft "absolute leftover" =<< rewriteBunCacheSymlinks cache
    assertTrue "mentions bun-cache" ("bun-cache" `T.isInfixOf` err)

testSanitizeQlotConfs :: IO ()
testSanitizeQlotConfs =
  withSystemTempDirectory "mndz-qlot-sanitize-" $ \tmp -> do
    let qlot = tmp </> ".qlot"
        conf = qlot </> "qlot.conf"
        srcReg = qlot </> "source-registry.conf"
        operatorHome = "/home/operator"
    createDirectoryIfMissing True qlot
    TIO.writeFile conf (T.pack operatorHome <> "/quicklisp/setup.lisp\n")
    TIO.writeFile srcReg (":directory \"" <> T.pack operatorHome <> "/quicklisp/local-projects/\"\n")
    assertRight "sanitize" =<< sanitizeQlotConfs tmp operatorHome
    confBody <- TIO.readFile conf
    srcBody <- TIO.readFile srcReg
    assertTrue "qlot.conf no operator home" (not (T.pack operatorHome `T.isInfixOf` confBody))
    assertTrue "source-registry no operator home" (not (T.pack operatorHome `T.isInfixOf` srcBody))
    assertTrue "rewritten to builder home" ("/home/builder" `T.isInfixOf` confBody)

testDockerWrapRequest :: IO ()
testDockerWrapRequest = do
  let cfg =
        MaterializeDockerCfg
          { mdcImage = defaultMaterializeImage,
            mdcUser = "1000:1000",
            mdcBindPath = "/tmp/mndz/overlay-manager/run1"
          }
      req =
        ProcessRequest
          { prMode = ExecCmd "go" ["version"],
            prCwd = Just "/tmp/mndz/overlay-manager/run1/work",
            prEnv =
              Just
                [ ("HOME", "/home/operator"),
                  ("GITHUB_TOKEN", "secret"),
                  ("GNUPGHOME", "/home/operator/.gnupg"),
                  ("SSH_AUTH_SOCK", "/tmp/ssh.sock"),
                  ("GOMODCACHE", "/tmp/mndz/overlay-manager/run1/work/go-mod"),
                  ("XZ_OPT", "-T1 -9e")
                ],
            prStdin = ""
          }
      wrapped = wrapMaterializeRequest cfg req
  case prMode wrapped of
    ExecCmd cmd args -> do
      assertEq "docker binary" "docker" cmd
      assertTrue "run --rm" (["run", "--rm"] `isInfixOf` args)
      assertTrue "--user host uid" (["--user", "1000:1000"] `isInfixOf` args)
      assertTrue
        "HOME=/home/builder"
        (any (("HOME=" <> materializeBuilderHome) `isInfixOf`) args)
      assertTrue
        "bind-mount same path"
        ( any
            (isInfixOf "type=bind,src=/tmp/mndz/overlay-manager/run1,dst=/tmp/mndz/overlay-manager/run1")
            args
        )
      assertTrue "workdir" (["--workdir", "/tmp/mndz/overlay-manager/run1/work"] `isInfixOf` args)
      assertTrue "inner go version" (["go", "version"] `isInfixOf` args)
      assertTrue "image tag" (defaultMaterializeImage `elem` args)
      assertTrue "no GITHUB_TOKEN" (not (any ("GITHUB_TOKEN" `isInfixOf`) args))
      assertTrue "no GNUPGHOME" (not (any ("GNUPGHOME" `isInfixOf`) args))
      assertTrue "no SSH_AUTH_SOCK" (not (any ("SSH_AUTH_SOCK" `isInfixOf`) args))
      assertTrue "keeps GOMODCACHE" (any ("GOMODCACHE=" `isInfixOf`) args)
      assertTrue "keeps XZ_OPT" (any ("XZ_OPT=" `isInfixOf`) args)
    ShellCmd _ -> fail "expected ExecCmd docker"
  assertEq "cwd consumed by --workdir" Nothing (prCwd wrapped)
  assertEq "env not inherited on host docker" Nothing (prEnv wrapped)

------------------------------------------------------------------------
-- Production mk*Ops / runners via scripted CommandRunner
------------------------------------------------------------------------

okResult :: String -> ProcessResult
okResult out =
  ProcessResult
    { prExitCode = ExitSuccess,
      prStdout = out,
      prStderr = ""
    }

failResult :: String -> ProcessResult
failResult err =
  ProcessResult
    { prExitCode = ExitFailure 1,
      prStdout = "",
      prStderr = err
    }

execCmd :: ProcessRequest -> Maybe (String, [String])
execCmd req = case prMode req of
  ExecCmd cmd args -> Just (cmd, args)
  ShellCmd _ -> Nothing

-- | Archive path argument after @-cJf@ / @-acf@ / @-f@.
tarArchivePath :: [String] -> Maybe FilePath
tarArchivePath = go
  where
    go [] = Nothing
    go ("-cJf" : p : _) = Just p
    go ("-acf" : p : _) = Just p
    go ("-f" : p : _) = Just p
    go (_ : rest) = go rest

archivePathFromArgs :: [String] -> Maybe FilePath
archivePathFromArgs = tarArchivePath

-- | Minimal bytes that pass 'verifyXzFile' (xz magic only).
writeFakeXz :: FilePath -> IO ()
writeFakeXz path = BS.writeFile path xzMagicPrefix

testNpmMkCommandRunner :: IO ()
testNpmMkCommandRunner =
  withSystemTempDirectory "mndz-npm-mk-" $ \outDir -> do
    reqsRef <- newIORef ([] :: [ProcessRequest])
    let successRun req = do
          atomicModifyIORef' reqsRef (\rs -> (req : rs, ()))
          case execCmd req of
            Just ("node", ["--version"]) -> pure (okResult "v20.19.0\n")
            Just ("npm", args)
              | "pack" `elem` args -> do
                  case prCwd req of
                    Just workDir -> writeFile (workDir </> "pkg-1.0.0.tgz") "packed"
                    Nothing -> pure ()
                  pure (okResult "")
              | "--cache" `elem` args -> pure (okResult "")
              | otherwise -> pure (failResult ("unexpected npm: " <> show args))
            Just ("tar", args) -> do
              for_ (tarArchivePath args) writeFakeXz
              pure (okResult "")
            _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        failRun req = case execCmd req of
          Just ("node", ["--version"]) -> pure (failResult "node missing")
          _ -> pure (failResult "should not run")
    path <-
      assertRight "npm mk success"
        =<< buildNpmDepsTarball
          (mkNpmCacheOps successRun)
          noopNpmProgress
          "left-pad"
          "1.0.0"
          "18.0.0"
          outDir
          outDir
          "left-pad-1.0.0-npm-cache.tar.xz"
    assertEq "out path" (outDir </> "left-pad-1.0.0-npm-cache.tar.xz") path
    exists <- doesFileExist path
    assertTrue "tarball written" exists
    -- Non-Cargo pack asserts uniform XZ_OPT=-T1 -9e.
    reqs <- reverse <$> readIORef reqsRef
    let tarReqs =
          [ r
          | r <- reqs,
            case prMode r of
              ExecCmd "tar" _ -> True
              _ -> False
          ]
    case tarReqs of
      [] -> fail "npm pack did not invoke tar"
      (tarReq : _) -> case prEnv tarReq of
        Just env ->
          case lookup "XZ_OPT" env of
            Just v -> do
              assertTrue "npm XZ_OPT -T1" ("-T1" `isInfixOf` v)
              assertTrue "npm XZ_OPT -9e" ("-9e" `isInfixOf` v)
            Nothing -> fail "npm tar missing XZ_OPT"
        Nothing -> fail "npm tar missing env"
    err <-
      assertLeft "npm mk host fail"
        =<< buildNpmDepsTarball
          (mkNpmCacheOps failRun)
          noopNpmProgress
          "pkg"
          "1.0.0"
          "18.0.0"
          outDir
          outDir
          "x.tar.xz"
    assertTrue "image node error" ("could not determine materialize image Node version" `T.isInfixOf` err)

testBunMkCommandRunner :: IO ()
testBunMkCommandRunner =
  withSystemTempDirectory "mndz-bun-mk-" $ \outDir -> do
    let successRun req = case execCmd req of
          Just ("bun", ["--version"]) -> pure (okResult "1.2.3\n")
          Just ("git", "clone" : args) -> do
            let dest = last args
            createDirectoryIfMissing True dest
            TIO.writeFile (dest </> "bun.lock") "{}"
            pure (okResult "")
          Just ("bun", "install" : _) -> pure (okResult "")
          Just ("tar", args) -> do
            for_ (tarArchivePath args) writeFakeXz
            pure (okResult "")
          _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        failRun req = case execCmd req of
          Just ("bun", ["--version"]) -> pure (okResult "1.2.3\n")
          Just ("git", "clone" : _) -> pure (failResult "clone offline")
          _ -> pure (failResult "should not run")
    path <-
      assertRight "bun mk success"
        =<< buildBunDepsTarball
          (mkBunCacheOps successRun)
          noopBunProgress
          BunCache
          "owner"
          "repo"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          outDir
          "repo-0.1.0-bun-cache.tar.xz"
    exists <- doesFileExist path
    assertTrue "bun tarball" exists
    err <-
      assertLeft "bun mk clone fail"
        =<< buildBunDepsTarball
          (mkBunCacheOps failRun)
          noopBunProgress
          BunCache
          "o"
          "r"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
          outDir
          "x.tar.xz"
    assertTrue "clone error" ("git clone failed" `T.isInfixOf` err)

testVendorMkCommandRunner :: IO ()
testVendorMkCommandRunner =
  withSystemTempDirectory "mndz-vendor-mk-" $ \outDir -> do
    let goMod =
          T.unlines
            [ "module example.com/pkg",
              "go 1.22.0"
            ]
        successRun req = case execCmd req of
          Just ("git", "clone" : args) -> do
            let dest = last args
            createDirectoryIfMissing True dest
            TIO.writeFile (dest </> "go.mod") goMod
            pure (okResult "")
          Just ("go", ["version"]) ->
            pure (okResult "go version go1.22.5 linux/amd64\n")
          Just ("go", "mod" : _) -> pure (okResult "")
          Just ("tar", args) -> do
            for_ (tarArchivePath args) writeFakeXz
            pure (okResult "")
          _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        failRun req = case execCmd req of
          Just ("git", "clone" : _) -> pure (failResult "network down")
          _ -> pure (failResult "should not run")
    res <-
      assertRight "vendor mk success"
        =<< buildVendorTarball
          (mkVendorOps successRun)
          noopVendorProgress
          "owner"
          "repo"
          "v"
          "0.1.0"
          Nothing
          outDir
          outDir
          "pkg-0.1.0-vendor.tar.xz"
    assertEq "go.mod version" (Just "1.22.0") (vrGoModVersion res)
    exists <- doesFileExist (vrTarballPath res)
    assertTrue "vendor tarball" exists
    vendorFail <-
      buildVendorTarball
        (mkVendorOps failRun)
        noopVendorProgress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        outDir
        "x.tar.xz"
    case vendorFail of
      Left err -> assertTrue "clone error" ("git clone failed" `T.isInfixOf` err)
      Right _ -> fail "expected vendor clone failure"

testCargoMkCommandRunner :: IO ()
testCargoMkCommandRunner =
  withSystemTempDirectory "mndz-cargo-mk-" $ \tmp -> do
    let outDir = tmp </> "out"
        -- Shared scratch so scripted git clone can drop a crate into a known
        -- distdir is awkward; instead pack path is exercised by real tar via
        -- productionCommandRunner for extract/archive only when pycargo stub
        -- leaves distdir empty and lock has no registry pkgs → empty stage pack.
        successRun req = case execCmd req of
          Just ("git", "clone" : args) -> do
            let dest = last args
            createDirectoryIfMissing True dest
            TIO.writeFile
              (dest </> "Cargo.lock")
              "# empty registry set\nversion = 4\n"
            TIO.writeFile
              (dest </> "Cargo.toml")
              "[package]\nname = \"pkg\"\nrust-version = \"1.85.0\"\n"
            pure (okResult "")
          Just ("pycargoebuild", args) -> do
            assertTrue
              "no-write-crate-tarball flag"
              ("--no-write-crate-tarball" `elem` args)
            assertTrue "crate-tarball mode -c" ("-c" `elem` args)
            case dropWhile (/= "-i") args of
              ("-i" : ebuildPath : _) ->
                TIO.writeFile ebuildPath (donorEbuild <> "\n# pycargo\n")
              _ -> pure ()
            -- Deliberately do not write the tarball (manager pack owns it).
            pure (okResult "")
          Just ("tar", _) ->
            -- Real pack: empty registry set → stage only cargo_home/gentoo,
            -- then archive. Delegate so the archive actually lands.
            productionCommandRunner req
          _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        failRun req = case execCmd req of
          Just ("git", "clone" : _) -> pure (failResult "clone refused")
          _ -> pure (failResult "should not run")
    createDirectoryIfMissing True outDir
    res <-
      assertRight "cargo mk success"
        =<< buildCargoCratesTarball
          (mkCargoOps successRun)
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
          outDir
          "pkg-0.1.0-crates.tar.xz"
    assertEq "msrv" "1.85.0" (crMsrv res)
    exists <- doesFileExist (crTarballPath res)
    assertTrue "crates tarball" exists
    cargoFail <-
      buildCargoCratesTarball
        (mkCargoOps failRun)
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
        outDir
        "x.tar.xz"
    case cargoFail of
      Left err -> assertTrue "clone error" ("git clone failed" `T.isInfixOf` err)
      Right _ -> fail "expected cargo clone failure"

testSimpleRunnersMk :: IO ()
testSimpleRunnersMk =
  withSystemTempDirectory "mndz-runners-mk-" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        overlay = tmp </> "overlay"
    createDirectoryIfMissing True gentoo
    createDirectoryIfMissing True overlay
    -- ebuild shell-mode success + failure
    let ebuildOk req = case prMode req of
          ShellCmd cmd
            | "ebuild" `isInfixOf` cmd && "manifest" `isInfixOf` cmd ->
                pure (okResult "")
          _ -> pure (failResult ("unexpected ebuild req: " <> show req))
        ebuildFail _ = pure (failResult "ebuild died")
    assertRight "ebuild ok"
      =<< mkEbuildRunner (tmp </> "distfiles") ebuildOk overlay "pkg-1.0.ebuild"
    ebuildErr <-
      assertLeft "ebuild fail"
        =<< mkEbuildRunner (tmp </> "distfiles") ebuildFail overlay "pkg-1.0.ebuild"
    assertTrue "ebuild err" ("ebuild manifest failed" `T.isInfixOf` ebuildErr)
    -- portageq success + failure
    let pqOk = mkPortageqRunner $ \req -> case execCmd req of
          Just ("portageq", ["get_repo_path", "/", "gentoo"]) ->
            pure (okResult (gentoo <> "\n"))
          _ -> pure (failResult ("unexpected portageq: " <> show req))
        pqFail = mkPortageqRunner $ \_ -> pure (failResult "no portageq")
    path <- assertRight "portageq path" =<< gentooRepoPath pqOk
    assertEq "gentoo path" gentoo path
    pqErr <- assertLeft "portageq fail" =<< gentooRepoPath pqFail
    assertTrue "portageq err" ("portageq" `T.isInfixOf` pqErr)
    -- egencache: portageq discover + egencache argv
    let egenOk req = case execCmd req of
          Just ("portageq", ["get_repo_path", "/", "gentoo"]) ->
            pure (okResult (gentoo <> "\n"))
          Just ("egencache", args) -> do
            assertTrue "repo mndz" ("--repo" `elem` args && "mndz" `elem` args)
            assertTrue "update" ("--update" `elem` args)
            pure (okResult "")
          _ -> pure (failResult ("unexpected egencache req: " <> show req))
        egenFail req = case execCmd req of
          Just ("portageq", _) -> pure (okResult (gentoo <> "\n"))
          Just ("egencache", _) -> pure (failResult "egencache boom")
          _ -> pure (failResult "unexpected")
    assertRight "egencache ok"
      =<< mkEgencacheRunner
        egenOk
        EgencacheRequest
          { erOverlayRoot = overlay,
            erAtoms = ["dev-lang/pkg"],
            erJobs = Just 2
          }
    egenErr <-
      assertLeft "egencache fail"
        =<< mkEgencacheRunner
          egenFail
          EgencacheRequest
            { erOverlayRoot = overlay,
              erAtoms = ["dev-lang/pkg"],
              erJobs = Nothing
            }
    assertTrue "egencache err" ("egencache failed" `T.isInfixOf` egenErr)

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
          outDir
          "pkg-npm.tar.xz"
    bunPath <-
      assertRight "env bun"
        =<< buildBunDepsTarball
          (aeBunCacheOps env)
          noopBunProgress
          BunCache
          "o"
          "r"
          "v"
          "0.1.0"
          "1.0.0"
          outDir
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
          outDir
          "pkg-crates.tar.xz"
    assertTrue "npm via env" =<< doesFileExist npmPath
    assertTrue "bun via env" =<< doesFileExist bunPath
    assertTrue "cargo via env" =<< doesFileExist (crTarballPath cargoRes)
