{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Progress (unitTests, integrationTests) where

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
import Test.Support (mkTestApplyEnv, unusedVendorOps)
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

-- | Progress UI / state helpers without apply-plan spine.
unitTests :: TestTree
unitTests =
  testGroup
    "Progress"
    [ testCase "Multi Progress State" testMultiProgressState,
      testCase "Multi Progress Skip Vs Fail" testMultiProgressSkipVsFail,
      testCase "Plan Draw" testPlanDraw,
      testCase "Multi Progress Draw Throw No Hang" testMultiProgressDrawThrowNoHang,
      testCase "Multi Progress Body Throw No Hang" testMultiProgressBodyThrowNoHang,
      testCase "Multi Progress Panel Fail Success" testMultiProgressPanelFailSuccess,
      testCase "Step Progress Draw Throw No Hang" testStepProgressDrawThrowNoHang,
      testCase "Step Progress Body Throw No Hang" testStepProgressBodyThrowNoHang,
      testCase "Step Progress Panel Fail Success" testStepProgressPanelFailSuccess,
      testCase "Pause Clear Throw Lock Not Stuck" testPauseClearThrowLockNotStuck
    ]

-- | Soft-skip handle drives ApplyEnv / PlanOps apply path.
integrationTests :: TestTree
integrationTests =
  testGroup
    "Progress"
    [ testCase "Apply Progress Soft Skip Handle" testApplyProgressSoftSkipHandle
    ]

testMultiProgressState :: IO ()
testMultiProgressState = do
  stateRef <-
    newIORef
      MultiState
        { msLabel = "Checking packages",
          msTotal = 2,
          msSucceeded = 0,
          msJobs = Map.empty,
          msTick = 0
        }
  let mh = multiHandle stateRef
      k1 = mkPackageKey "app-misc" "foo"
      k2 = mkPackageKey "dev-lang" "bar"
  mhStart mh k1
  mhStart mh k2
  mhStatus mh k1 "fetching"
  mhSteps mh k2 5
  mhStatus mh k2 "probing go.mod"
  mhStep mh k2 "probing go.mod"
  mhStep mh k2 "probing go.mod"
  s1 <- readIORef stateRef
  assertEq "top package done still 0" 0 (msSucceeded s1)
  case Map.lookup k1 (msJobs s1) of
    Just (JobActive aj) -> do
      assertEq "single-step total unset" 0 (ajStepTotal aj)
      assertEq "single-step name" "fetching" (ajName aj)
      assertTrue "omit bar when total <= 1" (ajStepTotal aj <= 1)
    _ -> do
      hPutStrLn stderr "expected active job for k1"
      exitFailure
  case Map.lookup k2 (msJobs s1) of
    Just (JobActive aj) -> do
      assertEq "multi step total" 5 (ajStepTotal aj)
      assertEq "multi step done" 2 (ajStepDone aj)
      assertTrue "show bar when total > 1" (ajStepTotal aj > 1)
    _ -> do
      hPutStrLn stderr "expected active job for k2"
      exitFailure
  -- Inner step advances must not bump package-level success counter.
  mhStep mh k2 "probing go.mod"
  s2 <- readIORef stateRef
  assertEq "top still 0 after inner steps" 0 (msSucceeded s2)
  mhSuccess mh k2
  s3 <- readIORef stateRef
  assertEq "package success bumps top" 1 (msSucceeded s3)
  assertTrue "success removes row" (Map.notMember k2 (msJobs s3))
  let frame = renderMulti ColorOff s1
  assertTrue "frame has package key" ("app-misc/foo" `T.isInfixOf` T.pack frame)
  assertTrue "frame has step fraction for multi" ("2/5" `T.isInfixOf` T.pack frame)
  -- Single-step row should not include a 0/0-style fraction.
  assertTrue
    "single-step omits 0/0 fraction"
    (not ("0/0" `T.isInfixOf` T.pack frame))

-- | Soft-skip and hard-fail terminals keep distinct chrome; both count as done.

-- | Soft-skip and hard-fail terminals keep distinct chrome; both count as done.
testMultiProgressSkipVsFail :: IO ()
testMultiProgressSkipVsFail = do
  stateRef <-
    newIORef
      MultiState
        { msLabel = "Updating packages",
          msTotal = 3,
          msSucceeded = 0,
          msJobs = Map.empty,
          msTick = 0
        }
  let mh = multiHandle stateRef
      kSkip = mkPackageKey "app-misc" "skipped"
      kFail = mkPackageKey "dev-lang" "broken"
      kOk = mkPackageKey "dev-util" "ok"
  mhStart mh kSkip
  mhStart mh kFail
  mhStart mh kOk
  mhSkip mh kSkip "already at latest"
  mhFail mh kFail "dirty involved paths"
  mhSuccess mh kOk
  s <- readIORef stateRef
  assertEq "success bumps top" 1 (msSucceeded s)
  assertTrue "success removes row" (Map.notMember kOk (msJobs s))
  case Map.lookup kSkip (msJobs s) of
    Just (JobSkipped reason) ->
      assertEq "skip reason retained" "already at latest" reason
    other -> do
      hPutStrLn stderr ("expected JobSkipped, got: " <> show other)
      exitFailure
  case Map.lookup kFail (msJobs s) of
    Just (JobFailed reason) ->
      assertEq "fail reason retained" "dirty involved paths" reason
    other -> do
      hPutStrLn stderr ("expected JobFailed, got: " <> show other)
      exitFailure
  let frame = T.pack (renderMulti ColorOff s)
  assertTrue "skip glyph" ("⚠" `T.isInfixOf` frame)
  assertTrue "fail glyph" ("✗" `T.isInfixOf` frame)
  assertTrue "skip reason in frame" ("already at latest" `T.isInfixOf` frame)
  assertTrue "fail reason in frame" ("dirty involved paths" `T.isInfixOf` frame)
  assertTrue "skip package key" ("app-misc/skipped" `T.isInfixOf` frame)
  assertTrue "fail package key" ("dev-lang/broken" `T.isInfixOf` frame)
  -- Top done = 1 success + 2 retained terminals
  assertTrue "top done counts skip+fail" ("3/3" `T.isInfixOf` frame)
  -- Color on: skip uses yellow path, fail uses red path (distinct styling).
  let frameOn = T.pack (renderMulti ColorOn s)
      yellow = "\ESC[93m"
      red = "\ESC[91m"
  assertTrue "skip styling yellow when color on" (yellow `T.isInfixOf` frameOn)
  assertTrue "fail styling red when color on" (red `T.isInfixOf` frameOn)

-- | Soft-skip-only package outcomes call mhSkip, not mhFail.

-- | Soft-skip-only package outcomes call mhSkip, not mhFail.
testApplyProgressSoftSkipHandle :: IO ()
testApplyProgressSoftSkipHandle = do
  withSystemTempDirectory "mndz-soft-skip-handle-" $ \tmp -> do
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    terminal <- newIORef ([] :: [T.Text])
    let logTerm t = atomicModifyIORef' terminal (\xs -> (t : xs, ()))
        key = mkPackageKey "app-misc" "no-such-policy-pkg"
        entry =
          PackageEntry
            { peKey = key,
              pePN = "no-such-policy-pkg",
              peLocal = parseEbuildVersion "1.0.0",
              pePath = tmp </> "no-such-policy-pkg-1.0.0.ebuild"
            }
        mh =
          MultiHandle
            { mhStart = \_ -> logTerm "start",
              mhStatus = \_ _ -> pure (),
              mhSteps = \_ _ -> pure (),
              mhStep = \_ _ -> pure (),
              mhSuccess = \_ -> logTerm "success",
              mhSkip = \_ reason -> logTerm ("skip:" <> reason),
              mhFail = \_ reason -> logTerm ("fail:" <> reason)
            }
        gitOps =
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
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
              roDownloadAsset = \_ _ -> pure (Left "unused"),
              roCreateReleaseWithAsset = \_ _ -> pure (Right ())
            }
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps
        (\_ _ -> pure (Right ()))
        releaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    let env = env0 {aeMulti = mh}
    outcomes <- applyPackagePhase1Tracked env tmp entry
    case outcomes of
      [ApplySoftSkip k reason] -> do
        assertEq "soft-skip key" key k
        assertTrue "no-policy reason" ("no hardcoded policy" `T.isInfixOf` reason)
      other -> do
        hPutStrLn stderr ("expected soft-skip, got: " <> show other)
        exitFailure
    calls <- reverse <$> readIORef terminal
    assertTrue "started" ("start" `elem` calls)
    assertTrue
      "called mhSkip"
      (any ("skip:" `T.isPrefixOf`) calls)
    assertTrue "did not call mhFail" (not (any ("fail:" `T.isPrefixOf`) calls))
    assertTrue "did not call mhSuccess" ("success" `notElem` calls)

------------------------------------------------------------------------
-- Pure panel redraw plan (tight dynamic height)
------------------------------------------------------------------------

testPlanDraw :: IO ()
testPlanDraw = do
  -- First frame: no previous band.
  let first = planDraw 0 "top\nrow1\nrow2"
  assertEq "first move-up" 0 (dpMoveUp first)
  assertEq "first content" ["top", "row1", "row2"] (dpContentLines first)
  assertEq "first clear-extra" 0 (dpClearExtra first)
  assertEq "first move-back" 0 (dpMoveBack first)
  assertEq "first store" 3 (dpStore first)
  assertPlanInvariants "first" 0 first

  -- Grow: more content than previous height.
  let grow = planDraw 2 "a\nb\nc\nd"
  assertEq "grow move-up" 2 (dpMoveUp grow)
  assertEq "grow content count" 4 (length (dpContentLines grow))
  assertEq "grow clear-extra" 0 (dpClearExtra grow)
  assertEq "grow move-back" 0 (dpMoveBack grow)
  assertEq "grow store" 4 (dpStore grow)
  assertPlanInvariants "grow" 2 grow

  -- Same height: rewrite in place, no clear-extra / move-back.
  let same = planDraw 3 "x\ny\nz"
  assertEq "same move-up" 3 (dpMoveUp same)
  assertEq "same clear-extra" 0 (dpClearExtra same)
  assertEq "same move-back" 0 (dpMoveBack same)
  assertEq "same store" 3 (dpStore same)
  assertPlanInvariants "same" 3 same

  -- Shrink: clear leftover band lines and move cursor back under content.
  let shrink = planDraw 5 "top\nrow"
  assertEq "shrink move-up" 5 (dpMoveUp shrink)
  assertEq "shrink content" ["top", "row"] (dpContentLines shrink)
  assertEq "shrink clear-extra" 3 (dpClearExtra shrink)
  assertEq "shrink move-back" 3 (dpMoveBack shrink)
  assertEq "shrink store" 2 (dpStore shrink)
  assertPlanInvariants "shrink" 5 shrink

  -- Empty / clear-shaped: reclaim entire previous band.
  let empty = planDraw 4 ""
  assertEq "empty move-up" 4 (dpMoveUp empty)
  assertEq "empty content" [] (dpContentLines empty)
  assertEq "empty clear-extra" 4 (dpClearExtra empty)
  assertEq "empty move-back" 4 (dpMoveBack empty)
  assertEq "empty store" 0 (dpStore empty)
  assertPlanInvariants "empty" 4 empty

  -- Empty with no previous height is a no-op plan.
  let empty0 = planDraw 0 ""
  assertEq "empty0 store" 0 (dpStore empty0)
  assertPlanInvariants "empty0" 0 empty0

-- | store == content line count; move-back == max(0, prev − n); clear-extra matches.

-- | store == content line count; move-back == max(0, prev − n); clear-extra matches.
assertPlanInvariants :: String -> Int -> DrawPlan -> IO ()
assertPlanInvariants label prev plan = do
  let n = length (dpContentLines plan)
  assertEq (label <> " store equals content lines") n (dpStore plan)
  assertEq
    (label <> " move-back equals max(0, prev - n)")
    (max 0 (prev - n))
    (dpMoveBack plan)
  assertEq
    (label <> " clear-extra equals move-back")
    (dpMoveBack plan)
    (dpClearExtra plan)
  assertEq (label <> " move-up is prev") prev (dpMoveUp plan)

------------------------------------------------------------------------
-- Progress host no-hang (injectable PanelIO; no TTY required)
------------------------------------------------------------------------

-- | Bound for host teardown in no-hang tests (≫ 300ms grace + one tick).
hostNoHangBoundMicros :: Int
hostNoHangBoundMicros = 2_000_000

silentLogger :: LogAction IO Message
silentLogger = LogAction (\_ -> pure ())

mkEnabledProgressConfig :: IO ProgressConfig
mkEnabledProgressConfig = do
  hold <- mkLogHold
  mkProgressConfig True ColorOff hold silentLogger

drawBombIO :: PanelIO
drawBombIO =
  defaultPanelIO
    { pioDrawFrame = \_ _ _ -> throwIO (userError "draw bomb"),
      pioClearLines = \_ _ -> pure (),
      pioDelay = \_ -> pure ()
    }

-- | Draw blocks until cancelled (forces cancel-after-grace path).

-- | Draw blocks until cancelled (forces cancel-after-grace path).
stuckDrawIO :: PanelIO
stuckDrawIO =
  defaultPanelIO
    { pioDrawFrame = \_ _ _ -> forever (threadDelay 100_000),
      pioClearLines = \_ _ -> pure (),
      pioDelay = \_ -> pure ()
    }

clearBombIO :: PanelIO
clearBombIO =
  defaultPanelIO
    { pioDrawFrame = \_ _ _ -> pure 0,
      pioClearLines = \_ _ -> throwIO (userError "clear bomb"),
      pioDelay = threadDelay
    }

assertFinishesWithin :: String -> IO a -> IO a
assertFinishesWithin label action = do
  raced <- race (threadDelay hostNoHangBoundMicros) action
  case raced of
    Left () -> do
      hPutStrLn stderr $ label <> ": host did not finish within bound (hang)"
      exitFailure
    Right a -> pure a

testMultiProgressDrawThrowNoHang :: IO ()
testMultiProgressDrawThrowNoHang = do
  cfg <- mkEnabledProgressConfig
  void $
    assertFinishesWithin "multi draw throw" $
      withMultiProgressIO drawBombIO cfg "Checking" 1 $
        \_ -> pure ()

testMultiProgressBodyThrowNoHang :: IO ()
testMultiProgressBodyThrowNoHang = do
  cfg <- mkEnabledProgressConfig
  er <-
    assertFinishesWithin "multi body throw" $
      try @SomeException $
        withMultiProgressIO defaultPanelIO cfg "Checking" 1 $ \_ ->
          throwIO (userError "body boom")
  case er of
    Left _ -> pure ()
    Right () -> do
      hPutStrLn stderr "multi body throw: expected exception to propagate"
      exitFailure

testMultiProgressPanelFailSuccess :: IO ()
testMultiProgressPanelFailSuccess = do
  cfg <- mkEnabledProgressConfig
  -- Panel dies on first draw; body still succeeds.
  r1 <-
    assertFinishesWithin "multi panel fail success" $
      withMultiProgressIO drawBombIO cfg "Checking" 1 $
        \_ -> pure (42 :: Int)
  assertEq "multi panel fail returns body" 42 r1
  -- Stuck draw forces cancel-after-grace; body result preserved.
  r2 <-
    assertFinishesWithin "multi panel cancel success" $
      withMultiProgressIO stuckDrawIO cfg "Checking" 1 $
        \_ -> pure (7 :: Int)
  assertEq "multi panel cancel returns body" 7 r2

testStepProgressDrawThrowNoHang :: IO ()
testStepProgressDrawThrowNoHang = do
  cfg <- mkEnabledProgressConfig
  void $
    assertFinishesWithin "step draw throw" $
      withStepProgressIO drawBombIO cfg 1 $
        \_ -> pure ()

testStepProgressBodyThrowNoHang :: IO ()
testStepProgressBodyThrowNoHang = do
  cfg <- mkEnabledProgressConfig
  er <-
    assertFinishesWithin "step body throw" $
      try @SomeException $
        withStepProgressIO defaultPanelIO cfg 1 $ \_ ->
          throwIO (userError "body boom")
  case er of
    Left _ -> pure ()
    Right () -> do
      hPutStrLn stderr "step body throw: expected exception to propagate"
      exitFailure

testStepProgressPanelFailSuccess :: IO ()
testStepProgressPanelFailSuccess = do
  cfg <- mkEnabledProgressConfig
  r1 <-
    assertFinishesWithin "step panel fail success" $
      withStepProgressIO drawBombIO cfg 1 $
        \_ -> pure ("ok" :: String)
  assertEq "step panel fail returns body" "ok" r1
  r2 <-
    assertFinishesWithin "step panel cancel success" $
      withStepProgressIO stuckDrawIO cfg 1 $
        \_ -> pure ("ok2" :: String)
  assertEq "step panel cancel returns body" "ok2" r2

testPauseClearThrowLockNotStuck :: IO ()
testPauseClearThrowLockNotStuck = do
  cfg <- mkEnabledProgressConfig
  void $
    assertFinishesWithin "pause clear throw" $
      withMultiProgressIO clearBombIO cfg "Checking" 1 $ \_ -> do
        -- Clear under pause throws, but withDrawLock must release.
        er <- try @SomeException (pauseActivePanel cfg)
        case er of
          Left _ -> pure ()
          Right () -> do
            hPutStrLn stderr "pause clear throw: expected clear bomb"
            exitFailure
        -- Resume must not block indefinitely on an abandoned draw lock.
        resumeActivePanel cfg
        pure ()
