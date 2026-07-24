{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.CLI (tests) where

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
    "CLI"
    [ testCase "Verbosity Resolution" testVerbosityResolution,
      testCase "Severity Filter Mapping" testSeverityFilterMapping,
      testCase "Severity Colors" testSeverityColors,
      testCase "No Color Strips Escapes" testNoColorStripsEscapes,
      testCase "Jobs Bound" testJobsBound,
      testCase "Jobs One Serial" testJobsOneSerial,
      testCase "Work Budget Bound" testWorkBudgetBound
    ]

------------------------------------------------------------------------
-- Verbosity / logging / concurrency
------------------------------------------------------------------------

testVerbosityResolution :: IO ()
testVerbosityResolution = do
  assertEq "default" V.Warn (resolveVerbosity Nothing 0)
  assertEq "single -v" V.Info (resolveVerbosity Nothing 1)
  assertEq "double -v" V.Debug (resolveVerbosity Nothing 2)
  assertEq "triple caps at debug" V.Debug (resolveVerbosity Nothing 5)
  assertEq "explicit overrides -v" V.Error (resolveVerbosity (Just V.Error) 2)
  assertEq "explicit warn overrides -vv" V.Warn (resolveVerbosity (Just V.Warn) 2)
  assertEq "explicit debug" V.Debug (resolveVerbosity (Just V.Debug) 0)

testSeverityFilterMapping :: IO ()
testSeverityFilterMapping = do
  assertEq "error" C.Error (verbosityToSeverity V.Error)
  assertEq "warn" C.Warning (verbosityToSeverity V.Warn)
  assertEq "info" C.Info (verbosityToSeverity V.Info)
  assertEq "debug" C.Debug (verbosityToSeverity V.Debug)
  -- filterBySeverity keeps messages with severity >= threshold
  assertTrue "warn hides info" (C.Info < C.Warning)
  assertTrue "warn shows warning" (C.Warning >= C.Warning)
  assertTrue "debug shows all" (C.Debug <= C.Info && C.Debug <= C.Error)

testSeverityColors :: IO ()
testSeverityColors = do
  let err = showSeverityColored ColorOn C.Error
      info = showSeverityColored ColorOn C.Info
      warn = showSeverityColored ColorOn C.Warning
      dbg = showSeverityColored ColorOn C.Debug
  assertTrue "error has escape" ("\ESC[" `T.isInfixOf` err)
  assertTrue "info has escape" ("\ESC[" `T.isInfixOf` info)
  assertTrue "warning has escape" ("\ESC[" `T.isInfixOf` warn)
  assertTrue "debug has escape" ("\ESC[" `T.isInfixOf` dbg)
  assertTrue "error tag text" ("[Error]" `T.isInfixOf` err)
  assertTrue "info tag text" ("[Info]" `T.isInfixOf` info)

testNoColorStripsEscapes :: IO ()
testNoColorStripsEscapes = do
  let plain = showSeverityColored ColorOff C.Error
      msg =
        Msg
          { msgSeverity = C.Warning,
            msgStack = callStack,
            msgText = "hello"
          }
      formatted = fmtMessageColored ColorOff msg
  assertTrue "plain error no esc" (not ("\ESC[" `T.isInfixOf` plain))
  assertTrue "plain still has tag" ("[Error]" `T.isInfixOf` plain)
  assertTrue "fmt no esc" (not ("\ESC[" `T.isInfixOf` formatted))
  assertTrue "fmt has warning" ("[Warning]" `T.isInfixOf` formatted)
  assertTrue "fmt has body" ("hello" `T.isInfixOf` formatted)

testJobsBound :: IO ()
testJobsBound = do
  results <- mapConcurrentlyN 4 pure [1 .. 10 :: Int]
  assertEq "preserves values" [1 .. 10] (sort results)

-- | With --jobs 1, concurrent slots never exceed one in-flight job.

-- | With --jobs 1, concurrent slots never exceed one in-flight job.
testJobsOneSerial :: IO ()
testJobsOneSerial = do
  inFlight <- newIORef (0 :: Int)
  maxSeen <- newIORef (0 :: Int)
  let job _ = do
        cur <-
          atomicModifyIORef' inFlight $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen $ \m -> (max m cur, ())
        threadDelay 20_000
        atomicModifyIORef' inFlight $ \n -> (n - 1, ())
        pure ()
  void $ mapConcurrentlyN 1 job [1 .. 6 :: Int]
  peak <- readIORef maxSeen
  assertEq "jobs 1 peak concurrency" 1 peak
  -- Also verify higher bound can exceed 1 when work overlaps.
  inFlight2 <- newIORef (0 :: Int)
  maxSeen2 <- newIORef (0 :: Int)
  let job2 _ = do
        cur <-
          atomicModifyIORef' inFlight2 $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen2 $ \m -> (max m cur, ())
        threadDelay 50_000
        atomicModifyIORef' inFlight2 $ \n -> (n - 1, ())
        pure ()
  void $ mapConcurrentlyN 3 job2 [1 .. 6 :: Int]
  peak2 <- readIORef maxSeen2
  assertTrue "jobs 3 can exceed 1" (peak2 > 1)

testWorkBudgetBound :: IO ()
testWorkBudgetBound = do
  let jobs = 3
  assertEq "capacity 2*jobs" 6 (workBudgetCapacity jobs)
  assertEq "capacity jobs=1" 2 (workBudgetCapacity 1)
  assertEq "capacity jobs=0 treated as 1" 2 (workBudgetCapacity 0)
  budget <- newWorkBudget jobs
  inFlight <- newIORef (0 :: Int)
  maxSeen <- newIORef (0 :: Int)
  let unit _ = withWorkSlot budget $ do
        cur <-
          atomicModifyIORef' inFlight $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen $ \m -> (max m cur, ())
        threadDelay 30_000
        atomicModifyIORef' inFlight $ \n -> (n - 1, ())
  void $ mapConcurrently unit [1 .. 20 :: Int]
  peak <- readIORef maxSeen
  assertTrue "peak <= 2*jobs" (peak <= workBudgetCapacity jobs)
  assertTrue "peak can exceed 1" (peak > 1)
