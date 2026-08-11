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
import Config.Types (CheckCacheTtl (..), OverlayConfig (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, race)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forever, unless, void, when)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy.Char8 qualified as L8
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
import Network.HTTP.Client (newManager, path, queryString, requestHeaders)
import Network.HTTP.Client.TLS (tlsManagerSettings)
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
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse)
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
import Update.Check
  ( PackageEntry (..),
    checkPackage,
    groupByPackage,
    groupNewest,
    statusFromCompare,
  )
import Update.CheckCache (openCheckCache)
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
import Update.GitHub
  ( fetchGitHubWithHttpLbs,
    listGitHubVersionsWithHttpLbs,
    stripAndParse,
  )
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
import Update.Go.ModFetch
  ( GoModKey (..),
    fetchGoModAtTagHttpLbs,
    withGoModCache,
  )
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
import Update.Http (fetchHttpWith, fetchHttpWithHttp, tryHttp)
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
import Update.Npm (fetchNpmWith, fetchNpmWithHttp)
import Update.Npm.Cache
  ( fetchNpmEnginesNodeHttpLbs,
    listNpmVersionsHttpLbs,
    productionNpmCacheOps,
  )
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
    ecosystemIsBun,
    ecosystemIsCargo,
    ecosystemIsGo,
    ecosystemIsNpm,
    ecosystemIsSbcl,
    mkPackageKey,
    packageKeyText,
    splitPackageKey,
    techniqueNeedsAssets,
  )

tests :: TestTree
tests =
  testGroup
    "Policy"
    [ testCase "Hardcoded Grok" testHardcodedGrok,
      testCase "Policy Classification" testPolicyClassification,
      testCase "Resolve Map Only" testResolveMapOnly,
      testCase "Group Newest" testGroupNewest,
      testCase "Check Package Product Statuses" testCheckPackageProductStatuses,
      testCase "Status From Compare" testStatusFromCompare,
      testCase "Group By Package" testGroupByPackage,
      testCase "Try Http" testTryHttp,
      testCase "Fetch Http Wrong Source" testFetchHttpWrongSource,
      testCase "Fetch Http With Fake" testFetchHttpWithFake,
      testCase "Fetch Npm Wrong Source" testFetchNpmWrongSource,
      testCase "Fetch Npm With Fake" testFetchNpmWithFake,
      testCase "Fetch GitHub With Fake" testFetchGitHubWithFake,
      testCase "List GitHub Versions With Fake" testListGitHubVersionsWithFake,
      testCase "List GitHub Versions Pagination" testListGitHubVersionsPagination,
      testCase "GitHub Auth Header" testGitHubAuthHeader,
      testCase "List Npm Versions With Fake" testListNpmVersionsWithFake,
      testCase "Fetch Npm Engines With Fake" testFetchNpmEnginesWithFake,
      testCase "Fetch GoMod At Tag With Fake" testFetchGoModAtTagWithFake,
      testCase "Types Helper Predicates" testTypesHelperPredicates
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
  case lookupPolicy (PackageKey "dev-util/opencode") of
    Just (PackagePolicy (GitHub "anomalyco" "opencode" "v") (DepsAndAssets Bun)) ->
      pure ()
    other -> do
      hPutStrLn stderr $ "opencode technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/opencode-bin") of
    Nothing -> pure ()
    other -> do
      hPutStrLn stderr $ "opencode-bin should be absent: " <> show other
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
  case lookupPolicy (PackageKey "dev-util/autolith") of
    Just
      ( PackagePolicy
          (GitHub "luciusmagn" "autolith" "v")
          (DepsAndAssets Sbcl)
        ) ->
        pure ()
    other -> do
      hPutStrLn stderr $ "autolith technique: " <> show other
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
  case lookupPolicy (PackageKey "dev-db/badger") of
    Just
      ( PackagePolicy
          (GitHub "dgraph-io" "badger" "v")
          (DepsAndAssets (Go Nothing))
        ) ->
        pure ()
    other -> do
      hPutStrLn stderr $ "badger technique: " <> show other
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

-- | Drive real 'checkPackage' (resolveSource + statusFromCompare) for each status.
testCheckPackageProductStatuses :: IO ()
testCheckPackageProductStatuses = do
  let mk cat pn ver =
        PackageEntry
          { peKey = mkPackageKey cat pn,
            pePN = pn,
            peLocal = parseEbuildVersion ver,
            pePath = "/tmp/" <> T.unpack pn <> ".ebuild"
          }
      fetchOutdated _ = pure (Right (parseEbuildVersion "2.1.10"))
      fetchOk _ = pure (Right (parseEbuildVersion "1.0.0"))
      fetchAhead _ = pure (Right (parseEbuildVersion "1.5.0"))
      fetchFail _ = pure (Left "network down")
      fetchUnused _ = pure (Left "should not fetch")
  (cache, _) <- openCheckCache CacheDisabled False "/tmp"
  outdated <- checkPackage fetchOutdated cache (mk "dev-lang" "deno-bin" "2.1.6") []
  ok <- checkPackage fetchOk cache (mk "dev-lang" "deno-bin" "1.0.0") []
  ahead <- checkPackage fetchAhead cache (mk "dev-lang" "bun-bin" "2.0.0") []
  unconf <- checkPackage fetchUnused cache (mk "dev-lang" "haskell" "9.6.1") []
  err <- checkPackage fetchFail cache (mk "dev-lang" "deno-bin" "1.0.0") []
  let statuses = map reportStatus [outdated, ok, ahead, unconf, err]
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

testStatusFromCompare :: IO ()
testStatusFromCompare = do
  let local = parseEbuildVersion "1.0.0"
      newer = parseEbuildVersion "1.1.0"
      older = parseEbuildVersion "0.9.0"
      raw = parseEbuildVersion "not-a-version"
  case statusFromCompare local newer of
    Outdated [line] -> do
      assertEq "outdated from" local (olFrom line)
      assertEq "outdated to" newer (olTo line)
    other -> do
      hPutStrLn stderr $ "expected Outdated, got " <> show other
      exitFailure
  case statusFromCompare local local of
    Ok v -> assertEq "ok local" local v
    other -> do
      hPutStrLn stderr $ "expected Ok, got " <> show other
      exitFailure
  case statusFromCompare local older of
    Ahead a b -> do
      assertEq "ahead local" local a
      assertEq "ahead remote" older b
    other -> do
      hPutStrLn stderr $ "expected Ahead, got " <> show other
      exitFailure
  case statusFromCompare local raw of
    FetchError msg ->
      assertTrue "incomparable message" ("incomparable" `T.isInfixOf` msg)
    other -> do
      hPutStrLn stderr $ "expected FetchError, got " <> show other
      exitFailure

testGroupByPackage :: IO ()
testGroupByPackage = do
  let ebuilds =
        [ Ebuild "dev-lang" "haskell" "9.4.5" "/tmp/haskell-9.4.5.ebuild",
          Ebuild "dev-lang" "haskell" "9.6.1" "/tmp/haskell-9.6.1.ebuild",
          Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim.ebuild"
        ]
      byPkg = groupByPackage ebuilds
      haskellKey = PackageKey "dev-lang/haskell"
      vimKey = PackageKey "app-editors/vim"
  assertEq "two packages" 2 (Map.size byPkg)
  case Map.lookup haskellKey byPkg of
    Just hs -> assertEq "haskell count" 2 (length hs)
    Nothing -> do
      hPutStrLn stderr "missing haskell group"
      exitFailure
  case Map.lookup vimKey byPkg of
    Just vs -> assertEq "vim count" 1 (length vs)
    Nothing -> do
      hPutStrLn stderr "missing vim group"
      exitFailure
  -- groupNewest keeps newest PV per package (covers pure edges with revisions).
  let withRev =
        [ Ebuild "dev-util" "pkg" "1.0" "/tmp/pkg-1.0.ebuild",
          Ebuild "dev-util" "pkg" "1.0-r1" "/tmp/pkg-1.0-r1.ebuild",
          Ebuild "dev-util" "pkg" "1.0-r2" "/tmp/pkg-1.0-r2.ebuild"
        ]
  case groupNewest withRev of
    [entry] -> do
      assertEq "newest rev key" (PackageKey "dev-util/pkg") (peKey entry)
      assertEq "newest rev" (Numeric [1, 0] (Just 2)) (peLocal entry)
      assertEq "newest path" "/tmp/pkg-1.0-r2.ebuild" (pePath entry)
    other -> do
      hPutStrLn stderr $ "expected one groupNewest entry, got " <> show other
      exitFailure

testTryHttp :: IO ()
testTryHttp = do
  ok <- tryHttp (pure (42 :: Int))
  assertEq "success" (Right 42) ok
  err <- tryHttp (throwIO (userError "boom") :: IO Int)
  case err of
    Left msg -> assertTrue "exception message" ("boom" `T.isInfixOf` msg)
    Right n -> do
      hPutStrLn stderr $ "expected Left, got Right " <> show n
      exitFailure

testFetchHttpWrongSource :: IO ()
testFetchHttpWrongSource = do
  mgr <- newManager tlsManagerSettings
  err <- fetchHttpWith mgr (Npm "left-pad")
  case err of
    Left msg -> assertTrue "not Http source" ("not an Http source" `T.isInfixOf` msg)
    Right v -> do
      hPutStrLn stderr $ "expected Left, got Right " <> show v
      exitFailure
  errGh <- fetchHttpWith mgr (GitHub "o" "r" "v")
  case errGh of
    Left msg -> assertTrue "github not http" ("not an Http source" `T.isInfixOf` msg)
    Right v -> do
      hPutStrLn stderr $ "expected Left, got Right " <> show v
      exitFailure

testFetchHttpWithFake :: IO ()
testFetchHttpWithFake = do
  let httpOk _ = pure (Right (fakeResponse 200 "1.2.3\n"))
      httpEmpty _ = pure (Right (fakeResponse 200 "  \n"))
      http404 _ = pure (Right (fakeResponse 404 "missing"))
      httpNet _ = pure (Left "timeout")
  ver <- assertRight "http ok" =<< fetchHttpWithHttp httpOk (Http "https://example.com/v" Nothing)
  assertEq "parsed version" (parseEbuildVersion "1.2.3") ver
  errEmpty <-
    assertLeft "empty body"
      =<< fetchHttpWithHttp httpEmpty (Http "https://example.com/v" Nothing)
  assertTrue "empty msg" ("empty version body" `T.isInfixOf` errEmpty)
  err404 <-
    assertLeft "404"
      =<< fetchHttpWithHttp http404 (Http "https://example.com/v" Nothing)
  assertTrue "http 404" ("HTTP 404" `T.isInfixOf` err404)
  errNet <-
    assertLeft "net"
      =<< fetchHttpWithHttp httpNet (Http "https://example.com/v" Nothing)
  assertEq "timeout" "timeout" errNet
  -- primary fails (500), fallback succeeds
  nRef <- newIORef (0 :: Int)
  let httpSeq _ = do
        n <- atomicModifyIORef' nRef (\i -> (i + 1, i))
        pure $
          Right $
            if n == 0
              then fakeResponse 500 "primary fail"
              else fakeResponse 200 "3.1.0"
  verFb <-
    assertRight "fallback"
      =<< fetchHttpWithHttp
        httpSeq
        (Http "https://example.com/primary" (Just "https://example.com/fallback"))
  assertEq "fallback ver" (parseEbuildVersion "3.1.0") verFb
  -- primary fails and no fallback
  let httpOnce _ = pure (Right (fakeResponse 500 "only"))
  errOnly <-
    assertLeft "no fallback"
      =<< fetchHttpWithHttp httpOnce (Http "https://example.com/v" Nothing)
  assertTrue "500" ("HTTP 500" `T.isInfixOf` errOnly)

testFetchNpmWrongSource :: IO ()
testFetchNpmWrongSource = do
  mgr <- newManager tlsManagerSettings
  err <- fetchNpmWith mgr (Http "https://example.com/version" Nothing)
  case err of
    Left msg -> assertTrue "not Npm source" ("not an Npm source" `T.isInfixOf` msg)
    Right v -> do
      hPutStrLn stderr $ "expected Left, got Right " <> show v
      exitFailure
  errGh <- fetchNpmWith mgr (GitHub "o" "r" "v")
  case errGh of
    Left msg -> assertTrue "github not npm" ("not an Npm source" `T.isInfixOf` msg)
    Right v -> do
      hPutStrLn stderr $ "expected Left, got Right " <> show v
      exitFailure

testFetchNpmWithFake :: IO ()
testFetchNpmWithFake = do
  let httpOk _ = pure (Right (fakeResponse 200 "{\"version\":\"4.5.6\"}"))
      httpBadJson _ = pure (Right (fakeResponse 200 "{nope"))
      httpNoVer _ = pure (Right (fakeResponse 200 "{\"name\":\"x\"}"))
      http404 _ = pure (Right (fakeResponse 404 "{}"))
      httpNet _ = pure (Left "npm net")
  ver <- assertRight "npm ok" =<< fetchNpmWithHttp httpOk (Npm "left-pad")
  assertEq "npm ver" (parseEbuildVersion "4.5.6") ver
  errJson <- assertLeft "bad json" =<< fetchNpmWithHttp httpBadJson (Npm "pkg")
  assertTrue "json err" (not (T.null errJson))
  errField <- assertLeft "no version" =<< fetchNpmWithHttp httpNoVer (Npm "pkg")
  assertTrue "version field" ("version field" `T.isInfixOf` errField)
  err404 <- assertLeft "404" =<< fetchNpmWithHttp http404 (Npm "pkg")
  assertTrue "http" ("HTTP 404" `T.isInfixOf` err404)
  errNet <- assertLeft "net" =<< fetchNpmWithHttp httpNet (Npm "pkg")
  assertEq "net" "npm net" errNet

------------------------------------------------------------------------
-- Update.GitHub Fake-HTTP (registry-http-fakes)
------------------------------------------------------------------------

testFetchGitHubWithFake :: IO ()
testFetchGitHubWithFake = do
  -- Latest release success
  let httpRelease _ =
        pure (Right (fakeResponse 200 "{\"tag_name\":\"v2.1.0\"}"))
  verRel <-
    assertRight "release ok"
      =<< fetchGitHubWithHttpLbs httpRelease Nothing (GitHub "o" "r" "v")
  assertEq "release ver" (parseEbuildVersion "2.1.0") verRel

  -- Release fails → max tag fallback
  let httpFallback req =
        pure $
          Right $
            if "releases" `BSC.isInfixOf` path req
              then fakeResponse 404 "missing"
              else
                fakeResponse
                  200
                  "[{\"name\":\"v1.0.0\"},{\"name\":\"v1.2.0\"},{\"name\":\"other\"}]"
  verFb <-
    assertRight "tag fallback"
      =<< fetchGitHubWithHttpLbs httpFallback Nothing (GitHub "o" "r" "v")
  assertEq "max tag" (parseEbuildVersion "1.2.0") verFb

  -- Non-GitHub source
  errSrc <-
    assertLeft "not github"
      =<< fetchGitHubWithHttpLbs (\_ -> pure (Right (fakeResponse 200 "{}"))) Nothing (Npm "pkg")
  assertTrue "not github msg" ("not a GitHub source" `T.isInfixOf` errSrc)

  -- HTTP error on release and tags
  let http500 _ = pure (Right (fakeResponse 500 "boom"))
  err500 <-
    assertLeft "http 500"
      =<< fetchGitHubWithHttpLbs http500 Nothing (GitHub "o" "r" "v")
  assertTrue "500 msg" ("HTTP 500" `T.isInfixOf` err500)

  -- Network error on release; tags also fail
  let httpNet _ = pure (Left "gh net")
  errNet <-
    assertLeft "net"
      =<< fetchGitHubWithHttpLbs httpNet Nothing (GitHub "o" "r" "v")
  assertEq "net" "gh net" errNet

  -- Bad JSON on release → tags path with bad JSON
  let httpBad _ = pure (Right (fakeResponse 200 "{nope"))
  errBad <-
    assertLeft "bad json"
      =<< fetchGitHubWithHttpLbs httpBad Nothing (GitHub "o" "r" "v")
  assertTrue "decode err" (not (T.null errBad))

  -- Release 404, tags empty comparable set
  let httpNoTags req =
        pure $
          Right $
            if "releases" `BSC.isInfixOf` path req
              then fakeResponse 404 ""
              else fakeResponse 200 "[{\"name\":\"unrelated\"}]"
  errNo <-
    assertLeft "no tags"
      =<< fetchGitHubWithHttpLbs httpNoTags Nothing (GitHub "o" "r" "v")
  assertTrue "no comparable" ("no comparable tags" `T.isInfixOf` errNo)

testListGitHubVersionsWithFake :: IO ()
testListGitHubVersionsWithFake = do
  let httpOk _ =
        pure
          ( Right
              ( fakeResponse
                  200
                  "[{\"name\":\"v1.0.0\"},{\"name\":\"v2.0.0\"},{\"name\":\"skip-me\"}]"
              )
          )
  vers <-
    assertRight "list ok"
      =<< listGitHubVersionsWithHttpLbs httpOk Nothing (GitHub "o" "r" "v")
  assertEq
    "newest first"
    [parseEbuildVersion "2.0.0", parseEbuildVersion "1.0.0"]
    vers

  -- Non-GitHub
  errSrc <-
    assertLeft "not github"
      =<< listGitHubVersionsWithHttpLbs
        (\_ -> pure (Right (fakeResponse 200 "[]")))
        Nothing
        (Http "https://example.com/v" Nothing)
  assertTrue "not github msg" ("not a GitHub source" `T.isInfixOf` errSrc)

  -- HTTP error
  let http404 _ = pure (Right (fakeResponse 404 "no"))
  err404 <-
    assertLeft "404"
      =<< listGitHubVersionsWithHttpLbs http404 Nothing (GitHub "o" "r" "v")
  assertTrue "http 404" ("HTTP 404" `T.isInfixOf` err404)

  -- Network
  let httpNet _ = pure (Left "list net")
  errNet <-
    assertLeft "net"
      =<< listGitHubVersionsWithHttpLbs httpNet Nothing (GitHub "o" "r" "v")
  assertEq "net" "list net" errNet

  -- Bad JSON / parse failure
  let httpBad _ = pure (Right (fakeResponse 200 "{\"not\":\"array\"}"))
  errBad <-
    assertLeft "bad"
      =<< listGitHubVersionsWithHttpLbs httpBad Nothing (GitHub "o" "r" "v")
  assertTrue "parse tags" ("could not parse tags list" `T.isInfixOf` errBad)

testListGitHubVersionsPagination :: IO ()
testListGitHubVersionsPagination = do
  pagesRef <- newIORef ([] :: [BSC.ByteString])
  let -- Full page (100 tags) then short page (1 tag)
      page1Tags =
        "["
          <> T.intercalate
            ","
            [ "{\"name\":\"v0.0." <> T.pack (show n) <> "\"}"
            | n <- [1 :: Int .. 100]
            ]
          <> "]"
      page2Tags = "[{\"name\":\"v9.9.9\"}]"
      httpPages req = do
        let qs = queryString req
        atomicModifyIORef' pagesRef (\xs -> (xs <> [qs], ()))
        pure $
          Right $
            if "page=2" `BSC.isInfixOf` qs
              then fakeResponse 200 (L8.pack (T.unpack page2Tags))
              else fakeResponse 200 (L8.pack (T.unpack page1Tags))
  vers <-
    assertRight "paginate"
      =<< listGitHubVersionsWithHttpLbs httpPages Nothing (GitHub "o" "r" "v")
  pages <- readIORef pagesRef
  assertEq "two pages requested" 2 (length pages)
  assertTrue "page1 query" (any ("page=1" `BSC.isInfixOf`) pages)
  assertTrue "page2 query" (any ("page=2" `BSC.isInfixOf`) pages)
  -- Newest-first: v9.9.9 first
  case vers of
    (newest : _) -> assertEq "newest is 9.9.9" (parseEbuildVersion "9.9.9") newest
    [] -> assertTrue "expected versions" False
  assertEq "101 versions" 101 (length vers)

testGitHubAuthHeader :: IO ()
testGitHubAuthHeader = do
  -- With token
  hasBearerRef <- newIORef False
  let httpTok req = do
        let hasBearer =
              any
                ( \(k, v) ->
                    k == "Authorization" && "Bearer secret-token" `BSC.isInfixOf` v
                )
                (requestHeaders req)
        when hasBearer $ writeIORef hasBearerRef True
        pure (Right (fakeResponse 200 "{\"tag_name\":\"v1.0.0\"}"))
  void $
    assertRight "with token"
      =<< fetchGitHubWithHttpLbs httpTok (Just "secret-token") (GitHub "o" "r" "v")
  hasBearer <- readIORef hasBearerRef
  assertTrue "has bearer" hasBearer

  -- Without token / empty token: no Authorization
  noAuthRef <- newIORef True
  let httpNo req = do
        let hasAuth = any (\(k, _) -> k == "Authorization") (requestHeaders req)
        when hasAuth $ writeIORef noAuthRef False
        pure (Right (fakeResponse 200 "{\"tag_name\":\"v1.0.0\"}"))
  void $
    assertRight "no token"
      =<< fetchGitHubWithHttpLbs httpNo Nothing (GitHub "o" "r" "v")
  void $
    assertRight "empty token"
      =<< fetchGitHubWithHttpLbs httpNo (Just "") (GitHub "o" "r" "v")
  noAuth <- readIORef noAuthRef
  assertTrue "no Authorization header" noAuth

------------------------------------------------------------------------
-- Update.Npm.Cache registry Fake-HTTP
------------------------------------------------------------------------

testListNpmVersionsWithFake :: IO ()
testListNpmVersionsWithFake = do
  let packument =
        "{\"versions\":{\"1.0.0\":{},\"2.0.0\":{},\"1.5.0\":{}}}"
      httpOk _ = pure (Right (fakeResponse 200 packument))
  vers <- assertRight "list ok" =<< listNpmVersionsHttpLbs httpOk "left-pad"
  assertEq
    "newest first"
    [ parseEbuildVersion "2.0.0",
      parseEbuildVersion "1.5.0",
      parseEbuildVersion "1.0.0"
    ]
    vers

  let http404 _ = pure (Right (fakeResponse 404 "{}"))
  err404 <- assertLeft "404" =<< listNpmVersionsHttpLbs http404 "missing"
  assertTrue "http 404" ("HTTP 404" `T.isInfixOf` err404)

  let httpBad _ = pure (Right (fakeResponse 200 "{nope"))
  errBad <- assertLeft "bad json" =<< listNpmVersionsHttpLbs httpBad "pkg"
  assertTrue "decode" (not (T.null errBad))

  let httpNoVers _ = pure (Right (fakeResponse 200 "{\"name\":\"x\"}"))
  errField <- assertLeft "no versions" =<< listNpmVersionsHttpLbs httpNoVers "pkg"
  assertTrue "parse versions" ("could not parse npm versions" `T.isInfixOf` errField)

  let httpNet _ = pure (Left "npm list net")
  errNet <- assertLeft "net" =<< listNpmVersionsHttpLbs httpNet "pkg"
  assertEq "net" "npm list net" errNet

testFetchNpmEnginesWithFake :: IO ()
testFetchNpmEnginesWithFake = do
  let httpOk _ =
        pure
          ( Right
              ( fakeResponse
                  200
                  "{\"engines\":{\"node\":\">=20.19.0\"}}"
              )
          )
  eng <-
    assertRight "engines ok"
      =<< fetchNpmEnginesNodeHttpLbs httpOk "pkg" "1.0.0"
  assertEq "min node" "20.19.0" eng

  let httpMissing _ = pure (Right (fakeResponse 200 "{\"name\":\"pkg\"}"))
  errMiss <-
    assertLeft "missing engines"
      =<< fetchNpmEnginesNodeHttpLbs httpMissing "pkg" "1.0.0"
  assertTrue "missing msg" ("missing engines.node" `T.isInfixOf` errMiss)

  let httpBadEng _ =
        pure
          ( Right
              ( fakeResponse
                  200
                  "{\"engines\":{\"node\":\"^18 || >=20\"}}"
              )
          )
  errUnp <-
    assertLeft "unparseable"
      =<< fetchNpmEnginesNodeHttpLbs httpBadEng "pkg" "1.0.0"
  assertTrue "unparseable msg" ("unparseable engines.node" `T.isInfixOf` errUnp)

  let http404 _ = pure (Right (fakeResponse 404 "{}"))
  err404 <-
    assertLeft "404"
      =<< fetchNpmEnginesNodeHttpLbs http404 "pkg" "9.9.9"
  assertTrue "http 404" ("HTTP 404" `T.isInfixOf` err404)

  let httpNet _ = pure (Left "engines net")
  errNet <-
    assertLeft "net"
      =<< fetchNpmEnginesNodeHttpLbs httpNet "pkg" "1.0.0"
  assertEq "net" "engines net" errNet

  let httpBadJson _ = pure (Right (fakeResponse 200 "{"))
  errJson <-
    assertLeft "bad json"
      =<< fetchNpmEnginesNodeHttpLbs httpBadJson "pkg" "1.0.0"
  assertTrue "decode" (not (T.null errJson))

------------------------------------------------------------------------
-- Update.Go.ModFetch Fake-HTTP
------------------------------------------------------------------------

testFetchGoModAtTagWithFake :: IO ()
testFetchGoModAtTagWithFake = do
  let key =
        GoModKey
          { gmkOwner = "o",
            gmkRepo = "r",
            gmkTag = "v1.2.3",
            gmkSubdir = Nothing
          }
      keySub =
        key {gmkSubdir = Just "cmd/tool"}
      body = "module example.com/r\n\ngo 1.22.0\n"
      httpOk _ = pure (Right (fakeResponse 200 (L8.pack body)))
  text <- assertRight "gomod ok" =<< fetchGoModAtTagHttpLbs httpOk Nothing key
  assertEq "body" (T.pack body) text

  -- Subdir path is requested
  pathRef <- newIORef ("" :: BSC.ByteString)
  let httpSub req = do
        writeIORef pathRef (path req)
        pure (Right (fakeResponse 200 "module x\ngo 1.21\n"))
  void $
    assertRight "subdir"
      =<< fetchGoModAtTagHttpLbs httpSub Nothing keySub
  p <- readIORef pathRef
  assertTrue "subdir in path" ("cmd/tool/go.mod" `BSC.isInfixOf` p)

  -- HTTP error
  let http404 _ = pure (Right (fakeResponse 404 "missing"))
  err404 <- assertLeft "404" =<< fetchGoModAtTagHttpLbs http404 Nothing key
  assertTrue "http 404" ("HTTP 404" `T.isInfixOf` err404)

  -- Network
  let httpNet _ = pure (Left "gomod net")
  errNet <- assertLeft "net" =<< fetchGoModAtTagHttpLbs httpNet Nothing key
  assertEq "net" "gomod net" errNet

  -- Token present / absent
  tokHdrs <- newIORef False
  noTokHdrs <- newIORef True
  let httpTok req = do
        let hasAuth =
              any
                ( \(k, v) ->
                    k == "Authorization" && "Bearer t0k" `BSC.isInfixOf` v
                )
                (requestHeaders req)
        writeIORef tokHdrs hasAuth
        pure (Right (fakeResponse 200 "go 1.20\n"))
      httpNoTok req = do
        let hasAuth = any (\(k, _) -> k == "Authorization") (requestHeaders req)
        when hasAuth $ writeIORef noTokHdrs False
        pure (Right (fakeResponse 200 "go 1.20\n"))
  void $
    assertRight "with token"
      =<< fetchGoModAtTagHttpLbs httpTok (Just "t0k") key
  void $
    assertRight "no token"
      =<< fetchGoModAtTagHttpLbs httpNoTok Nothing key
  void $
    assertRight "empty token"
      =<< fetchGoModAtTagHttpLbs httpNoTok (Just "") key
  hasTok <- readIORef tokHdrs
  noTok <- readIORef noTokHdrs
  assertTrue "bearer set" hasTok
  assertTrue "no auth when absent" noTok

------------------------------------------------------------------------
-- Update.Types pure helpers
------------------------------------------------------------------------

testTypesHelperPredicates :: IO ()
testTypesHelperPredicates = do
  -- techniqueNeedsAssets
  assertTrue "deps go needs assets" (techniqueNeedsAssets (DepsAndAssets (Go Nothing)))
  assertTrue "deps npm needs assets" (techniqueNeedsAssets (DepsAndAssets NpmEco))
  assertTrue
    "deps cargo needs assets"
    (techniqueNeedsAssets (DepsAndAssets (Cargo Nothing Nothing)))
  assertTrue "deps sbcl needs assets" (techniqueNeedsAssets (DepsAndAssets Sbcl))
  assertTrue "git-mv no assets" (not (techniqueNeedsAssets GitMvAndManifest))
  assertTrue "unsupported no assets" (not (techniqueNeedsAssets (Unsupported "why")))
  -- ecosystem predicates (positive + negative arms)
  assertTrue "is go" (ecosystemIsGo (Go (Just "subdir")))
  assertTrue "go not npm" (not (ecosystemIsNpm (Go Nothing)))
  assertTrue "is npm" (ecosystemIsNpm NpmEco)
  assertTrue "npm not go" (not (ecosystemIsGo NpmEco))
  assertTrue "is bun" (ecosystemIsBun Bun)
  assertTrue "bun not cargo" (not (ecosystemIsCargo Bun))
  assertTrue "is cargo" (ecosystemIsCargo (Cargo (Just "lock") (Just "pkg")))
  assertTrue "cargo not bun" (not (ecosystemIsBun (Cargo Nothing Nothing)))
  assertTrue "npm not bun" (not (ecosystemIsBun NpmEco))
  assertTrue "go not cargo" (not (ecosystemIsCargo (Go Nothing)))
  assertTrue "is sbcl" (ecosystemIsSbcl Sbcl)
  assertTrue "sbcl not cargo" (not (ecosystemIsCargo Sbcl))
  assertTrue "cargo not sbcl" (not (ecosystemIsSbcl (Cargo Nothing Nothing)))
  -- splitPackageKey success + Nothing arms
  assertEq
    "split ok"
    (Just ("dev-util", "hk"))
    (splitPackageKey (PackageKey "dev-util/hk"))
  assertEq
    "split via mk"
    (Just ("app-misc", "foo"))
    (splitPackageKey (mkPackageKey "app-misc" "foo"))
  assertEq "empty" Nothing (splitPackageKey (PackageKey ""))
  assertEq "no slash" Nothing (splitPackageKey (PackageKey "noslash"))
  assertEq "empty category" Nothing (splitPackageKey (PackageKey "/pkg"))
  assertEq "empty package" Nothing (splitPackageKey (PackageKey "cat/"))
  assertEq "slash only" Nothing (splitPackageKey (PackageKey "/"))
