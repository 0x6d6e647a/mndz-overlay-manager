{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Unit coverage for materialize-image floors, sidecar, recipe, and ensure IO.
module Test.Ensure (unitTests) where

import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Apply
  ( ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    PackagePlanResult (..),
    PlannedWork (..),
  )
import Update.DiskSpace
  ( DiskSpaceProbe (..),
    MaterializeClass (..),
  )
import Update.Go.Lanes
  ( CargoFloorCoverage (..),
    CargoTagFloorSnapshot (..),
    LaneTarget (..),
    RuntimeLanePlan (..),
    pattern LaneAmd64Plain,
  )
import Update.Materialize
  ( DockerInfoFacts (..),
    EnsureConfig (..),
    EnsureOutcome (..),
    ImageSidecar (..),
    ImageStoreLayout (..),
    NeededFloors (..),
    RecipeArch (..),
    ResolvedInstall (..),
    ResolvedToolchain (..),
    ToolchainKind (..),
    addToolchainCacheNeedBytes,
    addToolchainLayerNeedBytes,
    addToolchainNeedBytes,
    containerdDumpNeeded,
    containerdRootUnresolvedMessage,
    decodeImageSidecar,
    defaultMaterializeSidecarDirFromEnv,
    emptyFloors,
    encodeImageSidecar,
    ensureFailedMessage,
    ensureMaterializeImage,
    firstImageCacheNeedBytes,
    firstImageLayerNeedBytes,
    firstImageNeedBytes,
    floorsSatisfy,
    imageDiskInsufficientMessage,
    imageSidecarSchemaVersion,
    imageStoreLayout,
    imageStoreUnresolvedMessage,
    isBundledContainerdAddress,
    lookupRecipeArch,
    materializeGeneratorId,
    neededFloorsFromClassified,
    overlayBunFloorFromMetas,
    overrideUnusableMessage,
    parseContainerdDump,
    parseDockerInfoJson,
    prunePreviousMaterializeImage,
    renderMaterializeDockerfile,
    resolveToolchain,
    sidecarImageJsonPath,
    unionFloors,
    unmappedArchMessage,
  )
import Update.Process
  ( ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker
  ( defaultMaterializeImage,
    inspectMaterializeImage,
    materializeImageEnvVar,
    missingImageMessage,
  )
import Update.Runtime.Ceilings (RuntimeEbuildMeta (..), discoverBunBinMetas)
import Update.Types
  ( CargoSource (..),
    EcosystemSpec (..),
    UpdateSource (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "Ensure"
    [ testCase "union/satisfy Go floors" testUnionSatisfy,
      testCase "Bun-only first image omits SBCL" testBunOnlyOmitsSbcl,
      testCase "pin-only bun-bin is not SLOT=0 for image floor" testPinOnlyBunBinNotImageFloor,
      testCase "rust-bin preferred over plain rust" testResolvePrefersRustBin,
      testCase "sbcl without -bin picks source and ~amd64 accept" testResolveSbclNoBinTilde,
      testCase "missing ebuilds at floor is a resolve miss" testResolveMissingFloorMiss,
      testCase "floor 0 is unversioned; ~arch only without plain ebuild" testResolveFloorZero,
      testCase "full-path 1.24 + reuse 1.26 → Go floor 1.24" testFullPathFloorIgnoresReuseSibling,
      testCase "Cargo declared tag floor feeds ensure" testCargoDeclaredTagFloorFeedsEnsure,
      testCase "Cargo selection 0.0.0 is not an image floor" testCargoAbsenceNotImageFloor,
      testCase "render contains ::mndz and no official tarball URLs" testRenderMndzNoOfficial,
      testCase "uname map splits KEYWORDS from OpenRC Hub tag" testLookupRecipeArch,
      testCase "x86_64 recipe uses amd64-openrc FROM and ~amd64 keywords" testAmd64OpenrcRecipe,
      testCase "ppc64le recipe uses ppc64le-openrc FROM and ~ppc64 keywords" testPpc64leOpenrcRecipe,
      testCase "SBCL testing floor is one emerge plus ::gentoo ~amd64" testRenderSbclTestingFloor,
      testCase "i686 SBCL recipe uses /usr/lib/sbcl ENV" testRenderSbclX86Libdir,
      testCase "missing sidecar field is a miss" testMissingSidecarField,
      testCase "skip docker build when satisfies" testSkipWhenSatisfies,
      testCase "generator mismatch rebuilds despite floors" testGeneratorMismatchRebuilds,
      testCase "newer overlay qlot rebuilds despite language floors" testNewerQlotRebuilds,
      testCase "newer overlay node-gyp rebuilds despite language floors" testNewerNodeGypRebuilds,
      testCase "bun recipe emerges overlay node-gyp after node" testBunRecipeEmergesNodeGypAfterNode,
      testCase "Go-only recipe omits node-gyp" testGoOnlyOmitsNodeGyp,
      testCase "unmapped uname hard-fails without docker build" testUnmappedDefaultNoBuild,
      testCase "override on unmapped uname skips generate" testOverrideUnmappedNoBuild,
      testCase "override missing hard-fails without build" testOverrideMissingNoBuild,
      testCase "fake build records union satisfies" testFakeBuildRecordsUnion,
      testCase "parse docker info overlay2 and snapshotter sockets" testParseDockerInfoFixtures,
      testCase "parse containerd dump root and root_path" testParseContainerdDump,
      testCase "pure image store layout classic bundled system" testImageStoreLayout,
      testCase "role bounds combined vs split" testRoleBounds,
      testCase "image disk gate skipped when satisfies" testDiskGateSkippedWhenSatisfies,
      testCase "first build fails early on tiny disk" testFirstBuildDiskFail,
      testCase "split store fails on cache filesystem" testSplitCacheShort,
      testCase "split store fails on layer filesystem" testSplitLayersShort,
      testCase "split store ample overlay tiny still builds" testSplitAmpleOverlayTiny,
      testCase "system snapshotter dump miss fails closed" testSnapshotterDumpMiss,
      testCase "system snapshotter missing root fails closed" testSnapshotterRootMissing,
      testCase "bundled snapshotter does not dump containerd" testBundledSnapshotterNoDump,
      testCase "resolve miss does not invoke docker build" testResolveMissNoBuild,
      testCase "prune rmi unused previous id then image prune -f" testPruneRmiThenPruneF,
      testCase "inspect missing image uses ensure copy not Dockerfile recipe" testInspectMissingMessage,
      testCase "default sidecar path under HOME" testDefaultSidecarPath
    ]

------------------------------------------------------------------------
-- Pure floors / recipe / sidecar
------------------------------------------------------------------------

testUnionSatisfy :: IO ()
testUnionSatisfy = do
  let recorded = emptyFloors {nfGo = Just "1.26.5"}
      needed = emptyFloors {nfGo = Just "1.26.4"}
      bunOnly = emptyFloors {nfBun = Just "1.3.0"}
  assertTrue "1.26.5 satisfies 1.26.4" (floorsSatisfy recorded needed)
  assertTrue "1.26.4 does not satisfy 1.26.5" (not (floorsSatisfy needed recorded))
  assertTrue "missing Go does not satisfy" (not (floorsSatisfy emptyFloors needed))
  let unioned = unionFloors recorded bunOnly
  assertEq "union keeps Go" (Just "1.26.5") (nfGo unioned)
  assertEq "union adds Bun" (Just "1.3.0") (nfBun unioned)
  assertEq "union does not invent SBCL" Nothing (nfSbcl unioned)
  assertEq "union does not invent qlot" Nothing (nfQlot unioned)
  assertEq "union does not invent node-gyp" Nothing (nfNodeGyp unioned)
  let recQlot = emptyFloors {nfQlot = Just "1.8.4"}
      needQlot = emptyFloors {nfQlot = Just "1.8.5"}
  assertTrue "1.8.5 does not satisfy as recorded 1.8.4" (not (floorsSatisfy recQlot needQlot))
  assertTrue "missing recorded qlot is a miss" (not (floorsSatisfy emptyFloors needQlot))
  assertTrue "1.8.5 satisfies 1.8.4" (floorsSatisfy needQlot recQlot)
  let recGyp = emptyFloors {nfNodeGyp = Just "13.0.0"}
      needGyp = emptyFloors {nfNodeGyp = Just "13.0.1"}
  assertTrue "13.0.1 does not satisfy as recorded 13.0.0" (not (floorsSatisfy recGyp needGyp))
  assertTrue "missing recorded node-gyp is a miss" (not (floorsSatisfy emptyFloors needGyp))
  assertTrue "13.0.1 satisfies 13.0.0" (floorsSatisfy needGyp recGyp)
  let oldJson =
        "{\"go\":\"1.26.5\"}"
  case decodeImageSidecar
    ( encodeUtf8
        "{\"version\":1,\"id\":\"sha256:x\",\"tag\":\"t\",\"satisfies\":"
        <> encodeUtf8 oldJson
        <> ",\"generator\":\"g\",\"built_at\":\"2026-01-01T00:00:00Z\"}"
    ) of
    Left err -> assertFailure ("old sidecar decode: " <> err)
    Right side ->
      assertEq "old sidecar nodeGyp missing" Nothing (nfNodeGyp (isSatisfies side))

testBunOnlyOmitsSbcl :: IO ()
testBunOnlyOmitsSbcl = do
  let key = mkPackageKey "dev-util" "ralph-tui"
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "ralph-tui",
                  cpuPV = parseEbuildVersion "1.0.0",
                  cpuEco = Bun,
                  cpuClass = FullNpmBun,
                  cpuTempBaseline = Nothing
                }
            ]
        ]
      plan =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Bun,
                pdSource = GitHub "subsy" "ralph-tui" "v",
                pdPlan = bunPlan "1.2.0",
                pdLocalPVs = [],
                pdContentFix = [parseEbuildVersion "1.0.0"],
                pdForceFull = [],
                pdHypoProvider = Nothing
              }
        ]
      needed = neededFloorsFromClassified classify plan (Just "1.2.0") Nothing (Just "13.0.0")
  assertEq "bun floor" (Just "1.2.0") (nfBun needed)
  assertEq "node-gyp floor when bun" (Just "13.0.0") (nfNodeGyp needed)
  assertEq "no SBCL on first bun-only" Nothing (nfSbcl needed)
  assertEq "no qlot on bun-only" Nothing (nfQlot needed)
  assertEq "no Go on bun-only" Nothing (nfGo needed)
  df <- renderMapped "x86_64" [bunInstall "1.2.0" "amd64"] "/overlay"
  assertTrue "recipe has bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` df)
  assertTrue "recipe bun-bin is :0" (">=dev-lang/bun-bin-1.2.0:0::mndz" `T.isInfixOf` df)
  assertTrue "recipe omits sbcl emerge" (not ("dev-lisp/sbcl" `T.isInfixOf` df))
  assertTrue "bun-only omits SBCL_HOME" (not ("SBCL_HOME" `T.isInfixOf` df))
  assertTrue "bun-only omits qlot" (not ("dev-lisp/qlot" `T.isInfixOf` df))
  assertTrue "base still emerges wget" ("net-misc/wget" `T.isInfixOf` df)

testPinOnlyBunBinNotImageFloor :: IO ()
testPinOnlyBunBinNotImageFloor =
  withSystemTempDirectory "om-ensure-pin-only" $ \tmp -> do
    let pkgDir = tmp </> "dev-lang" </> "bun-bin"
    createDirectoryIfMissing True pkgDir
    TIO.writeFile
      (pkgDir </> "bun-bin-1.3.14.ebuild")
      "EAPI=8\nSLOT=\"1.3.14\"\nKEYWORDS=\"~amd64\"\n"
    metas <- discoverBunBinMetas tmp
    case metas of
      Left err -> assertFailure (T.unpack err)
      Right ms -> do
        assertEq "pin slot ignored" [] ms
        assertEq "no overlay bun floor" Nothing (overlayBunFloorFromMetas ms)

testResolvePrefersRustBin :: IO ()
testResolvePrefersRustBin = do
  let binMetas = [meta "1.88.0" ["~amd64"]]
      srcMetas = [meta "1.88.0" ["amd64"]]
  rt <-
    assertResolved "rust-bin" $
      resolveToolchain
        "amd64"
        "1.88.0"
        "dev-lang/rust-bin"
        binMetas
        "dev-lang/rust"
        srcMetas
        "gentoo"
  assertEq "atom" "dev-lang/rust-bin" (rtAtom rt)
  assertEq "emerge" ">=dev-lang/rust-bin-1.88.0" (rtEmergeSpec rt)
  assertEq
    "accept"
    (Just ">=dev-lang/rust-bin-1.88.0::gentoo ~amd64")
    (rtAcceptLine rt)

testResolveSbclNoBinTilde :: IO ()
testResolveSbclNoBinTilde = do
  rt <-
    assertResolved "sbcl" $
      resolveToolchain
        "amd64"
        "2.6.6"
        "dev-lisp/sbcl-bin"
        []
        "dev-lisp/sbcl"
        [meta "2.6.6" ["~amd64"]]
        "gentoo"
  assertEq "atom" "dev-lisp/sbcl" (rtAtom rt)
  assertEq "emerge" ">=dev-lisp/sbcl-2.6.6" (rtEmergeSpec rt)
  assertEq
    "accept"
    (Just ">=dev-lisp/sbcl-2.6.6::gentoo ~amd64")
    (rtAcceptLine rt)

testResolveMissingFloorMiss :: IO ()
testResolveMissingFloorMiss = do
  case resolveToolchain
    "amd64"
    "2.7.0"
    "dev-lisp/sbcl-bin"
    []
    "dev-lisp/sbcl"
    [meta "2.6.6" ["~amd64"]]
    "gentoo" of
    Left msg ->
      assertTrue "names floor" ("2.7.0" `T.isInfixOf` msg)
    Right rt ->
      assertFailure ("expected miss, got " <> show rt)

testResolveFloorZero :: IO ()
testResolveFloorZero = do
  plain <-
    assertResolved "floor0-plain" $
      resolveToolchain
        "amd64"
        "0"
        "dev-lang/go-bin"
        []
        "dev-lang/go"
        [meta "1.26.5" ["amd64"]]
        "gentoo"
  assertEq "unversioned emerge" "dev-lang/go" (rtEmergeSpec plain)
  assertEq "no accept when plain exists" Nothing (rtAcceptLine plain)
  tilde <-
    assertResolved "floor0-tilde" $
      resolveToolchain
        "amd64"
        "0"
        "dev-lang/go-bin"
        []
        "dev-lang/go"
        [meta "1.26.5" ["~amd64"]]
        "gentoo"
  assertEq "unversioned emerge tilde" "dev-lang/go" (rtEmergeSpec tilde)
  assertEq
    "accept without version"
    (Just "dev-lang/go::gentoo ~amd64")
    (rtAcceptLine tilde)

testFullPathFloorIgnoresReuseSibling :: IO ()
testFullPathFloorIgnoresReuseSibling = do
  let key = mkPackageKey "app-misc" "dolt"
      pvFull = parseEbuildVersion "1.0.0"
      pvReuse = parseEbuildVersion "1.1.0"
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "dolt",
                  cpuPV = pvFull,
                  cpuEco = Go Nothing,
                  cpuClass = FullGo,
                  cpuTempBaseline = Nothing
                },
              ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "dolt",
                  cpuPV = pvReuse,
                  cpuEco = Go Nothing,
                  cpuClass = ReusePath,
                  cpuTempBaseline = Nothing
                }
            ]
        ]
      plan =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Go Nothing,
                pdSource = GitHub "dolthub" "dolt" "v",
                pdPlan =
                  goPlan
                    [ (pvFull, "1.24.0"),
                      (pvReuse, "1.26.5")
                    ],
                pdLocalPVs = [pvFull, pvReuse],
                pdContentFix = [],
                pdForceFull = [],
                pdHypoProvider = Nothing
              }
        ]
      needed = neededFloorsFromClassified classify plan Nothing Nothing (Just "13.0.0")
  assertEq "Go floor from full-path PV only" (Just "1.24.0") (nfGo needed)
  assertEq "no unused toolchains" Nothing (nfSbcl needed)
  assertEq "no qlot without SBCL" Nothing (nfQlot needed)
  assertEq "no node-gyp without bun or node" Nothing (nfNodeGyp needed)

testCargoDeclaredTagFloorFeedsEnsure :: IO ()
testCargoDeclaredTagFloorFeedsEnsure = do
  let key = mkPackageKey "dev-util" "usage"
      pv = parseEbuildVersion "6.4.1"
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "usage",
                  cpuPV = pv,
                  cpuEco = Cargo Nothing (Just "cli") CargoGitTag,
                  cpuClass = FullCargo,
                  cpuTempBaseline = Nothing
                }
            ]
        ]
      plan =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Cargo Nothing (Just "cli") CargoGitTag,
                pdSource = GitHub "jdx" "usage" "v",
                pdPlan = cargoPlan pv (Just "1.91.0") "1.91.0",
                pdLocalPVs = [],
                pdContentFix = [pv],
                pdForceFull = [pv],
                pdHypoProvider = Nothing
              }
        ]
      needed = neededFloorsFromClassified classify plan Nothing Nothing (Just "13.0.0")
  assertEq "declared tag floor" (Just "1.91.0") (nfRust needed)

testCargoAbsenceNotImageFloor :: IO ()
testCargoAbsenceNotImageFloor = do
  let key = mkPackageKey "dev-util" "hk"
      pv = parseEbuildVersion "0.50.0"
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "hk",
                  cpuPV = pv,
                  cpuEco = Cargo Nothing Nothing CargoGitTag,
                  cpuClass = FullCargo,
                  cpuTempBaseline = Nothing
                }
            ]
        ]
      plan =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Cargo Nothing Nothing CargoGitTag,
                pdSource = GitHub "jdx" "hk" "v",
                pdPlan = cargoPlan pv Nothing "0.0.0",
                pdLocalPVs = [],
                pdContentFix = [pv],
                pdForceFull = [pv],
                pdHypoProvider = Nothing
              }
        ]
      needed = neededFloorsFromClassified classify plan Nothing Nothing (Just "13.0.0")
  assertTrue "not 0.0.0" (nfRust needed /= Just "0.0.0")
  assertEq "absence is unversioned rust" (Just "0") (nfRust needed)

testRenderMndzNoOfficial :: IO ()
testRenderMndzNoOfficial = do
  df <-
    renderMapped
      "x86_64"
      [goInstall "1.26.5", bunInstall "1.2.21" "amd64"]
      "/home/op/overlay"
  assertTrue "::mndz" ("::mndz" `T.isInfixOf` df)
  assertTrue
    "accept_keywords bun-bin"
    (">=dev-lang/bun-bin-1.2.21:0::mndz ~amd64" `T.isInfixOf` df)
  assertTrue "go via portage" ("dev-lang/go" `T.isInfixOf` df)
  assertTrue "no go.dev" (not ("go.dev" `T.isInfixOf` df))
  assertTrue "no nodejs.org" (not ("nodejs.org" `T.isInfixOf` df))
  assertTrue
    "no bun github zip"
    (not ("github.com/oven-sh/bun" `T.isInfixOf` df))
  assertTrue "overlay bind ro" (",ro" `T.isInfixOf` df)
  assertTrue "DISTDIR cache" ("/var/cache/distfiles" `T.isInfixOf` df)
  assertTrue "PKGDIR cache" ("/var/cache/binpkgs" `T.isInfixOf` df)
  assertTrue "buildpkg FEATURES" ("buildpkg" `T.isInfixOf` df)
  assertTrue "usepkg" ("--usepkg" `T.isInfixOf` df)
  assertTrue
    "stable distfiles cache id"
    ("id=mndz-materialize-distfiles" `T.isInfixOf` df)
  assertTrue
    "stable binpkgs cache id"
    ("id=mndz-materialize-binpkgs" `T.isInfixOf` df)
  assertTrue "no sbcl-bin ||" (not ("sbcl-bin" `T.isInfixOf` df))
  assertTrue "no shell fallback" (not ("|| emerge" `T.isInfixOf` df))

testLookupRecipeArch :: IO ()
testLookupRecipeArch = do
  let rows =
        [ ("x86_64", "amd64", "amd64-openrc"),
          ("amd64", "amd64", "amd64-openrc"),
          ("aarch64", "arm64", "arm64-openrc"),
          ("arm64", "arm64", "arm64-openrc"),
          ("ppc64le", "ppc64", "ppc64le-openrc"),
          ("riscv64", "riscv", "rv64_lp64d-openrc"),
          ("s390x", "s390", "s390x-openrc"),
          ("i686", "x86", "i686-openrc"),
          ("i386", "x86", "i686-openrc"),
          ("armv7l", "arm", "armv7a_hardfp-openrc"),
          ("armv6l", "arm", "armv6j_hardfp-openrc")
        ]
  mapM_ assertMapped rows
  assertTrue "sparc64 is a miss" (isNothing (lookupRecipeArch "sparc64"))
  assertTrue "ppc64 BE is a miss" (isNothing (lookupRecipeArch "ppc64"))
  assertTrue "loongarch64 is a miss" (isNothing (lookupRecipeArch "loongarch64"))
  where
    assertMapped (uname, kw, hub) =
      case lookupRecipeArch uname of
        Nothing -> assertFailure (uname <> " should map")
        Just arch -> do
          assertEq (uname <> " keywords") kw (raKeywords arch)
          assertEq (uname <> " hub") hub (raHubTag arch)

testAmd64OpenrcRecipe :: IO ()
testAmd64OpenrcRecipe = do
  df <- renderMapped "x86_64" [bunInstall "1.2.21" "amd64"] "/overlay"
  assertTrue
    "OpenRC FROM"
    ("FROM gentoo/stage3:amd64-openrc" `T.isInfixOf` df)
  assertTrue
    "not fossil amd64 FROM line"
    (not ("FROM gentoo/stage3:amd64\n" `T.isInfixOf` df))
  assertTrue
    "bun-bin KEYWORDS"
    (">=dev-lang/bun-bin-1.2.21:0::mndz ~amd64" `T.isInfixOf` df)

testPpc64leOpenrcRecipe :: IO ()
testPpc64leOpenrcRecipe = do
  df <- renderMapped "ppc64le" [bunInstall "1.2.21" "ppc64"] "/overlay"
  assertTrue
    "OpenRC FROM"
    ("FROM gentoo/stage3:ppc64le-openrc" `T.isInfixOf` df)
  assertTrue
    "bun-bin KEYWORDS ppc64"
    (">=dev-lang/bun-bin-1.2.21:0::mndz ~ppc64" `T.isInfixOf` df)

testRenderSbclTestingFloor :: IO ()
testRenderSbclTestingFloor = do
  rt <-
    assertResolved "sbcl-render" $
      resolveToolchain
        "amd64"
        "2.6.6"
        "dev-lisp/sbcl-bin"
        []
        "dev-lisp/sbcl"
        [meta "2.6.6" ["~amd64"]]
        "gentoo"
  df <-
    renderMapped
      "x86_64"
      [ResolvedInstall TkSbcl rt, overlayQlotInstall "1.8.4" "amd64"]
      "/overlay"
  assertEq
    "one versioned sbcl emerge"
    1
    (T.count "emerge -n \">=dev-lisp/sbcl-2.6.6\"" df)
  assertTrue
    "accept ::gentoo ~amd64"
    (">=dev-lisp/sbcl-2.6.6::gentoo ~amd64" `T.isInfixOf` df)
  assertTrue "no sbcl-bin" (not ("sbcl-bin" `T.isInfixOf` df))
  assertTrue "no shell || fallback" (not ("|| emerge" `T.isInfixOf` df))
  assertTrue "no source USE" (not ("[source]" `T.isInfixOf` df))
  assertTrue
    "ENV SBCL_HOME lib64"
    ("ENV SBCL_HOME=/usr/lib64/sbcl" `T.isInfixOf` df)
  assertTrue
    "ENV SBCL_SOURCE_ROOT lib64"
    ("ENV SBCL_SOURCE_ROOT=/usr/lib64/sbcl/src" `T.isInfixOf` df)
  let (beforeQlot, _) = T.breakOn "dev-lisp/qlot" df
  assertTrue
    "ENV HOME before qlot"
    ("ENV SBCL_HOME=/usr/lib64/sbcl" `T.isInfixOf` beforeQlot)
  assertTrue
    "ENV SOURCE_ROOT before qlot"
    ("ENV SBCL_SOURCE_ROOT=/usr/lib64/sbcl/src" `T.isInfixOf` beforeQlot)
  assertTrue
    "qlot emerge spec"
    (">=dev-lisp/qlot-1.8.4::mndz" `T.isInfixOf` df)
  assertTrue
    "qlot accept ::mndz ~amd64"
    (">=dev-lisp/qlot-1.8.4::mndz ~amd64" `T.isInfixOf` df)
  assertTrue
    "no Quicklisp installer fetch"
    (not ("beta.quicklisp.org" `T.isInfixOf` df))
  let qlotRuns = filter ("dev-lisp/qlot" `T.isInfixOf`) (T.splitOn "RUN " df)
  assertTrue "qlot has a RUN" (not (null qlotRuns))
  assertTrue
    "overlay bind on qlot RUN"
    (all ("from=overlay" `T.isInfixOf`) qlotRuns)
  assertTrue "base still emerges wget" ("net-misc/wget" `T.isInfixOf` df)
  assertTrue "base still emerges aria2" ("net-misc/aria2" `T.isInfixOf` df)

testRenderSbclX86Libdir :: IO ()
testRenderSbclX86Libdir = do
  let rt =
        ResolvedToolchain
          { rtAtom = "dev-lisp/sbcl",
            rtEmergeSpec = ">=dev-lisp/sbcl-2.6.6",
            rtAcceptLine = Just ">=dev-lisp/sbcl-2.6.6::gentoo ~x86"
          }
  df <-
    renderMapped
      "i686"
      [ResolvedInstall TkSbcl rt, overlayQlotInstall "1.8.4" "x86"]
      "/overlay"
  assertTrue
    "ENV SBCL_HOME lib"
    ("ENV SBCL_HOME=/usr/lib/sbcl" `T.isInfixOf` df)
  assertTrue
    "ENV SBCL_SOURCE_ROOT lib"
    ("ENV SBCL_SOURCE_ROOT=/usr/lib/sbcl/src" `T.isInfixOf` df)
  assertTrue
    "not lib64 on x86"
    (not ("/usr/lib64/sbcl" `T.isInfixOf` df))
  assertTrue
    "qlot emerge spec"
    (">=dev-lisp/qlot-1.8.4::mndz" `T.isInfixOf` df)
  assertTrue
    "no Quicklisp installer fetch"
    (not ("beta.quicklisp.org" `T.isInfixOf` df))
  let qlotRuns = filter ("dev-lisp/qlot" `T.isInfixOf`) (T.splitOn "RUN " df)
  assertTrue
    "overlay bind on qlot RUN"
    (all ("from=overlay" `T.isInfixOf`) qlotRuns)

renderMapped :: String -> [ResolvedInstall] -> FilePath -> IO T.Text
renderMapped uname installs overlay =
  case lookupRecipeArch uname of
    Nothing -> assertFailure (uname <> " should map")
    Just arch -> pure (renderMaterializeDockerfile arch overlay installs)

bunInstall :: T.Text -> T.Text -> ResolvedInstall
bunInstall ver kw =
  ResolvedInstall
    TkBun
    ResolvedToolchain
      { rtAtom = "dev-lang/bun-bin",
        rtEmergeSpec = ">=dev-lang/bun-bin-" <> ver <> ":0::mndz",
        rtAcceptLine = Just (">=dev-lang/bun-bin-" <> ver <> ":0::mndz ~" <> kw)
      }

overlayQlotInstall :: T.Text -> T.Text -> ResolvedInstall
overlayQlotInstall ver kw =
  ResolvedInstall
    TkQlot
    ResolvedToolchain
      { rtAtom = "dev-lisp/qlot",
        rtEmergeSpec = ">=dev-lisp/qlot-" <> ver <> "::mndz",
        rtAcceptLine = Just (">=dev-lisp/qlot-" <> ver <> "::mndz ~" <> kw)
      }

goInstall :: T.Text -> ResolvedInstall
goInstall ver =
  ResolvedInstall
    TkGo
    ResolvedToolchain
      { rtAtom = "dev-lang/go",
        rtEmergeSpec = ">=dev-lang/go-" <> ver,
        rtAcceptLine = Nothing
      }

nodeInstall :: T.Text -> ResolvedInstall
nodeInstall ver =
  ResolvedInstall
    TkNode
    ResolvedToolchain
      { rtAtom = "net-libs/nodejs",
        rtEmergeSpec = ">=net-libs/nodejs-" <> ver,
        rtAcceptLine = Nothing
      }

overlayNodeGypInstall :: T.Text -> T.Text -> ResolvedInstall
overlayNodeGypInstall ver kw =
  ResolvedInstall
    TkNodeGyp
    ResolvedToolchain
      { rtAtom = "dev-build/node-gyp",
        rtEmergeSpec = ">=dev-build/node-gyp-" <> ver <> "::mndz",
        rtAcceptLine = Just (">=dev-build/node-gyp-" <> ver <> "::mndz ~" <> kw)
      }

meta :: T.Text -> [T.Text] -> RuntimeEbuildMeta
meta ver kws =
  RuntimeEbuildMeta
    { remPV = parseEbuildVersion ver,
      remKeywords = kws
    }

assertResolved :: String -> Either T.Text ResolvedToolchain -> IO ResolvedToolchain
assertResolved name = \case
  Left err -> assertFailure (name <> ": " <> T.unpack err)
  Right rt -> pure rt

testMissingSidecarField :: IO ()
testMissingSidecarField = do
  let missingId =
        "{\"version\":1,\"tag\":\"t\",\"satisfies\":{},\
        \\"generator\":\"g\",\"built_at\":\"2026-01-01T00:00:00Z\"}"
      bad = decodeImageSidecar (encodeUtf8 missingId)
  assertTrue "missing id is a miss" (case bad of Left _ -> True; Right _ -> False)
  let now = epoch
      full =
        ImageSidecar
          { isVersion = imageSidecarSchemaVersion,
            isId = "sha256:abc",
            isTag = T.pack defaultMaterializeImage,
            isSatisfies = emptyFloors {nfGo = Just "1.26.5"},
            isGenerator = materializeGeneratorId,
            isBuiltAt = now
          }
  case decodeImageSidecar (LBS.toStrict (encodeImageSidecar full)) of
    Left err -> assertFailure ("roundtrip failed: " <> err)
    Right got -> do
      assertEq "id" (isId full) (isId got)
      assertEq "go floor" (nfGo (isSatisfies full)) (nfGo (isSatisfies got))

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) 0

bunPlan :: T.Text -> RuntimeLanePlan
bunPlan req =
  RuntimeLanePlan
    { glpLanes =
        [ LaneTarget
            { ltLane = LaneAmd64Plain,
              ltCeiling = Just (parseEbuildVersion "1.3.0"),
              ltPackagePV = Just (parseEbuildVersion "1.0.0"),
              ltGoReq = Just req
            }
        ],
      glpEbuilds = [],
      glpUniquePVs = [parseEbuildVersion "1.0.0"],
      glpRuntimeAtom = "dev-lang/bun-bin",
      glpDirectTagFloors = [],
      glpFloorPolicy = Nothing
    }

cargoPlan :: EbuildVersion -> Maybe T.Text -> T.Text -> RuntimeLanePlan
cargoPlan pv mFloor laneReq =
  RuntimeLanePlan
    { glpLanes =
        [ LaneTarget
            { ltLane = LaneAmd64Plain,
              ltCeiling = Just (parseEbuildVersion "1.92.0"),
              ltPackagePV = Just pv,
              ltGoReq = Just laneReq
            }
        ],
      glpEbuilds = [],
      glpUniquePVs = [pv],
      glpRuntimeAtom = "dev-lang/rust|rust-bin",
      glpDirectTagFloors =
        [ CargoTagFloorSnapshot
            { ctfsPV = pv,
              ctfsFloor = mFloor,
              ctfsCoverage = Just CargoCoverageComplete,
              ctfsReasons = [],
              ctfsProvenance = []
            }
        ],
      glpFloorPolicy = Just "2|prefix=v|pkg=|lock="
    }

goPlan :: [(EbuildVersion, T.Text)] -> RuntimeLanePlan
goPlan rows =
  RuntimeLanePlan
    { glpLanes =
        [ LaneTarget
            { ltLane = LaneAmd64Plain,
              ltCeiling = Just (parseEbuildVersion "1.26.5"),
              ltPackagePV = Just pv,
              ltGoReq = Just req
            }
        | (pv, req) <- rows
        ],
      glpEbuilds = [],
      glpUniquePVs = [pv | (pv, _) <- rows],
      glpRuntimeAtom = "dev-lang/go",
      glpDirectTagFloors = [],
      glpFloorPolicy = Nothing
    }

testDefaultSidecarPath :: IO ()
testDefaultSidecarPath = do
  let dir = defaultMaterializeSidecarDirFromEnv Nothing "/home/op"
  assertEq
    "HOME fallback"
    "/home/op/.cache/mndz/overlay-manager/materialize"
    dir
  let xdg = defaultMaterializeSidecarDirFromEnv (Just "/xdg") "/home/op"
  assertEq
    "XDG"
    "/xdg/mndz/overlay-manager/materialize"
    xdg

------------------------------------------------------------------------
-- Ensure IO with fake docker
------------------------------------------------------------------------

plentyDisk :: DiskSpaceProbe
plentyDisk =
  DiskSpaceProbe
    { dspFreeBytes = \_ -> pure (Right (100 * 1024 * 1024 * 1024)),
      dspDeviceId = \_ -> pure (Right 1)
    }

tinyDisk :: DiskSpaceProbe
tinyDisk =
  DiskSpaceProbe
    { dspFreeBytes = \_ -> pure (Right (1024 * 1024)),
      dspDeviceId = \_ -> pure (Right 1)
    }

data FakeDocker = FakeDocker
  { fdInspectOk :: Bool,
    fdInspectId :: String,
    fdBuildShouldRun :: IORef [[String]],
    fdDockerInfoJson :: String,
    fdContainerdDump :: Maybe String,
    fdContainerdCalls :: IORef [[String]]
  }

mkLogRef :: IO (IORef [[String]])
mkLogRef = newIORef []

classicInfoJson :: String
classicInfoJson =
  dockerInfoJson "/var/lib/docker" False "/run/containerd/containerd.sock"

dockerInfoJson :: FilePath -> Bool -> FilePath -> String
dockerInfoJson root snapshotter addr =
  concat
    [ "{\"DockerRootDir\":",
      show root,
      ",\"DriverStatus\":",
      if snapshotter
        then "[[\"driver-type\",\"io.containerd.snapshotter.v1\"]]"
        else "[[\"Backing Filesystem\",\"extfs\"]]",
      ",\"Containerd\":{\"Address\":",
      show addr,
      "}}"
    ]

containerdDumpText :: FilePath -> Maybe FilePath -> String
containerdDumpText root mRootPath =
  unlines
    [ "version = 2",
      "root = '" <> root <> "'",
      "",
      "[plugins.'io.containerd.snapshotter.v1.overlayfs']",
      "  root_path = "
        <> case mRootPath of
          Nothing -> "''"
          Just p -> "'" <> p <> "'"
    ]

mkFakeDocker :: Bool -> String -> IORef [[String]] -> IO FakeDocker
mkFakeDocker ok iid builds = do
  dumps <- mkLogRef
  pure
    FakeDocker
      { fdInspectOk = ok,
        fdInspectId = iid,
        fdBuildShouldRun = builds,
        fdDockerInfoJson = classicInfoJson,
        fdContainerdDump = Nothing,
        fdContainerdCalls = dumps
      }

okResult :: String -> ProcessResult
okResult out =
  ProcessResult
    { prExitCode = ExitSuccess,
      prStdout = out,
      prStderr = ""
    }

failResult :: Int -> String -> ProcessResult
failResult n err =
  ProcessResult
    { prExitCode = ExitFailure n,
      prStdout = "",
      prStderr = err
    }

fakeRunner :: FakeDocker -> ProcessRequest -> IO ProcessResult
fakeRunner fake req = case prMode req of
  ExecCmd "docker" ("image" : "inspect" : rest) -> do
    builds <- readIORef (fdBuildShouldRun fake)
    let built = any ("-t" `elem`) builds
    if fdInspectOk fake
      then pure (okResult (fdInspectId fake <> "\n"))
      else
        if built
          then pure (okResult "sha256:built\n")
          else
            pure (failResult 1 ("Error: No such image: " <> last rest))
  ExecCmd "docker" ("build" : args) -> do
    atomicModifyIORef' (fdBuildShouldRun fake) (\xs -> (args : xs, ()))
    pure (okResult "")
  ExecCmd "docker" ["info", "--format", "{{json .}}"] ->
    pure (okResult (fdDockerInfoJson fake <> "\n"))
  ExecCmd "docker" ("info" : _) ->
    pure (failResult 1 "expected docker info --format '{{json .}}'")
  ExecCmd "docker" ("rmi" : args) -> do
    atomicModifyIORef' (fdBuildShouldRun fake) (\xs -> (("rmi" : args) : xs, ()))
    pure (okResult "")
  ExecCmd "docker" ("image" : "prune" : args) -> do
    atomicModifyIORef'
      (fdBuildShouldRun fake)
      (\xs -> (("image" : "prune" : args) : xs, ()))
    pure (okResult "")
  ExecCmd "containerd" args -> do
    atomicModifyIORef' (fdContainerdCalls fake) (\xs -> (args : xs, ()))
    case (args, fdContainerdDump fake) of
      (["config", "dump"], Just txt) -> pure (okResult txt)
      (["config", "dump"], Nothing) ->
        pure (failResult 127 "containerd: command not found")
      _ -> pure (failResult 127 "unexpected containerd")
  _ ->
    pure (failResult 127 "unexpected")

mkCfg ::
  FilePath ->
  FilePath ->
  FakeDocker ->
  DiskSpaceProbe ->
  Maybe String ->
  IO EnsureConfig
mkCfg overlay sidecar fake probe mOverride =
  mkCfgUname overlay sidecar fake probe mOverride "x86_64"

mkCfgUname ::
  FilePath ->
  FilePath ->
  FakeDocker ->
  DiskSpaceProbe ->
  Maybe String ->
  String ->
  IO EnsureConfig
mkCfgUname overlay sidecar fake probe mOverride uname = do
  prev <- newMVar Nothing
  pure
    EnsureConfig
      { ecRun = fakeRunner fake,
        ecProbe = probe,
        ecOverlayRoot = overlay,
        ecSidecarDir = sidecar,
        ecNow = pure epoch,
        ecUname = uname,
        ecOverrideTag = mOverride,
        ecPrevImageId = prev,
        ecGentooRoot = pure (Right (takeDirectory overlay </> "gentoo"))
      }

writeRuntimeEbuild :: FilePath -> T.Text -> T.Text -> T.Text -> IO ()
writeRuntimeEbuild pkgDir pn ver keywords = do
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> (T.unpack pn <> "-" <> T.unpack ver <> ".ebuild"))
    ("KEYWORDS=\"" <> keywords <> "\"\n")

seedGoAmd64 :: FilePath -> IO ()
seedGoAmd64 gentoo =
  writeRuntimeEbuild (gentoo </> "dev-lang" </> "go") "go" "1.26.5" "amd64"

seedBunOverlay :: FilePath -> T.Text -> T.Text -> IO ()
seedBunOverlay overlay =
  writeRuntimeEbuild
    (overlay </> "dev-lang" </> "bun-bin")
    "bun-bin"

neededGo :: NeededFloors
neededGo = emptyFloors {nfGo = Just "1.26.4"}

writeSidecarGo :: FilePath -> String -> T.Text -> IO ()
writeSidecarGo dir iid goVer =
  writeSidecarGoGen dir iid goVer materializeGeneratorId

writeSidecarGoGen :: FilePath -> String -> T.Text -> T.Text -> IO ()
writeSidecarGoGen dir iid goVer gen = do
  createDirectoryIfMissing True dir
  let side =
        ImageSidecar
          { isVersion = imageSidecarSchemaVersion,
            isId = T.pack iid,
            isTag = T.pack defaultMaterializeImage,
            isSatisfies = emptyFloors {nfGo = Just goVer},
            isGenerator = gen,
            isBuiltAt = epoch
          }
  BS.writeFile (sidecarImageJsonPath dir) (LBS.toStrict (encodeImageSidecar side))

testSkipWhenSatisfies :: IO ()
testSkipWhenSatisfies =
  withSystemTempDirectory "om-ensure-skip" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        iid = "sha256:already"
    createDirectoryIfMissing True overlay
    writeSidecarGo sidecar iid "1.26.5"
    builds <- mkLogRef
    fake <- mkFakeDocker True iid builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    assertEq "skipped" (Right EnsureSkipped) got
    calls <- readIORef builds
    assertEq "no docker build" [] calls

testGeneratorMismatchRebuilds :: IO ()
testGeneratorMismatchRebuilds =
  withSystemTempDirectory "om-ensure-gen" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        iid = "sha256:stale-gen"
    createDirectoryIfMissing True overlay
    seedGoAmd64 (tmp </> "gentoo")
    writeSidecarGoGen sidecar iid "1.26.5" "mndz-overlay-manager-materialize-1"
    builds <- mkLogRef
    fake <- mkFakeDocker True iid builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    assertEq "rebuilt" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)
    bs <- BS.readFile (sidecarImageJsonPath sidecar)
    case decodeImageSidecar bs of
      Left err -> assertFailure err
      Right side ->
        assertEq "records current generator" materializeGeneratorId (isGenerator side)

testNewerQlotRebuilds :: IO ()
testNewerQlotRebuilds =
  withSystemTempDirectory "om-ensure-qlot" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        iid = "sha256:old-qlot"
        gentoo = tmp </> "gentoo"
    createDirectoryIfMissing True overlay
    writeRuntimeEbuild (gentoo </> "dev-lisp" </> "sbcl") "sbcl" "2.6.6" "~amd64"
    writeRuntimeEbuild (overlay </> "dev-lisp" </> "qlot") "qlot" "1.8.5" "~amd64"
    createDirectoryIfMissing True sidecar
    let side0 =
          ImageSidecar
            { isVersion = imageSidecarSchemaVersion,
              isId = T.pack iid,
              isTag = T.pack defaultMaterializeImage,
              isSatisfies =
                emptyFloors
                  { nfSbcl = Just "2.6.6",
                    nfQlot = Just "1.8.4"
                  },
              isGenerator = materializeGeneratorId,
              isBuiltAt = epoch
            }
    BS.writeFile (sidecarImageJsonPath sidecar) (LBS.toStrict (encodeImageSidecar side0))
    builds <- mkLogRef
    fake <- mkFakeDocker True iid builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    let needed =
          emptyFloors
            { nfSbcl = Just "2.6.6",
              nfQlot = Just "1.8.5"
            }
    got <- ensureMaterializeImage cfg needed
    assertEq "rebuilt for newer qlot" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)
    bs <- BS.readFile (sidecarImageJsonPath sidecar)
    case decodeImageSidecar bs of
      Left err -> assertFailure err
      Right side ->
        assertEq "records newer qlot" (Just "1.8.5") (nfQlot (isSatisfies side))
    df <- decodeUtf8 <$> BS.readFile (sidecar </> "Dockerfile")
    assertTrue "recipe emerges overlay qlot" (">=dev-lisp/qlot-1.8.5::mndz" `T.isInfixOf` df)
    assertTrue "no Quicklisp fetch" (not ("beta.quicklisp.org" `T.isInfixOf` df))

testNewerNodeGypRebuilds :: IO ()
testNewerNodeGypRebuilds =
  withSystemTempDirectory "om-ensure-node-gyp" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        iid = "sha256:old-node-gyp"
        gentoo = tmp </> "gentoo"
    createDirectoryIfMissing True overlay
    writeRuntimeEbuild (gentoo </> "net-libs" </> "nodejs") "nodejs" "22.22.2" "~amd64"
    writeRuntimeEbuild (overlay </> "dev-build" </> "node-gyp") "node-gyp" "13.0.1" "~amd64"
    createDirectoryIfMissing True sidecar
    let side0 =
          ImageSidecar
            { isVersion = imageSidecarSchemaVersion,
              isId = T.pack iid,
              isTag = T.pack defaultMaterializeImage,
              isSatisfies =
                emptyFloors
                  { nfNode = Just "22.22.2",
                    nfNodeGyp = Just "13.0.0"
                  },
              isGenerator = materializeGeneratorId,
              isBuiltAt = epoch
            }
    BS.writeFile (sidecarImageJsonPath sidecar) (LBS.toStrict (encodeImageSidecar side0))
    builds <- mkLogRef
    fake <- mkFakeDocker True iid builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    let needed =
          emptyFloors
            { nfNode = Just "22.22.2",
              nfNodeGyp = Just "13.0.1"
            }
    got <- ensureMaterializeImage cfg needed
    assertEq "rebuilt for newer node-gyp" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)
    bs <- BS.readFile (sidecarImageJsonPath sidecar)
    case decodeImageSidecar bs of
      Left err -> assertFailure err
      Right side ->
        assertEq "records newer node-gyp" (Just "13.0.1") (nfNodeGyp (isSatisfies side))
    df <- decodeUtf8 <$> BS.readFile (sidecar </> "Dockerfile")
    assertTrue
      "recipe emerges overlay node-gyp"
      (">=dev-build/node-gyp-13.0.1::mndz" `T.isInfixOf` df)

testBunRecipeEmergesNodeGypAfterNode :: IO ()
testBunRecipeEmergesNodeGypAfterNode = do
  df <-
    renderMapped
      "x86_64"
      [ nodeInstall "22.22.2",
        overlayNodeGypInstall "13.0.0" "amd64",
        bunInstall "1.2.0" "amd64"
      ]
      "/overlay"
  assertTrue
    "node-gyp emerge spec"
    (">=dev-build/node-gyp-13.0.0::mndz" `T.isInfixOf` df)
  assertTrue
    "node-gyp accept ::mndz ~amd64"
    (">=dev-build/node-gyp-13.0.0::mndz ~amd64" `T.isInfixOf` df)
  let (beforeGyp, afterGyp) = T.breakOn "dev-build/node-gyp" df
  assertTrue "Node install before node-gyp" ("net-libs/nodejs" `T.isInfixOf` beforeGyp)
  assertTrue "bun after node-gyp" ("dev-lang/bun-bin" `T.isInfixOf` afterGyp)
  let gypRuns = filter ("dev-build/node-gyp" `T.isInfixOf`) (T.splitOn "RUN " df)
  assertTrue "node-gyp has a RUN" (not (null gypRuns))
  assertTrue
    "overlay bind on node-gyp RUN"
    (all ("from=overlay" `T.isInfixOf`) gypRuns)

testGoOnlyOmitsNodeGyp :: IO ()
testGoOnlyOmitsNodeGyp = do
  df <- renderMapped "x86_64" [goInstall "1.26.5"] "/overlay"
  assertTrue "go via portage" ("dev-lang/go" `T.isInfixOf` df)
  assertTrue "Go-only omits node-gyp" (not ("dev-build/node-gyp" `T.isInfixOf` df))

testUnmappedDefaultNoBuild :: IO ()
testUnmappedDefaultNoBuild =
  withSystemTempDirectory "om-ensure-unmapped" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        uname = "sparc64"
    createDirectoryIfMissing True overlay
    builds <- mkLogRef
    fake <- mkFakeDocker False "" builds
    cfg <- mkCfgUname overlay sidecar fake plentyDisk Nothing uname
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names sparc64" ("sparc64" `T.isInfixOf` msg)
        assertEq "uses unmapped helper" (ensureFailedMessage (unmappedArchMessage uname)) msg
        assertTrue
          "no host-path fallback copy"
          (not ("host-path" `T.isInfixOf` msg))
      Right o -> assertFailure ("expected unmapped fail, got " <> show o)
    calls <- readIORef builds
    assertEq "no docker build" [] calls
    dfExists <- doesFileExist (sidecar </> "Dockerfile")
    assertTrue "did not write a fossil FROM recipe" (not dfExists)

testOverrideUnmappedNoBuild :: IO ()
testOverrideUnmappedNoBuild =
  withSystemTempDirectory "om-ensure-ovr-unmapped" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        tag = "example/materialize:ci"
    createDirectoryIfMissing True overlay
    builds <- mkLogRef
    fake <- mkFakeDocker True "sha256:override" builds
    cfg <- mkCfgUname overlay sidecar fake plentyDisk (Just tag) "sparc64"
    got <- ensureMaterializeImage cfg neededGo
    assertEq "inspect-only skip" (Right EnsureSkipped) got
    calls <- readIORef builds
    assertEq "no docker build" [] calls

testOverrideMissingNoBuild :: IO ()
testOverrideMissingNoBuild =
  withSystemTempDirectory "om-ensure-override" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        tag = "example/materialize:ci"
    createDirectoryIfMissing True overlay
    builds <- mkLogRef
    fake <- mkFakeDocker False "" builds
    cfg <- mkCfg overlay sidecar fake plentyDisk (Just tag)
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names override" (T.pack tag `T.isInfixOf` msg)
        assertTrue
          "mentions env"
          (T.pack materializeImageEnvVar `T.isInfixOf` msg)
        assertTrue
          "does not tell operator to docker build default"
          (not ("docker/materialize/Dockerfile" `T.isInfixOf` msg))
      Right o -> assertFailure ("expected fail, got " <> show o)
    calls <- readIORef builds
    assertEq "no docker build of override" [] calls
    -- Message helper stays aligned with spec copy.
    assertTrue
      "helper names tag"
      (T.pack tag `T.isInfixOf` overrideUnusableMessage tag)

testFakeBuildRecordsUnion :: IO ()
testFakeBuildRecordsUnion =
  withSystemTempDirectory "om-ensure-build" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        oldId = "sha256:old"
    createDirectoryIfMissing True overlay
    seedGoAmd64 (tmp </> "gentoo")
    seedBunOverlay overlay "1.3.0" "~amd64"
    writeSidecarGo sidecar oldId "1.26.5"
    builds <- mkLogRef
    fake <- mkFakeDocker True oldId builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    let needed = emptyFloors {nfBun = Just "1.3.0"}
    got <- ensureMaterializeImage cfg needed
    assertEq "built" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)
    bs <- BS.readFile (sidecarImageJsonPath sidecar)
    case decodeImageSidecar bs of
      Left err -> assertFailure err
      Right side -> do
        assertEq "keeps prior Go" (Just "1.26.5") (nfGo (isSatisfies side))
        assertEq "adds Bun" (Just "1.3.0") (nfBun (isSatisfies side))
        assertEq "no SBCL paid for" Nothing (nfSbcl (isSatisfies side))
    dfExists <- doesFileExist (sidecar </> "Dockerfile")
    assertTrue "wrote Dockerfile" dfExists
    df <- decodeUtf8 <$> BS.readFile (sidecar </> "Dockerfile")
    assertTrue "recipe ::mndz" ("::mndz" `T.isInfixOf` df)
    assertTrue "recipe still has go" ("dev-lang/go" `T.isInfixOf` df)

testDiskGateSkippedWhenSatisfies :: IO ()
testDiskGateSkippedWhenSatisfies =
  withSystemTempDirectory "om-ensure-disk" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        iid = "sha256:ok"
    createDirectoryIfMissing True overlay
    writeSidecarGo sidecar iid "1.26.5"
    builds <- mkLogRef
    fake <- mkFakeDocker True iid builds
    cfg <- mkCfg overlay sidecar fake tinyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    assertEq "tiny disk still skip when satisfies" (Right EnsureSkipped) got
    calls <- readIORef builds
    assertEq "no build" [] calls
    let msg =
          imageDiskInsufficientMessage
            "/var/lib/docker"
            (1024 * 1024)
            firstImageNeedBytes
    assertTrue "disk message names path" ("/var/lib/docker" `T.isInfixOf` msg)
    assertTrue "disk message mentions free" ("free:" `T.isInfixOf` msg)
    assertTrue "disk message mentions need" ("need:" `T.isInfixOf` msg)
    assertTrue "add-toolchain bound is below first image" (addToolchainNeedBytes < firstImageNeedBytes)

testFirstBuildDiskFail :: IO ()
testFirstBuildDiskFail =
  withSystemTempDirectory "om-ensure-disk-fail" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
    createDirectoryIfMissing True overlay
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- mkFakeDocker False "" builds
    cfg <- mkCfg overlay sidecar fake tinyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names docker path" ("/var/lib/docker" `T.isInfixOf` msg)
        assertTrue "mentions free" ("free:" `T.isInfixOf` msg)
        assertTrue "mentions need" ("need:" `T.isInfixOf` msg)
        assertTrue
          "combined does not invent roles"
          (not ("image layers" `T.isInfixOf` msg))
      Right o -> assertFailure ("expected disk fail, got " <> show o)
    calls <- readIORef builds
    assertEq "no docker build after disk fail" [] calls

testResolveMissNoBuild :: IO ()
testResolveMissNoBuild =
  withSystemTempDirectory "om-ensure-resolve-miss" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        gentoo = tmp </> "gentoo"
    createDirectoryIfMissing True overlay
    writeRuntimeEbuild
      (gentoo </> "dev-lisp" </> "sbcl")
      "sbcl"
      "2.6.6"
      "~amd64"
    builds <- mkLogRef
    fake <- mkFakeDocker False "" builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg (emptyFloors {nfSbcl = Just "2.7.0"})
    case got of
      Left msg ->
        assertTrue "names floor" ("2.7.0" `T.isInfixOf` msg)
      Right o -> assertFailure ("expected resolve miss, got " <> show o)
    calls <- readIORef builds
    assertEq "no docker build on resolve miss" [] calls
    dfExists <- doesFileExist (sidecar </> "Dockerfile")
    assertTrue "did not write recipe" (not dfExists)

testPruneRmiThenPruneF :: IO ()
testPruneRmiThenPruneF =
  withSystemTempDirectory "om-ensure-prune" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        oldId = "sha256:old"
        newId = "sha256:new"
    createDirectoryIfMissing True overlay
    builds <- mkLogRef
    fake <- mkFakeDocker True newId builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    modifyMVar_ (ecPrevImageId cfg) (\_ -> pure (Just oldId))
    prunePreviousMaterializeImage cfg
    calls <- readIORef builds
    assertTrue "rmi previous id" (["rmi", oldId] `elem` calls)
    assertTrue "image prune -f" (["image", "prune", "-f"] `elem` calls)
    assertTrue "not prune -a" (not (any ("-a" `elem`) calls))
    assertTrue
      "not builder prune"
      (not (any ("builder" `elem`) calls))

testInspectMissingMessage :: IO ()
testInspectMissingMessage = do
  let tag = "mndz-overlay-manager/materialize:local"
      fake req = case prMode req of
        ExecCmd "docker" ("image" : "inspect" : _) ->
          pure
            ProcessResult
              { prExitCode = ExitFailure 1,
                prStdout = "",
                prStderr = "No such image"
              }
        _ ->
          pure
            ProcessResult
              { prExitCode = ExitFailure 127,
                prStdout = "",
                prStderr = "unexpected"
              }
  got <- inspectMaterializeImage fake tag
  case got of
    Left msg -> do
      assertEq "inspect uses missingImageMessage" (missingImageMessage tag) msg
      assertTrue
        "no in-repo Dockerfile recipe"
        (not ("docker/materialize/Dockerfile" `T.isInfixOf` msg))
      assertTrue "mentions ensure" ("ensures the default tag" `T.isInfixOf` msg)
    Right () -> assertFailure "expected inspect miss"

------------------------------------------------------------------------
-- Image-store layout parse (pure)
------------------------------------------------------------------------

giB :: Integer
giB = 1024 * 1024 * 1024

testParseDockerInfoFixtures :: IO ()
testParseDockerInfoFixtures = do
  overlay2 <-
    case parseDockerInfoJson (T.pack classicInfoJson) of
      Left err -> assertFailure ("overlay2 JSON: " <> T.unpack err)
      Right facts -> pure facts
  assertEq "overlay2 root" "/var/lib/docker" (difDockerRootDir overlay2)
  assertEq "overlay2 not snapshotter" False (difUsesSnapshotter overlay2)
  assertEq
    "overlay2 dump not needed"
    False
    (containerdDumpNeeded overlay2)
  assertEq
    "system socket is not bundled"
    False
    (isBundledContainerdAddress "/run/containerd/containerd.sock")

  let systemJson =
        dockerInfoJson
          "/var/lib/docker"
          True
          "/run/containerd/containerd.sock"
  systemFacts <-
    case parseDockerInfoJson (T.pack systemJson) of
      Left err -> assertFailure ("system JSON: " <> T.unpack err)
      Right facts -> pure facts
  assertEq "system snapshotter" True (difUsesSnapshotter systemFacts)
  assertEq
    "system dump needed"
    True
    (containerdDumpNeeded systemFacts)
  assertEq
    "system address"
    (Just "/run/containerd/containerd.sock")
    (difContainerdAddress systemFacts)

  let bundledJson =
        dockerInfoJson
          "/var/lib/docker"
          True
          "/run/docker/containerd/containerd.sock"
  bundledFacts <-
    case parseDockerInfoJson (T.pack bundledJson) of
      Left err -> assertFailure ("bundled JSON: " <> T.unpack err)
      Right facts -> pure facts
  assertEq "bundled snapshotter" True (difUsesSnapshotter bundledFacts)
  assertTrue
    "bundled address"
    (isBundledContainerdAddress "/run/docker/containerd/containerd.sock")
  assertEq
    "bundled dump not needed"
    False
    (containerdDumpNeeded bundledFacts)

  case parseDockerInfoJson "{\"DriverStatus\":[]}" of
    Left msg ->
      assertEq
        "missing DockerRootDir"
        (imageStoreUnresolvedMessage "docker info did not report DockerRootDir")
        msg
    Right facts ->
      assertFailure ("expected missing root, got " <> show facts)

testParseContainerdDump :: IO ()
testParseContainerdDump = do
  case parseContainerdDump (T.pack (containerdDumpText "/var/lib/containerd" Nothing)) of
    Left err -> assertFailure ("dump root: " <> T.unpack err)
    Right path -> assertEq "top-level root" "/var/lib/containerd" path
  case parseContainerdDump
    (T.pack (containerdDumpText "/var/lib/containerd" (Just "/custom/snap"))) of
    Left err -> assertFailure ("dump root_path: " <> T.unpack err)
    Right path -> assertEq "non-empty root_path wins" "/custom/snap" path
  case parseContainerdDump "version = 2\n" of
    Left msg ->
      assertEq "dump miss" containerdRootUnresolvedMessage msg
    Right path -> assertFailure ("expected dump miss, got " <> path)
  case parseContainerdDump "root = ''\n" of
    Left msg ->
      assertEq "empty root" containerdRootUnresolvedMessage msg
    Right path -> assertFailure ("expected empty root fail, got " <> path)

testImageStoreLayout :: IO ()
testImageStoreLayout = do
  overlay2 <-
    case parseDockerInfoJson (T.pack classicInfoJson) of
      Left err -> assertFailure (T.unpack err)
      Right facts -> pure facts
  case imageStoreLayout overlay2 Nothing of
    Left err -> assertFailure ("classic layout: " <> T.unpack err)
    Right layout -> do
      assertEq "classic layers" ["/var/lib/docker"] (islLayerPaths layout)
      assertEq "classic cache" ["/var/lib/docker"] (islCachePaths layout)

  bundled <-
    case parseDockerInfoJson
      ( T.pack
          ( dockerInfoJson
              "/var/lib/docker"
              True
              "/run/docker/containerd/containerd.sock"
          )
      ) of
      Left err -> assertFailure (T.unpack err)
      Right facts -> pure facts
  case imageStoreLayout bundled Nothing of
    Left err -> assertFailure ("bundled layout: " <> T.unpack err)
    Right layout -> do
      assertEq "bundled layers" ["/var/lib/docker"] (islLayerPaths layout)
      assertEq "bundled cache" ["/var/lib/docker"] (islCachePaths layout)

  systemFacts <-
    case parseDockerInfoJson
      ( T.pack
          ( dockerInfoJson
              "/var/lib/docker"
              True
              "/run/containerd/containerd.sock"
          )
      ) of
      Left err -> assertFailure (T.unpack err)
      Right facts -> pure facts
  case imageStoreLayout systemFacts Nothing of
    Left msg ->
      assertTrue
        "system without root is discovery"
        ("could not resolve the image store" `T.isInfixOf` msg)
    Right layout ->
      assertFailure ("expected discovery miss, got " <> show layout)
  case imageStoreLayout systemFacts (Just "/var/lib/containerd") of
    Left err -> assertFailure ("system layout: " <> T.unpack err)
    Right layout -> do
      assertEq
        "system layers"
        ["/var/lib/containerd"]
        (islLayerPaths layout)
      assertEq "system cache" ["/var/lib/docker"] (islCachePaths layout)

testRoleBounds :: IO ()
testRoleBounds = do
  assertEq "first combined" (20 * giB) firstImageNeedBytes
  assertEq "add combined" (8 * giB) addToolchainNeedBytes
  assertEq "first layers" (16 * giB) firstImageLayerNeedBytes
  assertEq "first cache" (6 * giB) firstImageCacheNeedBytes
  assertEq "add layers" (6 * giB) addToolchainLayerNeedBytes
  assertEq "add cache" (2 * giB) addToolchainCacheNeedBytes
  assertTrue
    "split first does not sum past combined"
    ( firstImageLayerNeedBytes + firstImageCacheNeedBytes
        > firstImageNeedBytes
    )

------------------------------------------------------------------------
-- Split / discovery ensure IO
------------------------------------------------------------------------

splitProbe ::
  FilePath ->
  FilePath ->
  Integer ->
  Integer ->
  DiskSpaceProbe
splitProbe cachePath layerPath cacheFree layerFree =
  DiskSpaceProbe
    { dspFreeBytes = \p ->
        pure $
          Right $
            if p == cachePath
              then cacheFree
              else
                if p == layerPath
                  then layerFree
                  else 1024 * 1024,
      dspDeviceId = \p ->
        pure $
          Right $
            if p == cachePath
              then 10
              else
                if p == layerPath
                  then 20
                  else 1
    }

systemSnapshotterFake ::
  FilePath ->
  Maybe FilePath ->
  IORef [[String]] ->
  IO FakeDocker
systemSnapshotterFake dockerRoot mLayerRoot builds = do
  fake <- mkFakeDocker False "" builds
  pure
    fake
      { fdDockerInfoJson =
          dockerInfoJson dockerRoot True "/run/containerd/containerd.sock",
        fdContainerdDump =
          fmap (`containerdDumpText` Nothing) mLayerRoot
      }

assertNoBuild :: IORef [[String]] -> IO ()
assertNoBuild builds = do
  calls <- readIORef builds
  assertEq "no docker build" [] calls

testSplitCacheShort :: IO ()
testSplitCacheShort =
  withSystemTempDirectory "om-ensure-split-cache" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        dockerRoot = tmp </> "docker"
        layerRoot = tmp </> "containerd"
    createDirectoryIfMissing True overlay
    createDirectoryIfMissing True dockerRoot
    createDirectoryIfMissing True layerRoot
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- systemSnapshotterFake dockerRoot (Just layerRoot) builds
    let probe = splitProbe dockerRoot layerRoot giB (50 * giB)
    cfg <- mkCfg overlay sidecar fake probe Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names cache path" (T.pack dockerRoot `T.isInfixOf` msg)
        assertTrue "names layer path" (T.pack layerRoot `T.isInfixOf` msg)
        assertTrue "names cache role" ("build cache" `T.isInfixOf` msg)
        assertTrue "names layer role" ("image layers" `T.isInfixOf` msg)
        assertTrue "mentions free" ("free:" `T.isInfixOf` msg)
        assertTrue "mentions need" ("need:" `T.isInfixOf` msg)
      Right o -> assertFailure ("expected cache-short fail, got " <> show o)
    assertNoBuild builds

testSplitLayersShort :: IO ()
testSplitLayersShort =
  withSystemTempDirectory "om-ensure-split-layers" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        dockerRoot = tmp </> "docker"
        layerRoot = tmp </> "containerd"
    createDirectoryIfMissing True overlay
    createDirectoryIfMissing True dockerRoot
    createDirectoryIfMissing True layerRoot
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- systemSnapshotterFake dockerRoot (Just layerRoot) builds
    let probe = splitProbe dockerRoot layerRoot (50 * giB) giB
    cfg <- mkCfg overlay sidecar fake probe Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names cache path" (T.pack dockerRoot `T.isInfixOf` msg)
        assertTrue "names layer path" (T.pack layerRoot `T.isInfixOf` msg)
        assertTrue "names cache role" ("build cache" `T.isInfixOf` msg)
        assertTrue "names layer role" ("image layers" `T.isInfixOf` msg)
      Right o -> assertFailure ("expected layers-short fail, got " <> show o)
    assertNoBuild builds

testSplitAmpleOverlayTiny :: IO ()
testSplitAmpleOverlayTiny =
  withSystemTempDirectory "om-ensure-split-ok" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        dockerRoot = tmp </> "docker"
        layerRoot = tmp </> "containerd"
    createDirectoryIfMissing True overlay
    createDirectoryIfMissing True dockerRoot
    createDirectoryIfMissing True layerRoot
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- systemSnapshotterFake dockerRoot (Just layerRoot) builds
    let probe = splitProbe dockerRoot layerRoot (100 * giB) (100 * giB)
    cfg <- mkCfg overlay sidecar fake probe Nothing
    got <- ensureMaterializeImage cfg neededGo
    assertEq "built despite tiny overlay" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)

testSnapshotterDumpMiss :: IO ()
testSnapshotterDumpMiss =
  withSystemTempDirectory "om-ensure-dump-miss" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        dockerRoot = tmp </> "docker"
    createDirectoryIfMissing True overlay
    createDirectoryIfMissing True dockerRoot
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- systemSnapshotterFake dockerRoot Nothing builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue
          "unresolved store"
          ("could not resolve the image store" `T.isInfixOf` msg)
        assertTrue
          "dump hint"
          ("containerd config dump must yield a root" `T.isInfixOf` msg)
        assertTrue "not a free-space line" (not ("free:" `T.isInfixOf` msg))
        assertEq
          "helper matches"
          containerdRootUnresolvedMessage
          (sndPrefix msg)
      Right o -> assertFailure ("expected discovery fail, got " <> show o)
    assertNoBuild builds
    dumps <- readIORef (fdContainerdCalls fake)
    assertTrue "invoked dump" (["config", "dump"] `elem` dumps)
    assertTrue
      "no --config"
      (not (any ("--config" `elem`) dumps))
  where
    sndPrefix msg =
      let pfx = ensureFailedMessage ""
          stripped =
            if pfx `T.isPrefixOf` msg
              then T.drop (T.length pfx) msg
              else msg
       in stripped

testSnapshotterRootMissing :: IO ()
testSnapshotterRootMissing =
  withSystemTempDirectory "om-ensure-root-miss" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        dockerRoot = tmp </> "docker"
        missingRoot = tmp </> "no-such-containerd"
    createDirectoryIfMissing True overlay
    createDirectoryIfMissing True dockerRoot
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake <- systemSnapshotterFake dockerRoot (Just missingRoot) builds
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue
          "unresolved store"
          ("could not resolve the image store" `T.isInfixOf` msg)
        assertTrue "not a free-space line" (not ("free:" `T.isInfixOf` msg))
      Right o -> assertFailure ("expected discovery fail, got " <> show o)
    assertNoBuild builds

testBundledSnapshotterNoDump :: IO ()
testBundledSnapshotterNoDump =
  withSystemTempDirectory "om-ensure-bundled" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
    createDirectoryIfMissing True overlay
    seedGoAmd64 (tmp </> "gentoo")
    builds <- mkLogRef
    fake0 <- mkFakeDocker False "" builds
    let fake =
          fake0
            { fdDockerInfoJson =
                dockerInfoJson
                  "/var/lib/docker"
                  True
                  "/run/docker/containerd/containerd.sock"
            }
    cfg <- mkCfg overlay sidecar fake plentyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    assertEq "bundled still builds" (Right EnsureBuilt) got
    calls <- readIORef builds
    assertTrue "docker build ran" (any ("-t" `elem`) calls)
    dumps <- readIORef (fdContainerdCalls fake)
    assertEq "bundled does not dump" [] dumps
