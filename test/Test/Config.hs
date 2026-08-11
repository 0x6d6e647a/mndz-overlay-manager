{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Config (tests) where

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
import Config.Loader (ConfigError (..), configErrorMessage, loadConfig)
import Config.Types (CheckCacheTtl (..), OverlayConfig (..), defaultCheckCacheTtl, parseCheckCacheTtl)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, race)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Exception (SomeException, bracket_, throwIO, try)
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
import System.Environment (lookupEnv, setEnv, unsetEnv)
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
    "Config"
    [ testCase "Config Load Success" testConfigLoadSuccess,
      testCase "Config Optional Keys" testConfigOptionalKeys,
      testCase "Config Load Missing" testConfigLoadMissing,
      testCase "Config Load Missing Key" testConfigLoadMissingKey,
      testCase "Config Legacy Keys Rejected" testConfigLegacyKeysRejected,
      testCase "Config Error Messages" testConfigErrorMessages,
      testCase "Config Default Path Via XDG" testConfigDefaultPathViaXdg,
      testCase "Config Load Invalid Toml" testConfigLoadInvalidToml,
      testCase "Parse Check Cache TTL" testParseCheckCacheTtl,
      testCase "Config Check Cache TTL Zero" testConfigCheckCacheTtlZero,
      testCase "Config Check Cache TTL Invalid" testConfigCheckCacheTtlInvalid
    ]

testConfigLoadSuccess :: IO ()
testConfigLoadSuccess = do
  cfg <- assertRight "valid config" =<< loadConfig (Just "test/fixtures/valid-config.toml")
  assertEq "path key" "test/fixtures/populated-overlay" (overlayPath cfg)
  assertEq "assets optional absent" Nothing (assetsPath cfg)
  assertEq "token optional absent" Nothing (githubToken cfg)
  assertEq "distfiles optional absent" Nothing (distfilesPath cfg)
  assertEq "check-cache-ttl default" defaultCheckCacheTtl (checkCacheTtl cfg)

testConfigOptionalKeys :: IO ()
testConfigOptionalKeys = do
  cfg <- assertRight "full config" =<< loadConfig (Just "test/fixtures/full-config.toml")
  assertEq "path" "/tmp/overlay" (overlayPath cfg)
  assertEq "assets" (Just "/tmp/assets") (assetsPath cfg)
  assertEq "token" (Just "secret-token") (githubToken cfg)
  assertEq "distfiles" (Just "/tmp/distfiles") (distfilesPath cfg)
  assertEq "check-cache-ttl 1h" (CacheTtl (60 * 60)) (checkCacheTtl cfg)

testConfigLoadMissing :: IO ()
testConfigLoadMissing = do
  err <- assertLeft "missing config" =<< loadConfig (Just "test/fixtures/does-not-exist.toml")
  case err of
    ConfigNotFound path ->
      assertEq "missing path" "test/fixtures/does-not-exist.toml" path
    other -> do
      hPutStrLn stderr $ "expected ConfigNotFound, got " <> show other
      exitFailure

testConfigLoadMissingKey :: IO ()
testConfigLoadMissingKey = do
  err <- assertLeft "missing key" =<< loadConfig (Just "test/fixtures/missing-key-config.toml")
  case err of
    DecodeError msg ->
      assertTrue "mentions overlay-path" ("overlay-path" `elem` words msg || "overlay-path" `T.isInfixOf` T.pack msg)
    other -> do
      hPutStrLn stderr $ "expected DecodeError, got " <> show other
      exitFailure

testConfigLegacyKeysRejected :: IO ()
testConfigLegacyKeysRejected = do
  err <- assertLeft "legacy keys" =<< loadConfig (Just "test/fixtures/legacy-key-config.toml")
  case err of
    DecodeError msg ->
      assertTrue
        "legacy config fails without overlay-path"
        ("overlay-path" `elem` words msg || "overlay-path" `T.isInfixOf` T.pack msg)
    other -> do
      hPutStrLn stderr $ "expected DecodeError for legacy keys, got " <> show other
      exitFailure

------------------------------------------------------------------------
-- Config residual: error messages, default path, decode failure
------------------------------------------------------------------------

testConfigErrorMessages :: IO ()
testConfigErrorMessages = do
  assertEq
    "not found message"
    "config file not found: /tmp/missing.toml"
    (configErrorMessage (ConfigNotFound "/tmp/missing.toml"))
  assertEq
    "decode message"
    "failed to decode config: bad keys"
    (configErrorMessage (DecodeError "bad keys"))

-- | Hit 'defaultConfigPath' via 'loadConfig Nothing' under controlled XDG.
testConfigDefaultPathViaXdg :: IO ()
testConfigDefaultPathViaXdg =
  withSystemTempDirectory "om-config-xdg" $ \tmp -> do
    let expected = tmp </> "mndz" </> "overlay-manager.toml"
    withEnvVar "XDG_CONFIG_HOME" (Just tmp) $ do
      err <- assertLeft "default missing" =<< loadConfig Nothing
      case err of
        ConfigNotFound path ->
          assertEq "xdg default path" expected path
        other -> do
          hPutStrLn stderr $ "expected ConfigNotFound for XDG default, got " <> show other
          exitFailure
    -- Success arm: place a valid config at the XDG default path.
    createDirectoryIfMissing True (tmp </> "mndz")
    TIO.writeFile expected "overlay-path = \"/tmp/from-xdg\"\n"
    withEnvVar "XDG_CONFIG_HOME" (Just tmp) $ do
      cfg <- assertRight "default present" =<< loadConfig Nothing
      assertEq "loaded via xdg" "/tmp/from-xdg" (overlayPath cfg)

testConfigLoadInvalidToml :: IO ()
testConfigLoadInvalidToml =
  withSystemTempDirectory "om-config-bad" $ \tmp -> do
    let path = tmp </> "bad.toml"
    TIO.writeFile path "this is not = valid toml [[[\n"
    err <- assertLeft "invalid toml" =<< loadConfig (Just path)
    case err of
      DecodeError msg ->
        assertTrue "decode error non-empty" (not (null msg))
      other -> do
        hPutStrLn stderr $ "expected DecodeError for invalid toml, got " <> show other
        exitFailure

-- | Temporarily set or clear an environment variable, restoring afterward.
withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key mVal action = do
  prev <- lookupEnv key
  let restore = case prev of
        Nothing -> unsetEnv key
        Just v -> setEnv key v
      install = case mVal of
        Nothing -> unsetEnv key
        Just v -> setEnv key v
  bracket_ install restore action

testParseCheckCacheTtl :: IO ()
testParseCheckCacheTtl = do
  assertEq "5m" (Right (CacheTtl (5 * 60))) (parseCheckCacheTtl "5m")
  assertEq "30s" (Right (CacheTtl 30)) (parseCheckCacheTtl "30s")
  assertEq "1H" (Right (CacheTtl (60 * 60))) (parseCheckCacheTtl "1H")
  assertEq "2d" (Right (CacheTtl (2 * 24 * 60 * 60))) (parseCheckCacheTtl "2d")
  assertEq "0" (Right CacheDisabled) (parseCheckCacheTtl "0")
  assertEq "0s" (Right CacheDisabled) (parseCheckCacheTtl "0s")
  assertEq "0m" (Right CacheDisabled) (parseCheckCacheTtl "0m")
  assertTrue "bare 5 rejected" (case parseCheckCacheTtl "5" of Left _ -> True; Right _ -> False)
  assertTrue "multi rejected" (case parseCheckCacheTtl "1h30m" of Left _ -> True; Right _ -> False)
  assertTrue "empty rejected" (case parseCheckCacheTtl "" of Left _ -> True; Right _ -> False)
  assertTrue "unknown unit" (case parseCheckCacheTtl "3w" of Left _ -> True; Right _ -> False)

testConfigCheckCacheTtlZero :: IO ()
testConfigCheckCacheTtlZero =
  withSystemTempDirectory "om-cache-ttl0" $ \tmp -> do
    let path = tmp </> "c.toml"
    TIO.writeFile path "overlay-path = \"/tmp/ov\"\ncheck-cache-ttl = \"0s\"\n"
    cfg <- assertRight "zero ttl" =<< loadConfig (Just path)
    assertEq "disabled" CacheDisabled (checkCacheTtl cfg)

testConfigCheckCacheTtlInvalid :: IO ()
testConfigCheckCacheTtlInvalid =
  withSystemTempDirectory "om-cache-ttl-bad" $ \tmp -> do
    let path = tmp </> "c.toml"
    TIO.writeFile path "overlay-path = \"/tmp/ov\"\ncheck-cache-ttl = \"1h30m\"\n"
    err <- assertLeft "invalid ttl" =<< loadConfig (Just path)
    case err of
      DecodeError msg ->
        assertTrue "non-empty decode error" (not (null msg))
      other -> do
        hPutStrLn stderr $ "expected DecodeError, got " <> show other
        exitFailure
