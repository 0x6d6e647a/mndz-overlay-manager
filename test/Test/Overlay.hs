{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Overlay (tests) where

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
    "Overlay"
    [ testCase "Ebuild Atom" testEbuildAtom,
      testCase "Parse Ebuild File Name" testParseEbuildFileName,
      testCase "Discovery Happy Path" testDiscoveryHappyPath,
      testCase "Discovery Skips Non Categories" testDiscoverySkipsNonCategories,
      testCase "Discovery Bad Name" testDiscoveryBadName,
      testCase "Discovery Package Mismatch" testDiscoveryPackageMismatch,
      testCase "Empty Inventory Is Empty List" testEmptyInventoryIsEmptyList,
      testCase "Validate Populated" testValidatePopulated,
      testCase "Version Parse" testVersionParse,
      testCase "Version Render" testVersionRender,
      testCase "Version Compare" testVersionCompare
    ]

testEbuildAtom :: IO ()
testEbuildAtom = do
  let e = Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim-9.0.1234.ebuild"
  assertEq "ebuildAtom" "app-editors/vim-9.0.1234" (ebuildAtom e)

testParseEbuildFileName :: IO ()
testParseEbuildFileName = do
  assertEq "simple" (Just ("haskell", "9.4.5")) (parseEbuildFileName "haskell-9.4.5.ebuild")
  assertEq "revision" (Just ("vim", "9.0.1234-r1")) (parseEbuildFileName "vim-9.0.1234-r1.ebuild")
  assertEq "missing version" Nothing (parseEbuildFileName "haskell.ebuild")
  assertEq "not ebuild" Nothing (parseEbuildFileName "Manifest")

testDiscoveryHappyPath :: IO ()
testDiscoveryHappyPath = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  ebuilds <- assertRight "happy collect" =<< collectEbuilds root
  let atoms = sort (map (T.unpack . ebuildAtom) ebuilds)
  assertEq
    "atoms"
    [ "app-editors/vim-9.0.1234",
      "dev-lang/haskell-9.4.5",
      "dev-lang/haskell-9.6.1"
    ]
    atoms

testDiscoverySkipsNonCategories :: IO ()
testDiscoverySkipsNonCategories = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  ebuilds <- assertRight "skip non-cat" =<< collectEbuilds root
  let cats = map (T.unpack . ebuildCategory) ebuilds
  assertTrue "no eclass category" ("eclass" `notElem` cats)
  assertTrue "no licenses category" ("licenses" `notElem` cats)
  assertTrue "no profiles category" ("profiles" `notElem` cats)
  assertTrue "no metadata category" ("metadata" `notElem` cats)

testDiscoveryBadName :: IO ()
testDiscoveryBadName = do
  root <- makeAbsolute "test/fixtures/bad-ebuild-name"
  err <- assertLeft "bad name" =<< collectEbuilds root
  case err of
    MalformedEbuildName path ->
      assertTrue "path mentions haskell.ebuild" ("haskell.ebuild" `elem` splitPath path)
    other -> do
      hPutStrLn stderr $ "expected MalformedEbuildName, got " <> show other
      exitFailure
  where
    splitPath = map T.unpack . T.splitOn "/" . T.pack

testDiscoveryPackageMismatch :: IO ()
testDiscoveryPackageMismatch = do
  root <- makeAbsolute "test/fixtures/package-mismatch"
  err <- assertLeft "mismatch" =<< collectEbuilds root
  case err of
    PackageNameMismatch path expected got -> do
      assertEq "expected package" "haskell" expected
      assertEq "got package" "foo" got
      assertTrue "path has foo-1.0.ebuild" ("foo-1.0.ebuild" `elem` splitPath path)
    other -> do
      hPutStrLn stderr $ "expected PackageNameMismatch, got " <> show other
      exitFailure
  where
    splitPath = map T.unpack . T.splitOn "/" . T.pack

testEmptyInventoryIsEmptyList :: IO ()
testEmptyInventoryIsEmptyList = do
  root <- makeAbsolute "test/fixtures/empty-valid-overlay"
  ebuilds <- assertRight "empty collect" =<< collectEbuilds root
  assertEq "empty list" [] ebuilds

testValidatePopulated :: IO ()
testValidatePopulated = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  _ <- assertRight "validate populated" =<< validateOverlay root
  pure ()

------------------------------------------------------------------------
-- Ebuild version
------------------------------------------------------------------------

testVersionParse :: IO ()
testVersionParse = do
  assertEq
    "numeric with rev"
    (Numeric [1, 5, 3] (Just 2))
    (parseEbuildVersion "1.5.3-r2")
  assertEq
    "numeric no rev"
    (Numeric [0, 2, 93] Nothing)
    (parseEbuildVersion "0.2.93")
  assertEq
    "raw fallback"
    (Raw "1.0_alpha")
    (parseEbuildVersion "1.0_alpha")

testVersionRender :: IO ()
testVersionRender = do
  assertEq
    "pretty with rev"
    "1.5.3-r2"
    (prettyVersion (Numeric [1, 5, 3] (Just 2)))
  assertEq
    "pretty no rev"
    "2.1.10"
    (prettyVersion (Numeric [2, 1, 10] Nothing))

testVersionCompare :: IO ()
testVersionCompare = do
  assertEq
    "outdated"
    (Just LT)
    (comparePV (parseEbuildVersion "1.17.16") (parseEbuildVersion "1.17.18"))
  assertEq
    "rev ignored"
    (Just EQ)
    (comparePV (parseEbuildVersion "1.2.3-r5") (parseEbuildVersion "1.2.3"))
  assertEq
    "numeric order"
    (Just GT)
    (comparePV (parseEbuildVersion "1.10.0") (parseEbuildVersion "1.9.0"))
  assertEq
    "incomparable raw"
    Nothing
    (comparePV (Raw "foo") (parseEbuildVersion "1.0"))
