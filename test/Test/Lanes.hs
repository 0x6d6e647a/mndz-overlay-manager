{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Lanes (tests) where

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
import Test.Tasty.HUnit (testCase)
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
  ( combineMsrv,
    normalizeRustVersion,
    parseRustMinVerFromEbuild,
    parseRustVersionField,
  )
import Update.Check (PackageEntry (..), groupNewest)
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
    planNeedsWork,
    selectAllLaneTargets,
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
    discoverGoCeilingsWith,
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

tests :: TestTree
tests =
  testGroup
    "Lanes"
    [ testCase "Go Tree Ceilings" testGoTreeCeilings,
      testCase "Multi Arch Ceilings" testMultiArchCeilings,
      testCase "Tilde Only Bun Ceilings" testTildeOnlyBunCeilings,
      testCase "Candidate Version Filter" testCandidateVersionFilter,
      testCase "Engines Minimum Parse" testEnginesMinimumParse,
      testCase "Cargo Msrv And Ceilings" testCargoMsrvAndCeilings,
      testCase "Go Lane Selection" testGoLaneSelection,
      testCase "Go Lane Collapse" testGoLaneCollapse,
      testCase "Go Gap Lines" testGoGapLines,
      testCase "Go Strip And Parse List" testGoStripAndParseList,
      testCase "Go Plan Integration Mocked" testGoPlanIntegrationMocked,
      testCase "Go Mod Probe Early Exit Tip Fills All" testGoModProbeEarlyExitTipFillsAll,
      testCase "Go Mod Probe Early Exit Plain Older" testGoModProbeEarlyExitPlainOlder,
      testCase "Go Mod Probe Early Exit Matches Full Probe" testGoModProbeEarlyExitMatchesFullProbe,
      testCase "Go Mod Probe Early Exit Skips Unparseable Tip" testGoModProbeEarlyExitSkipsUnparseableTip,
      testCase "Go Plan Progress Coarse Steps" testGoPlanProgressCoarseSteps,
      testCase "Go Mod Cache Concurrent Distinct Keys" testGoModCacheConcurrentDistinctKeys,
      testCase "Go Mod Cache Hit No Refetch" testGoModCacheHitNoRefetch
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
  assertEq "complex caret" Nothing (parseEnginesMinimum "^20.0.0")
  assertEq "complex or" Nothing (parseEnginesMinimum ">=18 || >=20")
  assertEq "star" Nothing (parseEnginesMinimum "*")
  assertEq "empty" Nothing (parseEnginesMinimum "")

testCargoMsrvAndCeilings :: IO ()
testCargoMsrvAndCeilings = do
  assertEq "normalize short" (Just "1.91.0") (normalizeRustVersion "1.91")
  assertEq "normalize full" (Just "1.88.0") (normalizeRustVersion "1.88.0")
  assertEq
    "parse rust-version"
    (Just "1.88.0")
    (parseRustVersionField "name = \"hk\"\nrust-version = \"1.88.0\"\n")
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
      assertEq "bare dual keywords" ["amd64", "arm64"] (peKeywords pe)
      assertTrue "no ~amd64" ("~amd64" `notElem` peKeywords pe)
      assertTrue "no ~arm64" ("~arm64" `notElem` peKeywords pe)
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
      assertEq "0.84 bare amd64" ["amd64"] (peKeywords pe)
      assertTrue "0.84 no arm64" ("arm64" `notElem` peKeywords pe)
      assertTrue "0.84 no ~arm64" ("~arm64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.84 ebuild: " <> show other
      exitFailure
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> do
      assertEq "0.82 bare arm64" ["arm64"] (peKeywords pe)
      assertTrue "0.82 no amd64" ("amd64" `notElem` peKeywords pe)
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
    [pe] -> assertEq "0.75 bare amd64 only" ["amd64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.75 ebuild: " <> show other
      exitFailure
  case [pe | pe <- stagCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> assertEq "0.82 ~amd64 + bare arm64" ["~amd64", "arm64"] (peKeywords pe)
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
        "four keywords bare/tilde by lane"
        [ ["amd64"],
          ["~amd64"],
          ["arm64"],
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
    -- Plain lanes → bare KEYWORDS; tilde-only lanes → ~KEYWORDS
    case [pe | pe <- glpEbuilds plan, pePV pe == parseEbuildVersion "0.82.0"] of
      [pe] -> assertEq "0.82 plain bare dual" ["amd64", "arm64"] (peKeywords pe)
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
  assertEq "single network fetch" 1 fetches
