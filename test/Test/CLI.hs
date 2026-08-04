{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.CLI (tests) where

import CLI.Jobs
  ( mapConcurrentlyN,
    newWorkBudget,
    withWorkSlot,
    workBudgetCapacity,
  )
import CLI.Parser
  ( ColorMode (..),
    Options (..),
    parserInfo,
    resolveColorMode,
    resolveJobs,
    resolveVerbosity,
    showTopLevelHelpExit1,
  )
import CLI.Parser qualified as CLI
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
import Control.Exception (SomeException, bracket_, throwIO, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Stack (callStack)
import Logging.Bootstrap
  ( beginLogHold,
    flushLogHold,
    fmtMessageColored,
    mkLogHold,
    mkLogger,
    showSeverityColored,
    verbosityToSeverity,
  )
import Options.Applicative
  ( ParseError (ShowHelpText),
    ParserResult (..),
    defaultPrefs,
    execParserPure,
    getParseResult,
    parserFailure,
    renderFailure,
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
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..), exitFailure)
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
      testCase "Work Budget Bound" testWorkBudgetBound,
      testCase "Resolve Color Mode" testResolveColorMode,
      testCase "Resolve Jobs" testResolveJobs,
      testCase "Parser Pure Commands" testParserPureCommands,
      testCase "Parser Residual Edges" testParserResidualEdges,
      testCase "Help Catalogs Eclean And Distfiles" testHelpCatalogDistfiles,
      testCase "Show Top Level Help Exit 1" testShowTopLevelHelpExit1,
      testCase "Logger Hold And Filter" testLoggerHoldAndFilter
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

------------------------------------------------------------------------
-- CLI.Parser pure resolvers and execParserPure
------------------------------------------------------------------------

testResolveColorMode :: IO ()
testResolveColorMode = do
  offFlag <- resolveColorMode True
  assertEq "--no-color flag" ColorOff offFlag
  withNoColorEnv (Just "1") $ do
    offEnv <- resolveColorMode False
    assertEq "NO_COLOR set" ColorOff offEnv
  withNoColorEnv (Just "") $ do
    onEmpty <- resolveColorMode False
    assertEq "empty NO_COLOR keeps color" ColorOn onEmpty
  withNoColorEnv Nothing $ do
    onUnset <- resolveColorMode False
    assertEq "NO_COLOR unset keeps color" ColorOn onUnset

-- | Temporarily set or clear @NO_COLOR@, restoring the prior value afterward.
withNoColorEnv :: Maybe String -> IO a -> IO a
withNoColorEnv mVal action = do
  prev <- lookupEnv "NO_COLOR"
  let restore = case prev of
        Nothing -> unsetEnv "NO_COLOR"
        Just v -> setEnv "NO_COLOR" v
      install = case mVal of
        Nothing -> unsetEnv "NO_COLOR"
        Just v -> setEnv "NO_COLOR" v
  bracket_ install restore action

testResolveJobs :: IO ()
testResolveJobs = do
  assertEq "explicit positive" 4 =<< resolveJobs (Just 4)
  assertEq "explicit one" 1 =<< resolveJobs (Just 1)
  assertEq "zero becomes one" 1 =<< resolveJobs (Just 0)
  assertEq "negative becomes one" 1 =<< resolveJobs (Just (-3))
  host <- resolveJobs Nothing
  assertTrue "default host jobs positive" (host > 0)

testParserPureCommands :: IO ()
testParserPureCommands = do
  let parse args = getParseResult (execParserPure defaultPrefs parserInfo args)
  case parse ["list"] of
    Just opts -> do
      assertEq "list cmd" (Just CLI.List) (optCommand opts)
      assertEq "list no config" Nothing (optConfig opts)
      assertEq "list no jobs" Nothing (optJobs opts)
      assertEq "list color on default" False (optNoColor opts)
    Nothing -> do
      hPutStrLn stderr "parse list failed"
      exitFailure
  case parse ["outdated", "dev-lang/go", "mise"] of
    Just opts ->
      assertEq
        "outdated targets"
        (Just (CLI.Outdated ["dev-lang/go", "mise"]))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse outdated failed"
      exitFailure
  case parse ["update"] of
    Just opts -> assertEq "update all" (Just (CLI.Update [])) (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse update failed"
      exitFailure
  case parse ["update", "dev-util/hk"] of
    Just opts ->
      assertEq
        "update one"
        (Just (CLI.Update ["dev-util/hk"]))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse update target failed"
      exitFailure
  case parse ["gencache"] of
    Just opts ->
      assertEq
        "gencache default"
        (Just (CLI.Gencache {CLI.gencacheTargets = [], CLI.gencacheForce = False}))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse gencache failed"
      exitFailure
  case parse ["gencache", "--force", "dev-lang/go"] of
    Just opts ->
      assertEq
        "gencache force"
        (Just (CLI.Gencache {CLI.gencacheTargets = ["dev-lang/go"], CLI.gencacheForce = True}))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse gencache --force failed"
      exitFailure
  case parse ["--config", "/tmp/om.toml", "--overlay-path", "/tmp/ov", "--distfiles-path", "/tmp/df", "--jobs", "8", "--no-progress", "--no-color", "-v", "list"] of
    Just opts -> do
      assertEq "global config" (Just "/tmp/om.toml") (optConfig opts)
      assertEq "global overlay" (Just "/tmp/ov") (optOverlayPath opts)
      assertEq "global distfiles" (Just "/tmp/df") (optDistfilesPath opts)
      assertEq "global jobs" (Just 8) (optJobs opts)
      assertEq "global no-progress" True (optNoProgress opts)
      assertEq "global no-color" True (optNoColor opts)
      assertEq "global -v" V.Info (optVerbosity opts)
      assertEq "global + list" (Just CLI.List) (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse globals + list failed"
      exitFailure
  case parse ["eclean"] of
    Just opts -> assertEq "eclean cmd" (Just CLI.Eclean) (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse eclean failed"
      exitFailure
  case parse ["--log-level", "error", "outdated"] of
    Just opts -> assertEq "log-level error" V.Error (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse log-level failed"
      exitFailure
  case parse [] of
    Just opts -> assertEq "bare no command" Nothing (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse bare failed"
      exitFailure
  case parse ["not-a-command"] of
    Nothing -> pure ()
    Just opts -> do
      hPutStrLn stderr $ "expected parse failure, got " <> show opts
      exitFailure

-- | Residual verbosity / work-command edges beyond the baseline parser cases.
testParserResidualEdges :: IO ()
testParserResidualEdges = do
  let parse args = getParseResult (execParserPure defaultPrefs parserInfo args)
  case parse ["-vv", "list"] of
    Just opts -> assertEq "double -v is debug" V.Debug (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse -vv list failed"
      exitFailure
  case parse ["--verbose", "--verbose", "list"] of
    Just opts -> assertEq "long verbose twice" V.Debug (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse --verbose twice failed"
      exitFailure
  case parse ["--log-level", "info", "list"] of
    Just opts -> assertEq "log-level info" V.Info (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse log-level info failed"
      exitFailure
  case parse ["--log-level", "warn", "list"] of
    Just opts -> assertEq "log-level warn" V.Warn (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse log-level warn failed"
      exitFailure
  case parse ["--log-level", "debug", "list"] of
    Just opts -> assertEq "log-level debug" V.Debug (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse log-level debug failed"
      exitFailure
  case parse ["-v", "--log-level", "error", "list"] of
    Just opts -> assertEq "log-level wins over -v" V.Error (optVerbosity opts)
    Nothing -> do
      hPutStrLn stderr "parse -v + log-level failed"
      exitFailure
  case parse ["--log-level", "nope", "list"] of
    Nothing -> pure ()
    Just opts -> do
      hPutStrLn stderr $ "expected invalid log-level failure, got " <> show opts
      exitFailure
  case parse ["outdated"] of
    Just opts -> assertEq "outdated all" (Just (CLI.Outdated [])) (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse outdated bare failed"
      exitFailure
  case parse ["gencache", "dev-lang/go", "--force"] of
    Just opts ->
      assertEq
        "gencache force after target"
        (Just (CLI.Gencache {CLI.gencacheTargets = ["dev-lang/go"], CLI.gencacheForce = True}))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse gencache target --force failed"
      exitFailure
  case parse ["update", "a/b", "c/d"] of
    Just opts ->
      assertEq
        "update multi"
        (Just (CLI.Update ["a/b", "c/d"]))
        (optCommand opts)
    Nothing -> do
      hPutStrLn stderr "parse update multi failed"
      exitFailure

-- | Top-level and @eclean --help@ catalog manager distfiles surfaces.
testHelpCatalogDistfiles :: IO ()
testHelpCatalogDistfiles = do
  let topFailure = parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty
      (topMsg, _) = renderFailure topFailure "mndz-overlay-manager"
  assertTrue "top help lists eclean" ("eclean" `isInfixOf` topMsg)
  assertTrue "top help lists distfiles-path" ("distfiles-path" `isInfixOf` topMsg)
  case execParserPure defaultPrefs parserInfo ["eclean", "--help"] of
    Failure failure -> do
      let (msg, _) = renderFailure failure "mndz-overlay-manager"
      assertTrue "eclean help mentions manager" ("manager" `isInfixOf` msg || "distfiles" `isInfixOf` msg)
      assertTrue "eclean help mentions private/cache" ("cache" `isInfixOf` msg || "private" `isInfixOf` msg)
      assertTrue "eclean help mentions system not cleaned" ("system" `isInfixOf` msg)
    Success _ -> do
      hPutStrLn stderr "expected eclean --help Failure, got Success"
      exitFailure
    CompletionInvoked _ -> do
      hPutStrLn stderr "expected eclean --help Failure, got CompletionInvoked"
      exitFailure

testShowTopLevelHelpExit1 :: IO ()
testShowTopLevelHelpExit1 = do
  result <- try @ExitCode showTopLevelHelpExit1
  case result of
    Left (ExitFailure 1) -> pure ()
    Left other -> do
      hPutStrLn stderr $ "expected ExitFailure 1, got " <> show other
      exitFailure
    Right _ -> do
      hPutStrLn stderr "showTopLevelHelpExit1 returned unexpectedly"
      exitFailure

testLoggerHoldAndFilter :: IO ()
testLoggerHoldAndFilter = do
  hold <- mkLogHold
  let logger = mkLogger V.Warn ColorOff hold
  captured <- newIORef ([] :: [T.Text])
  let capture =
        LogAction $ \msg ->
          atomicModifyIORef' captured (\xs -> (xs <> [msgText msg], ()))
  beginLogHold hold
  unLogAction logger (Msg {msgSeverity = C.Info, msgStack = callStack, msgText = "info-hidden"})
  unLogAction logger (Msg {msgSeverity = C.Warning, msgStack = callStack, msgText = "warn-held"})
  unLogAction logger (Msg {msgSeverity = C.Error, msgStack = callStack, msgText = "err-held"})
  flushLogHold hold capture
  msgs <- readIORef captured
  assertEq "held warn/error only, in order" ["warn-held", "err-held"] msgs
  -- ColorOn + Debug path: hold debug messages then flush
  hold2 <- mkLogHold
  let loggerColor = mkLogger V.Debug ColorOn hold2
  captured2 <- newIORef ([] :: [T.Text])
  let capture2 =
        LogAction $ \msg ->
          atomicModifyIORef' captured2 (\xs -> (xs <> [msgText msg], ()))
  beginLogHold hold2
  unLogAction loggerColor (Msg {msgSeverity = C.Debug, msgStack = callStack, msgText = "dbg-held"})
  flushLogHold hold2 capture2
  msgs2 <- readIORef captured2
  assertEq "debug held under ColorOn" ["dbg-held"] msgs2
  -- Non-hold emit path (writes filtered sink to stderr)
  unLogAction logger (Msg {msgSeverity = C.Warning, msgStack = callStack, msgText = "warn-direct"})
