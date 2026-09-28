{-# LANGUAGE OverloadedStrings #-}

-- | Unit + Integration coverage for product Update.Check and Update.Deps.Plan
-- entry points with injectable Fetcher / DepsPlanOps — no live network.
module Test.CheckPlan (unitTests, integrationTests) where

import CLI.Jobs (newWorkBudget)
import CLI.Progress (MultiHandle (..), noopMultiHandle)
import Config.Types (CheckCacheTtl (..))
import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Support (dualArchGoCeilings)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Apply
  ( PackagePlanResult (..),
    PlanEnv (..),
    PlannedWork (..),
    planPackage,
  )
import Update.Cargo.Msrv (CargoTomlFetch (..))
import Update.Check
  ( PackageEntry (..),
    checkOverlayWithDepsPlan,
    checkPackage,
    checkPackageDeps,
    groupByPackage,
  )
import Update.CheckCache (CheckCacheHandle, openCheckCache)
import Update.Deps.Plan
  ( BunProbe,
    DepsPlanOps (..),
    minimumBunProbe,
    planDepsPackageWithProgress,
    planDepsPackageWithProgressDonor,
    readNpmDonorBody,
    toGoPlanOps,
    withBunEnginesSuccessCache,
    withListVersionsSuccessCache,
  )
import Update.EbuildEdit (ensureNodejsBdepend, nodejsBdependMatches)
import Update.Go.Lanes
  ( CargoTagFloorSnapshot (..),
    LaneTarget (..),
    PlanError (..),
    RuntimeLanePlan (..),
    planErrorMessage,
  )
import Update.Go.ModFetch (GoModKey (..))
import Update.Go.Plan (noopPlanProgress)
import Update.OverlayTree (withNewTreeLock)
import Update.OverlayWaves (bunBinPackageKey, overlayRefuseMessage)
import Update.Runtime.Ceilings (RuntimeCeilings (..))
import Update.Types
  ( CargoSource (..),
    EcosystemSpec (..),
    OutdatedLine (..),
    PackageKey (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    formatOutdatedLine,
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "CheckPlan"
    [ testGroup
        "formatOutdatedLine"
        [testCase "gap, removal, and note" testFormatOutdatedLine],
      testGroup
        "checkPackage GitMvAndManifest"
        [ testCase "outdated" testCheckPackageOutdated,
          testCase "ok" testCheckPackageOk,
          testCase "ahead" testCheckPackageAhead,
          testCase "fetch error" testCheckPackageFetchError,
          testCase "unconfigured" testCheckPackageUnconfigured,
          testCase "qlot outdated empty tag prefix" testCheckPackageQlotOutdated
        ],
      testGroup
        "checkPackageDeps"
        [ testCase "Go outdated via product plan" testCheckPackageDepsGoOutdated,
          testCase "plan failure becomes FetchError" testCheckPackageDepsPlanFail
        ],
      testGroup
        "planDepsPackageWithProgress"
        [ testCase "Go success" testPlanGoSuccess,
          testCase "Npm success" testPlanNpmSuccess,
          testCase "Bun success" testPlanBunSuccess,
          testCase "Cargo success" testPlanCargoSuccess,
          testCase "Cargo namespaced features plan" testPlanCargoNamespacedFeatures,
          testCase "Cargo incomplete newest skipped" testPlanCargoIncompleteSkipped,
          testCase "Cargo complete absence uses 0.0.0" testPlanCargoCompleteAbsence,
          testCase "Cargo parse failure fails package" testPlanCargoParseFails,
          testCase "Go wrong source" testPlanGoWrongSource,
          testCase "Npm wrong source" testPlanNpmWrongSource,
          testCase "Bun missing overlay" testPlanBunMissingOverlay,
          testCase "Cargo wrong source" testPlanCargoWrongSource,
          testCase "empty local PVs" testPlanNoNonLiveLocal,
          testCase "list versions failure" testPlanListVersionsFailed,
          testCase "zero planned PVs" testPlanZeroPlannedPVs,
          testCase "npm probe failure" testPlanNpmProbeFailed,
          testCase "npm absent engines uses donor" testPlanNpmAbsentEnginesUsesDonor,
          testCase "npm donor body is highest non-live" testReadNpmDonorHighest
        ],
      testGroup
        "overlay plan-delta refuse"
        [ testCase "refuse when bun-bin unselected and plan-delta" testRefusePlanDelta,
          testCase "no-delta still plans on-disk" testNoPlanDeltaAllowsOnDisk,
          testCase "provider fetch fail-closed" testRefuseFailClosed,
          testCase "ralph refuses, mise still plans" testRefuseRalphStillPlansMise,
          testCase "selected bun-bin uses hypo working plan" testSelectedBunBinHypoWorkingPlan,
          testCase "equal ceilings do not refuse and skip hypo list/probe" testRefuseEqualCeilingsSkip
        ],
      testGroup
        "deps plan success memos"
        [ testCase "successful list is cached; Left is retried" testListVersionsSuccessCache,
          testCase "successful bun probe is cached; Left is retried" testBunEnginesSuccessCache
        ]
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "CheckPlan"
    [ testCase
        "checkOverlayWithDepsPlan multi-package"
        testCheckOverlayWithDepsPlanMulti,
      testCase "contentFix Go content-only reusable" testContentFixGoReusable,
      testCase "contentFix Npm content-only reusable" testContentFixNpmReusable,
      testCase "contentFix Bun content-only reusable" testContentFixBunReusable,
      testCase "contentFix Cargo content-only reusable" testContentFixCargoReusable,
      testCase "Cargo written floor above tag is adequate" testCargoWrittenAboveTagAdequate,
      testCase "Codex pin-keyed rusty-v8 URL is adequate" testCodexRustyV8UrlAdequate,
      testCase "Cargo usage path-closure adequacy" testUsagePathClosureAdequacy,
      testCase "Cargo incomplete candidate is not a zero-floor gap" testIncompleteNotZeroFloorGap,
      testCase "checkPackageDeps Sbcl outdated floor" testCheckPackageDepsSbclOutdated,
      testCase "outdated ralph blocked on bun-bin" testOutdatedBlockedOn,
      testCase "outdated fail-closed when bun-bin latest missing" testOutdatedFailClosed,
      testCase "outdated bun-bin still has its own line" testOutdatedBunBinOwnLine,
      testCase "equal ceilings skip blocked-on and second list/probe" testOutdatedEqualCeilingsSkip,
      testCase "two hypothetical lanes stay two lines" testOutdatedTwoHypoLanes,
      testCase "satisfied hypothetical plan prints nothing" testOutdatedSatisfiedHypoSilent,
      testCase "left-out plan-delta with nothing to print still refuses" testOutdatedLeftOutRefuseOnly,
      testCase "provider not GitMv-outdated keeps on-disk lines" testOutdatedProviderNotOutdated,
      testCase "prune-only package prints removal lines" testOutdatedPruneOnly,
      testCase "pinned PV is not reported removed" testOutdatedPinnedNotRemoved,
      testCase "keep-set failure does not guess a removal" testOutdatedKeepFailure,
      testCase "GitMv bun-bin does not use removal lines" testOutdatedGitMvNoRemoval
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

entry :: T.Text -> T.Text -> T.Text -> PackageEntry
entry cat pn ver =
  PackageEntry
    { peKey = mkPackageKey cat pn,
      pePN = pn,
      peLocal = parseEbuildVersion ver,
      pePath = "/tmp/" <> T.unpack pn <> "-" <> T.unpack ver <> ".ebuild"
    }

-- | Dual-arch ceilings with a caller-chosen runtime atom label.
dualArchCeilings :: T.Text -> Maybe T.Text -> Maybe T.Text -> RuntimeCeilings
dualArchCeilings atom plain tilde =
  let base = dualArchGoCeilings plain tilde
   in base {rcAtom = atom}

goCeilings :: RuntimeCeilings
goCeilings = dualArchCeilings "dev-lang/go" (Just "1.26.3") (Just "1.26.5")

nodeCeilings :: RuntimeCeilings
nodeCeilings = dualArchCeilings "net-libs/nodejs" (Just "20.0.0") (Just "22.0.0")

bunCeilings :: RuntimeCeilings
bunCeilings = dualArchCeilings "dev-lang/bun-bin" (Just "1.1.0") (Just "1.2.0")

rustCeilings :: RuntimeCeilings
rustCeilings = dualArchCeilings "dev-lang/rust|rust-bin" (Just "1.80.0") (Just "1.85.0")

sbclCeilings :: RuntimeCeilings
sbclCeilings = dualArchCeilings "dev-lisp/sbcl" (Just "2.6.2") (Just "2.6.6")

-- | Fully mocked DepsPlanOps with pre-filled ceiling caches (no portageq / network).
mkDepsPlanOps ::
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (GoModKey -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text BunProbe)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> Maybe FilePath -> IO CargoTomlFetch) ->
  Maybe FilePath ->
  IO DepsPlanOps
mkDepsPlanOps listVers fetchGo fetchNpm fetchBun fetchCargo mOverlay = do
  mgr <- newManager tlsManagerSettings
  budget <- newWorkBudget 4
  goCache <- newMVar (Just goCeilings)
  nodeCache <- newMVar (Just nodeCeilings)
  bunCache <- newMVar (Just bunCeilings)
  rustCache <- newMVar (Just rustCeilings)
  sbclCache <- newMVar (Just sbclCeilings)
  pure
    DepsPlanOps
      { dpoPortageq = \_ -> pure (Left "portageq unused in CheckPlan tests"),
        dpoListVersions = listVers,
        dpoFetchGoMod = fetchGo,
        dpoFetchNpmEngines = fetchNpm,
        dpoFetchBunEngines = fetchBun,
        dpoFetchCargoToml = fetchCargo,
        dpoFetchRustToolchain = \_ _ _ _ _ -> pure CargoTomlMissing,
        dpoFetchSbclVersion = \_ _ _ _ -> pure (Left "sbcl.version unused"),
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoSbclCeilingsCache = sbclCache,
        dpoOverlayRoot = mOverlay,
        dpoManager = mgr
      }

unusedGoMod :: GoModKey -> IO (Either T.Text T.Text)
unusedGoMod _ = pure (Left "go.mod unused")

unusedNpm :: T.Text -> T.Text -> IO (Either T.Text T.Text)
unusedNpm _ _ = pure (Left "npm engines unused")

unusedBun :: T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text BunProbe)
unusedBun _ _ _ _ = pure (Left "bun engines unused")

unusedCargo ::
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  Maybe FilePath ->
  IO CargoTomlFetch
unusedCargo _ _ _ _ _ = pure (CargoTomlError "cargo toml unused")

unusedFetch :: UpdateSource -> IO (Either T.Text EbuildVersion)
unusedFetch _ = pure (Left "provider latest unused")

listFixed :: [T.Text] -> UpdateSource -> IO (Either T.Text [EbuildVersion])
listFixed vers _ = pure (Right (map parseEbuildVersion vers))

isOutdated :: UpdateStatus -> Bool
isOutdated (Outdated _) = True
isOutdated _ = False

disabledCache :: IO CheckCacheHandle
disabledCache = fst <$> openCheckCache CacheDisabled False "/tmp"

------------------------------------------------------------------------
-- checkPackage (GitMvAndManifest / resolveSource path)
------------------------------------------------------------------------

-- Uses real hardcoded keys so resolveSource + checkPackage run product code.
testCheckPackageOutdated :: IO ()
testCheckPackageOutdated = do
  let e = entry "dev-lang" "deno-bin" "0.1.0"
      fetch _ = pure (Right (parseEbuildVersion "0.2.0"))
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  case reportStatus report of
    Outdated [line] -> do
      assertEq "from" (parseEbuildVersion "0.1.0") (olFrom line)
      assertEq "to" (parseEbuildVersion "0.2.0") (olTo line)
    other -> assertFailure $ "expected Outdated, got " <> show other

testCheckPackageOk :: IO ()
testCheckPackageOk = do
  let e = entry "dev-lang" "deno-bin" "1.0.0"
      fetch _ = pure (Right (parseEbuildVersion "1.0.0"))
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  case reportStatus report of
    Ok v -> assertEq "ok" (parseEbuildVersion "1.0.0") v
    other -> assertFailure $ "expected Ok, got " <> show other

testCheckPackageAhead :: IO ()
testCheckPackageAhead = do
  let e = entry "dev-lang" "bun-bin" "2.0.0"
      fetch _ = pure (Right (parseEbuildVersion "1.5.0"))
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  case reportStatus report of
    Ahead local remote -> do
      assertEq "local" (parseEbuildVersion "2.0.0") local
      assertEq "remote" (parseEbuildVersion "1.5.0") remote
    other -> assertFailure $ "expected Ahead, got " <> show other

testCheckPackageFetchError :: IO ()
testCheckPackageFetchError = do
  let e = entry "dev-lang" "deno-bin" "1.0.0"
      fetch _ = pure (Left "network down")
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  case reportStatus report of
    FetchError msg -> assertTrue "error text" ("network down" `T.isInfixOf` msg)
    other -> assertFailure $ "expected FetchError, got " <> show other

testCheckPackageQlotOutdated :: IO ()
testCheckPackageQlotOutdated = do
  let e = entry "dev-lisp" "qlot" "1.8.4"
      fetch src = case src of
        GitHub "fukamachi" "qlot" "" ->
          pure (Right (parseEbuildVersion "1.8.5"))
        _ -> pure (Left "unexpected qlot source")
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  case reportStatus report of
    Outdated [line] -> do
      assertEq "from" (parseEbuildVersion "1.8.4") (olFrom line)
      assertEq "to" (parseEbuildVersion "1.8.5") (olTo line)
    other -> assertFailure $ "expected qlot Outdated, got " <> show other

testCheckPackageUnconfigured :: IO ()
testCheckPackageUnconfigured = do
  let e = entry "dev-lang" "haskell" "9.6.1"
      fetch _ = pure (Left "should not be called")
  cache <- disabledCache
  report <- checkPackage fetch cache e []
  assertEq "unconfigured" Unconfigured (reportStatus report)

------------------------------------------------------------------------
-- checkPackageDeps
------------------------------------------------------------------------

testCheckPackageDepsGoOutdated :: IO ()
testCheckPackageDepsGoOutdated = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.84.0", "0.82.0"])
      ( \key ->
          pure $
            Right $
              case gmkTag key of
                "v0.82.0" -> "module x\ngo 1.26.3\n"
                "v0.84.0" -> "module x\ngo 1.26.5\n"
                _ -> "module x\n"
      )
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  -- Touch toGoPlanOps so the view helper is covered.
  let _goView = toGoPlanOps ops
  let e = entry "dev-util" "beads" "0.80.0"
      locals =
        [ Ebuild "dev-util" "beads" "0.80.0" (pePath e)
        ]
      src = GitHub "gastownhall" "beads" "v"
  cache <- disabledCache
  report <-
    checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src (Go Nothing) Set.empty
  assertTrue "outdated gaps" (isOutdated (reportStatus report))
  assertEq "key" (PackageKey "dev-util/beads") (reportKey report)

testCheckPackageDepsSbclOutdated :: IO ()
testCheckPackageDepsSbclOutdated = do
  base <-
    mkDepsPlanOps
      (listFixed ["0.18.0", "0.17.2"])
      unusedGoMod
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  let ops =
        base
          { dpoFetchSbclVersion = \_ _ _ pv ->
              pure $
                Right $
                  case pv of
                    "0.17.2" -> "2.6.4\n"
                    "0.18.0" -> "2.6.4\n"
                    _ -> "not-a-version\n"
          }
      e = entry "dev-util" "autolith" "0.17.2"
      locals =
        [ Ebuild "dev-util" "autolith" "0.17.2" (pePath e)
        ]
      src = GitHub "luciusmagn" "autolith" "v"
  cache <- disabledCache
  report <-
    checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src Sbcl Set.empty
  case reportStatus report of
    Outdated lines_ -> do
      let gaps = [ol | ol@OutdatedLine {} <- lines_]
      assertTrue "has gaps" (not (null gaps))
      assertTrue
        "sbcl label"
        (any (maybe False ("dev-lisp/sbcl" `T.isInfixOf`) . olLabel) gaps)
      assertTrue
        "targets 0.18.0"
        (any (\l -> olTo l == parseEbuildVersion "0.18.0") gaps)
    other -> assertFailure $ "expected Outdated, got " <> show other

testCheckPackageDepsPlanFail :: IO ()
testCheckPackageDepsPlanFail = do
  ops <-
    mkDepsPlanOps
      (\_ -> pure (Left "registry unreachable"))
      unusedGoMod
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  let e = entry "dev-util" "openspec" "0.1.0"
      locals = [Ebuild "dev-util" "openspec" "0.1.0" (pePath e)]
      src = Npm "@fission-ai/openspec"
  cache <- disabledCache
  report <-
    checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src NpmEco Set.empty
  case reportStatus report of
    FetchError msg ->
      assertTrue
        "list failure surfaced"
        ("list versions failed" `T.isInfixOf` msg || "registry unreachable" `T.isInfixOf` msg)
    other -> assertFailure $ "expected FetchError, got " <> show other

------------------------------------------------------------------------
-- planDepsPackageWithProgress per ecosystem
------------------------------------------------------------------------

testPlanGoSuccess :: IO ()
testPlanGoSuccess = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.84.0", "0.82.0"])
      ( \key ->
          pure $
            Right $
              case gmkTag key of
                "v0.82.0" -> "module x\ngo 1.26.3\n"
                "v0.84.0" -> "module x\ngo 1.26.5\n"
                _ -> "module x\n"
      )
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  plan <-
    assertRight "go plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Go Nothing)
        (GitHub "o" "r" "v")
        [parseEbuildVersion "0.80.0"]
  assertEq "unique count" 2 (length (glpUniquePVs plan))
  assertTrue "has 0.82" (parseEbuildVersion "0.82.0" `elem` glpUniquePVs plan)
  assertTrue "has 0.84" (parseEbuildVersion "0.84.0" `elem` glpUniquePVs plan)
  assertEq "atom" "dev-lang/go" (glpRuntimeAtom plan)

testPlanNpmSuccess :: IO ()
testPlanNpmSuccess = do
  ops <-
    mkDepsPlanOps
      (listFixed ["2.0.0", "1.0.0"])
      unusedGoMod
      ( \_pkg pv ->
          pure $
            Right $
              case pv of
                "1.0.0" -> "20.0.0"
                "2.0.0" -> "22.0.0"
                _ -> "18.0.0"
      )
      unusedBun
      unusedCargo
      Nothing
  plan <-
    assertRight "npm plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        NpmEco
        (Npm "@scope/pkg")
        [parseEbuildVersion "1.0.0"]
  assertTrue "planned non-empty" (not (null (glpUniquePVs plan)))
  assertEq "nodejs atom" "net-libs/nodejs" (glpRuntimeAtom plan)

testPlanBunSuccess :: IO ()
testPlanBunSuccess = do
  ops <-
    mkDepsPlanOps
      (listFixed ["1.5.0", "1.0.0"])
      unusedGoMod
      unusedNpm
      ( \_o _r _p pv ->
          pure $
            Right $
              minimumBunProbe $
                case pv of
                  "1.0.0" -> "1.1.0"
                  "1.5.0" -> "1.2.0"
                  _ -> "1.0.0"
      )
      unusedCargo
      (Just "/tmp/fake-overlay") -- required; ceilings pre-cached so not scanned
  plan <-
    assertRight "bun plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        Bun
        (GitHub "subsy" "ralph-tui" "v")
        [parseEbuildVersion "1.0.0"]
  assertTrue "planned non-empty" (not (null (glpUniquePVs plan)))
  assertEq "bun atom" "dev-lang/bun-bin" (glpRuntimeAtom plan)

testPlanCargoSuccess :: IO ()
testPlanCargoSuccess = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.50.0", "0.40.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      ( \_o _r _p pv mSub ->
          pure $
            case (pv, mSub) of
              ("0.40.0", Nothing) ->
                CargoTomlBody " [package]\nrust-version = \"1.80.0\"\n"
              ("0.50.0", Nothing) ->
                CargoTomlBody " [package]\nrust-version = \"1.85.0\"\n"
              _ -> CargoTomlMissing
      )
      Nothing
  plan <-
    assertRight "cargo plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  assertTrue "planned non-empty" (not (null (glpUniquePVs plan)))
  assertEq "rust atom" "dev-lang/rust|rust-bin" (glpRuntimeAtom plan)

testPlanCargoNamespacedFeatures :: IO ()
testPlanCargoNamespacedFeatures = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.50.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      ( \_o _r _p pv mSub ->
          pure $
            case (pv, mSub) of
              ("0.50.0", Nothing) ->
                CargoTomlBody $
                  T.unlines
                    [ "[package]",
                      "name = \"mise\"",
                      "rust-version = \"1.85\"",
                      "[dependencies]",
                      "vfox = { path = \"crates/vfox\", default-features = false }",
                      "[features]",
                      "default = [\"vfox/vendored-lua\"]"
                    ]
              ("0.50.0", Just "crates/vfox") ->
                CargoTomlBody $
                  T.unlines
                    [ "[package]",
                      "name = \"vfox\"",
                      "rust-version = \"1.85\"",
                      "[features]",
                      "vendored-lua = [\"mlua/vendored\"]"
                    ]
              _ -> CargoTomlMissing
      )
      Nothing
  plan <-
    assertRight "cargo namespaced plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "mise" "v")
        [parseEbuildVersion "0.40.0"]
  assertTrue
    "mise-style features still plan"
    (parseEbuildVersion "0.50.0" `elem` glpUniquePVs plan)

testPlanCargoIncompleteSkipped :: IO ()
testPlanCargoIncompleteSkipped = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.50.0", "0.40.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      ( \_o _r _p pv mSub ->
          pure $
            case (pv, mSub) of
              ("0.50.0", Nothing) ->
                CargoTomlBody
                  "[package]\nname = \"p\"\nrust-version = \"1.80\"\n[dependencies]\ngone = { path = \"gone\" }\n"
              ("0.40.0", Nothing) ->
                CargoTomlBody "[package]\nname = \"p\"\nrust-version = \"1.85.0\"\n"
              _ -> CargoTomlMissing
      )
      Nothing
  plan <-
    assertRight "cargo incomplete skip"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  assertTrue
    "older complete selected"
    (parseEbuildVersion "0.40.0" `elem` glpUniquePVs plan)
  assertTrue
    "incomplete newest not selected"
    (parseEbuildVersion "0.50.0" `notElem` glpUniquePVs plan)
  assertTrue
    "no 0.0.0 lane req"
    (not (any (\lt -> ltGoReq lt == Just "0.0.0") (glpLanes plan)))

testPlanCargoCompleteAbsence :: IO ()
testPlanCargoCompleteAbsence = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.50.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      ( \_o _r _p pv mSub ->
          pure $
            case (pv, mSub) of
              ("0.50.0", Nothing) ->
                CargoTomlBody "[package]\nname = \"p\"\nversion = \"0.50.0\"\n"
              _ -> CargoTomlMissing
      )
      Nothing
  plan <-
    assertRight "cargo complete absence"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  assertTrue
    "selects complete empty"
    (parseEbuildVersion "0.50.0" `elem` glpUniquePVs plan)
  assertTrue
    "selection-only 0.0.0"
    (any (\lt -> ltGoReq lt == Just "0.0.0") (glpLanes plan))
  case glpDirectTagFloors plan of
    (s : _) -> assertEq "stored absence" Nothing (ctfsFloor s)
    [] -> assertFailure "expected snapshot for selected PV"

testPlanCargoParseFails :: IO ()
testPlanCargoParseFails = do
  ops <-
    mkDepsPlanOps
      (listFixed ["0.50.0", "0.40.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      ( \_o _r _p _pv mSub ->
          pure $
            case mSub of
              Nothing -> CargoTomlBody "[[[ not toml"
              _ -> CargoTomlMissing
      )
      Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  case err of
    PlanProbeFailed msg ->
      assertTrue "malformed fails" ("malformed" `T.isInfixOf` msg)
    other -> assertFailure $ "expected PlanProbeFailed, got " <> show other
  opsHttp <-
    mkDepsPlanOps
      (listFixed ["0.50.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      (\_o _r _p _pv _m -> pure (CargoTomlError "HTTP 500 from origin"))
      Nothing
  errHttp <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        opsHttp
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  case errHttp of
    PlanProbeFailed msg ->
      assertTrue "HTTP fails package" ("HTTP 500" `T.isInfixOf` msg)
    other -> assertFailure $ "expected PlanProbeFailed, got " <> show other

testPlanGoWrongSource :: IO ()
testPlanGoWrongSource = do
  ops <-
    mkDepsPlanOps (listFixed []) unusedGoMod unusedNpm unusedBun unusedCargo Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Go Nothing)
        (Npm "not-github")
        [parseEbuildVersion "1.0.0"]
  assertTrue
    "go needs github"
    ("GitHub" `T.isInfixOf` planErrorMessage err)

testPlanNpmWrongSource :: IO ()
testPlanNpmWrongSource = do
  ops <-
    mkDepsPlanOps (listFixed []) unusedGoMod unusedNpm unusedBun unusedCargo Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        NpmEco
        (GitHub "o" "r" "v")
        [parseEbuildVersion "1.0.0"]
  assertTrue
    "npm needs Npm source"
    ("Npm" `T.isInfixOf` planErrorMessage err)

testPlanBunMissingOverlay :: IO ()
testPlanBunMissingOverlay = do
  ops <-
    mkDepsPlanOps (listFixed ["1.0.0"]) unusedGoMod unusedNpm unusedBun unusedCargo Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        Bun
        (GitHub "o" "r" "v")
        [parseEbuildVersion "0.9.0"]
  assertTrue
    "overlay required"
    ("overlay path required" `T.isInfixOf` planErrorMessage err)

testPlanCargoWrongSource :: IO ()
testPlanCargoWrongSource = do
  ops <-
    mkDepsPlanOps (listFixed []) unusedGoMod unusedNpm unusedBun unusedCargo Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing CargoGitTag)
        (Http "https://example.com" Nothing)
        [parseEbuildVersion "1.0.0"]
  assertTrue
    "cargo needs github"
    ("GitHub" `T.isInfixOf` planErrorMessage err)

testPlanNoNonLiveLocal :: IO ()
testPlanNoNonLiveLocal = do
  ops <-
    mkDepsPlanOps
      (listFixed ["1.0.0"])
      unusedGoMod
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Go Nothing)
        (GitHub "o" "r" "v")
        []
  assertEq "empty locals" PlanNoNonLiveLocal err

testPlanListVersionsFailed :: IO ()
testPlanListVersionsFailed = do
  ops <-
    mkDepsPlanOps
      (\_ -> pure (Left "github 502"))
      unusedGoMod
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Go Nothing)
        (GitHub "o" "r" "v")
        [parseEbuildVersion "1.0.0"]
  case err of
    PlanListVersionsFailed msg ->
      assertTrue "list err" ("502" `T.isInfixOf` msg)
    other -> assertFailure $ "expected PlanListVersionsFailed, got " <> show other

testPlanZeroPlannedPVs :: IO ()
testPlanZeroPlannedPVs = do
  -- All candidates require go above every ceiling → no lane targets.
  ops <-
    mkDepsPlanOps
      (listFixed ["9.0.0"])
      (\_ -> pure (Right "module x\ngo 1.99.0\n"))
      unusedNpm
      unusedBun
      unusedCargo
      Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Go Nothing)
        (GitHub "o" "r" "v")
        [parseEbuildVersion "1.0.0"]
  assertEq "zero planned" PlanZeroPlannedPVs err

testPlanNpmProbeFailed :: IO ()
testPlanNpmProbeFailed = do
  ops <-
    mkDepsPlanOps
      (listFixed ["2.0.0", "1.0.0"])
      unusedGoMod
      (\_ _ -> pure (Left "engines.node missing"))
      unusedBun
      unusedCargo
      Nothing
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        NpmEco
        (Npm "@scope/pkg")
        [parseEbuildVersion "1.0.0"]
  case err of
    PlanProbeFailed msg ->
      assertTrue "probe err" ("engines.node" `T.isInfixOf` msg)
    other -> assertFailure $ "expected PlanProbeFailed, got " <> show other

testPlanNpmAbsentEnginesUsesDonor :: IO ()
testPlanNpmAbsentEnginesUsesDonor = do
  let donor =
        T.unlines
          [ "EAPI=8",
            "inherit npm",
            "BDEPEND=\">=net-libs/nodejs-22[npm]\""
          ]
  ops <-
    mkDepsPlanOps
      (listFixed ["2.0.0", "1.0.0"])
      unusedGoMod
      (\_ _ -> pure (Left "missing engines.node for pkg@2.0.0"))
      unusedBun
      unusedCargo
      Nothing
  plan <-
    assertRight "donor plan"
      =<< planDepsPackageWithProgressDonor
        ops
        noopPlanProgress
        NpmEco
        (Npm "@scope/pkg")
        [parseEbuildVersion "1.0.0"]
        []
        (Just donor)
  let reqs =
        [ req
        | lane <- glpLanes plan,
          ltPackagePV lane == Just (parseEbuildVersion "2.0.0"),
          Just req <- [ltGoReq lane]
        ]
  assertTrue "planned some lane" (not (null reqs))
  assertTrue "planned node requirement is donor" (all (== "22") reqs)
  fixed <- assertRight "rewrite" (ensureNodejsBdepend "22" donor)
  assertTrue "atom kept" (nodejsBdependMatches "22" fixed)
  assertEq
    "single [npm]"
    1
    (T.count "[npm]" fixed)
  err <-
    assertLeftPlan
      =<< planDepsPackageWithProgressDonor
        ops
        noopPlanProgress
        NpmEco
        (Npm "@scope/pkg")
        [parseEbuildVersion "1.0.0"]
        []
        (Just "DESCRIPTION=\"no nodejs\"\n")
  case err of
    PlanProbeFailed msg ->
      assertTrue "missing atom named" ("net-libs/nodejs" `T.isInfixOf` msg)
    other -> assertFailure $ "expected PlanProbeFailed, got " <> show other

testReadNpmDonorHighest :: IO ()
testReadNpmDonorHighest =
  withSystemTempDirectory "npm-donor" $ \dir -> do
    let writeBody name = TIO.writeFile (dir </> name)
    writeBody "pkg-1.0.0.ebuild" "BDEPEND=\">=net-libs/nodejs-18[npm]\""
    writeBody "pkg-1.13.0.ebuild" "BDEPEND=\">=net-libs/nodejs-22[npm]\""
    writeBody "pkg-9999.ebuild" "BDEPEND=\">=net-libs/nodejs-99[npm]\""
    let mk ver name =
          Ebuild "dev-util" "pkg" ver (dir </> name)
    got <-
      assertRight "highest"
        =<< readNpmDonorBody
          [ mk "1.0.0" "pkg-1.0.0.ebuild",
            mk "9999" "pkg-9999.ebuild",
            mk "1.13.0" "pkg-1.13.0.ebuild"
          ]
          TIO.readFile
    assertEq
      "donor is 1.13.0"
      (Just "BDEPEND=\">=net-libs/nodejs-22[npm]\"")
      got

assertLeftPlan :: Either PlanError a -> IO PlanError
assertLeftPlan = \case
  Left e -> pure e
  Right _ -> assertFailure "expected Left PlanError, got Right"

------------------------------------------------------------------------
-- Integration: multi-package overlay check
------------------------------------------------------------------------

testCheckOverlayWithDepsPlanMulti :: IO ()
testCheckOverlayWithDepsPlanMulti = do
  ops <-
    mkDepsPlanOps
      ( \src -> pure $ case src of
          GitHub "gastownhall" "beads" _ ->
            Right
              [ parseEbuildVersion "0.84.0",
                parseEbuildVersion "0.82.0"
              ]
          Npm "@fission-ai/openspec" ->
            Right
              [ parseEbuildVersion "0.2.0",
                parseEbuildVersion "0.1.0"
              ]
          _ -> Right []
      )
      ( \key ->
          pure $
            Right $
              case gmkTag key of
                "v0.82.0" -> "module x\ngo 1.26.3\n"
                "v0.84.0" -> "module x\ngo 1.26.5\n"
                _ -> "module x\ngo 1.26.3\n"
      )
      ( \_pkg pv ->
          pure $
            Right $
              case pv of
                "0.1.0" -> "20.0.0"
                "0.2.0" -> "22.0.0"
                _ -> "20.0.0"
      )
      unusedBun
      unusedCargo
      Nothing
  let fetch src = pure $ case src of
        GitHub "denoland" "deno" _ ->
          Right (parseEbuildVersion "0.5.0")
        _ -> Left "unexpected fetch source"
      ebuilds =
        [ -- GitMv: outdated via checkPackage
          Ebuild
            "dev-lang"
            "deno-bin"
            "0.1.0"
            "/tmp/deno-bin-0.1.0.ebuild",
          -- DepsAndAssets Go: plan gaps
          Ebuild
            "dev-util"
            "beads"
            "0.80.0"
            "/tmp/beads-0.80.0.ebuild",
          -- DepsAndAssets Npm: plan gaps
          Ebuild
            "dev-util"
            "openspec"
            "0.1.0"
            "/tmp/openspec-0.1.0.ebuild",
          -- Unconfigured (no policy)
          Ebuild
            "dev-lang"
            "haskell"
            "9.6.1"
            "/tmp/haskell-9.6.1.ebuild"
        ]
  cache <- disabledCache
  reports <-
    checkOverlayWithDepsPlan 2 noopMultiHandle fetch ops cache ebuilds
  let statuses = map reportStatus reports
  assertEq "four packages" 4 (length reports)
  assertTrue "has outdated" (any isOutdated statuses)
  assertTrue "has unconfigured" (Unconfigured `elem` statuses)
  -- At least one deps package reported outdated gaps.
  assertTrue
    "beads or openspec outdated"
    ( any
        ( \r ->
            reportKey r
              `elem` [ PackageKey "dev-util/beads",
                       PackageKey "dev-util/openspec"
                     ]
              && isOutdated (reportStatus r)
        )
        reports
    )
  assertTrue
    "deno-bin outdated"
    ( any
        ( \r ->
            reportKey r == PackageKey "dev-lang/deno-bin"
              && isOutdated (reportStatus r)
        )
        reports
    )

------------------------------------------------------------------------
-- contentFix: same-PV content/Manifest fix → olAssetsReusable (all ecos)
------------------------------------------------------------------------

assertContentOnlyReusable :: String -> UpdateStatus -> IO ()
assertContentOnlyReusable label status =
  case status of
    Outdated lines_ -> do
      let gaps = [ol | ol@OutdatedLine {} <- lines_]
      assertEq (label <> " gap lines only") (length lines_) (length gaps)
      assertTrue (label <> " non-empty gaps") (not (null gaps))
      assertTrue
        (label <> " all content-only reusable")
        (all olAssetsReusable gaps)
    other ->
      assertFailure $ label <> ": expected Outdated reusable, got " <> show other

assertOkStatus :: String -> UpdateStatus -> IO ()
assertOkStatus label status =
  case status of
    Ok _ -> pure ()
    other -> assertFailure $ label <> ": expected Ok, got " <> show other

-- | Go: present PV with missing Manifest vendor DIST → content-only reusable; fix → Ok.
testContentFixGoReusable :: IO ()
testContentFixGoReusable =
  withSystemTempDirectory "mndz-cf-go-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        ver = "0.84.0" :: T.Text
        ebuildPath = pkgDir </> "crush-0.84.0.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    -- Manifest without vendor DIST forces content fix on same PV.
    TIO.writeFile (pkgDir </> "Manifest") "DIST crush-0.84.0.tar.gz 1 SHA512 dead\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.84.0"])
        (\_ -> pure (Right "module x\ngo 1.26.5\n"))
        unusedNpm
        unusedBun
        unusedCargo
        Nothing
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "charmbracelet" "crush" "v"
    cache <- disabledCache
    report <-
      checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src (Go Nothing) Set.empty
    assertContentOnlyReusable "go content-fix" (reportStatus report)
    -- Complete Manifest + good BDEPEND → Ok
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 1 BLAKE2B aa SHA512 abcdef0123456789\n"
    reportOk <-
      checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src (Go Nothing) Set.empty
    assertOkStatus "go content ok" (reportStatus reportOk)

-- | Npm: wrong nodejs BDEPEND on present PV → content-only reusable.
testContentFixNpmReusable :: IO ()
testContentFixNpmReusable =
  withSystemTempDirectory "mndz-cf-npm-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        ver = "2.0.0" :: T.Text
        ebuildPath = pkgDir </> "openspec-2.0.0.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "BDEPEND=\">=net-libs/nodejs-18.0.0[npm]\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/openspec-${PV}/openspec-${PV}-deps.tar.xz\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST openspec-2.0.0-deps.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["2.0.0"])
        unusedGoMod
        (\_pkg _pv -> pure (Right "22.0.0"))
        unusedBun
        unusedCargo
        Nothing
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = Npm "@fission-ai/openspec"
    cache <- disabledCache
    report <-
      checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src NpmEco Set.empty
    assertContentOnlyReusable "npm content-fix" (reportStatus report)
    TIO.writeFile
      ebuildPath
      ( T.replace
          ">=net-libs/nodejs-18.0.0[npm]"
          ">=net-libs/nodejs-22.0.0[npm]"
          body
      )
    reportOk <-
      checkPackageDeps noopMultiHandle unusedFetch ops cache e locals src NpmEco Set.empty
    assertOkStatus "npm content ok" (reportStatus reportOk)

-- | Bun: missing Manifest deps DIST on present PV → content-only reusable.
testContentFixBunReusable :: IO ()
testContentFixBunReusable =
  withSystemTempDirectory "mndz-cf-bun-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "ralph-tui"
        pn = "ralph-tui" :: T.Text
        ver = "1.5.0" :: T.Text
        ebuildPath = pkgDir </> "ralph-tui-1.5.0.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "BDEPEND=\">=dev-lang/bun-bin-1.2.0:0\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/ralph-tui-${PV}/ralph-tui-${PV}-deps.tar.xz\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile (pkgDir </> "Manifest") "DIST ralph-tui-1.5.0.tar.gz 1 SHA512 x\n"
    _ <- seedBunBin tmp "1.2.0"
    ops <-
      mkDepsPlanOps
        (listFixed ["1.5.0"])
        unusedGoMod
        unusedNpm
        (\_o _r _p _pv -> pure (Right (minimumBunProbe "1.2.0")))
        unusedCargo
        (Just tmp)
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "subsy" "ralph-tui" "v"
    cache <- disabledCache
    let fetchBunLatest src0 = case src0 of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> unusedFetch src0
    report <-
      checkPackageDeps noopMultiHandle fetchBunLatest ops cache e locals src Bun Set.empty
    assertContentOnlyReusable "bun content-fix" (reportStatus report)
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST ralph-tui-1.5.0-deps.tar.xz 1 SHA512 deadbeef\n"
    reportOk <-
      checkPackageDeps noopMultiHandle fetchBunLatest ops cache e locals src Bun Set.empty
    assertOkStatus "bun content ok" (reportStatus reportOk)

-- | Cargo: wrong RUST_MIN_VER on present PV → content-only reusable.
testContentFixCargoReusable :: IO ()
testContentFixCargoReusable =
  withSystemTempDirectory "mndz-cf-cargo-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "hk"
        pn = "hk" :: T.Text
        ver = "0.50.0" :: T.Text
        ebuildPath = pkgDir </> "hk-0.50.0.ebuild"
        bodyBad =
          T.unlines
            [ "EAPI=8",
              "inherit cargo",
              "RUST_MIN_VER=\"1.70.0\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/hk-${PV}/hk-${PV}-crates.tar.xz\"",
              "CRATES=\"\""
            ]
        bodyOk =
          T.replace "1.70.0" "1.85.0" bodyBad
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath bodyBad
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST hk-0.50.0-crates.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.50.0"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p _pv mSub ->
            pure $
              case mSub of
                Nothing -> CargoTomlBody " [package]\nrust-version = \"1.85.0\"\n"
                _ -> CargoTomlMissing
        )
        Nothing
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "hk",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "jdx" "hk" "v"
    cache <- disabledCache
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo Nothing Nothing CargoGitTag)
        Set.empty
    assertContentOnlyReusable "cargo content-fix" (reportStatus report)
    TIO.writeFile ebuildPath bodyOk
    reportOk <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo Nothing Nothing CargoGitTag)
        Set.empty
    assertOkStatus "cargo content ok" (reportStatus reportOk)

-- | usage-style: written 1.95 vs tag 1.91 is adequate (too-low-only).
testCargoWrittenAboveTagAdequate :: IO ()
testCargoWrittenAboveTagAdequate =
  withSystemTempDirectory "mndz-cf-usage-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "usage"
        pn = "usage" :: T.Text
        ver = "6.4.1" :: T.Text
        ebuildPath = pkgDir </> "usage-6.4.1.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "inherit cargo",
              "RUST_MIN_VER=\"1.85.0\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/usage-${PV}/usage-${PV}-crates.tar.xz\"",
              "CRATES=\"\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST usage-6.4.1-crates.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["6.4.1"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p _pv mSub ->
            pure $
              case mSub of
                Just "cli" -> CargoTomlBody "[package]\nrust-version = \"1.80\"\n"
                _ -> CargoTomlMissing
        )
        Nothing
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "usage",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "jdx" "usage" "v"
    cache <- disabledCache
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo Nothing (Just "cli") CargoGitTag)
        Set.empty
    assertOkStatus "usage 1.85 vs tag 1.80" (reportStatus report)

-- | Codex-shaped two-URL SRC_URI at the present PV is Ok, not 0.153.4 -> 0.153.4.
testCodexRustyV8UrlAdequate :: IO ()
testCodexRustyV8UrlAdequate =
  withSystemTempDirectory "mndz-cf-codex-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "codex"
        pn = "codex" :: T.Text
        ver = "0.153.4" :: T.Text
        ebuildPath = pkgDir </> "codex-0.153.4.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "inherit cargo",
              "RUST_MIN_VER=\"1.95.0\"",
              "KEYWORDS=\"-* ~amd64\"",
              "CRATES=\"\"",
              "SRC_URI=\"https://github.com/openai/codex/archive/refs/tags/rust-v${PV}.tar.gz -> ${P}.tar.gz\"",
              "SRC_URI+=\" ${CARGO_CRATE_URIS}\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/codex-${PV}/codex-${PV}-crates.tar.xz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/rusty-v8-${RUSTY_V8_VER}/rusty-v8-${RUSTY_V8_VER}-with-submodules.tar.xz\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST codex-0.153.4-crates.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.153.4"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p _pv mSub ->
            pure $
              case mSub of
                Just "codex-rs/cli" ->
                  CargoTomlBody "[package]\nrust-version = \"1.95.0\"\n"
                _ -> CargoTomlMissing
        )
        Nothing
    modifyMVar_
      (dpoRustCeilingsCache ops)
      ( \_ ->
          pure
            ( Just
                ( dualArchCeilings
                    "dev-lang/rust|rust-bin"
                    (Just "1.95.0")
                    (Just "1.95.0")
                )
            )
      )
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "codex",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "openai" "codex" "rust-v"
    cache <- disabledCache
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo (Just "codex-rs") (Just "codex-rs/cli") CargoGitTag)
        Set.empty
    assertOkStatus "codex 0.153.4 two-url body" (reportStatus report)

-- | usage-style path closure: benches/xtask 1.99 must not raise T above 1.91.
testUsagePathClosureAdequacy :: IO ()
testUsagePathClosureAdequacy =
  withSystemTempDirectory "mndz-cf-usage-closure-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "usage"
        pn = "usage" :: T.Text
        ver = "6.4.1" :: T.Text
        ebuildPath = pkgDir </> "usage-6.4.1.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "inherit cargo",
              "RUST_MIN_VER=\"1.91.0\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/usage-${PV}/usage-${PV}-crates.tar.xz\"",
              "CRATES=\"\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST usage-6.4.1-crates.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["6.4.1"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p _pv mSub ->
            pure $
              case mSub of
                Just "cli" ->
                  CargoTomlBody
                    "[package]\nname = \"usage\"\nrust-version = \"1.91\"\n[dependencies]\nlib = { path = \"../lib\" }\n"
                Just "lib" ->
                  CargoTomlBody "[package]\nname = \"lib\"\nrust-version = \"1.91\"\n"
                Just "benches/shadows" ->
                  CargoTomlBody "[package]\nname = \"shadows\"\nrust-version = \"1.99\"\n"
                Just "xtask" ->
                  CargoTomlBody "[package]\nname = \"xtask\"\nrust-version = \"1.99\"\n"
                _ -> CargoTomlMissing
        )
        Nothing
    modifyMVar_
      (dpoRustCeilingsCache ops)
      ( \_ ->
          pure
            ( Just
                ( dualArchCeilings
                    "dev-lang/rust|rust-bin"
                    (Just "1.99.0")
                    (Just "1.99.0")
                )
            )
      )
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "usage",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "jdx" "usage" "v"
    cache <- disabledCache
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo Nothing (Just "cli") CargoGitTag)
        Set.empty
    assertOkStatus "usage path-closure 1.91" (reportStatus report)

-- | Incomplete newest tag is not reported as a 0.0.0 TO.
testIncompleteNotZeroFloorGap :: IO ()
testIncompleteNotZeroFloorGap =
  withSystemTempDirectory "mndz-cf-incomplete-" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "hk"
        pn = "hk" :: T.Text
        ver = "0.40.0" :: T.Text
        ebuildPath = pkgDir </> "hk-0.40.0.ebuild"
        body =
          T.unlines
            [ "EAPI=8",
              "inherit cargo",
              "RUST_MIN_VER=\"1.85.0\"",
              "KEYWORDS=\"~amd64 ~arm64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/hk-${PV}/hk-${PV}-crates.tar.xz\"",
              "CRATES=\"\""
            ]
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath body
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST hk-0.40.0-crates.tar.xz 1 SHA512 deadbeef\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.50.0", "0.40.0"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p pv mSub ->
            pure $
              case (pv, mSub) of
                ("0.50.0", Nothing) ->
                  CargoTomlBody
                    "[package]\nname = \"hk\"\nrust-version = \"1.80\"\n[dependencies]\ngone = { path = \"gone\" }\n"
                ("0.40.0", Nothing) ->
                  CargoTomlBody "[package]\nname = \"hk\"\nrust-version = \"1.85.0\"\n"
                _ -> CargoTomlMissing
        )
        Nothing
    let e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "hk",
              pePN = pn,
              peLocal = parseEbuildVersion ver,
              pePath = ebuildPath
            }
        locals = [Ebuild "dev-util" pn ver ebuildPath]
        src = GitHub "jdx" "hk" "v"
    cache <- disabledCache
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        src
        (Cargo Nothing Nothing CargoGitTag)
        Set.empty
    case reportStatus report of
      Ok _ -> pure ()
      Outdated lines_ ->
        assertTrue
          "incomplete newest is not a TO"
          (not (any isIncompleteTo lines_))
      other ->
        assertFailure ("expected Ok or no 0.50.0 TO, got " <> show other)
  where
    isIncompleteTo OutdatedLine {olTo = to} = to == parseEbuildVersion "0.50.0"
    isIncompleteTo _ = False

------------------------------------------------------------------------
-- Overlay wait-edge plan-delta / outdated blocked-on
------------------------------------------------------------------------

seedBunBin :: FilePath -> T.Text -> IO FilePath
seedBunBin overlay ver = do
  let pkgDir = overlay </> "dev-lang" </> "bun-bin"
      name = "bun-bin-" <> T.unpack ver <> ".ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> name)
    "EAPI=8\nKEYWORDS=\"~amd64 ~arm64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST bun 1\n"
  pure (pkgDir </> name)

seedRalph :: FilePath -> T.Text -> IO FilePath
seedRalph overlay ver = do
  let pkgDir = overlay </> "dev-util" </> "ralph-tui"
      name = "ralph-tui-" <> T.unpack ver <> ".ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> name) "EAPI=8\nKEYWORDS=\"~amd64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST ralph 1\n"
  pure (pkgDir </> name)

liveBunOps ::
  FilePath ->
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text BunProbe)) ->
  IO DepsPlanOps
liveBunOps overlay listVers fetchBun = do
  ops <-
    mkDepsPlanOps
      listVers
      unusedGoMod
      unusedNpm
      fetchBun
      unusedCargo
      (Just overlay)
  modifyMVar_ (dpoBunCeilingsCache ops) (\_ -> pure Nothing)
  pure ops

countingLiveBunOps ::
  FilePath ->
  [T.Text] ->
  IO (DepsPlanOps, IORef Int, IORef Int)
countingLiveBunOps overlay vers = do
  lists <- newIORef (0 :: Int)
  probes <- newIORef (0 :: Int)
  ops <-
    liveBunOps
      overlay
      ( \src -> do
          atomicModifyIORef' lists (\n -> (n + 1, ()))
          listFixed vers src
      )
      ( \o r p pv -> do
          atomicModifyIORef' probes (\n -> (n + 1, ()))
          bunEnginesForDelta o r p pv
      )
  pure (ops, lists, probes)

recordingListStatuses :: IORef [T.Text] -> MultiHandle
recordingListStatuses events =
  noopMultiHandle
    { mhStatus = \_ name ->
        atomicModifyIORef' events (\es -> (name : es, ()))
    }

bunEnginesForDelta ::
  T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text BunProbe)
bunEnginesForDelta _o _r _p pv =
  pure $
    Right $
      minimumBunProbe $
        case pv of
          "1.0.0" -> "1.1.0"
          "1.5.0" -> "1.2.0"
          _ -> "1.0.0"

ralphEbuild :: FilePath -> T.Text -> Ebuild
ralphEbuild path ver =
  Ebuild "dev-util" "ralph-tui" ver path

mkRalphPlanEnv ::
  (UpdateSource -> IO (Either T.Text EbuildVersion)) ->
  DepsPlanOps ->
  CheckCacheHandle ->
  [PackageKey] ->
  PlanEnv
mkRalphPlanEnv fetch ops cache selected =
  PlanEnv
    { peFetcher = fetch,
      peDepsPlanOps = ops,
      peCheckCache = cache,
      peJobs = 1,
      peMulti = noopMultiHandle,
      peSelectedKeys = selected,
      peObserveTree = withNewTreeLock
    }

testRefusePlanDelta :: IO ()
testRefusePlanDelta =
  withSystemTempDirectory "om-refuse-delta" $ \tmp -> do
    let overlay = tmp </> "ov"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    (ops, lists, _) <- countingLiveBunOps overlay ["1.5.0", "1.0.0"]
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected source")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        byPkg = groupByPackage (locals <> [Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath])
        env = mkRalphPlanEnv fetch ops cache [ralphKey]
    result <- planPackage env byPkg e
    case result of
      PlanHardFail k msg -> do
        assertEq "ralph key" ralphKey k
        assertTrue "names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` msg)
        assertTrue "mentions update" ("update" `T.isInfixOf` msg)
      other -> assertFailure $ "expected refuse hard-fail, got " <> show other
    listN <- readIORef lists
    assertEq "hypo still lists a second time when ceilings differ" 2 listN

testNoPlanDeltaAllowsOnDisk :: IO ()
testNoPlanDeltaAllowsOnDisk =
  withSystemTempDirectory "om-no-delta" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["1.0.0"])
        bunEnginesForDelta
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected source")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        byPkg = groupByPackage locals
        env = mkRalphPlanEnv fetch ops cache [ralphKey]
    result <- planPackage env byPkg e
    case result of
      PlanHardFail _ msg ->
        assertFailure $ "did not expect refuse: " <> T.unpack msg
      PlanSoftSkip k _ -> assertEq "ralph skip or apply on-disk" ralphKey k
      PlanNeedsWork k _ -> assertEq "ralph needs work on-disk" ralphKey k

testRefuseFailClosed :: IO ()
testRefuseFailClosed =
  withSystemTempDirectory "om-fail-closed" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["1.5.0", "1.0.0"])
        bunEnginesForDelta
    cache <- disabledCache
    let fetch _ = pure (Left "network down")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        env = mkRalphPlanEnv fetch ops cache [ralphKey]
    result <- planPackage env (groupByPackage locals) e
    case result of
      PlanHardFail k msg -> do
        assertEq "ralph key" ralphKey k
        assertTrue "names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` msg)
        assertTrue
          "indicates upstream check failed"
          ("upstream" `T.isInfixOf` msg || "could not check" `T.isInfixOf` msg)
      other -> assertFailure $ "expected fail-closed, got " <> show other

testRefuseRalphStillPlansMise :: IO ()
testRefuseRalphStillPlansMise =
  withSystemTempDirectory "om-ralph-mise" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        ( \src -> case src of
            GitHub "subsy" "ralph-tui" _ ->
              listFixed ["1.5.0", "1.0.0"] src
            GitHub "jdx" "mise" _ ->
              listFixed ["2025.1.0"] src
            _ -> listFixed ["1.0.0"] src
        )
        bunEnginesForDelta
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        miseKey = mkPackageKey "dev-util" "mise"
        ralphE =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        miseE = entry "dev-util" "mise" "2024.1.0"
        envBoth = mkRalphPlanEnv fetch ops cache [ralphKey, miseKey]
        ralphLocals = [ralphEbuild ralphPath "1.0.0"]
        miseLocals =
          [ Ebuild
              "dev-util"
              "mise"
              "2024.1.0"
              (pePath miseE)
          ]
    ralphR <- planPackage envBoth (groupByPackage ralphLocals) ralphE
    miseR <-
      planPackage
        envBoth
        (groupByPackage miseLocals)
        miseE
    case ralphR of
      PlanHardFail k _ -> assertEq "ralph refused" ralphKey k
      other -> assertFailure $ "expected ralph refuse, got " <> show other
    case miseR of
      PlanHardFail _ msg ->
        assertTrue
          "mise is not overlay-refuse"
          (not ("dev-lang/bun-bin" `T.isInfixOf` msg))
      _ -> pure ()

testSelectedBunBinHypoWorkingPlan :: IO ()
testSelectedBunBinHypoWorkingPlan =
  withSystemTempDirectory "om-selected-hypo" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["1.5.0", "1.0.0"])
        bunEnginesForDelta
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected source")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        env =
          mkRalphPlanEnv
            fetch
            ops
            cache
            [ralphKey, bunBinPackageKey]
    result <- planPackage env (groupByPackage locals) e
    case result of
      PlanNeedsWork k (PlannedDeps {pdPlan = plan, pdHypoProvider = hypo}) -> do
        assertEq "ralph key" ralphKey k
        assertTrue
          "hypo unique PVs include 1.5.0"
          (parseEbuildVersion "1.5.0" `elem` glpUniquePVs plan)
        case hypo of
          Just (prov, pv) -> do
            assertEq "provider" bunBinPackageKey prov
            assertEq "remote PV" (parseEbuildVersion "1.2.0") pv
          Nothing -> assertFailure "expected hypo provider on working plan"
      other ->
        assertFailure $ "expected hypo needs-work, got " <> show other

testOutdatedBlockedOn :: IO ()
testOutdatedBlockedOn =
  withSystemTempDirectory "om-outdated-block" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    (ops, lists, _) <- countingLiveBunOps overlay ["1.5.0", "1.0.0"]
    cache <- disabledCache
    let fetchBun src0 = case src0 of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected")
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        src = GitHub "subsy" "ralph-tui" "v"
    report <-
      checkPackageDeps
        noopMultiHandle
        fetchBun
        ops
        cache
        e
        locals
        src
        Bun
        Set.empty
    case reportStatus report of
      Outdated lines_ -> do
        assertEq
          "successful check, not a package error"
          Nothing
          (reportWarning report)
        let text = formattedReport report
            gaps = [ol | ol@OutdatedLine {} <- lines_]
            notes = [ol | ol@OutdatedNote {} <- lines_]
            refuse = overlayRefuseMessage bunBinPackageKey
        assertTrue "hypothetical gaps" (not (null gaps))
        assertTrue
          "gaps target 1.5.0"
          (all ((== parseEbuildVersion "1.5.0") . olTo) gaps)
        assertTrue
          "lane names bun-bin"
          (all (maybe False ("dev-lang/bun-bin" `T.isInfixOf`) . olLabel) gaps)
        assertTrue
          "no blocked on"
          (not (any ("blocked on" `T.isInfixOf`) text))
        assertEq "one refuse note" [OutdatedNote refuse] notes
        assertEq
          "one formatted refuse line"
          1
          (length (filter ("dev-util/ralph-tui:" `T.isPrefixOf`) text))
        assertRemovalOrder "gaps, then removal, then refuse" text
      other ->
        assertFailure $
          "expected outdated hypo lines plus refuse, got " <> show other
    listN <- readIORef lists
    assertEq "hypo still lists a second time when ceilings differ" 2 listN

testOutdatedFailClosed :: IO ()
testOutdatedFailClosed =
  withSystemTempDirectory "om-outdated-fc" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["1.5.0", "1.0.0"])
        bunEnginesForDelta
    cache <- disabledCache
    let fetch _ = pure (Left "network down")
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        src = GitHub "subsy" "ralph-tui" "v"
    report <-
      checkPackageDeps
        noopMultiHandle
        fetch
        ops
        cache
        e
        locals
        src
        Bun
        Set.empty
    case reportStatus report of
      FetchError msg -> do
        assertTrue "names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` msg)
      Ok _ ->
        assertFailure "fail-closed must not omit consumer as current"
      other ->
        assertFailure $ "expected FetchError, got " <> show other

testOutdatedBunBinOwnLine :: IO ()
testOutdatedBunBinOwnLine =
  withSystemTempDirectory "om-outdated-both" $ \tmp -> do
    let overlay = tmp </> "ov"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["1.5.0", "1.0.0"])
        bunEnginesForDelta
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          _ -> pure (Left "unexpected")
        ebuilds =
          [ Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath,
            ralphEbuild ralphPath "1.0.0"
          ]
    reports <-
      checkOverlayWithDepsPlan 2 noopMultiHandle fetch ops cache ebuilds
    let bunRep =
          [ r
          | r <- reports,
            reportKey r == mkPackageKey "dev-lang" "bun-bin"
          ]
        ralphRep =
          [ r
          | r <- reports,
            reportKey r == mkPackageKey "dev-util" "ralph-tui"
          ]
    case bunRep of
      [r] ->
        case reportStatus r of
          Outdated lines_ -> do
            let text = formattedReport r
            assertTrue
              "bun-bin unlabeled latest line"
              (any (isNothing . olLabel) [ol | ol@OutdatedLine {} <- lines_])
            assertTrue
              "gitmv has no removal line"
              (not (any ("-> removed" `T.isInfixOf`) text))
          other ->
            assertFailure $ "expected bun-bin outdated, got " <> show other
      _ -> assertFailure "expected bun-bin report"
    case ralphRep of
      [r] ->
        case reportStatus r of
          Outdated _ -> do
            let text = formattedReport r
            assertTrue
              "hypothetical ralph gap"
              (any ("-> 1.5.0" `T.isInfixOf`) text)
            assertTrue
              "no blocked on"
              (not (any ("blocked on" `T.isInfixOf`) text))
            assertTrue
              "no refuse line"
              (not (any ("dev-util/ralph-tui:" `T.isPrefixOf`) text))
          other ->
            assertFailure $ "expected ralph hypothetical gaps, got " <> show other
      _ -> assertFailure "expected ralph report"

testOutdatedEqualCeilingsSkip :: IO ()
testOutdatedEqualCeilingsSkip =
  withSystemTempDirectory "om-outdated-eq-ceil" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    (ops, lists, probes) <- countingLiveBunOps overlay ["1.5.0", "1.0.0"]
    statuses <- newIORef []
    cache <- disabledCache
    let fetchBun src0 = case src0 of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.1.0"))
          _ -> pure (Left "unexpected")
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        src = GitHub "subsy" "ralph-tui" "v"
    report <-
      checkPackageDeps
        (recordingListStatuses statuses)
        fetchBun
        ops
        cache
        e
        locals
        src
        Bun
        Set.empty
    case reportStatus report of
      Outdated _ -> do
        let text = formattedReport report
        assertTrue
          "must not indicate blocked-on"
          (not (any ("blocked on" `T.isInfixOf`) text))
        assertTrue
          "no provider-refuse line"
          (not (any ("dev-util/ralph-tui:" `T.isPrefixOf`) text))
      FetchError msg ->
        assertFailure $ "equal ceilings must not fail-close: " <> T.unpack msg
      _ -> pure ()
    listN <- readIORef lists
    probeN <- readIORef probes
    evs <- readIORef statuses
    let listingStatuses = length [s | s <- evs, s == "listing versions"]
    assertEq "on-disk list only" 1 listN
    assertTrue "probed on-disk candidates" (probeN > 0)
    assertEq "one listing versions status" 1 listingStatuses

testRefuseEqualCeilingsSkip :: IO ()
testRefuseEqualCeilingsSkip =
  withSystemTempDirectory "om-refuse-eq-ceil" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay "1.0.0"
    (ops, lists, probes) <- countingLiveBunOps overlay ["1.5.0", "1.0.0"]
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.1.0"))
          _ -> pure (Left "unexpected source")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
        env = mkRalphPlanEnv fetch ops cache [ralphKey]
    result <- planPackage env (groupByPackage locals) e
    case result of
      PlanHardFail _ msg ->
        assertFailure $ "equal ceilings must not refuse: " <> T.unpack msg
      PlanSoftSkip k _ -> assertEq "ralph on-disk skip" ralphKey k
      PlanNeedsWork k _ -> assertEq "ralph on-disk needs-work" ralphKey k
    listN <- readIORef lists
    probeN <- readIORef probes
    assertEq "on-disk list only" 1 listN
    assertTrue "probed on-disk candidates" (probeN > 0)

formattedReport :: UpdateReport -> [T.Text]
formattedReport report =
  case reportStatus report of
    Outdated lines_ -> map (formatOutdatedLine (reportKey report)) lines_
    _ -> []

assertRemovalOrder :: String -> [T.Text] -> IO ()
assertRemovalOrder label text = do
  let idxs p = [i | (i, t) <- zip [0 :: Int ..] text, p t]
      gaps = idxs (\t -> "->" `T.isInfixOf` t && not ("removed" `T.isInfixOf` t))
      removals = idxs ("-> removed" `T.isInfixOf`)
      refuses = idxs ("dev-util/ralph-tui:" `T.isPrefixOf`)
  assertTrue (label <> ": has a gap") (not (null gaps))
  assertTrue (label <> ": has a removal") (not (null removals))
  assertTrue (label <> ": has a refuse") (not (null refuses))
  assertTrue (label <> ": removal after gaps") (maximum gaps < minimum removals)
  assertTrue (label <> ": refuse after removal") (maximum removals < minimum refuses)

testFormatOutdatedLine :: IO ()
testFormatOutdatedLine = do
  let gitKey = mkPackageKey "dev-lang" "deno-bin"
      ralphKey = mkPackageKey "dev-util" "ralph-tui"
      crushKey = mkPackageKey "dev-util" "crush"
      gap =
        OutdatedLine
          { olFrom = parseEbuildVersion "0.1.0",
            olTo = parseEbuildVersion "0.2.0",
            olLabel = Nothing,
            olAssetsReusable = False
          }
      labeled =
        OutdatedLine
          { olFrom = parseEbuildVersion "1.0.0",
            olTo = parseEbuildVersion "1.5.0",
            olLabel = Just "(dev-lang/bun-bin ~amd64)",
            olAssetsReusable = True
          }
  assertEq
    "gitmv unlabeled LOCAL -> REMOTE"
    "dev-lang/deno-bin 0.1.0 -> 0.2.0"
    (formatOutdatedLine gitKey gap)
  assertEq
    "lane gap with assets marker"
    "dev-util/ralph-tui 1.0.0 -> 1.5.0 (dev-lang/bun-bin ~amd64) [assets reusable]"
    (formatOutdatedLine ralphKey labeled)
  assertEq
    "removal strips revision and has no lane label"
    "dev-util/crush 6.6.1 -> removed"
    (formatOutdatedLine crushKey (OutdatedRemoval (parseEbuildVersion "6.6.1-r2")))
  assertEq
    "note is category/package: message"
    "dev-util/ralph-tui: overlay ceiling provider dev-lang/bun-bin is not selected"
    ( formatOutdatedLine
        ralphKey
        (OutdatedNote "overlay ceiling provider dev-lang/bun-bin is not selected")
    )

writeBunEbuild :: FilePath -> T.Text -> T.Text -> IO FilePath
writeBunEbuild overlay ver keywords = do
  let pkgDir = overlay </> "dev-lang" </> "bun-bin"
      name = "bun-bin-" <> T.unpack ver <> ".ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> name)
    ("EAPI=8\nKEYWORDS=\"" <> keywords <> "\"\n")
  TIO.writeFile (pkgDir </> "Manifest") "DIST bun 1\n"
  pure (pkgDir </> name)

testOutdatedTwoHypoLanes :: IO ()
testOutdatedTwoHypoLanes =
  withSystemTempDirectory "om-two-lanes" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- writeBunEbuild overlay "1.1.0" "amd64"
    _ <- writeBunEbuild overlay "1.3.0" "~amd64"
    ralphPath <- seedRalph overlay "0.1.0"
    ops <-
      liveBunOps
        overlay
        (listFixed ["2.0.0", "1.0.0"])
        ( \_o _r _p pv ->
            pure $
              Right $
                minimumBunProbe $
                  case pv of
                    "1.0.0" -> "1.1.0"
                    "2.0.0" -> "1.4.0"
                    _ -> "9.9.9"
        )
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.4.0"))
          _ -> pure (Left "unexpected")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "0.1.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "0.1.0"]
    report <-
      checkPackageDeps
        noopMultiHandle
        fetch
        ops
        cache
        e
        locals
        (GitHub "subsy" "ralph-tui" "v")
        Bun
        (Set.fromList [bunBinPackageKey, ralphKey])
    case reportStatus report of
      Outdated lines_ -> do
        let gaps = [ol | ol@OutdatedLine {} <- lines_]
            text = formattedReport report
        case gaps of
          [a, b] ->
            assertTrue "different target PVs" (olTo a /= olTo b)
          _ ->
            assertFailure $ "expected two lane lines, got " <> show (length gaps)
        assertTrue
          "no blocked on"
          (not (any ("blocked on" `T.isInfixOf`) text))
        assertEq "no refuse note" [] [n | n@OutdatedNote {} <- lines_]
      other ->
        assertFailure $ "expected two hypothetical lanes, got " <> show other

ralphAdequate :: T.Text -> T.Text
ralphAdequate bun =
  T.unlines
    [ "EAPI=8",
      "BDEPEND=\">=dev-lang/bun-bin-" <> bun <> ":0\"",
      "KEYWORDS=\"~amd64\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/ralph-tui-${PV}/ralph-tui-${PV}-deps.tar.xz\""
    ]

-- | Plain bun 1.1.0 and tilde bun 1.3.0, with ralph 1.0.0 and 2.0.0 on disk.
-- A remote bun 1.4.0 selects both ralph PVs; the on-disk ceilings select only 1.0.0.
seedSplitBunRalph :: FilePath -> IO [Ebuild]
seedSplitBunRalph overlay = do
  plain <- writeBunEbuild overlay "1.1.0" "amd64"
  tilde <- writeBunEbuild overlay "1.3.0" "~amd64"
  let pkgDir = overlay </> "dev-util" </> "ralph-tui"
      p10 = pkgDir </> "ralph-tui-1.0.0.ebuild"
      p20 = pkgDir </> "ralph-tui-2.0.0.ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile p10 (ralphAdequate "1.1.0")
  TIO.writeFile p20 (ralphAdequate "1.4.0")
  TIO.writeFile
    (pkgDir </> "Manifest")
    ( T.unlines
        [ "DIST ralph-tui-1.0.0-deps.tar.xz 1 SHA512 deadbeef",
          "DIST ralph-tui-2.0.0-deps.tar.xz 1 SHA512 deadbeef"
        ]
    )
  pure
    [ Ebuild "dev-lang" "bun-bin" "1.1.0" plain,
      Ebuild "dev-lang" "bun-bin" "1.3.0" tilde,
      ralphEbuild p10 "1.0.0",
      ralphEbuild p20 "2.0.0"
    ]

splitBunEngines :: T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text BunProbe)
splitBunEngines _o _r _p pv =
  pure $
    Right $
      minimumBunProbe $
        case pv of
          "1.0.0" -> "1.1.0"
          "2.0.0" -> "1.4.0"
          _ -> "9.9.9"

fetchBun14 :: UpdateSource -> IO (Either T.Text EbuildVersion)
fetchBun14 src = case src of
  GitHub "oven-sh" "bun" _ ->
    pure (Right (parseEbuildVersion "1.4.0"))
  _ -> pure (Left "unexpected")

testOutdatedSatisfiedHypoSilent :: IO ()
testOutdatedSatisfiedHypoSilent =
  withSystemTempDirectory "om-hypo-silent" $ \tmp -> do
    let overlay = tmp </> "ov"
    ebuilds <- seedSplitBunRalph overlay
    ops <-
      liveBunOps
        overlay
        (listFixed ["2.0.0", "1.0.0"])
        splitBunEngines
    cache <- disabledCache
    reports <-
      checkOverlayWithDepsPlan 2 noopMultiHandle fetchBun14 ops cache ebuilds
    let bunRep = headReport (mkPackageKey "dev-lang" "bun-bin") reports
        ralphRep = headReport (mkPackageKey "dev-util" "ralph-tui") reports
    case reportStatus ralphRep of
      Ok _ -> pure ()
      other ->
        assertFailure $ "satisfied hypo must print nothing, got " <> show other
    case reportStatus bunRep of
      Outdated lines_ ->
        assertTrue
          "bun-bin unlabeled latest line"
          (any (isNothing . olLabel) [ol | ol@OutdatedLine {} <- lines_])
      other ->
        assertFailure $ "expected bun-bin outdated line, got " <> show other

testOutdatedLeftOutRefuseOnly :: IO ()
testOutdatedLeftOutRefuseOnly =
  withSystemTempDirectory "om-refuse-only" $ \tmp -> do
    let overlay = tmp </> "ov"
    ebuilds <- seedSplitBunRalph overlay
    ops <-
      liveBunOps
        overlay
        (listFixed ["2.0.0", "1.0.0"])
        splitBunEngines
    cache <- disabledCache
    let ralphKey = mkPackageKey "dev-util" "ralph-tui"
        ralphs = [e | e <- ebuilds, ebuildPackage e == "ralph-tui"]
        ralphPath = case ralphs of
          (e : _) -> ebuildPath e
          [] -> overlay
        entryR =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "2.0.0",
              pePath = ralphPath
            }
    report <-
      checkPackageDeps
        noopMultiHandle
        fetchBun14
        ops
        cache
        entryR
        ralphs
        (GitHub "subsy" "ralph-tui" "v")
        Bun
        Set.empty
    case reportStatus report of
      Outdated [OutdatedNote note] -> do
        assertEq "refuse sentence" (overlayRefuseMessage bunBinPackageKey) note
        assertEq "no keep warning" Nothing (reportWarning report)
        assertEq
          "only the refuse line"
          ["dev-util/ralph-tui: " <> overlayRefuseMessage bunBinPackageKey]
          (formattedReport report)
      other ->
        assertFailure $ "expected only the refuse line, got " <> show other

testOutdatedProviderNotOutdated :: IO ()
testOutdatedProviderNotOutdated =
  withSystemTempDirectory "om-provider-current" $ \tmp -> do
    let overlay = tmp </> "ov"
    _ <- seedBunBin overlay "1.2.0"
    ralphPath <- seedRalph overlay "1.0.0"
    (ops, lists, _) <- countingLiveBunOps overlay ["1.5.0", "1.0.0"]
    cache <- disabledCache
    let fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.1.0"))
          _ -> pure (Left "unexpected")
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
        e =
          PackageEntry
            { peKey = ralphKey,
              pePN = "ralph-tui",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = ralphPath
            }
        locals = [ralphEbuild ralphPath "1.0.0"]
    report <-
      checkPackageDeps
        noopMultiHandle
        fetch
        ops
        cache
        e
        locals
        (GitHub "subsy" "ralph-tui" "v")
        Bun
        (Set.fromList [bunBinPackageKey, ralphKey])
    case reportStatus report of
      Outdated lines_ -> do
        let gaps = [ol | ol@OutdatedLine {} <- lines_]
            text = formattedReport report
        assertTrue
          "on-disk gap targets 1.5.0"
          (any (\ol -> olTo ol == parseEbuildVersion "1.5.0") gaps)
        assertTrue
          "no refuse line"
          (not (any ("dev-util/ralph-tui:" `T.isPrefixOf`) text))
      other ->
        assertFailure $ "expected on-disk lines, got " <> show other
    listN <- readIORef lists
    assertEq "no hypothetical list" 1 listN

crushOkBody :: T.Text
crushOkBody =
  T.unlines
    [ "EAPI=8",
      "inherit go-module",
      "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
      "KEYWORDS=\"~amd64 ~arm64\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
    ]

testOutdatedPruneOnly :: IO ()
testOutdatedPruneOnly =
  withSystemTempDirectory "om-prune-only" $ \tmp -> do
    let pkgDir = tmp </> "dev-util" </> "crush"
        vers = ["0.84.0", "0.80.0", "0.80.0-r1", "0.70.0"]
    createDirectoryIfMissing True pkgDir
    mapM_
      ( \ver ->
          TIO.writeFile
            (pkgDir </> ("crush-" <> T.unpack ver <> ".ebuild"))
            (if ver == "0.84.0" then crushOkBody else "EAPI=8\n")
      )
      vers
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 1 BLAKE2B aa SHA512 abcdef0123456789\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.84.0"])
        (\_ -> pure (Right "module x\ngo 1.26.5\n"))
        unusedNpm
        unusedBun
        unusedCargo
        (Just tmp)
    cache <- disabledCache
    let ebuild ver =
          Ebuild
            "dev-util"
            "crush"
            ver
            (pkgDir </> ("crush-" <> T.unpack ver <> ".ebuild"))
        locals = map ebuild vers
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = "crush",
              peLocal = parseEbuildVersion "0.84.0",
              pePath = ebuildPath (ebuild "0.84.0")
            }
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        (GitHub "charmbracelet" "crush" "v")
        (Go Nothing)
        Set.empty
    assertEq
      "removal lines, package not omitted"
      [ "dev-util/crush 0.70.0 -> removed",
        "dev-util/crush 0.80.0 -> removed"
      ]
      (formattedReport report)

testOutdatedPinnedNotRemoved :: IO ()
testOutdatedPinnedNotRemoved =
  withSystemTempDirectory "om-pinned" $ \tmp -> do
    let crushDir = tmp </> "dev-util" </> "crush"
        otherDir = tmp </> "dev-util" </> "needs-crush"
    createDirectoryIfMissing True crushDir
    createDirectoryIfMissing True otherDir
    TIO.writeFile (crushDir </> "crush-0.84.0.ebuild") crushOkBody
    TIO.writeFile (crushDir </> "crush-0.80.0.ebuild") "EAPI=8\n"
    TIO.writeFile
      (crushDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 1 BLAKE2B aa SHA512 abcdef0123456789\n"
    TIO.writeFile
      (otherDir </> "needs-crush-1.0.0.ebuild")
      "EAPI=8\nDEPEND=\"=dev-util/crush-0.80.0\"\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.84.0"])
        (\_ -> pure (Right "module x\ngo 1.26.5\n"))
        unusedNpm
        unusedBun
        unusedCargo
        (Just tmp)
    cache <- disabledCache
    let locals =
          [ Ebuild "dev-util" "crush" "0.84.0" (crushDir </> "crush-0.84.0.ebuild"),
            Ebuild "dev-util" "crush" "0.80.0" (crushDir </> "crush-0.80.0.ebuild")
          ]
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = "crush",
              peLocal = parseEbuildVersion "0.84.0",
              pePath = crushDir </> "crush-0.84.0.ebuild"
            }
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        (GitHub "charmbracelet" "crush" "v")
        (Go Nothing)
        Set.empty
    case reportStatus report of
      Ok _ ->
        assertTrue
          "no 0.80.0 removal"
          (not (any ("0.80.0 -> removed" `T.isInfixOf`) (formattedReport report)))
      other ->
        assertFailure $ "pinned extra must not become a removal line, got " <> show other

testOutdatedKeepFailure :: IO ()
testOutdatedKeepFailure =
  withSystemTempDirectory "om-keep-fail" $ \tmp -> do
    let crushDir = tmp </> "dev-util" </> "crush"
        otherDir = tmp </> "dev-util" </> "needs-crush"
    createDirectoryIfMissing True crushDir
    createDirectoryIfMissing True otherDir
    TIO.writeFile (crushDir </> "crush-0.84.0.ebuild") crushOkBody
    TIO.writeFile (crushDir </> "crush-0.80.0.ebuild") "EAPI=8\n"
    TIO.writeFile
      (crushDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 1 BLAKE2B aa SHA512 abcdef0123456789\n"
    TIO.writeFile
      (otherDir </> "needs-crush-1.0.0.ebuild")
      "EAPI=8\nDEPEND=\"unterminated\n"
    ops <-
      mkDepsPlanOps
        (listFixed ["0.90.0", "0.84.0"])
        (\_ -> pure (Right "module x\ngo 1.26.5\n"))
        unusedNpm
        unusedBun
        unusedCargo
        (Just tmp)
    cache <- disabledCache
    let locals =
          [ Ebuild "dev-util" "crush" "0.84.0" (crushDir </> "crush-0.84.0.ebuild"),
            Ebuild "dev-util" "crush" "0.80.0" (crushDir </> "crush-0.80.0.ebuild")
          ]
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = "crush",
              peLocal = parseEbuildVersion "0.84.0",
              pePath = crushDir </> "crush-0.84.0.ebuild"
            }
    report <-
      checkPackageDeps
        noopMultiHandle
        unusedFetch
        ops
        cache
        e
        locals
        (GitHub "charmbracelet" "crush" "v")
        (Go Nothing)
        Set.empty
    case reportStatus report of
      Outdated lines_ -> do
        let gaps = [ol | ol@OutdatedLine {} <- lines_]
        assertTrue
          "lane gap still emitted"
          (any (\ol -> olTo ol == parseEbuildVersion "0.90.0") gaps)
        assertTrue
          "no guessed removal"
          (not (any ("-> removed" `T.isInfixOf`) (formattedReport report)))
        case reportWarning report of
          Just _ -> pure ()
          Nothing -> assertFailure "keep failure must be a warning"
      other ->
        assertFailure $ "expected gaps plus keep error, got " <> show other

testOutdatedGitMvNoRemoval :: IO ()
testOutdatedGitMvNoRemoval =
  withSystemTempDirectory "om-gitmv-pin" $ \tmp -> do
    newest <- writeBunEbuild tmp "1.2.0" "~amd64 ~arm64"
    let pkgDir = tmp </> "dev-lang" </> "bun-bin"
        pin = pkgDir </> "bun-bin-1.1.0.ebuild"
    TIO.writeFile pin "EAPI=8\nSLOT=\"${PV}\"\nKEYWORDS=\"~amd64\"\n"
    cache <- disabledCache
    let locals =
          [ Ebuild "dev-lang" "bun-bin" "1.2.0" newest,
            Ebuild "dev-lang" "bun-bin" "1.1.0" pin
          ]
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-lang" "bun-bin",
              pePN = "bun-bin",
              peLocal = parseEbuildVersion "1.2.0",
              pePath = newest
            }
        fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.3.0"))
          _ -> pure (Left "unexpected")
    report <- checkPackage fetch cache e locals
    case reportStatus report of
      Outdated [line@OutdatedLine {}] -> do
        assertEq "from" (parseEbuildVersion "1.2.0") (olFrom line)
        assertEq "to" (parseEbuildVersion "1.3.0") (olTo line)
        assertEq "unlabeled" Nothing (olLabel line)
        assertTrue
          "no removal line"
          (not (any ("-> removed" `T.isInfixOf`) (formattedReport report)))
      other ->
        assertFailure $ "expected unlabeled bun-bin line, got " <> show other

headReport :: PackageKey -> [UpdateReport] -> UpdateReport
headReport key reports =
  case [r | r <- reports, reportKey r == key] of
    (r : _) -> r
    [] ->
      UpdateReport
        { reportKey = key,
          reportStatus = FetchError "missing report",
          reportWarning = Nothing
        }

testListVersionsSuccessCache :: IO ()
testListVersionsSuccessCache = do
  fetchCount <- newIORef (0 :: Int)
  let src = GitHub "o" "r" "v"
      vers = [parseEbuildVersion "1.0.0"]
      base _ = do
        n <- atomicModifyIORef' fetchCount (\c -> (c + 1, c + 1))
        if n == 1
          then pure (Left "transient")
          else pure (Right vers)
  cached <- withListVersionsSuccessCache base
  r1 <- cached src
  r2 <- cached src
  r3 <- cached src
  fetches <- readIORef fetchCount
  assertEq "Left is not stored" (Left "transient") r1
  assertEq "retry succeeds" (Right vers) r2
  assertEq "success is reused" (Right vers) r3
  assertEq "one retry after Left then cache hit" 2 fetches

testBunEnginesSuccessCache :: IO ()
testBunEnginesSuccessCache = do
  fetchCount <- newIORef (0 :: Int)
  let probe = minimumBunProbe "1.2.0"
      base _o _r _p _pv = do
        n <- atomicModifyIORef' fetchCount (\c -> (c + 1, c + 1))
        if n == 1
          then pure (Left "transient")
          else pure (Right probe)
  cached <- withBunEnginesSuccessCache base
  r1 <- cached "o" "r" "v" "1.0.0"
  r2 <- cached "o" "r" "v" "1.0.0"
  r3 <- cached "o" "r" "v" "1.0.0"
  fetches <- readIORef fetchCount
  assertEq "Left is not stored" (Left "transient") r1
  assertEq "retry succeeds" (Right probe) r2
  assertEq "success is reused" (Right probe) r3
  assertEq "one retry after Left then cache hit" 2 fetches
