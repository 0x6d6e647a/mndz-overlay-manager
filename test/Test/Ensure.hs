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
  ( LaneTarget (..),
    RuntimeLanePlan (..),
    pattern LaneAmd64Plain,
  )
import Update.Materialize
  ( EnsureConfig (..),
    EnsureOutcome (..),
    ImageSidecar (..),
    NeededFloors (..),
    RecipeArch (..),
    ResolvedInstall (..),
    ResolvedToolchain (..),
    ToolchainKind (..),
    addToolchainNeedBytes,
    decodeImageSidecar,
    defaultMaterializeSidecarDirFromEnv,
    emptyFloors,
    encodeImageSidecar,
    ensureFailedMessage,
    ensureMaterializeImage,
    firstImageNeedBytes,
    floorsSatisfy,
    imageDiskInsufficientMessage,
    imageSidecarSchemaVersion,
    lookupRecipeArch,
    materializeGeneratorId,
    neededFloorsFromClassified,
    overrideUnusableMessage,
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
import Update.Runtime.Ceilings (RuntimeEbuildMeta (..))
import Update.Types
  ( EcosystemSpec (..),
    UpdateSource (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "Ensure"
    [ testCase "union/satisfy Go floors" testUnionSatisfy,
      testCase "Bun-only first image omits SBCL" testBunOnlyOmitsSbcl,
      testCase "rust-bin preferred over plain rust" testResolvePrefersRustBin,
      testCase "sbcl without -bin picks source and ~amd64 accept" testResolveSbclNoBinTilde,
      testCase "missing ebuilds at floor is a resolve miss" testResolveMissingFloorMiss,
      testCase "floor 0 is unversioned; ~arch only without plain ebuild" testResolveFloorZero,
      testCase "full-path 1.24 + reuse 1.26 → Go floor 1.24" testFullPathFloorIgnoresReuseSibling,
      testCase "render contains ::mndz and no official tarball URLs" testRenderMndzNoOfficial,
      testCase "uname map splits KEYWORDS from OpenRC Hub tag" testLookupRecipeArch,
      testCase "x86_64 recipe uses amd64-openrc FROM and ~amd64 keywords" testAmd64OpenrcRecipe,
      testCase "ppc64le recipe uses ppc64le-openrc FROM and ~ppc64 keywords" testPpc64leOpenrcRecipe,
      testCase "SBCL testing floor is one emerge plus ::gentoo ~amd64" testRenderSbclTestingFloor,
      testCase "missing sidecar field is a miss" testMissingSidecarField,
      testCase "skip docker build when satisfies" testSkipWhenSatisfies,
      testCase "generator mismatch rebuilds despite floors" testGeneratorMismatchRebuilds,
      testCase "unmapped uname hard-fails without docker build" testUnmappedDefaultNoBuild,
      testCase "override on unmapped uname skips generate" testOverrideUnmappedNoBuild,
      testCase "override missing hard-fails without build" testOverrideMissingNoBuild,
      testCase "fake build records union satisfies" testFakeBuildRecordsUnion,
      testCase "image disk gate skipped when satisfies" testDiskGateSkippedWhenSatisfies,
      testCase "first build fails early on tiny disk" testFirstBuildDiskFail,
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
                pdContentFix = [parseEbuildVersion "1.0.0"]
              }
        ]
      needed = neededFloorsFromClassified classify plan (Just "1.2.0")
  assertEq "bun floor" (Just "1.2.0") (nfBun needed)
  assertEq "no SBCL on first bun-only" Nothing (nfSbcl needed)
  assertEq "no Go on bun-only" Nothing (nfGo needed)
  df <- renderMapped "x86_64" [bunInstall "1.2.0" "amd64"] "/overlay"
  assertTrue "recipe has bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` df)
  assertTrue "recipe omits sbcl emerge" (not ("dev-lisp/sbcl" `T.isInfixOf` df))

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
                pdContentFix = []
              }
        ]
      needed = neededFloorsFromClassified classify plan Nothing
  assertEq "Go floor from full-path PV only" (Just "1.24.0") (nfGo needed)
  assertEq "no unused toolchains" Nothing (nfSbcl needed)

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
    (">=dev-lang/bun-bin-1.2.21::mndz ~amd64" `T.isInfixOf` df)
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
    (">=dev-lang/bun-bin-1.2.21::mndz ~amd64" `T.isInfixOf` df)

testPpc64leOpenrcRecipe :: IO ()
testPpc64leOpenrcRecipe = do
  df <- renderMapped "ppc64le" [bunInstall "1.2.21" "ppc64"] "/overlay"
  assertTrue
    "OpenRC FROM"
    ("FROM gentoo/stage3:ppc64le-openrc" `T.isInfixOf` df)
  assertTrue
    "bun-bin KEYWORDS ppc64"
    (">=dev-lang/bun-bin-1.2.21::mndz ~ppc64" `T.isInfixOf` df)

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
  df <- renderMapped "x86_64" [ResolvedInstall TkSbcl rt] "/overlay"
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
        rtEmergeSpec = ">=dev-lang/bun-bin-" <> ver <> "::mndz",
        rtAcceptLine = Just (">=dev-lang/bun-bin-" <> ver <> "::mndz ~" <> kw)
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
      glpRuntimeAtom = "dev-lang/bun-bin"
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
      glpRuntimeAtom = "dev-lang/go"
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
    fdBuildShouldRun :: IORef [[String]]
  }

mkLogRef :: IO (IORef [[String]])
mkLogRef = newIORef []

fakeRunner :: FakeDocker -> ProcessRequest -> IO ProcessResult
fakeRunner fake req = case prMode req of
  ExecCmd "docker" ("image" : "inspect" : rest) ->
    if fdInspectOk fake
      then
        pure
          ProcessResult
            { prExitCode = ExitSuccess,
              prStdout = fdInspectId fake <> "\n",
              prStderr = ""
            }
      else
        pure
          ProcessResult
            { prExitCode = ExitFailure 1,
              prStdout = "",
              prStderr = "Error: No such image: " <> last rest
            }
  ExecCmd "docker" ("build" : args) -> do
    atomicModifyIORef' (fdBuildShouldRun fake) (\xs -> (args : xs, ()))
    pure
      ProcessResult
        { prExitCode = ExitSuccess,
          prStdout = "",
          prStderr = ""
        }
  ExecCmd "docker" ("info" : _) ->
    pure
      ProcessResult
        { prExitCode = ExitSuccess,
          prStdout = "/var/lib/docker\n",
          prStderr = ""
        }
  ExecCmd "docker" ("rmi" : args) -> do
    atomicModifyIORef' (fdBuildShouldRun fake) (\xs -> (("rmi" : args) : xs, ()))
    pure
      ProcessResult
        { prExitCode = ExitSuccess,
          prStdout = "",
          prStderr = ""
        }
  ExecCmd "docker" ("image" : "prune" : args) -> do
    atomicModifyIORef'
      (fdBuildShouldRun fake)
      (\xs -> (("image" : "prune" : args) : xs, ()))
    pure
      ProcessResult
        { prExitCode = ExitSuccess,
          prStdout = "",
          prStderr = ""
        }
  _ ->
    pure
      ProcessResult
        { prExitCode = ExitFailure 127,
          prStdout = "",
          prStderr = "unexpected"
        }

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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = iid,
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = iid,
              fdBuildShouldRun = builds
            }
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

testUnmappedDefaultNoBuild :: IO ()
testUnmappedDefaultNoBuild =
  withSystemTempDirectory "om-ensure-unmapped" $ \tmp -> do
    let overlay = tmp </> "ov"
        sidecar = tmp </> "side"
        uname = "sparc64"
    createDirectoryIfMissing True overlay
    builds <- mkLogRef
    let fake =
          FakeDocker
            { fdInspectOk = False,
              fdInspectId = "",
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = "sha256:override",
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = False,
              fdInspectId = "",
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = oldId,
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = iid,
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = False,
              fdInspectId = "",
              fdBuildShouldRun = builds
            }
    cfg <- mkCfg overlay sidecar fake tinyDisk Nothing
    got <- ensureMaterializeImage cfg neededGo
    case got of
      Left msg -> do
        assertTrue "names docker path" ("/var/lib/docker" `T.isInfixOf` msg)
        assertTrue "mentions free" ("free:" `T.isInfixOf` msg)
        assertTrue "mentions need" ("need:" `T.isInfixOf` msg)
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
    let fake =
          FakeDocker
            { fdInspectOk = False,
              fdInspectId = "",
              fdBuildShouldRun = builds
            }
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
    let fake =
          FakeDocker
            { fdInspectOk = True,
              fdInspectId = newId,
              fdBuildShouldRun = builds
            }
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
