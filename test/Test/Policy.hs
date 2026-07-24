{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Policy (tests) where

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
    "Policy"
    [ testCase "Hardcoded Grok" testHardcodedGrok,
      testCase "Policy Classification" testPolicyClassification,
      testCase "Resolve Map Only" testResolveMapOnly,
      testCase "Group Newest" testGroupNewest,
      testCase "Check Overlay Statuses" testCheckOverlayStatuses
    ]

------------------------------------------------------------------------
-- Hardcoded policy
------------------------------------------------------------------------

testHardcodedGrok :: IO ()
testHardcodedGrok = do
  let key = PackageKey "dev-util/grok-build-bin"
  case lookupHardcoded key of
    Just (Http primary (Just fb)) -> do
      assertEq "primary" "https://x.ai/cli/stable" primary
      assertTrue "fallback mentions gcs" ("storage.googleapis.com" `T.isInfixOf` fb)
    other -> do
      hPutStrLn stderr $ "expected hardcoded Http, got " <> show other
      exitFailure
  assertEq "resolve map only" (lookupHardcoded key) (resolveSource key)

testPolicyClassification :: IO ()
testPolicyClassification = do
  case lookupPolicy (PackageKey "dev-util/opencode-bin") of
    Just (PackagePolicy _ GitMvAndManifest) -> pure ()
    other -> do
      hPutStrLn stderr $ "opencode technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/mise") of
    Just (PackagePolicy (GitHub "jdx" "mise" "v") (DepsAndAssets (Cargo Nothing Nothing))) ->
      pure ()
    other -> do
      hPutStrLn stderr $ "mise technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/hk") of
    Just (PackagePolicy _ (DepsAndAssets (Cargo Nothing Nothing))) -> pure ()
    other -> do
      hPutStrLn stderr $ "hk technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/usage") of
    Just (PackagePolicy _ (DepsAndAssets (Cargo Nothing (Just "cli")))) -> pure ()
    other -> do
      hPutStrLn stderr $ "usage technique: " <> show other
      exitFailure
  assertEq "unmapped" Nothing (lookupPolicy (PackageKey "dev-lang/haskell"))
  case lookupPolicy (PackageKey "dev-lang/bun-bin") of
    Just (PackagePolicy (GitHub "oven-sh" "bun" "bun-v") GitMvAndManifest) -> pure ()
    other -> do
      hPutStrLn stderr $ "bun policy: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-db/dolt") of
    Just (PackagePolicy _ (DepsAndAssets (Go (Just "go")))) -> pure ()
    other -> do
      hPutStrLn stderr $ "dolt technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/beads") of
    Just (PackagePolicy _ (DepsAndAssets (Go Nothing))) -> pure ()
    other -> do
      hPutStrLn stderr $ "beads technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/openspec") of
    Just (PackagePolicy (Npm "@fission-ai/openspec") (DepsAndAssets NpmEco)) -> pure ()
    other -> do
      hPutStrLn stderr $ "openspec technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/ralph-tui") of
    Just (PackagePolicy _ (DepsAndAssets Bun)) -> pure ()
    other -> do
      hPutStrLn stderr $ "ralph-tui technique: " <> show other
      exitFailure

testResolveMapOnly :: IO ()
testResolveMapOnly = do
  assertEq
    "dolt source"
    (Just (GitHub "dolthub" "dolt" "v"))
    (resolveSource (PackageKey "dev-db/dolt"))
  assertEq
    "unknown"
    Nothing
    (resolveSource (PackageKey "no/such"))

------------------------------------------------------------------------
-- Check pipeline
------------------------------------------------------------------------

testGroupNewest :: IO ()
testGroupNewest = do
  let ebuilds =
        [ Ebuild "dev-lang" "haskell" "9.4.5" "/tmp/haskell-9.4.5.ebuild",
          Ebuild "dev-lang" "haskell" "9.6.1" "/tmp/haskell-9.6.1.ebuild",
          Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim.ebuild"
        ]
      grouped = groupNewest ebuilds
      keys = sort (map (T.unpack . packageKeyText . peKey) grouped)
  assertEq "keys" ["app-editors/vim", "dev-lang/haskell"] keys
  case [e | e <- grouped, peKey e == PackageKey "dev-lang/haskell"] of
    (haskell : _) -> do
      assertEq "newest haskell" (Numeric [9, 6, 1] Nothing) (peLocal haskell)
      assertEq "path" "/tmp/haskell-9.6.1.ebuild" (pePath haskell)
    [] -> do
      hPutStrLn stderr "missing haskell group"
      exitFailure

testCheckOverlayStatuses :: IO ()
testCheckOverlayStatuses = do
  let fetch src = pure $ case src of
        GitHub "dolthub" "dolt" _ -> Right (parseEbuildVersion "2.1.10")
        GitHub "ok" "ok" _ -> Right (parseEbuildVersion "1.0.0")
        GitHub "ahead" "ahead" _ -> Right (parseEbuildVersion "1.5.0")
        GitHub "fail" "fail" _ -> Left "network down"
        _ -> Left "unexpected source"
  reports <-
    checkWithFakeResolve
      fetch
      [ (mkPackageKey "dev-db" "dolt", "dolt", "2.1.6", Just (GitHub "dolthub" "dolt" "v")),
        (mkPackageKey "dev-util" "okpkg", "okpkg", "1.0.0", Just (GitHub "ok" "ok" "v")),
        (mkPackageKey "dev-util" "ahead", "ahead", "2.0.0", Just (GitHub "ahead" "ahead" "v")),
        (mkPackageKey "dev-util" "none", "none", "1.0", Nothing),
        (mkPackageKey "dev-util" "fail", "fail", "1.0", Just (GitHub "fail" "fail" "v"))
      ]
  let statuses = map reportStatus reports
  assertTrue "has outdated" (any isOutdated statuses)
  assertTrue "has ok" (any isOk statuses)
  assertTrue "has ahead" (any isAhead statuses)
  assertTrue "has unconfigured" (Unconfigured `elem` statuses)
  assertTrue "has error" (any isErr statuses)
  where
    isOutdated (Outdated _) = True
    isOutdated _ = False
    isOk (Ok _) = True
    isOk _ = False
    isAhead (Ahead _ _) = True
    isAhead _ = False
    isErr (FetchError _) = True
    isErr _ = False

-- | Check packages with pre-resolved sources (avoids filesystem for unit tests).

-- | Check packages with pre-resolved sources (avoids filesystem for unit tests).
checkWithFakeResolve ::
  (UpdateSource -> IO (Either T.Text EbuildVersion)) ->
  [(PackageKey, T.Text, T.Text, Maybe UpdateSource)] ->
  IO [UpdateReport]
checkWithFakeResolve fetch = mapM go
  where
    go (key, _pn, pv, mSrc) = do
      let local = parseEbuildVersion pv
      case mSrc of
        Nothing ->
          pure UpdateReport {reportKey = key, reportStatus = Unconfigured}
        Just src -> do
          result <- fetch src
          pure $ case result of
            Left err ->
              UpdateReport {reportKey = key, reportStatus = FetchError err}
            Right remote ->
              UpdateReport
                { reportKey = key,
                  reportStatus = case comparePV local remote of
                    Just LT ->
                      Outdated
                        [ OutdatedLine
                            { olFrom = local,
                              olTo = remote,
                              olLabel = Nothing,
                              olAssetsReusable = False
                            }
                        ]
                    Just EQ -> Ok local
                    Just GT -> Ahead local remote
                    Nothing -> FetchError "incomparable"
                }
