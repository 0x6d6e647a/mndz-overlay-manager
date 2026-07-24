{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Targets (tests) where

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
    "Targets"
    [ testCase "Target Resolution" testTargetResolution
    ]

------------------------------------------------------------------------
-- Targets / preflight / apply helpers
------------------------------------------------------------------------

sampleEntries :: [PackageEntry]
sampleEntries =
  [ PackageEntry
      { peKey = PackageKey "dev-lang/deno-bin",
        pePN = "deno-bin",
        peLocal = parseEbuildVersion "2.9.2",
        pePath = "/overlay/dev-lang/deno-bin/deno-bin-2.9.2.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "dev-util/opencode-bin",
        pePN = "opencode-bin",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/dev-util/opencode-bin/opencode-bin-1.0.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "bar/foo",
        pePN = "foo",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/bar/foo/foo-1.0.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "baz/foo",
        pePN = "foo",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/baz/foo/foo-1.0.ebuild"
      }
  ]

testTargetResolution :: IO ()
testTargetResolution = do
  -- category/package exact key
  assertEq
    "full key"
    (Right (PackageKey "dev-lang/deno-bin"))
    (resolveTargetToken sampleEntries "dev-lang/deno-bin")
  -- bare package name (unambiguous)
  assertEq
    "bare unique"
    (Right (PackageKey "dev-util/opencode-bin"))
    (resolveTargetToken sampleEntries "opencode-bin")
  -- ambiguous bare name hard-fails
  case resolveTargetToken sampleEntries "foo" of
    Left (AmbiguousPackage "foo" keys) ->
      assertEq
        "ambiguous keys"
        (sort (map packageKeyText keys))
        ["bar/foo", "baz/foo"]
    other -> do
      hPutStrLn stderr $ "expected ambiguous foo, got " <> show other
      exitFailure
  -- zero tokens = full inventory (outdated/update/gencache)
  case resolveTargets sampleEntries [] of
    Right keys -> do
      assertEq "all keys count" 4 (length keys)
      assertEq
        "all keys set"
        (sort (map packageKeyText keys))
        ["bar/foo", "baz/foo", "dev-lang/deno-bin", "dev-util/opencode-bin"]
    Left e -> do
      hPutStrLn stderr $ "all targets: " <> show e
      exitFailure
  -- cat/pn and bare pn together; selected set only those keys
  case resolveTargets sampleEntries ["dev-lang/deno-bin", "opencode-bin"] of
    Right keys -> do
      assertEq
        "selected keys"
        (sort (map packageKeyText keys))
        ["dev-lang/deno-bin", "dev-util/opencode-bin"]
      let selected = [e | e <- sampleEntries, peKey e `elem` keys]
      assertEq "filtered entry count" 2 (length selected)
      assertTrue
        "unselected packages excluded"
        (all (\e -> pePN e /= "foo") selected)
    Left e -> do
      hPutStrLn stderr $ "selected targets: " <> show e
      exitFailure
  -- unknown package hard-fails (alone or with valid tokens)
  case resolveTargets sampleEntries ["missing/pkg"] of
    Left errs ->
      assertTrue "unknown alone" (any isUnknown errs)
    Right _ -> do
      hPutStrLn stderr "expected unknown missing/pkg"
      exitFailure
  case resolveTargets sampleEntries ["deno-bin", "nope"] of
    Left errs ->
      assertTrue "has unknown" (any isUnknown errs)
    Right _ -> do
      hPutStrLn stderr "expected unknown error"
      exitFailure
  -- ambiguous bare name in multi-token resolve hard-fails
  case resolveTargets sampleEntries ["foo"] of
    Left errs ->
      assertTrue "has ambiguous" (any isAmbiguous errs)
    Right _ -> do
      hPutStrLn stderr "expected ambiguous foo"
      exitFailure
  where
    isUnknown (UnknownPackage _) = True
    isUnknown _ = False
    isAmbiguous (AmbiguousPackage _ _) = True
    isAmbiguous _ = False
