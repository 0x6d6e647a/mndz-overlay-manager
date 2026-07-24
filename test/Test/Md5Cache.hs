{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Md5Cache (tests) where

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
  ( mkTestApplyEnv,
    mockEgencacheWriteMatching,
    unusedReleaseOps,
    unusedVendorOps,
    writeMatchingCacheFile,
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
    "Md5Cache"
    [ testCase "Md5Cache Layout Gate" testMd5CacheLayoutGate,
      testCase "Md5Cache Match Mismatch Missing" testMd5CacheMatchMismatchMissing,
      testCase "Md5Cache Multi Version Completeness" testMd5CacheMultiVersionCompleteness,
      testCase "Md5Cache Gencache Decisions" testMd5CacheGencacheDecisions,
      testCase "Md5Cache Gate Blocks Git Mv" testMd5CacheGateBlocksGitMv,
      testCase "Gencache Force And Mismatch" testGencacheForceAndMismatch
    ]

------------------------------------------------------------------------
-- md5-cache
------------------------------------------------------------------------

testMd5CacheLayoutGate :: IO ()
testMd5CacheLayoutGate =
  withSystemTempDirectory "mndz-layout-gate-" $ \tmp -> do
    createDirectoryIfMissing True (tmp </> "metadata")
    -- Missing layout.conf
    missing <- checkLayoutCacheFormats tmp
    case missing of
      Left msg ->
        assertTrue "missing mentions layout" ("layout.conf" `T.isInfixOf` msg)
      Right () -> do
        hPutStrLn stderr "expected layout gate failure for missing file"
        exitFailure
    -- Present without md5-dict
    TIO.writeFile (tmp </> "metadata" </> "layout.conf") "masters = gentoo\n"
    noFmt <- checkLayoutCacheFormats tmp
    case noFmt of
      Left msg ->
        assertTrue "mentions md5-dict" ("md5-dict" `T.isInfixOf` msg)
      Right () -> do
        hPutStrLn stderr "expected layout gate failure without cache-formats"
        exitFailure
    -- Explicit md5-dict
    TIO.writeFile
      (tmp </> "metadata" </> "layout.conf")
      "masters = gentoo\ncache-formats = md5-dict\n"
    ok <- checkLayoutCacheFormats tmp
    assertRight "layout ok" ok
    pure ()

testMd5CacheMatchMismatchMissing :: IO ()
testMd5CacheMatchMismatchMissing =
  withSystemTempDirectory "mndz-md5-status-" $ \tmp -> do
    let cat = "dev-lang" :: T.Text
        pn = "haskell" :: T.Text
        ver = "9.4.5" :: T.Text
        pkgDir = tmp </> T.unpack cat </> T.unpack pn
        ebuildPath = pkgDir </> "haskell-9.4.5.ebuild"
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath "EAPI=8\nDESCRIPTION=test\n"
    missing <- classifyVersionCache tmp cat pn ver ebuildPath
    assertEq "missing" VersionCacheMissing missing
    writeMatchingCacheFile tmp cat pn ver ebuildPath
    match <- classifyVersionCache tmp cat pn ver ebuildPath
    assertEq "match" VersionCacheMatch match
    let cpath = cacheFilePath tmp cat pn ver
    TIO.writeFile cpath "_md5_=00000000000000000000000000000000\n"
    mismatch <- classifyVersionCache tmp cat pn ver ebuildPath
    assertEq "mismatch" VersionCacheMismatch mismatch
    mField <- readCacheMd5Field cpath
    assertEq "read field" (Just "00000000000000000000000000000000") mField
    let conf =
          buildRepositoriesConfiguration
            "/var/db/repos/gentoo"
            "/tmp/work/mndz-overlay"
    assertTrue "repos conf has mndz" ("[mndz]" `T.isInfixOf` conf)
    assertTrue
      "repos conf location"
      ("location = /tmp/work/mndz-overlay" `T.isInfixOf` conf)

testMd5CacheMultiVersionCompleteness :: IO ()
testMd5CacheMultiVersionCompleteness =
  withSystemTempDirectory "mndz-md5-multi-" $ \tmp -> do
    let cat = "dev-util" :: T.Text
        pn = "crush" :: T.Text
        pkgDir = tmp </> T.unpack cat </> T.unpack pn
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> "crush-0.82.0.ebuild") "EAPI=8\nv1\n"
    TIO.writeFile (pkgDir </> "crush-0.84.0.ebuild") "EAPI=8\nv2\n"
    TIO.writeFile (pkgDir </> "crush-9999.ebuild") "EAPI=8\nlive\n"
    vers <- listNonLiveEbuildVersions pkgDir pn
    assertEq "two non-live" 2 (length vers)
    -- Only one cache entry
    writeMatchingCacheFile tmp cat pn "0.82.0" (pkgDir </> "crush-0.82.0.ebuild")
    inspected <- inspectPackageCache tmp cat pn pkgDir
    case inspected of
      Left (PackageCacheMissing ms) ->
        assertTrue "missing sibling" ("0.84.0" `elem` ms)
      other -> do
        hPutStrLn stderr ("expected PackageCacheMissing, got " <> show other)
        exitFailure
    writeMatchingCacheFile tmp cat pn "0.84.0" (pkgDir </> "crush-0.84.0.ebuild")
    ok <- inspectPackageCache tmp cat pn pkgDir
    assertRight "complete" ok
    pure ()

testMd5CacheGencacheDecisions :: IO ()
testMd5CacheGencacheDecisions = do
  assertEq
    "force always generate"
    GencacheGenerate
    (decideGencacheAction True (Right ()))
  assertEq
    "match skips"
    GencacheSkip
    (decideGencacheAction False (Right ()))
  assertEq
    "missing generates"
    GencacheGenerate
    (decideGencacheAction False (Left (PackageCacheMissing ["1.0"])))
  case decideGencacheAction False (Left (PackageCacheMismatch ["1.0"])) of
    GencacheError msg ->
      assertTrue "mentions force" ("--force" `T.isInfixOf` msg)
    other -> do
      hPutStrLn stderr ("expected GencacheError, got " <> show other)
      exitFailure
  let key = mkPackageKey "dev-util" "crush"
  assertTrue
    "gate error missing"
    ("gencache dev-util/crush" `T.isInfixOf` packageCacheGateError key (PackageCacheMissing []))
  assertTrue
    "gate error mismatch"
    ( "gencache --force dev-util/crush"
        `T.isInfixOf` packageCacheGateError key (PackageCacheMismatch [])
    )
  -- Apply unit pretty-printers mirror md5 gate / config hard-fail wording
  assertEq
    "apply unit md5 missing via ADT"
    (packageCacheGateError key (PackageCacheMissing []))
    (applyUnitErrorMessage (ApplyMd5CacheGate key (PackageCacheMissing [])))
  assertEq
    "dirty paths message"
    "involved paths are dirty (newest ebuild and/or Manifest)"
    (applyUnitErrorMessage ApplyDirtyInvolvedPaths)
  assertTrue
    "assets-path message identifiable"
    ("assets-path" `T.isInfixOf` applyUnitErrorMessage ApplyMissingAssetsPath)
  assertTrue
    "token message identifiable"
    ("token" `T.isInfixOf` applyUnitErrorMessage ApplyMissingGitHubToken)
  case applyUnitHardFail key ApplyMissingAssetsPath False True of
    ApplyHardFail k msg half assets -> do
      assertEq "hard-fail key" key k
      assertTrue "half unchanged" (not half)
      assertTrue "assets flag preserved" assets
      assertTrue "assets-path in hard-fail" ("assets-path" `T.isInfixOf` msg)
    other -> do
      hPutStrLn stderr ("expected ApplyHardFail, got: " <> show other)
      exitFailure

testMd5CacheGateBlocksGitMv :: IO ()
testMd5CacheGateBlocksGitMv =
  withSystemTempDirectory "mndz-gate-gitmv-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        pkgDir = overlayRoot </> "dev-util" </> "opencode-bin"
        oldName = "opencode-bin-1.0.ebuild"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "opencode-bin",
              pePN = "opencode-bin",
              peLocal = parseEbuildVersion "1.0",
              pePath = pkgDir </> oldName
            }
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> oldName) "EAPI=8\n"
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    -- Intentionally no md5-cache
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 1
    ceilingsCache <- newMVar Nothing
    let gitOps =
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
              poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    let env =
          env0
            { aeFetcher = \_ -> pure (Right (parseEbuildVersion "1.1")),
              aeEgencacheRunner = \_ -> pure (Left "egencache should not run")
            }
    outcomes <- applyPackagePhase1 env overlayRoot entry
    let key = peKey entry
    case outcomes of
      [ApplyHardFail _ msg half _] -> do
        assertTrue "mentions gencache" ("gencache" `T.isInfixOf` msg)
        assertEq
          "matches ApplyMd5CacheGate pretty"
          (applyUnitErrorMessage (ApplyMd5CacheGate key (PackageCacheMissing [])))
          msg
        assertTrue "not half-applied" (not half)
        stillThere <- doesFileExist (pkgDir </> oldName)
        assertTrue "ebuild not renamed" stillThere
      other -> do
        hPutStrLn stderr ("expected gate hard-fail, got: " <> show other)
        exitFailure

testGencacheForceAndMismatch :: IO ()
testGencacheForceAndMismatch =
  withSystemTempDirectory "mndz-gencache-" $ \tmp -> do
    let overlayRoot = tmp
        cat = "dev-lang" :: T.Text
        pn = "haskell" :: T.Text
        pkgDir = overlayRoot </> T.unpack cat </> T.unpack pn
        ebuildPath = pkgDir </> "haskell-9.4.5.ebuild"
        key = mkPackageKey cat pn
    createDirectoryIfMissing True pkgDir
    TIO.writeFile ebuildPath "EAPI=8\n"
    -- Bootstrap missing without force → generates
    egCalls <- newIORef (0 :: Int)
    commitCalls <- newIORef (0 :: Int)
    let runner req = do
          atomicModifyIORef' egCalls (\n -> (n + 1, ()))
          mockEgencacheWriteMatching req
        gitOps dirty =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right dirty),
              goAddAndCommit = \_ _ _ -> do
                atomicModifyIORef' commitCalls (\n -> (n + 1, ()))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
    r1 <-
      gencachePackages
        runner
        (gitOps True)
        overlayRoot
        [key]
        False
        (Just 1)
    case r1 of
      Right (Just _) -> pure ()
      other -> do
        hPutStrLn stderr ("expected commit after generate, got " <> show other)
        exitFailure
    nEg1 <- readIORef egCalls
    assertEq "egencache once for missing" 1 nEg1
    -- Now matching without force → skip, no dirty commit
    writeIORef egCalls 0
    writeIORef commitCalls 0
    r2 <-
      gencachePackages
        runner
        (gitOps False)
        overlayRoot
        [key]
        False
        Nothing
    assertEq "no commit when match" (Right Nothing) r2
    nEg2 <- readIORef egCalls
    assertEq "skipped egencache when match" 0 nEg2
    -- Mismatch without force → error
    let cpath = cacheFilePath overlayRoot cat pn "9.4.5"
    TIO.writeFile cpath "_md5_=ffffffffffffffffffffffffffffffff\n"
    r3 <-
      gencachePackages
        runner
        (gitOps False)
        overlayRoot
        [key]
        False
        Nothing
    case r3 of
      Left msg -> assertTrue "mismatch force" ("--force" `T.isInfixOf` msg)
      Right _ -> do
        hPutStrLn stderr "expected mismatch hard-fail without force"
        exitFailure
    -- Force regenerates mismatch
    writeIORef egCalls 0
    r4 <-
      gencachePackages
        runner
        (gitOps True)
        overlayRoot
        [key]
        True
        Nothing
    case r4 of
      Right (Just _) -> pure ()
      other -> do
        hPutStrLn stderr ("expected force commit, got " <> show other)
        exitFailure
    nEg4 <- readIORef egCalls
    assertEq "force ran egencache" 1 nEg4
    -- Injected runner args include overlay location in request
    reqRef <- newIORef ([] :: [EgencacheRequest])
    let captureRunner req = do
          atomicModifyIORef' reqRef (\rs -> (req : rs, ()))
          pure (Right ())
    _ <-
      gencachePackages
        captureRunner
        (gitOps False)
        "/tmp/work/mndz-overlay"
        [key]
        True
        (Just 2)
    reqs <- readIORef reqRef
    case reqs of
      (r : _) -> do
        assertEq "atom" ["dev-lang/haskell"] (erAtoms r)
        assertEq "overlay" "/tmp/work/mndz-overlay" (erOverlayRoot r)
        assertEq "jobs" (Just 2) (erJobs r)
      [] -> do
        hPutStrLn stderr "expected captured egencache request"
        exitFailure
