{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Preflight (tests) where

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
import Update.Preflight
  ( AssetsPreflight (..),
    assetsRequiredTools,
    bunRequiredTools,
    cargoFetcherTools,
    cargoRequiredTools,
    checkToolsOnPath,
    goAssetsRequiredTools,
    goRequiredTools,
    npmRequiredTools,
    preflightUpdateToolsWith,
    updateRequiredTools,
    validateAssetsPathWith,
  )
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
import Update.TextUtil (stripSurroundingQuotes)
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
    "Preflight"
    [ testCase "Preflight Missing Tools" testPreflightMissingTools,
      testCase "Required Tool List Constants" testRequiredToolListConstants,
      testCase "Check Tools Multiple Missing" testCheckToolsMultipleMissing,
      testCase "Validate Assets Path" testValidateAssetsPath,
      testCase "Preflight Update Tools" testPreflightUpdateTools,
      testCase "Strip Surrounding Quotes" testStripSurroundingQuotes
    ]

testPreflightMissingTools :: IO ()
testPreflightMissingTools = do
  missing <-
    checkToolsOnPath
      ( \name ->
          pure $
            if name == "ebuild"
              then Nothing
              else Just ("/usr/bin/" <> name)
      )
      updateRequiredTools
  assertEq "missing ebuild only" ["ebuild"] missing
  none <-
    checkToolsOnPath
      (\name -> pure (Just ("/bin/" <> name)))
      updateRequiredTools
  assertEq "none missing" [] none

testRequiredToolListConstants :: IO ()
testRequiredToolListConstants = do
  assertEq "update tools" ["git", "ebuild", "egencache", "gpg"] updateRequiredTools
  assertEq "assets tools" ["xz"] assetsRequiredTools
  assertEq "go tools" ["go"] goRequiredTools
  assertEq "npm tools" ["npm"] npmRequiredTools
  assertEq "bun tools" ["bun"] bunRequiredTools
  assertEq "cargo tools" ["pycargoebuild"] cargoRequiredTools
  assertEq "cargo fetchers" ["wget", "aria2c", "aria2"] cargoFetcherTools
  assertEq "go+assets" ["go", "xz"] goAssetsRequiredTools

testCheckToolsMultipleMissing :: IO ()
testCheckToolsMultipleMissing = do
  missing <-
    checkToolsOnPath
      ( \name ->
          pure $
            if name `elem` ["git", "gpg"]
              then Nothing
              else Just ("/usr/bin/" <> name)
      )
      updateRequiredTools
  assertEq "missing git and gpg" ["git", "gpg"] missing
  emptyList <- checkToolsOnPath (\_ -> pure Nothing) []
  assertEq "empty tools list" [] emptyList

allPresent :: String -> IO (Maybe FilePath)
allPresent name = pure (Just ("/bin/" <> name))

missingNamed :: [String] -> String -> IO (Maybe FilePath)
missingNamed missing name =
  pure $
    if name `elem` missing
      then Nothing
      else Just ("/bin/" <> name)

basePreflight :: AssetsPreflight
basePreflight =
  AssetsPreflight
    { apNeedAssets = False,
      apNeedGo = False,
      apNeedNpm = False,
      apNeedBun = False,
      apNeedCargo = False
    }

testValidateAssetsPath :: IO ()
testValidateAssetsPath = do
  none <- validateAssetsPathWith (const (pure True)) (const (pure True)) Nothing
  errNone <- assertLeft "missing path" none
  assertTrue "mentions assets-path" ("assets-path is required" `T.isInfixOf` errNone)
  notDir <-
    validateAssetsPathWith
      (\_ -> pure False)
      (\_ -> pure True)
      (Just "/tmp/missing-assets")
  errDir <- assertLeft "not a directory" notDir
  assertTrue "mentions not a directory" ("not a directory" `T.isInfixOf` errDir)
  notGit <-
    validateAssetsPathWith
      (\_ -> pure True)
      (\_ -> pure False)
      (Just "/tmp/assets")
  errGit <- assertLeft "not git" notGit
  assertTrue "mentions git work tree" ("git work tree" `T.isInfixOf` errGit)
  ok <-
    validateAssetsPathWith
      (\_ -> pure True)
      (\_ -> pure True)
      (Just "/tmp/assets")
  path <- assertRight "valid assets path" ok
  assertEq "returns path" "/tmp/assets" path

testPreflightUpdateTools :: IO ()
testPreflightUpdateTools = do
  okBase <- preflightUpdateToolsWith allPresent basePreflight
  assertEq "base tools ok" (Right ()) okBase
  missEbuild <- preflightUpdateToolsWith (missingNamed ["ebuild"]) basePreflight
  errEbuild <- assertLeft "missing ebuild" missEbuild
  assertTrue "lists ebuild" ("ebuild" `T.isInfixOf` errEbuild)
  let full =
        basePreflight
          { apNeedAssets = True,
            apNeedGo = True,
            apNeedNpm = True,
            apNeedBun = True,
            apNeedCargo = True
          }
  okFull <-
    preflightUpdateToolsWith
      ( \name ->
          pure $
            if name == "aria2"
              then Nothing
              else Just ("/bin/" <> name)
      )
      full
  assertEq "cargo ok with one fetcher" (Right ()) okFull
  missFetchers <-
    preflightUpdateToolsWith
      ( \name ->
          pure $
            if name `elem` cargoFetcherTools
              then Nothing
              else Just ("/bin/" <> name)
      )
      full
  errFetch <- assertLeft "missing cargo fetchers" missFetchers
  assertTrue
    "mentions wget or aria2c"
    ("wget or aria2c" `T.isInfixOf` errFetch)
  missEco <-
    preflightUpdateToolsWith
      (missingNamed ["xz", "go", "npm", "bun", "pycargoebuild"])
      full
  errEco <- assertLeft "missing ecosystem tools" missEco
  assertTrue "lists xz" ("xz" `T.isInfixOf` errEco)
  assertTrue "lists go" ("go" `T.isInfixOf` errEco)
  assertTrue "lists npm" ("npm" `T.isInfixOf` errEco)
  assertTrue "lists bun" ("bun" `T.isInfixOf` errEco)
  assertTrue "lists pycargoebuild" ("pycargoebuild" `T.isInfixOf` errEco)

testStripSurroundingQuotes :: IO ()
testStripSurroundingQuotes = do
  assertEq "double quotes" "hello" (stripSurroundingQuotes "\"hello\"")
  assertEq "single quotes" "hello" (stripSurroundingQuotes "'hello'")
  assertEq "unquoted" "hello" (stripSurroundingQuotes "hello")
  assertEq "mismatched double open" "\"hello" (stripSurroundingQuotes "\"hello")
  assertEq "mismatched single open" "'hello" (stripSurroundingQuotes "'hello")
  assertEq "mismatched ends" "\"hello'" (stripSurroundingQuotes "\"hello'")
  assertEq "empty" "" (stripSurroundingQuotes "")
  assertEq "single char" "x" (stripSurroundingQuotes "x")
  assertEq "empty double pair" "" (stripSurroundingQuotes "\"\"")
  assertEq "inner quotes kept" "he\"llo" (stripSurroundingQuotes "\"he\"llo\"")
