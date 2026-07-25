{-# LANGUAGE OverloadedStrings #-}

-- | Unit + Integration coverage for product Update.Check and Update.Deps.Plan
-- entry points with injectable Fetcher / DepsPlanOps — no live network.
module Test.CheckPlan (unitTests, integrationTests) where

import CLI.Jobs (newWorkBudget)
import CLI.Progress (noopMultiHandle)
import Control.Concurrent.MVar (newMVar)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Support (dualArchGoCeilings)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Check
  ( PackageEntry (..),
    checkOverlayWithDepsPlan,
    checkPackage,
    checkPackageDeps,
  )
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithProgress,
    toGoPlanOps,
  )
import Update.Go.Lanes
  ( PlanError (..),
    RuntimeLanePlan (..),
    planErrorMessage,
  )
import Update.Go.ModFetch (GoModKey (..))
import Update.Go.Plan (noopPlanProgress)
import Update.Runtime.Ceilings (RuntimeCeilings (..))
import Update.Types
  ( EcosystemSpec (..),
    OutdatedLine (..),
    PackageKey (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "CheckPlan"
    [ testGroup
        "checkPackage GitMvAndManifest"
        [ testCase "outdated" testCheckPackageOutdated,
          testCase "ok" testCheckPackageOk,
          testCase "ahead" testCheckPackageAhead,
          testCase "fetch error" testCheckPackageFetchError,
          testCase "unconfigured" testCheckPackageUnconfigured
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
          testCase "Go wrong source" testPlanGoWrongSource,
          testCase "Npm wrong source" testPlanNpmWrongSource,
          testCase "Bun missing overlay" testPlanBunMissingOverlay,
          testCase "Cargo wrong source" testPlanCargoWrongSource,
          testCase "empty local PVs" testPlanNoNonLiveLocal,
          testCase "list versions failure" testPlanListVersionsFailed,
          testCase "zero planned PVs" testPlanZeroPlannedPVs,
          testCase "npm probe failure" testPlanNpmProbeFailed
        ]
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "CheckPlan"
    [ testCase
        "checkOverlayWithDepsPlan multi-package"
        testCheckOverlayWithDepsPlanMulti
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

-- | Fully mocked DepsPlanOps with pre-filled ceiling caches (no portageq / network).
mkDepsPlanOps ::
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (GoModKey -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> Maybe FilePath -> IO (Either T.Text T.Text)) ->
  Maybe FilePath ->
  IO DepsPlanOps
mkDepsPlanOps listVers fetchGo fetchNpm fetchBun fetchCargo mOverlay = do
  mgr <- newManager tlsManagerSettings
  budget <- newWorkBudget 4
  goCache <- newMVar (Just goCeilings)
  nodeCache <- newMVar (Just nodeCeilings)
  bunCache <- newMVar (Just bunCeilings)
  rustCache <- newMVar (Just rustCeilings)
  pure
    DepsPlanOps
      { dpoPortageq = \_ -> pure (Left "portageq unused in CheckPlan tests"),
        dpoListVersions = listVers,
        dpoFetchGoMod = fetchGo,
        dpoFetchNpmEngines = fetchNpm,
        dpoFetchBunEngines = fetchBun,
        dpoFetchCargoToml = fetchCargo,
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoOverlayRoot = mOverlay,
        dpoManager = mgr
      }

unusedGoMod :: GoModKey -> IO (Either T.Text T.Text)
unusedGoMod _ = pure (Left "go.mod unused")

unusedNpm :: T.Text -> T.Text -> IO (Either T.Text T.Text)
unusedNpm _ _ = pure (Left "npm engines unused")

unusedBun :: T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)
unusedBun _ _ _ _ = pure (Left "bun engines unused")

unusedCargo ::
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  Maybe FilePath ->
  IO (Either T.Text T.Text)
unusedCargo _ _ _ _ _ = pure (Left "cargo toml unused")

listFixed :: [T.Text] -> UpdateSource -> IO (Either T.Text [EbuildVersion])
listFixed vers _ = pure (Right (map parseEbuildVersion vers))

isOutdated :: UpdateStatus -> Bool
isOutdated (Outdated _) = True
isOutdated _ = False

------------------------------------------------------------------------
-- checkPackage (GitMvAndManifest / resolveSource path)
------------------------------------------------------------------------

-- Uses real hardcoded keys so resolveSource + checkPackage run product code.
testCheckPackageOutdated :: IO ()
testCheckPackageOutdated = do
  let e = entry "dev-util" "opencode-bin" "0.1.0"
      fetch _ = pure (Right (parseEbuildVersion "0.2.0"))
  report <- checkPackage fetch e
  case reportStatus report of
    Outdated [line] -> do
      assertEq "from" (parseEbuildVersion "0.1.0") (olFrom line)
      assertEq "to" (parseEbuildVersion "0.2.0") (olTo line)
    other -> assertFailure $ "expected Outdated, got " <> show other

testCheckPackageOk :: IO ()
testCheckPackageOk = do
  let e = entry "dev-util" "opencode-bin" "1.0.0"
      fetch _ = pure (Right (parseEbuildVersion "1.0.0"))
  report <- checkPackage fetch e
  case reportStatus report of
    Ok v -> assertEq "ok" (parseEbuildVersion "1.0.0") v
    other -> assertFailure $ "expected Ok, got " <> show other

testCheckPackageAhead :: IO ()
testCheckPackageAhead = do
  let e = entry "dev-lang" "bun-bin" "2.0.0"
      fetch _ = pure (Right (parseEbuildVersion "1.5.0"))
  report <- checkPackage fetch e
  case reportStatus report of
    Ahead local remote -> do
      assertEq "local" (parseEbuildVersion "2.0.0") local
      assertEq "remote" (parseEbuildVersion "1.5.0") remote
    other -> assertFailure $ "expected Ahead, got " <> show other

testCheckPackageFetchError :: IO ()
testCheckPackageFetchError = do
  let e = entry "dev-util" "opencode-bin" "1.0.0"
      fetch _ = pure (Left "network down")
  report <- checkPackage fetch e
  case reportStatus report of
    FetchError msg -> assertTrue "error text" ("network down" `T.isInfixOf` msg)
    other -> assertFailure $ "expected FetchError, got " <> show other

testCheckPackageUnconfigured :: IO ()
testCheckPackageUnconfigured = do
  let e = entry "dev-lang" "haskell" "9.6.1"
      fetch _ = pure (Left "should not be called")
  report <- checkPackage fetch e
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
  report <-
    checkPackageDeps noopMultiHandle ops e locals src (Go Nothing)
  assertTrue "outdated gaps" (isOutdated (reportStatus report))
  assertEq "key" (PackageKey "dev-util/beads") (reportKey report)

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
  report <-
    checkPackageDeps noopMultiHandle ops e locals src NpmEco
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
                Right " [package]\nrust-version = \"1.80.0\"\n"
              ("0.50.0", Nothing) ->
                Right " [package]\nrust-version = \"1.85.0\"\n"
              _ -> Left "missing Cargo.toml"
      )
      Nothing
  plan <-
    assertRight "cargo plan"
      =<< planDepsPackageWithProgress
        ops
        noopPlanProgress
        (Cargo Nothing Nothing)
        (GitHub "jdx" "hk" "v")
        [parseEbuildVersion "0.40.0"]
  assertTrue "planned non-empty" (not (null (glpUniquePVs plan)))
  assertEq "rust atom" "dev-lang/rust|rust-bin" (glpRuntimeAtom plan)

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
        (Cargo Nothing Nothing)
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
        GitHub "anomalyco" "opencode" _ ->
          Right (parseEbuildVersion "0.5.0")
        _ -> Left "unexpected fetch source"
      ebuilds =
        [ -- GitMv: outdated via checkPackage
          Ebuild
            "dev-util"
            "opencode-bin"
            "0.1.0"
            "/tmp/opencode-bin-0.1.0.ebuild",
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
  reports <-
    checkOverlayWithDepsPlan 2 noopMultiHandle fetch ops ebuilds
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
    "opencode outdated"
    ( any
        ( \r ->
            reportKey r == PackageKey "dev-util/opencode-bin"
              && isOutdated (reportStatus r)
        )
        reports
    )
