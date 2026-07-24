{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Assets (tests) where

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
import Test.Support
  ( dualArchGoCeilings,
    mkTestApplyEnv,
    mockEgencacheWriteMatching,
    unusedReleaseOps,
    unusedVendorOps,
    writeMatchingCacheFile,
    writeMatchingCachesForPackage,
  )
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
    "Assets"
    [ testCase "Token Resolver" testTokenResolver,
      testCase "Hash Bytes" testHashBytes,
      testCase "Sidecar Line" testSidecarLine,
      testCase "Deps Distfile Names" testDepsDistfileNames,
      testCase "Release Lookup" testReleaseLookup
    ]

testTokenResolver :: IO ()
testTokenResolver = do
  assertEq
    "env wins"
    (Just "from-env")
    (resolveGitHubTokenWith (Just "from-env") (Just "gh") (Just "cfg"))
  assertEq
    "gh token second"
    (Just "from-gh")
    (resolveGitHubTokenWith Nothing (Just "from-gh") (Just "cfg"))
  assertEq
    "config last"
    (Just "cfg")
    (resolveGitHubTokenWith Nothing Nothing (Just "cfg"))
  assertEq
    "empty env skipped"
    (Just "cfg")
    (resolveGitHubTokenWith (Just "") Nothing (Just "cfg"))
  assertEq
    "none"
    Nothing
    (resolveGitHubTokenWith Nothing Nothing Nothing)

testHashBytes :: IO ()
testHashBytes = do
  let d = hashBytes (encodeUtf8 "hello")
  -- SHA-256 of "hello"
  assertEq
    "sha256 hello"
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    (digestSHA256 d)
  assertTrue "sha512 nonempty" (T.length (digestSHA512 d) == 128)
  assertTrue "blake3 nonempty" (T.length (digestBLAKE3 d) == 64)

testSidecarLine :: IO ()
testSidecarLine = do
  assertEq
    "basename only"
    "abc  crush-0.76.0-vendor.tar.xz"
    (sidecarLine "abc" "/tmp/build/crush-0.76.0-vendor.tar.xz")

testDepsDistfileNames :: IO ()
testDepsDistfileNames = do
  assertEq
    "vendor"
    "crush-0.84.0-vendor.tar.xz"
    (vendorTarballName "crush" "0.84.0")
  assertEq
    "deps"
    "openspec-1.4.2-deps.tar.xz"
    (depsTarballName "openspec" "1.4.2")
  assertEq
    "crates"
    "mise-2026.7.5-crates.tar.xz"
    (cratesTarballName "mise" "2026.7.5")

------------------------------------------------------------------------
-- Release lookup / reuse / Manifest content-fix
------------------------------------------------------------------------

testReleaseLookup :: IO ()
testReleaseLookup = do
  let jsonFound =
        encodeUtf8
          "{\"id\":42,\"tag_name\":\"beads-1.0.5\",\"assets\":[{\"name\":\"beads-1.0.5-vendor.tar.xz\",\"browser_download_url\":\"https://example/a\"},{\"name\":\"other.bin\",\"browser_download_url\":\"https://example/b\"}]}"
      jsonWrongAsset =
        encodeUtf8
          "{\"id\":1,\"tag_name\":\"crush-0.84.0\",\"assets\":[{\"name\":\"notes.txt\",\"browser_download_url\":\"https://example/n\"}]}"
  info <- case eitherDecodeStrict' jsonFound of
    Left err -> do
      hPutStrLn stderr ("decode release json: " <> err)
      exitFailure
    Right val ->
      case parseMaybe parseReleaseInfo val of
        Nothing -> do
          hPutStrLn stderr "parseReleaseInfo failed"
          exitFailure
        Just i -> pure i
  assertEq "tag" "beads-1.0.5" (riTag info)
  assertEq
    "find asset"
    (Just "https://example/a")
    (raBrowserDownloadUrl <$> findAssetByName info "beads-1.0.5-vendor.tar.xz")
  assertEq
    "missing asset name"
    Nothing
    (findAssetByName info "nope.tar.xz")
  info2 <- case eitherDecodeStrict' jsonWrongAsset of
    Left err -> do
      hPutStrLn stderr ("decode release json2: " <> err)
      exitFailure
    Right val ->
      case parseMaybe parseReleaseInfo val of
        Nothing -> do
          hPutStrLn stderr "parseReleaseInfo2 failed"
          exitFailure
        Just i -> pure i
  assertEq
    "wrong asset name is nothing"
    Nothing
    (findAssetByName info2 "crush-0.84.0-vendor.tar.xz")
  -- Injectable ops: found / missing tag / missing asset name
  let opsFound =
        ReleaseOps
          { roGetReleaseByTag = \_ _ tag ->
              pure $
                if tag == "beads-1.0.5"
                  then Right (Just info)
                  else Right Nothing,
            roDownloadAsset = \_ _ -> pure (Right ()),
            roCreateReleaseWithAsset = \_ _ -> pure (Left "unused create")
          }
  found <- lookupNamedAsset opsFound "o" "r" "beads-1.0.5" "beads-1.0.5-vendor.tar.xz"
  assertEq "lookup found" (Right (Just "https://example/a")) found
  missingTag <- lookupNamedAsset opsFound "o" "r" "beads-9.9.9" "beads-1.0.5-vendor.tar.xz"
  assertEq "lookup missing tag" (Right Nothing) missingTag
  missingAsset <- lookupNamedAsset opsFound "o" "r" "beads-1.0.5" "wrong-name.tar.xz"
  assertEq "lookup missing asset" (Right Nothing) missingAsset

-- | Dual-arch Go ceilings helper for tests.
