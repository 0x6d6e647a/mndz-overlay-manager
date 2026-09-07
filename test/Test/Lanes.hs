{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Lanes (unitTests, integrationTests) where

import CLI.Jobs
  ( mapConcurrentlyN,
    newWorkBudget,
    withWorkSlot,
    workBudgetCapacity,
  )
import CLI.Parser (ColorMode (..), resolveVerbosity)
import CLI.Parser qualified as V
import CLI.Progress
  ( ActiveJob (..),
    DrawPlan (..),
    JobRow (..),
    MultiHandle (..),
    MultiState (..),
    PanelIO (..),
    ProgressConfig,
    defaultPanelIO,
    mkProgressConfig,
    multiHandle,
    noopMultiHandle,
    pauseActivePanel,
    planDraw,
    renderMulti,
    resumeActivePanel,
    withMultiProgressIO,
    withStepProgressIO,
  )
import Colog (LogAction (..), Message, Msg (..))
import Colog qualified as C
import Config.Loader (ConfigError (..), loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, race)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Stack (callStack)
import Logging.Bootstrap
  ( fmtMessageColored,
    mkLogHold,
    showSeverityColored,
    verbosityToSeverity,
  )
import Overlay.Discovery
  ( DiscoveryError (..),
    collectEbuilds,
    parseEbuildFileName,
  )
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Validation (validateOverlay)
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    prettyVersion,
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Support (dualArchGoCeilings)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    applyPackagePhase1Tracked,
    foldExitHardFail,
  )
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitErrorMessage,
    applyUnitHardFail,
  )
import Update.Apply.TestSupport
  ( applyPackagePhase1,
    contentFixNeeded,
    fullPathMaterializeSteps,
    goPublishAndOverlay,
    harvestVsLaneCeiling,
    markSuccessLinesReused,
    materializePlan,
    materializeStepTotalUpper,
    newEbuildFileName,
    renderPVNoRev,
    reusePathMaterializeSteps,
    reviseMaterializeStepTotal,
    signedOverlayCommit,
  )
import Update.Assets.Hash (FileDigests (..), digestSHA512, hashBytes, sidecarLine)
import Update.Assets.Layout (cratesTarballName, depsTarballName, vendorTarballName)
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseOps (..),
    findAssetByName,
    lookupNamedAsset,
    parseReleaseInfo,
  )
import Update.Auth (resolveGitHubTokenWith)
import Update.Bun.Cache (productionBunCacheOps)
import Update.Cargo.Crates (productionCargoOps)
import Update.Cargo.Msrv
  ( CargoTomlFetch (..),
    TagFloorResult (..),
    combineMsrv,
    maxRustVersion,
    normalizeRustVersion,
    orderedCargoTomlProbePaths,
    parseRustMinVerFromEbuild,
    parseRustVersionField,
    probeDirectTagFloor,
    probePolicyTagFloor,
  )
import Update.Check
  ( InventoryFile (..),
    PackageEntry (..),
    groupNewest,
    selectCanonicalSamePV,
    selectHighestNonLive,
  )
import Update.Deps.Plan (DepsPlanOps (..), productionDepsPlanOps)
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildHasDevLangGoBdepend,
    ebuildNeedsCargoContentFix,
    ebuildNeedsContentFix,
    ensureCargoAssetsSrcUri,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureRustMinVer,
    goBdependAtom,
    goBdependMatches,
    keywordsMatch,
    manifestHasVendorDist,
    nextRevisionVersion,
    nodejsBdependMatches,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
    setKeywords,
    writeVersionForPlannedPV,
  )
import Update.Engines (parseEnginesMinimum)
import Update.Git (GitOps (..))
import Update.GitHub (stripAndParse)
import Update.Go.Lanes
  ( GapLine (..),
    LaneId (..),
    LaneTarget (..),
    PlanError (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    VersionCandidate (..),
    assembleKeywords,
    assembleKeywordsFor,
    buildGapLines,
    collapsePlannedEbuilds,
    extrasToDelete,
    filterCandidateVersions,
    laneLabel,
    laneLabelWith,
    ltLane,
    maxVersionUnder,
    missingTargets,
    planErrorMessage,
    planFromTargets,
    planFromTargetsWithAtomFor,
    planNeedsWork,
    selectAllLaneTargets,
    selectAllLaneTargetsFor,
    zeroPlannedPVsError,
    pattern LaneAmd64Plain,
    pattern LaneAmd64Tilde,
    pattern LaneArm64Plain,
    pattern LaneArm64Tilde,
  )
import Update.Go.ModFetch (GoModKey (..), withGoModCache)
import Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    noopPlanProgress,
    planGoPackage,
    planGoPackageWithProgress,
  )
import Update.Go.Vendor
  ( VendorOps (..),
    VendorProgress (..),
    VendorResult (..),
    buildVendorTarball,
    noopVendorProgress,
  )
import Update.Go.Version
  ( compareGoVersions,
    enrichGoModDownloadError,
    goVersionTooOldMessage,
    hostMeetsGoRequirement,
    looksLikeToolchainError,
    parseGoModGoDirective,
    parseGoVersionOutput,
    parseGoVersionToken,
  )
import Update.GpgAgent
  ( GpgAgentOps (..),
    Keygrip (..),
    ensureGpgReady,
    newGpgHandle,
    parseKeyinfoCached,
    parseSignCapableKeygrip,
    pinentryChildEnv,
    teardownGpgHandle,
  )
import Update.Hardcoded (lookupHardcoded, lookupPolicy)
import Update.Md5Cache
  ( EgencacheRequest (..),
    GencacheAction (..),
    PackageCacheIssue (..),
    VersionCacheStatus (..),
    buildRepositoriesConfiguration,
    cacheFilePath,
    checkLayoutCacheFormats,
    classifyVersionCache,
    decideGencacheAction,
    ebuildFileMd5,
    gencachePackages,
    inspectPackageCache,
    listNonLiveEbuildVersions,
    packageCacheGateError,
    readCacheMd5Field,
  )
import Update.Npm.Cache (productionNpmCacheOps)
import Update.Preflight (checkToolsOnPath, goAssetsRequiredTools, updateRequiredTools)
import Update.Resolve (resolveSource)
import Update.Runtime.Ceilings
  ( ArchCeilings (..),
    RuntimeCeilings (..),
    RuntimeEbuildMeta (..),
    computeCeilings,
    discoverBunBinCeilings,
    discoverGoCeilingsWith,
    discoverNodejsCeilingsWith,
    discoverRustUnionCeilingsWith,
    discoverSbclCeilingsWith,
    emptyCeilings,
    isLiveRuntimeVersion,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    mergeCeilingsMax,
    normalizeArchToken,
    parseKeywordsField,
    parseRuntimeEbuildMeta,
  )
import Update.SshAgent
  ( AgentIdentities (..),
    SshAgentOps (..),
    SshSession (..),
    ensureSshAgent,
    parseIdentityFiles,
  )
import Update.Targets (TargetError (..), resolveTargetToken, resolveTargets)
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    OutdatedLine (..),
    PackageKey (..),
    PackagePolicy (..),
    SuccessLine (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    UpdateTechnique (..),
    mkPackageKey,
    packageKeyText,
  )

-- | Pure / single-concern lane ceilings, filters, and cache helpers.
unitTests :: TestTree
unitTests =
  testGroup
    "Lanes"
    [ testCase "Go Tree Ceilings" testGoTreeCeilings,
      testCase "Multi Arch Ceilings" testMultiArchCeilings,
      testCase "Tilde Only Bun Ceilings" testTildeOnlyBunCeilings,
      testCase "Candidate Version Filter" testCandidateVersionFilter,
      testCase "Engines Minimum Parse" testEnginesMinimumParse,
      testCase "Cargo Msrv And Ceilings" testCargoMsrvAndCeilings,
      testCase "Cargo Toml Probe Order" testCargoTomlProbeOrder,
      testCase "Cargo Policy Tag Floor Walker" testPolicyTagFloorWalker,
      testCase "Canonical Ebuild Revision" testCanonicalEbuildRevision,
      testCase "Go Lane Selection" testGoLaneSelection,
      testCase "Go Lane Collapse" testGoLaneCollapse,
      testCase "Lane Arch Allowlist" testLaneArchAllowlist,
      testCase "Go Gap Lines" testGoGapLines,
      testCase "Go Strip And Parse List" testGoStripAndParseList,
      testCase "Go Mod Cache Concurrent Distinct Keys" testGoModCacheConcurrentDistinctKeys,
      testCase "Go Mod Cache Hit No Refetch" testGoModCacheHitNoRefetch
    ]

-- | PlanOps-driven go plan / probe workflows (multi-phase planning).
integrationTests :: TestTree
integrationTests =
  testGroup
    "Lanes"
    [ testCase "Go Plan Integration Mocked" testGoPlanIntegrationMocked,
      testCase "Go Mod Probe Early Exit Tip Fills All" testGoModProbeEarlyExitTipFillsAll,
      testCase "Go Mod Probe Early Exit Plain Older" testGoModProbeEarlyExitPlainOlder,
      testCase "Go Mod Probe Early Exit Matches Full Probe" testGoModProbeEarlyExitMatchesFullProbe,
      testCase "Go Mod Probe Early Exit Skips Unparseable Tip" testGoModProbeEarlyExitSkipsUnparseableTip,
      testCase "Go Plan Progress Coarse Steps" testGoPlanProgressCoarseSteps,
      testCase "Runtime Ceiling Discover Residual Empty Cache" testRuntimeCeilingDiscoverResidual
    ]

------------------------------------------------------------------------
-- Go tree-lane planner
------------------------------------------------------------------------

testGoTreeCeilings :: IO ()
testGoTreeCeilings = do
  let kwPlain = parseKeywordsField "KEYWORDS=\"amd64 ~arm64\"\n"
      kwTilde = parseKeywordsField "KEYWORDS=\"~amd64 ~arm64\"\n"
  assertTrue "bare amd64" (keywordsHasBare "amd64" kwPlain)
  assertTrue "not bare when tilde only" (not (keywordsHasBare "amd64" kwTilde))
  assertTrue "tilde or bare for ~amd64" (keywordsHasTildeOrBare "amd64" kwTilde)
  assertTrue "tilde or bare for bare" (keywordsHasTildeOrBare "amd64" kwPlain)
  assertTrue "live 9999" (isLiveRuntimeVersion (parseEbuildVersion "9999"))
  assertTrue "not live" (not (isLiveRuntimeVersion (parseEbuildVersion "1.26.3")))
  case parseRuntimeEbuildMeta "/x/go-9999.ebuild" "KEYWORDS=\"~amd64\"\n" of
    Nothing -> pure ()
    Just _ -> do
      hPutStrLn stderr "expected Nothing for live go ebuild"
      exitFailure
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "1.26.3") ["amd64", "arm64"],
          RuntimeEbuildMeta (parseEbuildVersion "1.26.4") ["~amd64", "~arm64"],
          RuntimeEbuildMeta (parseEbuildVersion "1.25.0") ["~amd64"]
        ]
      ceilings = computeCeilings "dev-lang/go" metas
  assertEq "amd64 plain" (Just (parseEbuildVersion "1.26.3")) (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
  assertEq "amd64 tilde" (Just (parseEbuildVersion "1.26.4")) (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
  assertEq "arm64 plain" (Just (parseEbuildVersion "1.26.3")) (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "arm64" (rcByArch ceilings)))
  assertEq "arm64 tilde" (Just (parseEbuildVersion "1.26.4")) (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "arm64" (rcByArch ceilings)))
  assertEq "empty ceilings" (emptyCeilings "dev-lang/go") (computeCeilings "dev-lang/go" [])

testMultiArchCeilings :: IO ()
testMultiArchCeilings = do
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "20.0.0") ["amd64", "~loong"],
          RuntimeEbuildMeta (parseEbuildVersion "22.0.0") ["~amd64", "~loong", "arm64"]
        ]
      ceilings = computeCeilings "net-libs/nodejs" metas
  assertTrue "has loong" (Map.member "loong" (rcByArch ceilings))
  assertTrue "has amd64" (Map.member "amd64" (rcByArch ceilings))
  assertTrue "has arm64" (Map.member "arm64" (rcByArch ceilings))
  assertEq
    "loong plain absent"
    Nothing
    (acPlain (rcByArch ceilings Map.! "loong"))
  assertEq
    "loong tilde"
    (Just (parseEbuildVersion "22.0.0"))
    (acTilde (rcByArch ceilings Map.! "loong"))
  assertEq
    "arm64 plain"
    (Just (parseEbuildVersion "22.0.0"))
    (acPlain (rcByArch ceilings Map.! "arm64"))

testTildeOnlyBunCeilings :: IO ()
testTildeOnlyBunCeilings = do
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "1.3.6") ["~amd64", "~arm64"]
        ]
      ceilings = computeCeilings "dev-lang/bun-bin" metas
      targets = selectAllLaneTargets ceilings []
  assertTrue "no plain amd64 ceiling" (isNothing (acPlain (rcByArch ceilings Map.! "amd64")))
  assertEq
    "tilde amd64 ceiling"
    (Just (parseEbuildVersion "1.3.6"))
    (acTilde (rcByArch ceilings Map.! "amd64"))
  -- Lanes exist for tilde only
  assertTrue
    "tilde lanes present"
    (any (\t -> ltLane t == LaneAmd64Tilde) targets)

testCandidateVersionFilter :: IO ()
testCandidateVersionFilter = do
  let local = [parseEbuildVersion "1.4.1"]
      upstream =
        [ parseEbuildVersion "1.4.0",
          parseEbuildVersion "1.4.1",
          parseEbuildVersion "1.5.0",
          parseEbuildVersion "1.6.0"
        ]
  case filterCandidateVersions local upstream of
    Left err -> do
      hPutStrLn stderr (T.unpack (planErrorMessage err))
      exitFailure
    Right cs -> do
      assertTrue "has local 1.4.1" (parseEbuildVersion "1.4.1" `elem` cs)
      assertTrue "has 1.5.0" (parseEbuildVersion "1.5.0" `elem` cs)
      assertTrue "has 1.6.0" (parseEbuildVersion "1.6.0" `elem` cs)
      assertTrue "no 1.4.0" (parseEbuildVersion "1.4.0" `notElem` cs)
  case filterCandidateVersions [] upstream of
    Left PlanNoNonLiveLocal -> pure ()
    Left other -> do
      hPutStrLn stderr ("expected PlanNoNonLiveLocal, got: " <> show other)
      exitFailure
    Right _ -> do
      hPutStrLn stderr "expected hard-fail for empty local"
      exitFailure

  -- Pretty-printers stay stable for known plan failure classes
  assertEq
    "zero planned PVs message"
    zeroPlannedPVsError
    (planErrorMessage PlanZeroPlannedPVs)
  assertTrue
    "no non-live local mentions first import"
    ("first import" `T.isInfixOf` planErrorMessage PlanNoNonLiveLocal)

testEnginesMinimumParse :: IO ()
testEnginesMinimumParse = do
  assertEq ">= form" (Just "20.19.0") (parseEnginesMinimum ">=20.19.0")
  assertEq "bare" (Just "1.3.6") (parseEnginesMinimum "1.3.6")
  assertEq "v prefix" (Just "1.2.3") (parseEnginesMinimum "v1.2.3")
  assertEq "caret" (Just "22.22.2") (parseEnginesMinimum "^22.22.2")
  assertEq
    "node-gyp disjunction"
    (Just "22.22.2")
    (parseEnginesMinimum "^22.22.2 || ^24.15.0 || >=26.0.0")
  assertEq "or lowest bound" (Just "18.0.0") (parseEnginesMinimum ">=18.0.0 || >=20.0.0")
  assertEq "star" Nothing (parseEnginesMinimum "*")
  assertEq "empty" Nothing (parseEnginesMinimum "")
  assertEq "hyphen range" Nothing (parseEnginesMinimum "1.0.0 - 2.0.0")
  assertEq "less-than" Nothing (parseEnginesMinimum "<20.0.0")

testCargoMsrvAndCeilings :: IO ()
testCargoMsrvAndCeilings = do
  assertEq "normalize short" (Just "1.91.0") (normalizeRustVersion "1.91")
  assertEq "normalize full" (Just "1.88.0") (normalizeRustVersion "1.88.0")
  assertEq
    "parse rust-version"
    (Right (Just "1.88.0"))
    (parseRustVersionField "[package]\nname = \"hk\"\nrust-version = \"1.88.0\"\n")
  assertEq
    "package precedes workspace.package"
    (Right (Just "1.91.0"))
    ( parseRustVersionField
        "[package]\nrust-version = \"1.91\"\n[workspace.package]\nrust-version = \"1.95\"\n"
    )
  assertEq
    "workspace.package used when package absent"
    (Right (Just "1.70.0"))
    ( parseRustVersionField
        "[workspace.package]\nrust-version = \"1.70\"\n"
    )
  assertEq
    "inheritance marker is absent not malformed"
    (Right Nothing)
    ( parseRustVersionField
        "[package]\nrust-version.workspace = true\n"
    )
  assertEq
    "wrong-table rust-version ignored"
    (Right Nothing)
    ( parseRustVersionField
        "[dependencies]\nrust-version = \"1.99\"\n"
    )
  assertEq
    "malformed TOML fails"
    True
    ( case parseRustVersionField "[[[ not toml" of
        Left _ -> True
        Right _ -> False
    )
  assertEq
    "malformed present value fails"
    True
    ( case parseRustVersionField "[package]\nrust-version = \"not-a-version\"\n" of
        Left _ -> True
        Right _ -> False
    )
  assertEq
    "numeric 1.100 > 1.99"
    (Just "1.100.0")
    (maxRustVersion "1.100" "1.99")
  assertEq
    "parse RUST_MIN_VER"
    (Just "1.95.0")
    (parseRustMinVerFromEbuild "RUST_MIN_VER=\"1.95.0\"\n")
  -- max(root missing, deps 1.90, donor 1.95) = 1.95
  assertEq
    "max deps vs donor"
    (Just "1.95.0")
    (combineMsrv Nothing (Just "1.90.0") (Just "1.95.0"))
  assertEq
    "max root over deps"
    (Just "1.92.0")
    (combineMsrv (Just "1.92") (Just "1.90.0") Nothing)
  assertEq
    "missing all hard-fail signal"
    Nothing
    (combineMsrv Nothing Nothing Nothing)
  -- U1 max: rust-bin ahead on plain amd64
  let rustCeil =
        RuntimeCeilings
          { rcAtom = "dev-lang/rust",
            rcByArch =
              Map.fromList
                [ ( "amd64",
                    ArchCeilings
                      { acPlain = Just (parseEbuildVersion "1.95.0"),
                        acTilde = Just (parseEbuildVersion "1.96.0")
                      }
                  )
                ]
          }
      binCeil =
        RuntimeCeilings
          { rcAtom = "dev-lang/rust-bin",
            rcByArch =
              Map.fromList
                [ ( "amd64",
                    ArchCeilings
                      { acPlain = Just (parseEbuildVersion "1.96.1"),
                        acTilde = Just (parseEbuildVersion "1.96.1")
                      }
                  )
                ]
          }
      merged = mergeCeilingsMax "dev-lang/rust|rust-bin" rustCeil binCeil
  assertEq "union atom" "dev-lang/rust|rust-bin" (rcAtom merged)
  assertEq
    "U1 max plain"
    (Just (parseEbuildVersion "1.96.1"))
    (acPlain (rcByArch merged Map.! "amd64"))
  assertEq
    "U1 max tilde"
    (Just (parseEbuildVersion "1.96.1"))
    (acTilde (rcByArch merged Map.! "amd64"))
  assertEq
    "lane label union"
    "(dev-lang/rust|rust-bin ~amd64)"
    (laneLabelWith "dev-lang/rust|rust-bin" LaneAmd64Tilde)
  -- rust-bin-style KEYWORDS with trailing shell comment must not invent arches
  let rustBinKw =
        parseKeywordsField
          "KEYWORDS=\"~amd64 ~arm64 ~x86\" # \"~mips ~sparc\"\n"
  assertTrue "has amd64" ("~amd64" `elem` rustBinKw || "amd64" `elem` rustBinKw)
  assertTrue "no hash token" ("#" `notElem` rustBinKw)
  assertTrue "no quoted mips" (not (any ("mips" `T.isInfixOf`) (filter (T.isPrefixOf "\"") rustBinKw)))
  assertEq
    "normalize rejects hash"
    Nothing
    (normalizeArchToken "#")
  assertEq
    "normalize rejects quote junk"
    Nothing
    (normalizeArchToken "x86\"")

testCargoTomlProbeOrder :: IO ()
testCargoTomlProbeOrder = do
  assertEq
    "package then lock then root"
    [Just "cli", Just "lock", Nothing]
    (orderedCargoTomlProbePaths (Just "cli") (Just "lock"))
  assertEq
    "effective package is lock when package unset"
    [Just "lock", Nothing]
    (orderedCargoTomlProbePaths Nothing (Just "lock"))
  assertEq
    "dedup identical package and lock"
    [Just "cli", Nothing]
    (orderedCargoTomlProbePaths (Just "cli") (Just "cli"))
  logRef <- newIORef ([] :: [Maybe FilePath])
  let fetch mSub = do
        modifyIORef' logRef (<> [mSub])
        pure CargoTomlMissing
  r <- probeDirectTagFloor (Just "cli") (Just "lock") fetch
  assertEq "all missing is absent" (Right Nothing) r
  got <- readIORef logRef
  assertEq "fetch order" [Just "cli", Just "lock", Nothing] got
  rFail <-
    probeDirectTagFloor Nothing Nothing $ \mSub ->
      pure $
        if isNothing mSub
          then CargoTomlError "boom"
          else CargoTomlMissing
  assertEq "fetch error fails closed" (Left "boom") rFail
  rParse <-
    probeDirectTagFloor (Just "cli") Nothing $ \mSub ->
      pure $
        case mSub of
          Just "cli" -> CargoTomlBody "[[[ not toml"
          _ -> CargoTomlBody "[package]\nrust-version = \"1.91\"\n"
  assertEq
    "parse error does not fall through"
    True
    ( case rParse of
        Left _ -> True
        Right _ -> False
    )
  rOk <-
    probeDirectTagFloor (Just "cli") Nothing $ \mSub ->
      pure $
        case mSub of
          Just "cli" -> CargoTomlMissing
          Nothing -> CargoTomlBody "[package]\nrust-version = \"1.91\"\n"
          _ -> CargoTomlMissing
  assertEq "fallback after missing" (Right (Just "1.91.0")) rOk

fetchMap :: [(Maybe FilePath, T.Text)] -> Maybe FilePath -> IO CargoTomlFetch
fetchMap xs k = pure $ maybe CargoTomlMissing CargoTomlBody (lookup k xs)

runFloor ::
  Maybe FilePath ->
  Maybe FilePath ->
  [(Maybe FilePath, T.Text)] ->
  IO TagFloorResult
runFloor pkg lock files =
  probePolicyTagFloor pkg lock Nothing (fetchMap files)

pkgToml :: T.Text -> T.Text -> T.Text
pkgToml name ver =
  "[package]\nname = \"" <> name <> "\"\nrust-version = \"" <> ver <> "\"\n"

testPolicyTagFloorWalker :: IO ()
testPolicyTagFloorWalker = do
  -- 1.2 inheritance
  inh <-
    runFloor
      (Just "cli")
      Nothing
      [ ( Just "cli",
          "[package]\nname = \"cli\"\nrust-version.workspace = true\n"
        ),
        ( Nothing,
          "[workspace]\nmembers = [\"cli\"]\n[workspace.package]\nrust-version = \"1.91\"\n"
        )
      ]
  case inh of
    TagFloorComplete (Just v) _ -> assertEq "resolved inheritance" "1.91.0" v
    other -> assertFailure ("inheritance: " <> show other)
  missingWs <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          "[package]\nname = \"p\"\nrust-version.workspace = true\n"
        )
      ]
  case missingWs of
    TagFloorIncomplete reasons _ ->
      assertTrue "missing workspace doc" (any ("workspace" `T.isInfixOf`) reasons)
    other -> assertFailure ("missing ws: " <> show other)
  escapeWs <-
    runFloor
      (Just "cli")
      Nothing
      [ ( Just "cli",
          "[package]\nname = \"cli\"\nworkspace = \"../..\"\nrust-version.workspace = true\n"
        )
      ]
  case escapeWs of
    TagFloorFailed err ->
      assertTrue "workspace escape names path" ("escapes" `T.isInfixOf` err)
    other -> assertFailure ("ws escape: " <> show other)
  sameFile <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          "[package]\nname = \"p\"\nrust-version = \"1.91\"\n[workspace.package]\nrust-version = \"1.95\"\n"
        )
      ]
  case sameFile of
    TagFloorComplete (Just v) _ ->
      assertEq "package field precedes workspace.package" "1.91.0" v
    other -> assertFailure ("same-file: " <> show other)
  -- 1.3 path closure
  usage <-
    runFloor
      (Just "cli")
      Nothing
      [ ( Just "cli",
          T.unlines
            [ "[package]",
              "name = \"usage\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "usage-rs = { path = \"../usage-rs\" }",
              "lib = { path = \"../lib\" }",
              "usage-derive = { path = \"../derive\", optional = true }",
              "[features]",
              "default = [\"derive\"]",
              "derive = [\"dep:usage-derive\"]"
            ]
        ),
        (Just "usage-rs", pkgToml "usage-rs" "1.91"),
        (Just "lib", pkgToml "lib" "1.91"),
        (Just "derive", pkgToml "usage-derive" "1.91"),
        (Just "benches/shadows", pkgToml "shadows" "1.99"),
        (Just "xtask", pkgToml "xtask" "1.99")
      ]
  case usage of
    TagFloorComplete (Just v) prov -> do
      assertEq "usage-style floor" "1.91.0" v
      let paths = map fst prov
      assertTrue "includes cli" (any (("cli" `T.isInfixOf`) . T.pack) paths)
      assertTrue
        "excludes benches"
        (not (any (("benches" `T.isInfixOf`) . T.pack) paths))
      assertTrue
        "excludes xtask"
        (not (any (("xtask" `T.isInfixOf`) . T.pack) paths))
    other -> assertFailure ("usage: " <> show other)
  optOn <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "extra = { path = \"extra\", optional = true }",
              "[features]",
              "default = [\"extra\"]",
              "extra = [\"dep:extra\"]"
            ]
        ),
        (Just "extra", pkgToml "extra" "1.92")
      ]
  case optOn of
    TagFloorComplete (Just v) _ ->
      assertEq "default-on optional raises" "1.92.0" v
    other -> assertFailure ("opt-on: " <> show other)
  wsDep <-
    runFloor
      (Just "cli")
      Nothing
      [ ( Just "cli",
          T.unlines
            [ "[package]",
              "name = \"cli\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "lib = { workspace = true }"
            ]
        ),
        ( Nothing,
          T.unlines
            [ "[workspace]",
              "members = [\"cli\", \"lib\"]",
              "[workspace.dependencies]",
              "lib = { path = \"lib\" }"
            ]
        ),
        (Just "lib", pkgToml "lib" "1.93")
      ]
  case wsDep of
    TagFloorComplete (Just v) _ ->
      assertEq "workspace.dependencies path" "1.93.0" v
    other -> assertFailure ("ws dep: " <> show other)
  nsFeat <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"mise\"",
              "rust-version = \"1.85\"",
              "[dependencies]",
              "vfox = { path = \"crates/vfox\", default-features = false }",
              "[features]",
              "default = [\"native-tls\", \"vfox/vendored-lua\"]",
              "native-tls = []"
            ]
        ),
        ( Just "crates/vfox",
          T.unlines
            [ "[package]",
              "name = \"vfox\"",
              "rust-version = \"1.85\"",
              "[features]",
              "default = [\"vendored-lua\"]",
              "vendored-lua = [\"mlua/vendored\"]"
            ]
        )
      ]
  case nsFeat of
    TagFloorComplete (Just v) _ ->
      assertEq "mise-style namespaced feature completes" "1.85.0" v
    other -> assertFailure ("namespaced: " <> show other)
  usageNs <-
    runFloor
      (Just "cli")
      Nothing
      [ ( Just "cli",
          T.unlines
            [ "[package]",
              "name = \"usage-cli\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "usage-rs = { path = \"../usage-rs\", features = [\"completions\"] }"
            ]
        ),
        ( Just "usage-rs",
          T.unlines
            [ "[package]",
              "name = \"usage-rs\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "usage-argv = { path = \"../argv\" }",
              "usage-derive = { path = \"../derive\", optional = true }",
              "usage-test = { path = \"../test\", optional = true }",
              "[features]",
              "default = [\"spec\"]",
              "spec = [\"usage-argv/spec\", \"dep:usage-derive\"]",
              "completions = [\"spec\", \"usage-test?/completions\"]"
            ]
        ),
        (Just "argv", pkgToml "usage-argv" "1.91"),
        (Just "derive", pkgToml "usage-derive" "1.91"),
        (Just "test", pkgToml "usage-test" "1.99")
      ]
  case usageNs of
    TagFloorComplete (Just v) _ ->
      assertEq "usage-argv/spec completes; weak test does not raise" "1.91.0" v
    other -> assertFailure ("usage ns: " <> show other)
  weakNs <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "extra = { path = \"extra\", optional = true }",
              "[features]",
              "default = [\"extra?/hot\"]"
            ]
        ),
        (Just "extra", pkgToml "extra" "1.99")
      ]
  case weakNs of
    TagFloorComplete (Just v) _ ->
      assertEq "weak namespaced does not enable optional" "1.91.0" v
    other -> assertFailure ("weak ns: " <> show other)
  depQ <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[features]",
              "default = [\"dep:foo?\"]"
            ]
        )
      ]
  case depQ of
    TagFloorIncomplete reasons _ ->
      assertTrue "dep:foo? unreadable" (any ("feature" `T.isInfixOf`) reasons)
    other -> assertFailure ("dep:foo?: " <> show other)
  devOnly <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[dev-dependencies]",
              "devcrate = { path = \"devcrate\" }"
            ]
        ),
        (Just "devcrate", pkgToml "devcrate" "1.99")
      ]
  case devOnly of
    TagFloorComplete (Just v) _ ->
      assertEq "dev-only excluded" "1.91.0" v
    other -> assertFailure ("dev-only: " <> show other)
  cycleR <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"a\"",
              "rust-version = \"1.80\"",
              "[dependencies]",
              "b = { path = \"b\" }"
            ]
        ),
        ( Just "b",
          T.unlines
            [ "[package]",
              "name = \"b\"",
              "rust-version = \"1.81\"",
              "[dependencies]",
              "a = { path = \"..\" }"
            ]
        )
      ]
  case cycleR of
    TagFloorComplete (Just v) _ -> assertEq "cycle max" "1.81.0" v
    other -> assertFailure ("cycle: " <> show other)
  missingPath <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "gone = { path = \"gone\" }"
            ]
        )
      ]
  case missingPath of
    TagFloorIncomplete reasons _ ->
      assertTrue "in-tree missing" (any ("gone" `T.isInfixOf`) reasons)
    other -> assertFailure ("missing path: " <> show other)
  -- 1.4 targets
  winOnly <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(windows)'.dependencies]",
              "wincrate = { path = \"wincrate\" }"
            ]
        ),
        (Just "wincrate", pkgToml "wincrate" "1.99")
      ]
  case winOnly of
    TagFloorComplete (Just v) _ ->
      assertEq "windows-only ignored" "1.91.0" v
    other -> assertFailure ("windows: " <> show other)
  watchedRaiseR <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(target_os = \"macos\")'.dependencies]",
              "mac = { path = \"mac\" }"
            ]
        ),
        (Just "mac", pkgToml "mac" "1.95")
      ]
  case watchedRaiseR of
    TagFloorFailed err -> do
      assertTrue "names watched path" ("mac" `T.isInfixOf` err)
      assertTrue "names watched floor" ("1.95" `T.isInfixOf` err)
      assertTrue "names active floor" ("1.91" `T.isInfixOf` err)
    other -> assertFailure ("watched raise: " <> show other)
  watchedEq <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(target_os = \"macos\")'.dependencies]",
              "mac = { path = \"mac\" }"
            ]
        ),
        (Just "mac", pkgToml "mac" "1.91")
      ]
  case watchedEq of
    TagFloorComplete (Just v) _ ->
      assertEq "watched equal succeeds" "1.91.0" v
    other -> assertFailure ("watched eq: " <> show other)
  unixInc <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(unix)'.dependencies]",
              "unixc = { path = \"unixc\" }"
            ]
        ),
        (Just "unixc", pkgToml "unixc" "1.93")
      ]
  case unixInc of
    TagFloorComplete (Just v) _ ->
      assertEq "unix included" "1.93.0" v
    other -> assertFailure ("unix: " <> show other)
  unparsed <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(weirdness)'.dependencies]",
              "x = { path = \"x\" }"
            ]
        ),
        (Just "x", pkgToml "x" "1.80")
      ]
  case unparsed of
    TagFloorIncomplete reasons _ ->
      assertTrue "unparsed cfg" (any ("cfg" `T.isInfixOf`) reasons)
    other -> assertFailure ("unparsed: " <> show other)
  androidNot <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[target.'cfg(not(target_os = \"android\"))'.dependencies]",
              "tui = { path = \"tui\" }"
            ]
        ),
        (Just "tui", pkgToml "tui" "1.93")
      ]
  case androidNot of
    TagFloorComplete (Just v) _ ->
      assertEq "not-android is active linux" "1.93.0" v
    other -> assertFailure ("not-android: " <> show other)
  -- 1.5 escape, virtual, patch
  escapeDep <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.91\"",
              "[dependencies]",
              "out = { path = \"../out\" }"
            ]
        )
      ]
  case escapeDep of
    TagFloorFailed err ->
      assertTrue "escape names path" ("escapes" `T.isInfixOf` err)
    other -> assertFailure ("escape dep: " <> show other)
  virt <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          "[workspace]\nmembers = [\"cli\"]\n"
        )
      ]
  case virt of
    TagFloorFailed err ->
      assertTrue
        "virtual asks for subdirectory"
        ("subdirectory" `T.isInfixOf` err || "package" `T.isInfixOf` err)
    other -> assertFailure ("virtual: " <> show other)
  patchOk <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.80\"",
              "[patch.crates-io]",
              "foo = { path = \"vendor/foo\" }"
            ]
        ),
        (Just "vendor/foo", pkgToml "foo" "1.88")
      ]
  case patchOk of
    TagFloorComplete (Just v) _ ->
      assertEq "in-tree patch followed" "1.88.0" v
    other -> assertFailure ("patch: " <> show other)
  patchEsc <-
    runFloor
      Nothing
      Nothing
      [ ( Nothing,
          T.unlines
            [ "[package]",
              "name = \"root\"",
              "rust-version = \"1.80\"",
              "[patch.crates-io]",
              "foo = { path = \"../escape\" }"
            ]
        )
      ]
  case patchEsc of
    TagFloorFailed err ->
      assertTrue "patch escape" ("escapes" `T.isInfixOf` err)
    other -> assertFailure ("patch escape: " <> show other)

testCanonicalEbuildRevision :: IO ()
testCanonicalEbuildRevision = do
  let mk v = InventoryFile (parseEbuildVersion v)
      files =
        [ mk "1.0.0-r2" "b.ebuild",
          mk "1.0.0" "a.ebuild",
          mk "1.0.0-r10" "c.ebuild",
          mk "9999" "live.ebuild",
          mk "2.0.0" "other.ebuild"
        ]
  case selectCanonicalSamePV (parseEbuildVersion "1.0.0") files of
    Right (Just f) -> assertEq "highest rev r10" "c.ebuild" (invPath f)
    other -> assertFailure ("expected r10, got " <> show other)
  case selectHighestNonLive files of
    Right (Just f) -> assertEq "highest non-live PV" "other.ebuild" (invPath f)
    other -> assertFailure ("expected 2.0.0, got " <> show other)
  case selectCanonicalSamePV (parseEbuildVersion "1.0.0") [mk "9999" "live.ebuild"] of
    Right Nothing -> pure ()
    other -> assertFailure ("live excluded, got " <> show other)
  case selectHighestNonLive [mk "1.0.0" "a.ebuild", mk "foo" "raw.ebuild"] of
    Left _ -> pure ()
    other -> assertFailure ("incomparable should fail, got " <> show other)

testLaneArchAllowlist :: IO ()
testLaneArchAllowlist = do
  let rustCeilings = dualArchGoCeilings (Just "1.80.0") (Just "1.85.0")
      -- amd64 ceilings stay high; arm64 is lower so a mid harvest would bind
      -- only if arm64 lanes participated.
      rustArmLower =
        let base = dualArchGoCeilings (Just "1.90.0") (Just "1.90.0")
            arm =
              ArchCeilings
                (Just (parseEbuildVersion "1.80.0"))
                (Just (parseEbuildVersion "1.81.0"))
         in base {rcByArch = Map.insert "arm64" arm (rcByArch base)}
      candidates =
        [ VersionCandidate (parseEbuildVersion "0.153.3") (Just "1.95.0"),
          VersionCandidate (parseEbuildVersion "0.50.0") (Just "1.80.0")
        ]
      lowCandidates =
        [ VersionCandidate (parseEbuildVersion "0.50.0") (Just "1.80.0")
        ]
  -- Codex: amd64-only, KEYWORDS -* ~amd64, no arm64 lanes.
  let codexTargets = selectAllLaneTargetsFor ["amd64"] rustCeilings lowCandidates
      codexPlan = planFromTargetsWithAtomFor ["amd64"] "dev-lang/rust|rust-bin" codexTargets
  assertEq "codex unique" 1 (length (glpUniquePVs codexPlan))
  assertTrue
    "no arm64 lane"
    (not (any (\t -> liArch (ltLane t) == "arm64") (glpLanes codexPlan)))
  case glpEbuilds codexPlan of
    [pe] -> assertEq "codex keywords" ["-*", "~amd64"] (peKeywords pe)
    other -> assertFailure ("codex ebuilds: " <> show other)
  assertEq
    "assemble allowlist"
    ["-*", "~amd64"]
    (assembleKeywordsFor ["amd64"] [LaneAmd64Plain, LaneAmd64Tilde])
  -- Harvest 1.85 vs amd64 1.90 succeeds; arm64 1.81 is not a selecting lane.
  let harvestPlan =
        planFromTargetsWithAtomFor
          ["amd64"]
          "dev-lang/rust|rust-bin"
          (selectAllLaneTargetsFor ["amd64"] rustArmLower lowCandidates)
  case harvestVsLaneCeiling harvestPlan (parseEbuildVersion "0.50.0") (Just "1.80.0") (Just "1.85.0") of
    Right () -> pure ()
    Left err -> assertFailure ("codex harvest should ignore arm64 ceiling: " <> T.unpack err)
  -- Same harvest against an unfiltered plan (arm64 1.81 binds) hard-fails.
  let fullPlan =
        planFromTargetsWithAtomFor
          []
          "dev-lang/rust|rust-bin"
          (selectAllLaneTargets rustArmLower lowCandidates)
  case harvestVsLaneCeiling fullPlan (parseEbuildVersion "0.50.0") (Just "1.80.0") (Just "1.85.0") of
    Left err ->
      assertTrue "names arm64 ceiling" ("1.81" `T.isInfixOf` err || "1.80" `T.isInfixOf` err)
    Right () -> assertFailure "expected harvest vs arm64 ceiling to fail"
  -- hk: every rust arch, no -* from the allowlist requirement.
  let hkTargets = selectAllLaneTargets rustCeilings lowCandidates
      hkPlan = planFromTargetsWithAtomFor [] "dev-lang/rust|rust-bin" hkTargets
  assertTrue
    "hk has arm64"
    (any (\t -> liArch (ltLane t) == "arm64") (glpLanes hkPlan))
  case glpEbuilds hkPlan of
    [pe] -> do
      assertTrue "hk has ~amd64" ("~amd64" `elem` peKeywords pe)
      assertTrue "hk has ~arm64" ("~arm64" `elem` peKeywords pe)
      assertTrue "hk no -*" ("-*" `notElem` peKeywords pe)
    other -> assertFailure ("hk ebuilds: " <> show other)
  -- silence unused
  assertEq "candidates kept" 2 (length candidates)

testGoLaneSelection :: IO ()
testGoLaneSelection = do
  let ceilings = dualArchGoCeilings (Just "1.26.3") (Just "1.26.5")
      candidates =
        [ VersionCandidate (parseEbuildVersion "0.82.0") (Just "1.26.3"),
          VersionCandidate (parseEbuildVersion "0.84.0") (Just "1.26.5"),
          VersionCandidate (parseEbuildVersion "0.85.0") Nothing
        ]
  assertEq
    "max under plain"
    (Just (parseEbuildVersion "0.82.0", "1.26.3"))
    (maxVersionUnder (parseEbuildVersion "1.26.3") candidates)
  assertEq
    "max under tilde"
    (Just (parseEbuildVersion "0.84.0", "1.26.5"))
    (maxVersionUnder (parseEbuildVersion "1.26.5") candidates)
  let targets = selectAllLaneTargets ceilings candidates
      plan = planFromTargets targets
  assertEq "two unique PVs" 2 (length (glpUniquePVs plan))
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Plain] of
    [Just pv] -> assertEq "plain lane" (parseEbuildVersion "0.82.0") pv
    other -> do
      hPutStrLn stderr $ "plain lane target: " <> show other
      exitFailure
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Tilde] of
    [Just pv] -> assertEq "tilde lane" (parseEbuildVersion "0.84.0") pv
    other -> do
      hPutStrLn stderr $ "tilde lane target: " <> show other
      exitFailure

testGoLaneCollapse :: IO ()
testGoLaneCollapse = do
  let allSame =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
        ]
      collapsed = collapsePlannedEbuilds allSame
  assertEq "single PV collapse" 1 (length collapsed)
  case collapsed of
    [pe] -> do
      assertEq "pv" (parseEbuildVersion "0.84.0") (pePV pe)
      assertEq "tilde dual keywords" ["~amd64", "~arm64"] (peKeywords pe)
      assertTrue "no bare amd64" ("amd64" `notElem` peKeywords pe)
      assertTrue "no bare arm64" ("arm64" `notElem` peKeywords pe)
    _ -> exitFailure
  let divergent =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3")
        ]
      divCollapsed = collapsePlannedEbuilds divergent
  assertEq "arch divergent count" 2 (length divCollapsed)
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.84.0"] of
    [pe] -> do
      assertEq "0.84 ~amd64" ["~amd64"] (peKeywords pe)
      assertTrue "0.84 no arm64" ("arm64" `notElem` peKeywords pe)
      assertTrue "0.84 no ~arm64" ("~arm64" `notElem` peKeywords pe)
      assertTrue "0.84 no bare amd64" ("amd64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.84 ebuild: " <> show other
      exitFailure
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> do
      assertEq "0.82 ~arm64" ["~arm64"] (peKeywords pe)
      assertTrue "0.82 no amd64" ("amd64" `notElem` peKeywords pe)
      assertTrue "0.82 no bare arm64" ("arm64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.82 ebuild: " <> show other
      exitFailure
  -- Tilde-only: only amd64 tilde lane targets PV
  let tildeOnly =
        [ LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
        ]
  case collapsePlannedEbuilds tildeOnly of
    [pe] -> assertEq "tilde-only keywords" ["~amd64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "tilde-only ebuild: " <> show other
      exitFailure
  -- Staggered plain vs tilde: plain amd64 → 0.75; tilde amd64 + both arm64 → 0.82
  let staggered =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.75.0")) (Just "1.26.3"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5")
        ]
      stagCollapsed = collapsePlannedEbuilds staggered
  assertEq "staggered count" 2 (length stagCollapsed)
  case [pe | pe <- stagCollapsed, pePV pe == parseEbuildVersion "0.75.0"] of
    [pe] -> assertEq "0.75 ~amd64 only" ["~amd64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.75 ebuild: " <> show other
      exitFailure
  case [pe | pe <- stagCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> assertEq "0.82 ~amd64 + ~arm64" ["~amd64", "~arm64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.82 staggered ebuild: " <> show other
      exitFailure
  let fourDistinct =
        [ LaneTarget LaneAmd64Plain Nothing (Just (parseEbuildVersion "0.80.0")) (Just "1.0"),
          LaneTarget LaneAmd64Tilde Nothing (Just (parseEbuildVersion "0.81.0")) (Just "1.0"),
          LaneTarget LaneArm64Plain Nothing (Just (parseEbuildVersion "0.82.0")) (Just "1.0"),
          LaneTarget LaneArm64Tilde Nothing (Just (parseEbuildVersion "0.83.0")) (Just "1.0")
        ]
  assertEq "four ebuilds" 4 (length (collapsePlannedEbuilds fourDistinct))
  case collapsePlannedEbuilds fourDistinct of
    pes ->
      assertEq
        "four keywords always tilde by arch membership"
        [ ["~amd64"],
          ["~amd64"],
          ["~arm64"],
          ["~arm64"]
        ]
        (map peKeywords (sortByPv pes))
  let plan = planFromTargets allSame
      locals = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
  assertEq "missing target" [parseEbuildVersion "0.84.0"] (missingTargets locals plan)
  assertEq
    "extras"
    [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
    (extrasToDelete locals plan)
  assertTrue "needs work" (planNeedsWork locals [] plan)
  assertTrue "satisfied" (not (planNeedsWork [parseEbuildVersion "0.84.0"] [] plan))
  where
    sortByPv =
      sortBy
        ( \a b ->
            case comparePV (pePV a) (pePV b) of
              Just o -> o
              Nothing -> compare (show (pePV a)) (show (pePV b))
        )

testGoGapLines :: IO ()
testGoGapLines = do
  assertEq
    "labels"
    "(dev-lang/go amd64)"
    (laneLabel LaneAmd64Plain)
  assertEq
    "tilde label"
    "(dev-lang/go ~amd64)"
    (laneLabel LaneAmd64Tilde)
  let planSplit =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals1 = [parseEbuildVersion "0.80.0"]
      needs = [parseEbuildVersion "0.82.0", parseEbuildVersion "0.84.0"]
      linesSplit = buildGapLines locals1 needs planSplit
  assertEq "split line count" 2 (length linesSplit)
  assertTrue
    "split from 0.80"
    (all (\g -> glFrom g == parseEbuildVersion "0.80.0") linesSplit)
  assertTrue
    "has 0.82"
    (any (\g -> glTo g == parseEbuildVersion "0.82.0") linesSplit)
  assertTrue
    "has 0.84"
    (any (\g -> glTo g == parseEbuildVersion "0.84.0") linesSplit)
  let planConverge =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals2 = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
      linesConv = buildGapLines locals2 [parseEbuildVersion "0.84.0"] planConverge
  assertEq "converge line count" 2 (length linesConv)
  assertTrue
    "converge has 0.80"
    (any (\g -> glFrom g == parseEbuildVersion "0.80.0") linesConv)
  assertTrue
    "converge has 0.82"
    (any (\g -> glFrom g == parseEbuildVersion "0.82.0") linesConv)
  assertTrue
    "converge to 0.84"
    (all (\g -> glTo g == parseEbuildVersion "0.84.0") linesConv)

testGoStripAndParseList :: IO ()
testGoStripAndParseList = do
  case stripAndParse "v" "v0.80.0" of
    Right v -> assertEq "prefix v" (parseEbuildVersion "0.80.0") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  case stripAndParse "bun-v" "bun-v1.2.3" of
    Right v -> assertEq "bun prefix" (parseEbuildVersion "1.2.3") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  -- Empty prefix leaves the tag unchanged.
  case stripAndParse "" "1.2.3" of
    Right v -> assertEq "empty prefix" (parseEbuildVersion "1.2.3") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  -- Non-matching prefix still returns the original tag body (no strip).
  case stripAndParse "v" "release-1.0.0" of
    Right v -> assertEq "non-matching tag" (parseEbuildVersion "release-1.0.0") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  case stripAndParse "v" "v" of
    Left msg ->
      assertTrue
        "empty after strip"
        ("empty version after stripping" `T.isInfixOf` msg)
    Right v -> do
      hPutStrLn stderr $ "expected Left for empty strip, got " <> show v
      exitFailure
  case stripAndParse "v" "vnot-numeric" of
    Right (Raw t) -> assertEq "bad version becomes Raw" "not-numeric" t
    other -> do
      hPutStrLn stderr $ "expected Raw version, got " <> show other
      exitFailure
  case stripAndParse "v" "v2.0.0-r1" of
    Right v -> assertEq "revision tag" (Numeric [2, 0, 0] (Just 1)) v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure

testGoPlanIntegrationMocked :: IO ()
testGoPlanIntegrationMocked = do
  withSystemTempDirectory "mndz-go-tree-" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        goDir = gentoo </> "dev-lang" </> "go"
    createDirectoryIfMissing True goDir
    TIO.writeFile
      (goDir </> "go-1.26.3.ebuild")
      "KEYWORDS=\"amd64 arm64\"\n"
    TIO.writeFile
      (goDir </> "go-1.26.5.ebuild")
      "KEYWORDS=\"~amd64 ~arm64\"\n"
    TIO.writeFile
      (goDir </> "go-9999.ebuild")
      "KEYWORDS=\"~amd64\"\n"
    let portageq args =
          pure $
            if args == ["get_repo_path", "/", "gentoo"]
              then Right (T.pack gentoo)
              else Left "unexpected portageq"
    ceilings <-
      assertRight "discover ceilings"
        =<< discoverGoCeilingsWith portageq
    assertEq
      "mock plain"
      (Just (parseEbuildVersion "1.26.3"))
      (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
    assertEq
      "mock tilde"
      (Just (parseEbuildVersion "1.26.5"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps =
          PlanOps
            { poPortageq = portageq,
              -- Newest-first (production listGitHubVersionsWith order).
              poListVersions = \_ ->
                pure $
                  Right
                    [ parseEbuildVersion "0.84.0",
                      parseEbuildVersion "0.82.0"
                    ],
              poFetchGoMod = \key ->
                pure $
                  Right $
                    case gmkTag key of
                      "v0.82.0" -> "module x\ngo 1.26.3\n"
                      "v0.84.0" -> "module x\ngo 1.26.5\n"
                      _ -> "module x\n",
              poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
    plan <-
      assertRight "plan go package"
        =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
    assertEq "planned unique" 2 (length (glpUniquePVs plan))
    assertTrue
      "has 0.82"
      (parseEbuildVersion "0.82.0" `elem` glpUniquePVs plan)
    assertTrue
      "has 0.84"
      (parseEbuildVersion "0.84.0" `elem` glpUniquePVs plan)
    -- Any lane membership → tilde KEYWORDS only (plain still selects PV/arches)
    case [pe | pe <- glpEbuilds plan, pePV pe == parseEbuildVersion "0.82.0"] of
      [pe] -> assertEq "0.82 plain dual tilde" ["~amd64", "~arm64"] (peKeywords pe)
      other -> do
        hPutStrLn stderr $ "plan 0.82 ebuild: " <> show other
        exitFailure
    case [pe | pe <- glpEbuilds plan, pePV pe == parseEbuildVersion "0.84.0"] of
      [pe] -> assertEq "0.84 tilde dual" ["~amd64", "~arm64"] (peKeywords pe)
      other -> do
        hPutStrLn stderr $ "plan 0.84 ebuild: " <> show other
        exitFailure

------------------------------------------------------------------------
-- go.mod probe early exit
------------------------------------------------------------------------

-- | Shared ceilings: plain 1.26.3, tilde 1.26.5 (both arches).
earlyExitCeilings :: RuntimeCeilings
earlyExitCeilings = dualArchGoCeilings (Just "1.26.3") (Just "1.26.5")

-- | Mock plan ops that record go.mod fetch tags (newest-first version list).

-- | Mock plan ops that record go.mod fetch tags (newest-first version list).
mkEarlyExitPlanOps ::
  [EbuildVersion] ->
  (T.Text -> Either T.Text T.Text) ->
  IO (PlanOps, IORef [T.Text])
mkEarlyExitPlanOps versions fetchBody = do
  budget <- newWorkBudget 2
  ceilingsCache <- newMVar (Just earlyExitCeilings)
  fetchTags <- newIORef ([] :: [T.Text])
  let planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Right versions),
            poFetchGoMod = \key -> do
              atomicModifyIORef' fetchTags (\ts -> (gmkTag key : ts, ()))
              pure (fetchBody (gmkTag key)),
            poWorkBudget = budget,
            poCeilingsCache = ceilingsCache
          }
  pure (planOps, fetchTags)

lanePV :: RuntimeLanePlan -> LaneId -> Maybe EbuildVersion
lanePV plan lid =
  case [ltPackagePV t | t <- glpLanes plan, ltLane t == lid] of
    (m : _) -> m
    [] -> Nothing

-- | Tip go_req under every ceiling → one go.mod fetch; all lanes tip.

-- | Tip go_req under every ceiling → one go.mod fetch; all lanes tip.
testGoModProbeEarlyExitTipFillsAll :: IO ()
testGoModProbeEarlyExitTipFillsAll = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\ngo 1.26.3\n"
        "v0.84.0" -> Right "module x\ngo 1.26.5\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "tip fills all"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertEq "only tip probed" ["v0.90.0"] tags
  assertEq "unique tip" [parseEbuildVersion "0.90.0"] (glpUniquePVs plan)
  assertEq
    "plain tip"
    (Just (parseEbuildVersion "0.90.0"))
    (lanePV plan LaneAmd64Plain)
  assertEq
    "tilde tip"
    (Just (parseEbuildVersion "0.90.0"))
    (lanePV plan LaneAmd64Tilde)

-- | Tilde takes newer PV; plain needs older; no probes older than plain target.

-- | Tilde takes newer PV; plain needs older; no probes older than plain target.
testGoModProbeEarlyExitPlainOlder :: IO ()
testGoModProbeEarlyExitPlainOlder = do
  let versions =
        [ parseEbuildVersion "0.86.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0",
          parseEbuildVersion "0.80.0"
        ]
      fetchBody = \case
        "v0.86.0" -> Right "module x\ngo 1.26.5\n"
        "v0.84.0" -> Right "module x\ngo 1.26.4\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        "v0.80.0" -> Right "module x\ngo 1.26.0\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "plain older"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertEq
    "stop after plain filled"
    ["v0.86.0", "v0.84.0", "v0.82.0"]
    tags
  assertTrue "did not probe older than plain" ("v0.80.0" `notElem` tags)
  assertEq
    "tilde 0.86"
    (Just (parseEbuildVersion "0.86.0"))
    (lanePV plan LaneAmd64Tilde)
  assertEq
    "plain 0.82"
    (Just (parseEbuildVersion "0.82.0"))
    (lanePV plan LaneAmd64Plain)

-- | Early-exit lane targets equal full-probe + selectAllLaneTargets.

-- | Early-exit lane targets equal full-probe + selectAllLaneTargets.
testGoModProbeEarlyExitMatchesFullProbe :: IO ()
testGoModProbeEarlyExitMatchesFullProbe = do
  let versions =
        [ parseEbuildVersion "0.86.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0",
          parseEbuildVersion "0.80.0"
        ]
      goReqFor = \case
        "v0.86.0" -> Just "1.26.5"
        "v0.84.0" -> Just "1.26.4"
        "v0.82.0" -> Just "1.26.3"
        "v0.80.0" -> Just "1.26.0"
        _ -> Nothing
      fetchBody tag =
        case goReqFor tag of
          Just req -> Right ("module x\ngo " <> req <> "\n")
          Nothing -> Left "missing"
      fullCandidates =
        [ VersionCandidate
            { vcPV = pv,
              vcGoReq = goReqFor ("v" <> renderPVNoRev pv)
            }
        | pv <- versions
        ]
      expectedTargets = selectAllLaneTargets earlyExitCeilings fullCandidates
  (planOps, _) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "early exit matches full"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  assertEq
    "lane targets match full probe"
    expectedTargets
    (glpLanes plan)

-- | Unparseable tip is skipped; older parseable version used.

-- | Unparseable tip is skipped; older parseable version used.
testGoModProbeEarlyExitSkipsUnparseableTip :: IO ()
testGoModProbeEarlyExitSkipsUnparseableTip = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\n" -- no go directive
        "v0.84.0" -> Right "module x\ngo 1.26.3\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "skip unparseable tip"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertTrue "probed tip" ("v0.90.0" `elem` tags)
  assertTrue "probed next" ("v0.84.0" `elem` tags)
  assertEq
    "only tip then fill"
    ["v0.90.0", "v0.84.0"]
    tags
  assertEq "unique 0.84" [parseEbuildVersion "0.84.0"] (glpUniquePVs plan)
  assertEq
    "plain 0.84"
    (Just (parseEbuildVersion "0.84.0"))
    (lanePV plan LaneAmd64Plain)

-- | Progress reports three coarse steps; probe done once.

-- | Progress reports three coarse steps; probe done once.
testGoPlanProgressCoarseSteps :: IO ()
testGoPlanProgressCoarseSteps = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\ngo 1.26.3\n"
        tag -> Right ("module x\ngo 1.26.5\n" <> tag)
  (planOps, _) <- mkEarlyExitPlanOps versions fetchBody
  events <- newIORef ([] :: [T.Text])
  listCount <- newIORef (0 :: Int)
  probeCount <- newIORef (0 :: Int)
  let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
      progress =
        PlanProgress
          { ppOnCeilingsStart = logEv "ceilings-start",
            ppOnCeilingsDone = logEv "ceilings-done",
            ppOnListStart = logEv "list-start",
            ppOnListDone = \n -> do
              writeIORef listCount n
              logEv "list-done",
            ppOnProbeDone = do
              atomicModifyIORef' probeCount (\c -> (c + 1, ()))
              logEv "probe-done"
          }
  _ <-
    assertRight "plan with progress"
      =<< planGoPackageWithProgress planOps progress (GitHub "o" "r" "v") Nothing
  evs <- reverse <$> readIORef events
  nList <- readIORef listCount
  nProbe <- readIORef probeCount
  assertEq
    "coarse event order"
    [ "ceilings-start",
      "ceilings-done",
      "list-start",
      "list-done",
      "probe-done"
    ]
    evs
  assertEq "list reports version count" 3 nList
  assertEq "probe done once" 1 nProbe
  -- Hooks optional path still works.
  _ <-
    assertRight "noop progress"
      =<< planGoPackageWithProgress
        planOps
        noopPlanProgress
        (GitHub "o" "r" "v")
        Nothing
  pure ()

------------------------------------------------------------------------
-- Richer activity progress / work budget / go.mod cache
------------------------------------------------------------------------

testGoModCacheConcurrentDistinctKeys :: IO ()
testGoModCacheConcurrentDistinctKeys = do
  inFlight <- newIORef (0 :: Int)
  maxSeen <- newIORef (0 :: Int)
  fetchCount <- newIORef (0 :: Int)
  let base key = do
        atomicModifyIORef' fetchCount (\n -> (n + 1, ()))
        cur <-
          atomicModifyIORef' inFlight $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen $ \m -> (max m cur, ())
        threadDelay 40_000
        atomicModifyIORef' inFlight $ \n -> (n - 1, ())
        pure (Right ("body-" <> gmkTag key))
  cached <- withGoModCache base
  let keys =
        [ GoModKey "o" "r" "v1" Nothing,
          GoModKey "o" "r" "v2" Nothing,
          GoModKey "o" "r" "v3" Nothing,
          GoModKey "o" "r" "v4" Nothing
        ]
  results <- mapConcurrently cached keys
  peak <- readIORef maxSeen
  fetches <- readIORef fetchCount
  assertEq "four results" 4 (length results)
  assertTrue "distinct keys overlap" (peak > 1)
  assertEq "one fetch per key" 4 fetches

testGoModCacheHitNoRefetch :: IO ()
testGoModCacheHitNoRefetch = do
  fetchCount <- newIORef (0 :: Int)
  let key = GoModKey "o" "r" "v1" Nothing
      base _ = do
        atomicModifyIORef' fetchCount (\n -> (n + 1, ()))
        pure (Right "mod")
  cached <- withGoModCache base
  r1 <- cached key
  r2 <- cached key
  fetches <- readIORef fetchCount
  assertEq "first hit" (Right "mod") r1
  assertEq "second hit" (Right "mod") r2
  assertEq "single fetch on hit" 1 fetches

-- | Empty-cache residual: fake portageq discovers nodejs/rust; bun from overlay dir.
testRuntimeCeilingDiscoverResidual :: IO ()
testRuntimeCeilingDiscoverResidual =
  withSystemTempDirectory "mndz-ceil-residual-" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        overlay = tmp </> "overlay"
        nodeDir = gentoo </> "net-libs" </> "nodejs"
        rustDir = gentoo </> "dev-lang" </> "rust"
        rustBinDir = gentoo </> "dev-lang" </> "rust-bin"
        bunDir = overlay </> "dev-lang" </> "bun-bin"
    createDirectoryIfMissing True nodeDir
    createDirectoryIfMissing True rustDir
    createDirectoryIfMissing True rustBinDir
    createDirectoryIfMissing True bunDir
    TIO.writeFile
      (nodeDir </> "nodejs-20.0.0.ebuild")
      "KEYWORDS=\"amd64 arm64\"\n"
    TIO.writeFile
      (nodeDir </> "nodejs-22.0.0.ebuild")
      "KEYWORDS=\"~amd64 ~arm64\"\n"
    TIO.writeFile
      (rustDir </> "rust-1.80.0.ebuild")
      "KEYWORDS=\"amd64\"\n"
    TIO.writeFile
      (rustBinDir </> "rust-bin-1.85.0.ebuild")
      "KEYWORDS=\"~amd64\"\n"
    TIO.writeFile
      (bunDir </> "bun-bin-1.1.0.ebuild")
      "KEYWORDS=\"~amd64 ~arm64\"\n"
    let sbclDir = gentoo </> "dev-lisp" </> "sbcl"
    createDirectoryIfMissing True sbclDir
    TIO.writeFile
      (sbclDir </> "sbcl-2.6.2.ebuild")
      "KEYWORDS=\"amd64\"\n"
    TIO.writeFile
      (sbclDir </> "sbcl-2.6.6.ebuild")
      "KEYWORDS=\"~amd64 ~x86\"\n"
    let portageq args =
          pure $
            if args == ["get_repo_path", "/", "gentoo"]
              then Right (T.pack gentoo)
              else Left "unexpected portageq"
    -- Missing package dir → Left (empty discover residual).
    missing <-
      discoverNodejsCeilingsWith
        (\_ -> pure (Right (T.pack (tmp </> "no-gentoo"))))
    case missing of
      Left msg ->
        assertTrue "missing nodejs dir" ("not found" `T.isInfixOf` msg)
      Right _ -> do
        hPutStrLn stderr "expected Left for missing nodejs"
        exitFailure
    nodeC <-
      assertRight "nodejs ceilings" =<< discoverNodejsCeilingsWith portageq
    assertEq
      "nodejs plain"
      (Just (parseEbuildVersion "20.0.0"))
      (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch nodeC)))
    assertEq
      "nodejs tilde"
      (Just (parseEbuildVersion "22.0.0"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch nodeC)))
    bunC <-
      assertRight "bun ceilings" =<< discoverBunBinCeilings overlay
    assertEq
      "bun tilde only"
      (Just (parseEbuildVersion "1.1.0"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch bunC)))
    assertTrue
      "bun no plain"
      (isNothing (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch bunC))))
    rustC <-
      assertRight "rust union" =<< discoverRustUnionCeilingsWith portageq
    assertEq "rust union atom" "dev-lang/rust|rust-bin" (rcAtom rustC)
    assertEq
      "rust plain from rust"
      (Just (parseEbuildVersion "1.80.0"))
      (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch rustC)))
    assertEq
      "rust tilde from rust-bin"
      (Just (parseEbuildVersion "1.85.0"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch rustC)))
    -- Both rust sides missing → error
    bothMissing <-
      discoverRustUnionCeilingsWith
        (\_ -> pure (Right (T.pack (tmp </> "empty-gentoo"))))
    case bothMissing of
      Left msg ->
        assertTrue
          "both rust missing"
          ("neither" `T.isInfixOf` msg || "rust" `T.isInfixOf` msg)
      Right _ -> do
        hPutStrLn stderr "expected Left when both rust dirs missing"
        exitFailure
    sbclC <-
      assertRight "sbcl ceilings" =<< discoverSbclCeilingsWith portageq
    assertEq "sbcl atom" "dev-lisp/sbcl" (rcAtom sbclC)
    assertEq
      "sbcl plain"
      (Just (parseEbuildVersion "2.6.2"))
      (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch sbclC)))
    assertEq
      "sbcl tilde"
      (Just (parseEbuildVersion "2.6.6"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch sbclC)))
