{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for smoke runtime floor readers, run planning, and the
-- local-tree ceiling loader.
module Test.SmokePlan (tests) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Smoke.Ceilings (loadHostCeilings)
import Smoke.Floors
  ( bunFloor,
    cargoFloor,
    ecosystemFloor,
    goFloor,
    nodejsFloor,
    pythonSlot,
    sbclFloor,
  )
import Smoke.Plan
  ( HostCeilings (..),
    LaneRuntime (..),
    PackageInput (..),
    PlannedItem (..),
    RuntimeCap (..),
    SmokeRun (..),
    itemAtom,
    planSmokeRuns,
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Types
  ( CargoSource (..),
    EcosystemSpec (..),
    UpdateTechnique (..),
    mkPackageKey,
  )

tests :: TestTree
tests =
  testGroup
    "SmokePlan"
    [ testGroup
        "floors"
        [ testCase "beads Go floor" $
            assertEq "beads" (Just (v "1.26.5")) (goFloor beadsText),
          testCase "gastown Go floor" $
            assertEq "gastown" (Just (v "1.25.8")) (goFloor gastownText),
          testCase "node-gyp Node.js floor" $
            assertEq "node-gyp" (Just (v "22.22.2")) (nodejsFloor nodeGypText),
          testCase "claude-agent-acp bare-major Node.js floor" $
            assertEq "claude-agent-acp" (Just (v "22")) (nodejsFloor claudeAgentAcpText),
          testCase "autolith SBCL floor" $
            assertEq "autolith" (Just (v "2.6.6")) (sbclFloor autolithText),
          testCase "mise RUST_MIN_VER floor" $
            assertEq "mise" (Just (v "1.95.0")) (cargoFloor miseText),
          testCase "opencode compile pin is its exact version" $
            assertEq "opencode" (Just (v "1.4.4")) (bunFloor opencodeText),
          testCase "ralph-tui Bun floor" $
            assertEq "ralph-tui" (Just (v "1.3.6")) (bunFloor ralphTuiText),
          testCase "codex-as-mcp Python slot" $
            assertEq "codex-as-mcp" (Just "3.13") (pythonSlot codexAsMcpText),
          testCase "ebuild without a floor" $ do
            assertEq "go" Nothing (goFloor denoBinText)
            assertEq "cargo" Nothing (cargoFloor denoBinText)
            assertEq "slot" Nothing (pythonSlot denoBinText),
          testCase "upper bounds and comments are not floors" $
            assertEq
              "go"
              (Just (v "1.24"))
              (goFloor "# >=dev-lang/go-1.30\nBDEPEND=\"<dev-lang/go-1.29 >=dev-lang/go-1.24:= <=dev-lang/go-1.28\"\n"),
          testCase "go-bootstrap is not a Go floor" $
            assertEq "go" Nothing (goFloor "BDEPEND=\">=dev-lang/go-bootstrap-1.24\"\n"),
          testCase "Uv and Pdm have no lane floor" $
            assertEq "uv" Nothing (ecosystemFloor (Uv Nothing) codexAsMcpText)
        ],
      testGroup
        "plan"
        [ testCase "ebuild not keyworded for the host is skipped" testKeywordSkip,
          testCase "binary package gets one unlabeled run" testBinaryOneRun,
          testCase "Uv package gets one run with its slot" testUvOneRun,
          testCase "newest version serves both lanes" testNewestServesBoth,
          testCase "split lanes" testSplitLanes,
          testCase "equal ceilings collapse" testEqualCeilingsCollapse,
          testCase "runtime with only a tilde ceiling" testTildeOnly,
          testCase "ebuild with no floor qualifies under every ceiling" testNoFloorQualifies,
          testCase "retained older version is capped at plain" testRetainedOlder,
          testCase "floor above every ceiling is a plan failure" testFloorAboveEvery,
          testCase "runtime without a host ceiling is a plan failure" testNoHostCeiling,
          testCase "live ebuilds are not tested" testLiveNotTested,
          testCase "stable order: key, version, plain before tilde" testStableOrder,
          testCase "Cargo lane label names the rust union" testCargoLabel
        ],
      testGroup
        "ceilings"
        [ testCase "loader reads host-arch ceilings from local trees only" testLoaderLocal
        ]
    ]

v :: Text -> EbuildVersion
v = parseEbuildVersion

eb :: Text -> Text -> Text -> Ebuild
eb cat pn ver =
  Ebuild
    { ebuildCategory = cat,
      ebuildPackage = pn,
      ebuildVersion = ver,
      ebuildPath = T.unpack ("/ov/" <> cat <> "/" <> pn <> "/" <> pn <> "-" <> ver <> ".ebuild")
    }

goPkg :: Text -> [(Text, Text)] -> PackageInput
goPkg pn vers =
  PackageInput
    { piKey = mkPackageKey "dev-util" pn,
      piTechnique = DepsAndAssets (Go Nothing),
      piEbuilds = [(eb "dev-util" pn ver, goBody floor') | (ver, floor') <- vers]
    }

goBody :: Text -> Text
goBody floor' =
  "BDEPEND=\">=dev-lang/go-" <> floor' <> ":=\"\nKEYWORDS=\"~amd64 ~arm64\"\n"

goCeilings :: Maybe Text -> Maybe Text -> Map.Map LaneRuntime HostCeilings
goCeilings p t = Map.singleton RuntimeGo (HostCeilings (v <$> p) (v <$> t))

lines' :: [PlannedItem] -> [Text]
lines' = map describe
  where
    describe item = case item of
      PlannedRun _ -> itemAtom item <> ": run"
      PlannedSkip _ r -> itemAtom item <> ": skip: " <> r
      PlannedFail _ r -> itemAtom item <> ": fail: plan (" <> r <> ")"

testKeywordSkip :: IO ()
testKeywordSkip = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-util" "claude-agent-acp",
            piTechnique = DepsAndAssets NpmEco,
            piEbuilds = [(eb "dev-util" "claude-agent-acp" "0.107.0", claudeAgentAcpText)]
          }
      ceilings = Map.singleton RuntimeNodejs (HostCeilings (Just (v "22.22.2")) Nothing)
  case planSmokeRuns "arm64" ceilings [pkg] of
    [PlannedSkip _ reason] -> assertTrue "names arm64" ("arm64" `T.isInfixOf` reason)
    other -> assertFailure ("expected one skip, got " <> show other)

testBinaryOneRun :: IO ()
testBinaryOneRun = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-lang" "deno-bin",
            piTechnique = GitMvAndManifest,
            piEbuilds = [(eb "dev-lang" "deno-bin" "2.9.8", denoBinText)]
          }
  assertEq
    "one unlabeled run"
    ["dev-lang/deno-bin-2.9.8: run"]
    (lines' (planSmokeRuns "amd64" Map.empty [pkg]))

testUvOneRun :: IO ()
testUvOneRun = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-util" "codex-as-mcp",
            piTechnique = DepsAndAssets (Uv Nothing),
            piEbuilds = [(eb "dev-util" "codex-as-mcp" "2026.6.29.1", codexAsMcpText)]
          }
  case planSmokeRuns "amd64" Map.empty [pkg] of
    [PlannedRun run] -> do
      assertEq "slot" (Just "3.13") (srPythonSlot run)
      assertEq "no cap" Nothing (srCap run)
    other -> assertFailure ("expected one run, got " <> show other)

testNewestServesBoth :: IO ()
testNewestServesBoth =
  assertEq
    "beads"
    [ "dev-util/beads-1.0.4 (dev-lang/go amd64): run",
      "dev-util/beads-1.3.4 (dev-lang/go amd64): run",
      "dev-util/beads-1.3.4 (dev-lang/go ~amd64): run"
    ]
    ( lines' $
        planSmokeRuns
          "amd64"
          (goCeilings (Just "1.26.11") (Just "1.27.4"))
          [goPkg "beads" [("1.3.4", "1.26.5"), ("1.0.4", "1.26.2")]]
    )

testSplitLanes :: IO ()
testSplitLanes =
  assertEq
    "split"
    [ "dev-util/beads-1.0.4 (dev-lang/go amd64): run",
      "dev-util/beads-1.3.4 (dev-lang/go ~amd64): run"
    ]
    ( lines' $
        planSmokeRuns
          "amd64"
          (goCeilings (Just "1.26.11") (Just "1.27.4"))
          [goPkg "beads" [("1.0.4", "1.26.2"), ("1.3.4", "1.27.1")]]
    )

testEqualCeilingsCollapse :: IO ()
testEqualCeilingsCollapse =
  assertEq
    "one run"
    ["dev-util/crush-0.101.0 (dev-lang/go amd64): run"]
    ( lines' $
        planSmokeRuns
          "amd64"
          (goCeilings (Just "1.27.4") (Just "1.27.4"))
          [goPkg "crush" [("0.101.0", "1.27.3")]]
    )

testTildeOnly :: IO ()
testTildeOnly = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-util" "opencode",
            piTechnique = DepsAndAssets Bun,
            piEbuilds = [(eb "dev-util" "opencode" "2.3.0", opencodeText)]
          }
      ceilings = Map.singleton RuntimeBun (HostCeilings Nothing (Just (v "1.4.4")))
  assertEq
    "tilde run"
    ["dev-util/opencode-2.3.0 (dev-lang/bun-bin ~amd64): run"]
    (lines' (planSmokeRuns "amd64" ceilings [pkg]))

testNoFloorQualifies :: IO ()
testNoFloorQualifies = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-util" "nofloor",
            piTechnique = DepsAndAssets (Go Nothing),
            piEbuilds = [(eb "dev-util" "nofloor" "1.0", "KEYWORDS=\"~amd64\"\n")]
          }
  assertEq
    "both lanes"
    [ "dev-util/nofloor-1.0 (dev-lang/go amd64): run",
      "dev-util/nofloor-1.0 (dev-lang/go ~amd64): run"
    ]
    (lines' (planSmokeRuns "amd64" (goCeilings (Just "1.26.11") (Just "1.27.4")) [pkg]))

testRetainedOlder :: IO ()
testRetainedOlder =
  case planSmokeRuns "amd64" (goCeilings (Just "1.26.11") (Just "1.27.4")) [goPkg "beads" [("1.0.4", "1.26.2"), ("1.3.4", "1.26.5")]] of
    PlannedRun run : _ -> do
      assertEq "older version" "1.0.4" (ebuildVersion (srEbuild run))
      assertEq "plain cap" (Just (v "1.26.11")) (fmap capCeiling (srCap run))
    other -> assertFailure ("expected a run first, got " <> show other)

testFloorAboveEvery :: IO ()
testFloorAboveEvery =
  case planSmokeRuns "amd64" (goCeilings (Just "1.26.11") (Just "1.27.4")) [goPkg "beads" [("2.0.0", "1.28.0")]] of
    [PlannedFail _ reason] -> do
      assertTrue "names floor" ("1.28.0" `T.isInfixOf` reason)
      assertTrue "names tilde ceiling" ("1.27.4" `T.isInfixOf` reason)
      assertTrue "names plain ceiling" ("1.26.11" `T.isInfixOf` reason)
    other -> assertFailure ("expected one plan failure, got " <> show other)

testNoHostCeiling :: IO ()
testNoHostCeiling =
  case planSmokeRuns "amd64" Map.empty [goPkg "beads" [("1.3.4", "1.26.5")]] of
    [PlannedFail _ reason] -> assertTrue "names runtime" ("dev-lang/go" `T.isInfixOf` reason)
    other -> assertFailure ("expected one plan failure, got " <> show other)

testLiveNotTested :: IO ()
testLiveNotTested =
  assertEq
    "live dropped"
    ["dev-util/crush-0.101.0 (dev-lang/go amd64): run"]
    ( lines' $
        planSmokeRuns
          "amd64"
          (goCeilings (Just "1.27.4") Nothing)
          [goPkg "crush" [("9999", "1.27.3"), ("0.101.0", "1.27.3")]]
    )

testStableOrder :: IO ()
testStableOrder =
  assertEq
    "order"
    [ "dev-util/beads-1.0.4 (dev-lang/go amd64): run",
      "dev-util/beads-1.3.4 (dev-lang/go amd64): run",
      "dev-util/beads-1.3.4 (dev-lang/go ~amd64): run",
      "dev-util/crush-0.9.0 (dev-lang/go amd64): run",
      "dev-util/crush-0.10.0 (dev-lang/go amd64): run",
      "dev-util/crush-0.10.0 (dev-lang/go ~amd64): run"
    ]
    ( lines' $
        planSmokeRuns
          "amd64"
          (goCeilings (Just "1.26.11") (Just "1.27.4"))
          [ goPkg "crush" [("0.10.0", "1.26.0"), ("0.9.0", "1.26.0")],
            goPkg "beads" [("1.3.4", "1.26.5"), ("1.0.4", "1.26.2")]
          ]
    )

testCargoLabel :: IO ()
testCargoLabel = do
  let pkg =
        PackageInput
          { piKey = mkPackageKey "dev-util" "mise",
            piTechnique = DepsAndAssets (Cargo Nothing Nothing CargoGitTag),
            piEbuilds = [(eb "dev-util" "mise" "2026.11.8", miseText)]
          }
      ceilings = Map.singleton RuntimeRust (HostCeilings (Just (v "1.95.0")) (Just (v "1.96.0")))
  assertEq
    "labels"
    [ "dev-util/mise-2026.11.8 (dev-lang/rust|rust-bin amd64): run",
      "dev-util/mise-2026.11.8 (dev-lang/rust|rust-bin ~amd64): run"
    ]
    (lines' (planSmokeRuns "amd64" ceilings [pkg]))

-- | The loader's only inputs are two directories: it takes no HTTP manager
-- and no check cache, so planning cannot reach upstream.
testLoaderLocal :: IO ()
testLoaderLocal =
  withSystemTempDirectory "om-smoke-ceilings" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        overlay = tmp </> "ov"
    writeEbuild (gentoo </> "dev-lang" </> "go") "go-1.26.11.ebuild" "KEYWORDS=\"-* amd64 arm64\"\n"
    writeEbuild (gentoo </> "dev-lang" </> "go") "go-1.27.4.ebuild" "KEYWORDS=\"-* ~amd64 arm64\"\n"
    writeEbuild (gentoo </> "dev-lang" </> "go") "go-9999.ebuild" "KEYWORDS=\"\"\n"
    writeEbuild (overlay </> "dev-lang" </> "bun-bin") "bun-bin-1.4.4.ebuild" "KEYWORDS=\"-* ~amd64 ~arm64\"\n"
    got <- loadHostCeilings "amd64" gentoo overlay [RuntimeGo, RuntimeBun, RuntimeSbcl]
    m <- assertRight "loaded" got
    assertEq
      "go amd64"
      (Just (HostCeilings (Just (v "1.26.11")) (Just (v "1.27.4"))))
      (Map.lookup RuntimeGo m)
    assertEq
      "bun amd64"
      (Just (HostCeilings Nothing (Just (v "1.4.4"))))
      (Map.lookup RuntimeBun m)
    assertEq
      "missing sbcl has no ceiling"
      (Just (HostCeilings Nothing Nothing))
      (Map.lookup RuntimeSbcl m)
    assertEq "only requested runtimes" Nothing (Map.lookup RuntimeNodejs m)
  where
    writeEbuild dir name body = do
      createDirectoryIfMissing True dir
      TIO.writeFile (dir </> name) body

------------------------------------------------------------------------
-- Fixture texts copied from the overlay's ebuilds (relevant lines).

beadsText :: Text
beadsText =
  T.unlines
    [ "EAPI=8",
      "inherit go-module",
      "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
      "LICENSE=\"MIT\"",
      "SLOT=\"0\"",
      "KEYWORDS=\"~amd64 ~arm ~arm64 ~loong ~mips ~ppc64 ~riscv ~s390 ~x64-macos ~x64-solaris ~x86\""
    ]

gastownText :: Text
gastownText =
  T.unlines
    [ "EAPI=8",
      "inherit go-module",
      "BDEPEND=\">=dev-lang/go-1.25.8:=\"",
      "KEYWORDS=\"~amd64 ~arm ~arm64 ~loong ~mips ~ppc64 ~riscv ~s390 ~x64-macos ~x64-solaris ~x86\""
    ]

nodeGypText :: Text
nodeGypText =
  T.unlines
    [ "KEYWORDS=\"~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x64-macos ~x86\"",
      "RDEPEND=\"",
      "\t>=net-libs/nodejs-22.22.2[npm]",
      "\tdev-lang/python",
      "\""
    ]

claudeAgentAcpText :: Text
claudeAgentAcpText =
  T.unlines
    [ "KEYWORDS=\"-* ~amd64\"",
      "RDEPEND=\"",
      "\t>=net-libs/nodejs-22[npm]",
      "\t!bundled-claude? ( !external-claude? ( dev-util/claude-code ) )",
      "\"",
      "BDEPEND=\"${RDEPEND}\""
    ]

autolithText :: Text
autolithText =
  T.unlines
    [ "# Template body owned by seed packaging; manager rewrite may touch KEYWORDS,",
      "KEYWORDS=\"~amd64 ~ppc ~ppc64 ~riscv ~sparc ~x64-macos ~x86\"",
      "BDEPEND=\"",
      "\t>=dev-lisp/sbcl-2.6.6:=[source]",
      "\"",
      "\t\tdie \"host SBCL ${host_pv} is older than Autolith floor ${floor} (need >=dev-lisp/sbcl-2.6.6:=[source]-${floor}[source])\""
    ]

miseText :: Text
miseText =
  T.unlines
    [ "# Autogenerated by pycargoebuild 0.16.0",
      "EAPI=8",
      "RUST_MIN_VER=\"1.95.0\"",
      "CRATES=\"\"",
      "KEYWORDS=\"~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86\""
    ]

opencodeText :: Text
opencodeText =
  T.unlines
    [ "KEYWORDS=\"~amd64 ~arm64\"",
      "BDEPEND=\"~dev-lang/bun-bin-1.4.4\""
    ]

ralphTuiText :: Text
ralphTuiText =
  T.unlines
    [ "KEYWORDS=\"~amd64 ~arm64\"",
      "BDEPEND=\">=dev-lang/bun-bin-1.3.6:0\""
    ]

codexAsMcpText :: Text
codexAsMcpText =
  T.unlines
    [ "EAPI=8",
      "PYTHON_COMPAT=( python3_13 )",
      "inherit python-single-r1",
      "KEYWORDS=\"~alpha ~amd64 ~arm ~arm64 ~hppa ~loong ~m68k ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86\"",
      "RDEPEND=\"",
      "\t${PYTHON_DEPS}",
      "\tdev-lang/python:3.13",
      "\""
    ]

denoBinText :: Text
denoBinText =
  T.unlines
    [ "EAPI=8",
      "SRC_URI=\"amd64? ( https://github.com/denoland/deno/releases/download/v${PV}/deno-x86_64-unknown-linux-gnu.zip -> ${P}-amd64.zip )\"",
      "KEYWORDS=\"-* ~amd64 ~arm64\""
    ]
