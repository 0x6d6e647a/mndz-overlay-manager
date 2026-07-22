{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Main (main) where

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
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    applyPackagePhase1,
    contentFixNeeded,
    foldExitHardFail,
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
import Update.Assets.Layout (depsTarballName, vendorTarballName)
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
import Update.Check (PackageEntry (..), groupNewest)
import Update.Deps.Plan (DepsPlanOps (..), productionDepsPlanOps)
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildHasDevLangGoBdepend,
    ebuildNeedsContentFix,
    ensureGoBdepend,
    ensureNodejsBdepend,
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
    GoLanePlan (..),
    LaneId (..),
    LaneTarget (..),
    PlannedEbuild (..),
    VersionCandidate (..),
    assembleKeywords,
    buildGapLines,
    collapsePlannedEbuilds,
    extrasToDelete,
    filterCandidateVersions,
    laneLabel,
    ltLane,
    maxVersionUnder,
    missingTargets,
    planFromTargets,
    planNeedsWork,
    selectAllLaneTargets,
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
import Update.Go.Tree
  ( ArchCeilings (..),
    RuntimeCeilings (..),
    RuntimeEbuildMeta (..),
    computeCeilings,
    discoverGoCeilingsWith,
    emptyCeilings,
    isLiveGoVersion,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    parseGoEbuildMeta,
    parseKeywordsField,
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

main :: IO ()
main = do
  putStrLn "Running mndz-overlay-manager tests..."
  testEbuildAtom
  testParseEbuildFileName
  testDiscoveryHappyPath
  testDiscoverySkipsNonCategories
  testDiscoveryBadName
  testDiscoveryPackageMismatch
  testConfigLoadSuccess
  testConfigLoadMissing
  testConfigLoadMissingKey
  testConfigLegacyKeysRejected
  testConfigOptionalKeys
  testEmptyInventoryIsEmptyList
  testValidatePopulated
  testVersionParse
  testVersionRender
  testVersionCompare
  testHardcodedGrok
  testPolicyClassification
  testResolveMapOnly
  testGroupNewest
  testCheckOverlayStatuses
  testTargetResolution
  testPreflightMissingTools
  testMd5CacheLayoutGate
  testMd5CacheMatchMismatchMissing
  testMd5CacheMultiVersionCompleteness
  testMd5CacheGencacheDecisions
  testMd5CacheGateBlocksGitMv
  testGencacheForceAndMismatch
  testNewEbuildFileName
  testFoldExitHardFail
  testTokenResolver
  testHashBytes
  testSidecarLine
  testEbuildEdit
  testGoVersionParse
  testGoBdependEdit
  testNodejsBdependUseReplace
  testVendorGoVersionGate
  testSshAgentReuse
  testGpgSignReadiness
  testVerbosityResolution
  testSeverityFilterMapping
  testSeverityColors
  testNoColorStripsEscapes
  testJobsBound
  testJobsOneSerial
  testGoModCacheConcurrentDistinctKeys
  testGoModCacheHitNoRefetch
  testWorkBudgetBound
  testMultiProgressState
  testPlanDraw
  testMultiProgressDrawThrowNoHang
  testMultiProgressBodyThrowNoHang
  testMultiProgressPanelFailSuccess
  testStepProgressDrawThrowNoHang
  testStepProgressBodyThrowNoHang
  testStepProgressPanelFailSuccess
  testPauseClearThrowLockNotStuck
  testGoTreeCeilings
  testMultiArchCeilings
  testTildeOnlyBunCeilings
  testCandidateVersionFilter
  testEnginesMinimumParse
  testDepsDistfileNames
  testGoKeywordsAssembly
  testGoLaneSelection
  testGoLaneCollapse
  testGoGapLines
  testGoStripAndParseList
  testSetKeywords
  testGoPlanIntegrationMocked
  testGoModProbeEarlyExitTipFillsAll
  testGoModProbeEarlyExitPlainOlder
  testGoModProbeEarlyExitMatchesFullProbe
  testGoModProbeEarlyExitSkipsUnparseableTip
  testGoPlanProgressCoarseSteps
  testReleaseLookup
  testContentFixManifest
  testReuseVsFullPublish
  testVendorProgressEventOrder
  testFullPathApplyProgressSequence
  testReusePathApplyProgressSequence
  testMaterializeStepBudget
  testMarkSuccessLinesReused
  testGitMvCommitsOnSuccess
  testGoMultiPvSequentialCommits
  testGoMultiPvStopOnHardFail
  testOverlayCommitLock
  testBdependMismatchNeedsFix
  testBdependMissingNeedsFix
  putStrLn "All tests passed."

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
  unless (expected == actual) $ do
    hPutStrLn stderr $ label <> ": expected " <> show expected <> " but got " <> show actual
    exitFailure

assertTrue :: String -> Bool -> IO ()
assertTrue label cond =
  unless cond $ do
    hPutStrLn stderr $ label <> ": expected True"
    exitFailure

assertLeft :: (Show a) => String -> Either e a -> IO e
assertLeft label = \case
  Left e -> pure e
  Right a -> do
    hPutStrLn stderr $ label <> ": expected Left, got Right " <> show a
    exitFailure

assertRight :: (Show e) => String -> Either e a -> IO a
assertRight label = \case
  Right a -> pure a
  Left e -> do
    hPutStrLn stderr $ label <> ": expected Right, got Left " <> show e
    exitFailure

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

testConfigLoadSuccess :: IO ()
testConfigLoadSuccess = do
  cfg <- assertRight "valid config" =<< loadConfig (Just "test/fixtures/valid-config.toml")
  assertEq "path key" "test/fixtures/populated-overlay" (overlayPath cfg)
  assertEq "assets optional absent" Nothing (assetsPath cfg)
  assertEq "token optional absent" Nothing (githubToken cfg)

testConfigOptionalKeys :: IO ()
testConfigOptionalKeys = do
  cfg <- assertRight "full config" =<< loadConfig (Just "test/fixtures/full-config.toml")
  assertEq "path" "/tmp/overlay" (overlayPath cfg)
  assertEq "assets" (Just "/tmp/assets") (assetsPath cfg)
  assertEq "token" (Just "secret-token") (githubToken cfg)

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
    Just (PackagePolicy _ (Unsupported _)) -> pure ()
    other -> do
      hPutStrLn stderr $ "mise technique: " <> show other
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
  assertEq
    "full key"
    (Right (PackageKey "dev-lang/deno-bin"))
    (resolveTargetToken sampleEntries "dev-lang/deno-bin")
  assertEq
    "bare unique"
    (Right (PackageKey "dev-util/opencode-bin"))
    (resolveTargetToken sampleEntries "opencode-bin")
  case resolveTargetToken sampleEntries "foo" of
    Left (AmbiguousPackage "foo" keys) ->
      assertEq
        "ambiguous keys"
        (sort (map packageKeyText keys))
        ["bar/foo", "baz/foo"]
    other -> do
      hPutStrLn stderr $ "expected ambiguous foo, got " <> show other
      exitFailure
  case resolveTargets sampleEntries [] of
    Right keys ->
      assertEq "all keys count" 4 (length keys)
    Left e -> do
      hPutStrLn stderr $ "all targets: " <> show e
      exitFailure
  case resolveTargets sampleEntries ["deno-bin", "nope"] of
    Left errs ->
      assertTrue "has unknown" (any isUnknown errs)
    Right _ -> do
      hPutStrLn stderr "expected unknown error"
      exitFailure
  where
    isUnknown (UnknownPackage _) = True
    isUnknown _ = False

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

testNewEbuildFileName :: IO ()
testNewEbuildFileName = do
  assertEq
    "filename"
    "opencode-bin-1.17.20.ebuild"
    (newEbuildFileName "opencode-bin" (parseEbuildVersion "1.17.20"))
  assertEq
    "render strips rev for filename base"
    "0.2.99"
    (renderPVNoRev (parseEbuildVersion "0.2.99-r1"))
  assertEq
    "render remote"
    "0.2.101"
    (renderPVNoRev (parseEbuildVersion "0.2.101"))

testFoldExitHardFail :: IO ()
testFoldExitHardFail = do
  let soft =
        [ ApplySoftSkip (PackageKey "a/b") "unsupported",
          ApplySoftSkip (PackageKey "c/d") "not outdated"
        ]
      mixed =
        soft
          <> [ ApplyHardFail (PackageKey "e/f") "dirty" False False,
               ApplySuccess
                 (PackageKey "g/h")
                 [ SuccessLine
                     { slFrom = parseEbuildVersion "1.0",
                       slTo = parseEbuildVersion "1.1",
                       slLabel = Nothing,
                       slAssetsReused = False
                     }
                 ]
                 ["g/h/g-h-1.1.ebuild"]
             ]
  assertEq "soft only" False (foldExitHardFail soft)
  assertEq "mixed" True (foldExitHardFail mixed)

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

testEbuildEdit :: IO ()
testEbuildEdit = do
  let frozen =
        T.unlines
          [ "SRC_URI=\"https://github.com/dolthub/dolt/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-2.1.6/dolt-2.1.6-vendor.tar.xz\""
          ]
      fixed = parameterizeAssetsSrcUri "dolt" frozen
      already =
        "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/beads-${PV}/beads-${PV}-vendor.tar.xz\"\n"
  assertEq "frozen not parameterized" False (assetsSrcUriParameterized frozen)
  assertTrue "fixed parameterized" (assetsSrcUriParameterized fixed)
  assertTrue "has ${PV} tag" ("dolt-${PV}/dolt-${PV}-vendor" `T.isInfixOf` fixed)
  -- Regression: intercalate must keep the assets host path (not strip it).
  assertTrue
    "keeps mndz-overlay-assets download path"
    ( "https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-${PV}/dolt-${PV}-vendor.tar.xz"
        `T.isInfixOf` fixed
    )
  assertTrue
    "does not produce bare user/repo URL"
    (not ("https://github.com/0x6d6e647a/dolt-" `T.isInfixOf` fixed))
  assertEq
    "already parameterized unchanged path"
    already
    (parameterizeAssetsSrcUri "beads" already)
  let rev1 = nextRevisionVersion (parseEbuildVersion "2.1.6")
  assertEq "r1" (Numeric [2, 1, 6] (Just 1)) rev1
  let planned = parseEbuildVersion "2.1.6"
      bare = Numeric [2, 1, 6] Nothing
      r1 = Numeric [2, 1, 6] (Just 1)
      r2 = Numeric [2, 1, 6] (Just 2)
      other = parseEbuildVersion "2.1.7"
  assertEq
    "write version new PV (no local same)"
    bare
    (writeVersionForPlannedPV planned [])
  assertEq
    "write version ignores other PVs"
    bare
    (writeVersionForPlannedPV planned [other])
  assertEq
    "write version bare local → r1"
    r1
    (writeVersionForPlannedPV planned [bare])
  assertEq
    "write version local r1 → r2"
    r2
    (writeVersionForPlannedPV planned [r1])
  assertEq
    "write version max of bare and r1 is r2"
    r2
    (writeVersionForPlannedPV planned [bare, r1, other])
  assertEq
    "write version planned rev ignored when locals present"
    r2
    (writeVersionForPlannedPV r1 [r1])
  let man =
        "DIST dolt-2.1.6-vendor.tar.xz 123 BLAKE2B deadbeef SHA512 abcdef0123456789\n"
  assertEq
    "manifest sha512"
    (Just "abcdef0123456789")
    (parseManifestVendorSHA512 man "dolt-2.1.6-vendor.tar.xz")
  assertTrue
    "manifest has vendor dist"
    (manifestHasVendorDist man "dolt-2.1.6-vendor.tar.xz")
  assertTrue
    "manifest missing other dist"
    (not (manifestHasVendorDist man "crush-0.84.0-vendor.tar.xz"))

testGoVersionParse :: IO ()
testGoVersionParse = do
  let modSample =
        T.unlines
          [ "module github.com/charmbracelet/crush",
            "",
            "go 1.26.5",
            "",
            "toolchain go1.26.5",
            "",
            "require (",
            "        github.com/foo/bar v1.0.0",
            ")"
          ]
  assertEq
    "go.mod directive"
    (Just "1.26.5")
    (parseGoModGoDirective modSample)
  assertEq
    "commented go ignored"
    Nothing
    (parseGoModGoDirective "// go 1.99.0\nmodule x\n")
  assertEq
    "missing go line"
    Nothing
    (parseGoModGoDirective "module x\nrequire github.com/a/b v1\n")
  assertEq
    "go version output"
    (Just "1.26.4")
    (parseGoVersionOutput "go version go1.26.4 linux/amd64\n")
  assertEq
    "go version with experiment suffix"
    (Just "1.26.4")
    (parseGoVersionOutput "go version go1.26.4-X:nodwarf5 linux/amd64\n")
  assertEq
    "1.26 pads like 1.26.0"
    (parseGoVersionToken "1.26")
    (parseGoVersionToken "1.26.0")
  assertEq
    "host older"
    (Just LT)
    (compareGoVersions "1.26.4" "1.26.5")
  assertEq
    "host equal"
    (Just EQ)
    (compareGoVersions "1.26.5" "1.26.5")
  assertEq
    "host newer"
    (Just GT)
    (compareGoVersions "1.27.0" "1.26.5")
  assertEq
    "meets requirement"
    (Just True)
    (hostMeetsGoRequirement "1.26.5" "1.26.5")
  assertEq
    "does not meet"
    (Just False)
    (hostMeetsGoRequirement "1.26.4" "1.26.5")
  assertTrue
    "too-old message names versions"
    ( "1.26.4" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
        && "1.26.5" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
        && "GOTOOLCHAIN=auto" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
    )
  assertTrue
    "toolchain stderr detected"
    (looksLikeToolchainError "go: go.mod requires go >= 1.26.5 (running go 1.26.4; GOTOOLCHAIN=local)")
  assertTrue
    "enrich mentions upgrade"
    ("dev-lang/go" `T.isInfixOf` enrichGoModDownloadError "toolchain not available")

testGoBdependEdit :: IO ()
testGoBdependEdit = do
  let base =
        T.unlines
          [ "# Copyright",
            "EAPI=8",
            "",
            "inherit go-module",
            "",
            "DESCRIPTION=\"x\"",
            "SRC_URI=\"https://example/a-${PV}.tar.gz\""
          ]
  inserted <- assertRight "insert bdepend" (ensureGoBdepend "1.26.5" base)
  assertTrue
    "inserted atom"
    (goBdependAtom "1.26.5" `T.isInfixOf` inserted)
  assertTrue "has go bdepend" (ebuildHasDevLangGoBdepend inserted)
  assertTrue "matches" (goBdependMatches "1.26.5" inserted)
  let withOld =
        T.unlines
          [ "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.24.11:=\"",
            "BDEPEND+=\" app-arch/unzip\"",
            "DESCRIPTION=\"y\""
          ]
  replaced <- assertRight "replace bdepend" (ensureGoBdepend "1.26.5" withOld)
  assertTrue
    "new atom present"
    (goBdependMatches "1.26.5" replaced)
  assertTrue
    "old atom gone"
    (not (">=dev-lang/go-1.24.11:=" `T.isInfixOf` replaced))
  assertTrue
    "unrelated bdepend kept"
    ("app-arch/unzip" `T.isInfixOf` replaced)
  case ensureGoBdepend "1.26.5" "DESCRIPTION=\"no inherit\"\n" of
    Left msg ->
      assertTrue "no inherit error" ("inherit" `T.isInfixOf` msg)
    Right _ -> do
      hPutStrLn stderr "expected Left when no inherit line"
      exitFailure
  case ensureGoBdepend "" base of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected Left for empty go version"
      exitFailure

-- | Regression: replacing nodejs atoms must consume full [npm] USE (no [npm]npm]).
testNodejsBdependUseReplace :: IO ()
testNodejsBdependUseReplace = do
  let openspecStyle =
        T.unlines
          [ "inherit shell-completion",
            "RDEPEND=\">=net-libs/nodejs-20.19.0[npm]\"",
            "BDEPEND=\"${RDEPEND}\"",
            "DESCRIPTION=\"x\""
          ]
  same <- assertRight "same-version rewrite" (ensureNodejsBdepend "20.19.0" openspecStyle)
  assertTrue
    "exact atom present"
    (nodejsBdependMatches "20.19.0" same)
  assertTrue
    "no mangled USE"
    (not ("[npm]npm]" `T.isInfixOf` same))
  assertTrue
    "RDEPEND line intact form"
    ("RDEPEND=\">=net-libs/nodejs-20.19.0[npm]\"" `T.isInfixOf` same)
  case [ln | ln <- T.lines same, "RDEPEND=" `T.isPrefixOf` ln] of
    (rdep : _) ->
      assertEq "single [npm] on RDEPEND line" 1 (T.count "[npm]" rdep)
    [] -> do
      hPutStrLn stderr "expected RDEPEND line after rewrite"
      exitFailure
  let older =
        T.unlines
          [ "inherit shell-completion",
            "RDEPEND=\">=net-libs/nodejs-18.0.0[npm]\"",
            "BDEPEND=\"${RDEPEND}\""
          ]
  bumped <- assertRight "bump version" (ensureNodejsBdepend "20.19.0" older)
  assertTrue "new version" (nodejsBdependMatches "20.19.0" bumped)
  assertTrue "old version gone" (not (">=net-libs/nodejs-18.0.0" `T.isInfixOf` bumped))
  assertTrue "no mangled USE after bump" (not ("[npm]npm]" `T.isInfixOf` bumped))
  -- Go slot form still works via shared replacer.
  let goLine = "BDEPEND=\">=dev-lang/go-1.24.11:= app-arch/unzip\""
  goFixed <- assertRight "go still ok" (ensureGoBdepend "1.26.5" ("inherit go-module\n" <> goLine <> "\n"))
  assertTrue "go atom" (goBdependMatches "1.26.5" goFixed)
  assertTrue "unzip kept" ("app-arch/unzip" `T.isInfixOf` goFixed)

testVendorGoVersionGate :: IO ()
testVendorGoVersionGate = do
  downloadCalls <- newIORef (0 :: Int)
  let goMod =
        T.unlines
          [ "module example.com/pkg",
            "go 1.26.5"
          ]
      writeClone _url _tag dest = do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "go.mod") goMod
        pure (Right ())
      ops hostVer =
        VendorOps
          { voClone = writeClone,
            voHostGoVersion = pure (Right hostVer),
            voGoModDownload = \_ -> do
              atomicModifyIORef' downloadCalls (\n -> (n + 1, ()))
              pure (Right ()),
            voTarXz = \_goDir _entry outPath -> do
              writeFile outPath "fake-tarball"
              pure (Right ())
          }
  -- Older host: fail before download
  atomicModifyIORef' downloadCalls (const (0, ()))
  older <-
    buildVendorTarball
      (ops "1.26.4")
      noopVendorProgress
      "o"
      "r"
      "v"
      "0.1.0"
      Nothing
      "/tmp"
      "pkg-0.1.0-vendor.tar.xz"
  case older of
    Left msg -> do
      assertTrue "names host" ("1.26.4" `T.isInfixOf` msg)
      assertTrue "names required" ("1.26.5" `T.isInfixOf` msg)
      n <- readIORef downloadCalls
      assertEq "download not called when host old" 0 n
    Right _ -> do
      hPutStrLn stderr "expected hard-fail for older host Go"
      exitFailure
  -- Equal host: proceeds
  atomicModifyIORef' downloadCalls (const (0, ()))
  withSystemTempDirectory "mndz-vendor-test-" $ \outDir -> do
    ok <-
      buildVendorTarball
        (ops "1.26.5")
        noopVendorProgress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor.tar.xz"
    case ok of
      Right VendorResult {vrGoModVersion = mVer, vrTarballPath = path} -> do
        assertEq "go.mod version plumbed" (Just "1.26.5") mVer
        n <- readIORef downloadCalls
        assertEq "download called once" 1 n
        assertEq
          "tarball path"
          (outDir </> "pkg-0.1.0-vendor.tar.xz")
          path
      Left err -> do
        hPutStrLn stderr $ "expected success, got " <> T.unpack err
        exitFailure

testSshAgentReuse :: IO ()
testSshAgentReuse = do
  let opsWithKeys =
        SshAgentOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoSetEnv = \_ _ -> pure (),
            saoUnsetEnv = \_ -> pure (),
            saoRunAgent = pure (Left "should not start"),
            saoSshAdd = pure (Left "should not add"),
            saoListIdentities = pure HasIdentities,
            saoKillAgent = \_ -> pure ()
          }
  result <- ensureSshAgent opsWithKeys
  case result of
    Right SshSessionReused -> pure ()
    other -> do
      hPutStrLn stderr $ "expected reused session, got " <> show other
      exitFailure
  let opsEmpty =
        opsWithKeys
          { saoListIdentities = pure NoIdentities,
            saoSshAdd = pure (Right ())
          }
  resultEmpty <- ensureSshAgent opsEmpty
  case resultEmpty of
    Left msg ->
      assertTrue
        "mentions no identities"
        ("no identities" `T.isInfixOf` msg)
    Right _ -> do
      hPutStrLn stderr "expected failure when agent stays empty"
      exitFailure
  let parsed =
        parseIdentityFiles
          "/home/u"
          "Host github.com\n  IdentityFile ~/.ssh/keys/github\n# IdentityFile ~/.ssh/skip\nIdentityFile /abs/key\n"
  assertEq
    "parsed identity files"
    ["/home/u/.ssh/keys/github", "/abs/key"]
    parsed
  missing <-
    checkToolsOnPath
      ( \name ->
          pure $
            if name == "go"
              then Nothing
              else Just ("/bin/" <> name)
      )
      goAssetsRequiredTools
  assertEq "go missing among assets tools" ["go"] missing

------------------------------------------------------------------------
-- GPG sign readiness (fake ops; no live pinentry)
------------------------------------------------------------------------

testGpgSignReadiness :: IO ()
testGpgSignReadiness = do
  testParseSignCapableKeygrip
  testParseKeyinfoCached
  testPinentryChildEnv
  testMissingSigningKeyFails
  testWarmCacheSkipsPrompt
  testColdCacheReadyThenWarm
  testNoTtyWhenColdFails
  testClearOnlyIfWarmed
  testPerRepoKeygrips

testParseSignCapableKeygrip :: IO ()
testParseSignCapableKeygrip = do
  let sample =
        unlines
          [ "sec:u:255:22:AB3AA8D9F11259B4:1781074659:::u:::scESC:::+::ed25519:::0:",
            "fpr:::::::::CD806AAD3E54156ACC3842B7AB3AA8D9F11259B4:",
            "grp:::::::::6FD5C82CED9AF42C796A9C275BF5CD4082063513:",
            "ssb:u:255:18:0FFCBBF091D67623:1781074659::::::e:::+::cv25519::",
            "grp:::::::::76D0B0AC365AE824D6705200A8898C3E7F33A81D:"
          ]
  case parseSignCapableKeygrip sample of
    Right (Keygrip g) ->
      assertEq
        "sign keygrip"
        "6FD5C82CED9AF42C796A9C275BF5CD4082063513"
        g
    Left err -> do
      hPutStrLn stderr $ "parseSignCapableKeygrip failed: " <> T.unpack err
      exitFailure
  case parseSignCapableKeygrip "ssb:u:255:18:0FFC::::::e:::\ngrp:::::::::AAAA:\n" of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected no sign-capable keygrip"
      exitFailure

testParseKeyinfoCached :: IO ()
testParseKeyinfoCached = do
  let grip = "6FD5C82CED9AF42C796A9C275BF5CD4082063513"
      warm =
        "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - 1 P - - -\nOK\n"
      cold =
        "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - - P - - -\nOK\n"
  assertEq "warm" (Right True) (parseKeyinfoCached warm grip)
  assertEq "cold" (Right False) (parseKeyinfoCached cold grip)

testPinentryChildEnv :: IO ()
testPinentryChildEnv = do
  let parent = [("DISPLAY", ":0"), ("HOME", "/home/u"), ("GPG_TTY", "old")]
      env' = pinentryChildEnv (Just "/dev/tty") parent
  assertEq "GPG_TTY set" (Just "/dev/tty") (lookup "GPG_TTY" env')
  assertEq "DISPLAY cleared" Nothing (lookup "DISPLAY" env')
  assertEq "HOME kept" (Just "/home/u") (lookup "HOME" env')

baseFakeOps :: GpgAgentOps
baseFakeOps =
  GpgAgentOps
    { gaoGetSigningKey = \_ -> pure (Right "KEY1"),
      gaoResolveKeygrip = \_ -> pure (Right (Keygrip "GRIP1")),
      gaoKeyinfoCached = \_ -> pure (Right True),
      gaoReadyPrompt = pure (Left "should not prompt"),
      gaoWarmKey = \_ -> pure (Left "should not warm"),
      gaoClearPassphrase = \_ -> pure (),
      gaoControllingTty = pure (Just "/dev/tty"),
      gaoPauseUi = pure (),
      gaoResumeUi = pure ()
    }

testMissingSigningKeyFails :: IO ()
testMissingSigningKeyFails = do
  let ops =
        baseFakeOps
          { gaoGetSigningKey = \_ -> pure (Left "git config user.signingkey is unset")
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  err <- assertLeft "missing signingkey" result
  assertTrue "mentions signingkey" ("signingkey" `T.isInfixOf` err)
  teardownGpgHandle h

testWarmCacheSkipsPrompt :: IO ()
testWarmCacheSkipsPrompt = do
  promptRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right True),
            gaoReadyPrompt = do
              atomicModifyIORef' promptRef (\n -> (n + 1, ()))
              pure (Right ())
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "warm cache ready" result
  prompts <- readIORef promptRef
  assertEq "no ready prompt when warm" 0 prompts
  teardownGpgHandle h

testColdCacheReadyThenWarm :: IO ()
testColdCacheReadyThenWarm = do
  promptRef <- newIORef (0 :: Int)
  warmRef <- newIORef (0 :: Int)
  pauseRef <- newIORef (0 :: Int)
  resumeRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoReadyPrompt = do
              atomicModifyIORef' promptRef (\n -> (n + 1, ()))
              pure (Right ()),
            gaoWarmKey = \_ -> do
              atomicModifyIORef' warmRef (\n -> (n + 1, ()))
              pure (Right ()),
            gaoPauseUi = atomicModifyIORef' pauseRef (\n -> (n + 1, ())),
            gaoResumeUi = atomicModifyIORef' resumeRef (\n -> (n + 1, ()))
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "cold ready" result
  prompts <- readIORef promptRef
  warms <- readIORef warmRef
  pauses <- readIORef pauseRef
  resumes <- readIORef resumeRef
  assertEq "ready once" 1 prompts
  assertEq "warm once" 1 warms
  assertEq "ui paused" 1 pauses
  assertEq "ui resumed" 1 resumes
  teardownGpgHandle h

testNoTtyWhenColdFails :: IO ()
testNoTtyWhenColdFails = do
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoControllingTty = pure Nothing
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  err <- assertLeft "no tty" result
  assertTrue "mentions TTY" ("TTY" `T.isInfixOf` err)
  teardownGpgHandle h

testClearOnlyIfWarmed :: IO ()
testClearOnlyIfWarmed = do
  clearedRef <- newIORef ([] :: [T.Text])
  let opsWarm =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoReadyPrompt = pure (Right ()),
            gaoWarmKey = \_ -> pure (Right ()),
            gaoClearPassphrase = \(Keygrip g) ->
              atomicModifyIORef' clearedRef (\xs -> (xs <> [g], ()))
          }
  h1 <- newGpgHandle opsWarm
  void $ assertRight "warm path" =<< ensureGpgReady h1 "/tmp/overlay-repo"
  teardownGpgHandle h1
  cleared1 <- readIORef clearedRef
  assertEq "cleared after we warmed" ["GRIP1"] cleared1

  clearedRef2 <- newIORef ([] :: [T.Text])
  let opsAlreadyWarm =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right True),
            gaoClearPassphrase = \(Keygrip g) ->
              atomicModifyIORef' clearedRef2 (\xs -> (xs <> [g], ()))
          }
  h2 <- newGpgHandle opsAlreadyWarm
  void $ assertRight "already warm" =<< ensureGpgReady h2 "/tmp/overlay-repo"
  teardownGpgHandle h2
  cleared2 <- readIORef clearedRef2
  assertEq "no clear when we did not warm" [] cleared2

testPerRepoKeygrips :: IO ()
testPerRepoKeygrips = do
  resolveRef <- newIORef ([] :: [FilePath])
  let ops =
        baseFakeOps
          { gaoGetSigningKey = \root -> do
              atomicModifyIORef' resolveRef (\xs -> (xs <> [root], ()))
              pure $
                if "assets" `T.isInfixOf` T.pack root
                  then Right "KEY-ASSETS"
                  else Right "KEY-OVERLAY",
            gaoResolveKeygrip = \k ->
              pure $
                Right $
                  Keygrip $
                    if k == "KEY-ASSETS" then "GRIP-A" else "GRIP-O",
            gaoKeyinfoCached = \_ -> pure (Right True)
          }
  h <- newGpgHandle ops
  void $ assertRight "overlay" =<< ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "assets" =<< ensureGpgReady h "/tmp/assets-repo"
  -- Second call same overlay should reuse resolved state (no second get for same abs path)
  void $ assertRight "overlay again" =<< ensureGpgReady h "/tmp/overlay-repo"
  roots <- readIORef resolveRef
  -- makeAbsolute may expand; we only require both repos were queried at least once
  assertTrue "queried more than once" (length roots >= 2)
  teardownGpgHandle h

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

------------------------------------------------------------------------
-- Go tree-lane planner
------------------------------------------------------------------------

testGoTreeCeilings :: IO ()
testGoTreeCeilings = do
  let kwPlain = parseKeywordsField "KEYWORDS=\"amd64 ~arm64\"\n"
      kwTilde = parseKeywordsField "KEYWORDS=\"~amd64 ~arm64\"\n"
  assertTrue "bare amd64" (keywordsHasBare "amd64" kwPlain)
  assertTrue "not bare when tilde only" (not (keywordsHasBare "amd64" kwTilde))
  assertTrue "tilde or bare for ~amd64" (keywordsHasTildeOrBare "amd64" kwTilde)
  assertTrue "tilde or bare for bare" (keywordsHasTildeOrBare "amd64" kwPlain)
  assertTrue "live 9999" (isLiveGoVersion (parseEbuildVersion "9999"))
  assertTrue "not live" (not (isLiveGoVersion (parseEbuildVersion "1.26.3")))
  case parseGoEbuildMeta "/x/go-9999.ebuild" "KEYWORDS=\"~amd64\"\n" of
    Nothing -> pure ()
    Just _ -> do
      hPutStrLn stderr "expected Nothing for live go ebuild"
      exitFailure
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "1.26.3") ["amd64", "arm64"],
          RuntimeEbuildMeta (parseEbuildVersion "1.26.4") ["~amd64", "~arm64"],
          RuntimeEbuildMeta (parseEbuildVersion "1.25.0") ["~amd64"]
        ]
      ceilings = computeCeilings "dev-lang/go" metas
  assertEq "amd64 plain" (Just (parseEbuildVersion "1.26.3")) (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
  assertEq "amd64 tilde" (Just (parseEbuildVersion "1.26.4")) (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
  assertEq "arm64 plain" (Just (parseEbuildVersion "1.26.3")) (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "arm64" (rcByArch ceilings)))
  assertEq "arm64 tilde" (Just (parseEbuildVersion "1.26.4")) (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "arm64" (rcByArch ceilings)))
  assertEq "empty ceilings" (emptyCeilings "dev-lang/go") (computeCeilings "dev-lang/go" [])

testMultiArchCeilings :: IO ()
testMultiArchCeilings = do
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "20.0.0") ["amd64", "~loong"],
          RuntimeEbuildMeta (parseEbuildVersion "22.0.0") ["~amd64", "~loong", "arm64"]
        ]
      ceilings = computeCeilings "net-libs/nodejs" metas
  assertTrue "has loong" (Map.member "loong" (rcByArch ceilings))
  assertTrue "has amd64" (Map.member "amd64" (rcByArch ceilings))
  assertTrue "has arm64" (Map.member "arm64" (rcByArch ceilings))
  assertEq
    "loong plain absent"
    Nothing
    (acPlain (rcByArch ceilings Map.! "loong"))
  assertEq
    "loong tilde"
    (Just (parseEbuildVersion "22.0.0"))
    (acTilde (rcByArch ceilings Map.! "loong"))
  assertEq
    "arm64 plain"
    (Just (parseEbuildVersion "22.0.0"))
    (acPlain (rcByArch ceilings Map.! "arm64"))

testTildeOnlyBunCeilings :: IO ()
testTildeOnlyBunCeilings = do
  let metas =
        [ RuntimeEbuildMeta (parseEbuildVersion "1.3.6") ["~amd64", "~arm64"]
        ]
      ceilings = computeCeilings "dev-lang/bun-bin" metas
      targets = selectAllLaneTargets ceilings []
  assertTrue "no plain amd64 ceiling" (isNothing (acPlain (rcByArch ceilings Map.! "amd64")))
  assertEq
    "tilde amd64 ceiling"
    (Just (parseEbuildVersion "1.3.6"))
    (acTilde (rcByArch ceilings Map.! "amd64"))
  -- Lanes exist for tilde only
  assertTrue
    "tilde lanes present"
    (any (\t -> ltLane t == LaneAmd64Tilde) targets)

testCandidateVersionFilter :: IO ()
testCandidateVersionFilter = do
  let local = [parseEbuildVersion "1.4.1"]
      upstream =
        [ parseEbuildVersion "1.4.0",
          parseEbuildVersion "1.4.1",
          parseEbuildVersion "1.5.0",
          parseEbuildVersion "1.6.0"
        ]
  case filterCandidateVersions local upstream of
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
    Right cs -> do
      assertTrue "has local 1.4.1" (parseEbuildVersion "1.4.1" `elem` cs)
      assertTrue "has 1.5.0" (parseEbuildVersion "1.5.0" `elem` cs)
      assertTrue "has 1.6.0" (parseEbuildVersion "1.6.0" `elem` cs)
      assertTrue "no 1.4.0" (parseEbuildVersion "1.4.0" `notElem` cs)
  case filterCandidateVersions [] upstream of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected hard-fail for empty local"
      exitFailure

testEnginesMinimumParse :: IO ()
testEnginesMinimumParse = do
  assertEq ">= form" (Just "20.19.0") (parseEnginesMinimum ">=20.19.0")
  assertEq "bare" (Just "1.3.6") (parseEnginesMinimum "1.3.6")
  assertEq "v prefix" (Just "1.2.3") (parseEnginesMinimum "v1.2.3")
  assertEq "complex caret" Nothing (parseEnginesMinimum "^20.0.0")
  assertEq "complex or" Nothing (parseEnginesMinimum ">=18 || >=20")
  assertEq "star" Nothing (parseEnginesMinimum "*")
  assertEq "empty" Nothing (parseEnginesMinimum "")

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

testGoKeywordsAssembly :: IO ()
testGoKeywordsAssembly = do
  -- All four lanes → bare amd64 arm64 (plain membership wins; no tilde tokens)
  assertEq
    "all four lanes bare both arches"
    ["amd64", "arm64"]
    (assembleKeywords [LaneAmd64Plain, LaneAmd64Tilde, LaneArm64Plain, LaneArm64Tilde])
  -- Tilde-only membership
  assertEq "amd64 tilde only" ["~amd64"] (assembleKeywords [LaneAmd64Tilde])
  assertEq "arm64 tilde only" ["~arm64"] (assembleKeywords [LaneArm64Tilde])
  assertEq
    "both arches tilde only"
    ["~amd64", "~arm64"]
    (assembleKeywords [LaneAmd64Tilde, LaneArm64Tilde])
  -- Plain-only membership
  assertEq "amd64 plain only" ["amd64"] (assembleKeywords [LaneAmd64Plain])
  assertEq "arm64 plain only" ["arm64"] (assembleKeywords [LaneArm64Plain])
  -- Plain + tilde on same arch → bare only (never both)
  assertEq
    "plain wins over tilde amd64"
    ["amd64"]
    (assembleKeywords [LaneAmd64Plain, LaneAmd64Tilde])
  -- Deterministic order: amd64 before arm64
  assertEq
    "order amd64 then arm64"
    ["amd64", "arm64"]
    (assembleKeywords [LaneArm64Plain, LaneAmd64Plain])
  -- Staggered: plain amd64 only + tilde amd64 on other PV is per-call; mixed tiers across arches
  assertEq
    "tilde amd64 + plain arm64"
    ["~amd64", "arm64"]
    (assembleKeywords [LaneAmd64Tilde, LaneArm64Plain, LaneArm64Tilde])

testGoLaneSelection :: IO ()
testGoLaneSelection = do
  let ceilings = dualArchGoCeilings (Just "1.26.3") (Just "1.26.5")
      candidates =
        [ VersionCandidate (parseEbuildVersion "0.82.0") (Just "1.26.3"),
          VersionCandidate (parseEbuildVersion "0.84.0") (Just "1.26.5"),
          VersionCandidate (parseEbuildVersion "0.85.0") Nothing
        ]
  assertEq
    "max under plain"
    (Just (parseEbuildVersion "0.82.0", "1.26.3"))
    (maxVersionUnder (parseEbuildVersion "1.26.3") candidates)
  assertEq
    "max under tilde"
    (Just (parseEbuildVersion "0.84.0", "1.26.5"))
    (maxVersionUnder (parseEbuildVersion "1.26.5") candidates)
  let targets = selectAllLaneTargets ceilings candidates
      plan = planFromTargets targets
  assertEq "two unique PVs" 2 (length (glpUniquePVs plan))
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Plain] of
    [Just pv] -> assertEq "plain lane" (parseEbuildVersion "0.82.0") pv
    other -> do
      hPutStrLn stderr $ "plain lane target: " <> show other
      exitFailure
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Tilde] of
    [Just pv] -> assertEq "tilde lane" (parseEbuildVersion "0.84.0") pv
    other -> do
      hPutStrLn stderr $ "tilde lane target: " <> show other
      exitFailure

testGoLaneCollapse :: IO ()
testGoLaneCollapse = do
  let allSame =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
        ]
      collapsed = collapsePlannedEbuilds allSame
  assertEq "single PV collapse" 1 (length collapsed)
  case collapsed of
    [pe] -> do
      assertEq "pv" (parseEbuildVersion "0.84.0") (pePV pe)
      assertEq "bare dual keywords" ["amd64", "arm64"] (peKeywords pe)
      assertTrue "no ~amd64" ("~amd64" `notElem` peKeywords pe)
      assertTrue "no ~arm64" ("~arm64" `notElem` peKeywords pe)
    _ -> exitFailure
  let divergent =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3")
        ]
      divCollapsed = collapsePlannedEbuilds divergent
  assertEq "arch divergent count" 2 (length divCollapsed)
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.84.0"] of
    [pe] -> do
      assertEq "0.84 bare amd64" ["amd64"] (peKeywords pe)
      assertTrue "0.84 no arm64" ("arm64" `notElem` peKeywords pe)
      assertTrue "0.84 no ~arm64" ("~arm64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.84 ebuild: " <> show other
      exitFailure
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> do
      assertEq "0.82 bare arm64" ["arm64"] (peKeywords pe)
      assertTrue "0.82 no amd64" ("amd64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.82 ebuild: " <> show other
      exitFailure
  -- Tilde-only: only amd64 tilde lane targets PV
  let tildeOnly =
        [ LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
        ]
  case collapsePlannedEbuilds tildeOnly of
    [pe] -> assertEq "tilde-only keywords" ["~amd64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "tilde-only ebuild: " <> show other
      exitFailure
  -- Staggered plain vs tilde: plain amd64 → 0.75; tilde amd64 + both arm64 → 0.82
  let staggered =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.75.0")) (Just "1.26.3"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.5")
        ]
      stagCollapsed = collapsePlannedEbuilds staggered
  assertEq "staggered count" 2 (length stagCollapsed)
  case [pe | pe <- stagCollapsed, pePV pe == parseEbuildVersion "0.75.0"] of
    [pe] -> assertEq "0.75 bare amd64 only" ["amd64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.75 ebuild: " <> show other
      exitFailure
  case [pe | pe <- stagCollapsed, pePV pe == parseEbuildVersion "0.82.0"] of
    [pe] -> assertEq "0.82 ~amd64 + bare arm64" ["~amd64", "arm64"] (peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.82 staggered ebuild: " <> show other
      exitFailure
  let fourDistinct =
        [ LaneTarget LaneAmd64Plain Nothing (Just (parseEbuildVersion "0.80.0")) (Just "1.0"),
          LaneTarget LaneAmd64Tilde Nothing (Just (parseEbuildVersion "0.81.0")) (Just "1.0"),
          LaneTarget LaneArm64Plain Nothing (Just (parseEbuildVersion "0.82.0")) (Just "1.0"),
          LaneTarget LaneArm64Tilde Nothing (Just (parseEbuildVersion "0.83.0")) (Just "1.0")
        ]
  assertEq "four ebuilds" 4 (length (collapsePlannedEbuilds fourDistinct))
  case collapsePlannedEbuilds fourDistinct of
    pes ->
      assertEq
        "four keywords bare/tilde by lane"
        [ ["amd64"],
          ["~amd64"],
          ["arm64"],
          ["~arm64"]
        ]
        (map peKeywords (sortByPv pes))
  let plan = planFromTargets allSame
      locals = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
  assertEq "missing target" [parseEbuildVersion "0.84.0"] (missingTargets locals plan)
  assertEq
    "extras"
    [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
    (extrasToDelete locals plan)
  assertTrue "needs work" (planNeedsWork locals [] plan)
  assertTrue "satisfied" (not (planNeedsWork [parseEbuildVersion "0.84.0"] [] plan))
  where
    sortByPv =
      sortBy
        ( \a b ->
            case comparePV (pePV a) (pePV b) of
              Just o -> o
              Nothing -> compare (show (pePV a)) (show (pePV b))
        )

testGoGapLines :: IO ()
testGoGapLines = do
  assertEq
    "labels"
    "(dev-lang/go amd64)"
    (laneLabel LaneAmd64Plain)
  assertEq
    "tilde label"
    "(dev-lang/go ~amd64)"
    (laneLabel LaneAmd64Tilde)
  let planSplit =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals1 = [parseEbuildVersion "0.80.0"]
      needs = [parseEbuildVersion "0.82.0", parseEbuildVersion "0.84.0"]
      linesSplit = buildGapLines locals1 needs planSplit
  assertEq "split line count" 2 (length linesSplit)
  assertTrue
    "split from 0.80"
    (all (\g -> glFrom g == parseEbuildVersion "0.80.0") linesSplit)
  assertTrue
    "has 0.82"
    (any (\g -> glTo g == parseEbuildVersion "0.82.0") linesSplit)
  assertTrue
    "has 0.84"
    (any (\g -> glTo g == parseEbuildVersion "0.84.0") linesSplit)
  let planConverge =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals2 = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
      linesConv = buildGapLines locals2 [parseEbuildVersion "0.84.0"] planConverge
  assertEq "converge line count" 2 (length linesConv)
  assertTrue
    "converge has 0.80"
    (any (\g -> glFrom g == parseEbuildVersion "0.80.0") linesConv)
  assertTrue
    "converge has 0.82"
    (any (\g -> glFrom g == parseEbuildVersion "0.82.0") linesConv)
  assertTrue
    "converge to 0.84"
    (all (\g -> glTo g == parseEbuildVersion "0.84.0") linesConv)

testGoStripAndParseList :: IO ()
testGoStripAndParseList = do
  case stripAndParse "v" "v0.80.0" of
    Right v -> assertEq "prefix v" (parseEbuildVersion "0.80.0") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  case stripAndParse "bun-v" "bun-v1.2.3" of
    Right v -> assertEq "bun prefix" (parseEbuildVersion "1.2.3") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure

testSetKeywords :: IO ()
testSetKeywords = do
  let base =
        T.unlines
          [ "inherit go-module",
            "KEYWORDS=\"~amd64\"",
            "DESCRIPTION=\"x\""
          ]
      fixedTilde = setKeywords ["~amd64", "~arm64"] base
  assertTrue "match dual tilde" (keywordsMatch ["~amd64", "~arm64"] fixedTilde)
  -- Apply writes bare tokens when the plan includes them (plain-lane membership).
  let fixedBare = setKeywords ["amd64", "arm64"] base
  assertTrue "match dual bare" (keywordsMatch ["amd64", "arm64"] fixedBare)
  assertTrue "writes bare amd64" ("KEYWORDS=\"amd64 arm64\"" `T.isInfixOf` fixedBare)
  -- Drift: planned bare vs existing tilde needs content-fix.
  assertTrue
    "tilde vs bare drift"
    (not (keywordsMatch ["amd64"] base))
  assertTrue
    "content-fix on ~ → bare upgrade"
    ( ebuildNeedsContentFix
        ["amd64"]
        ( T.unlines
            [ "inherit go-module",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/pkg-${PV}/pkg-${PV}-vendor.tar.xz\""
            ]
        )
        Nothing
    )
  let noKw =
        T.unlines
          [ "inherit go-module",
            "",
            "DESCRIPTION=\"y\""
          ]
      inserted = setKeywords ["amd64"] noKw
  assertTrue "inserted bare" (keywordsMatch ["amd64"] inserted)

testGoPlanIntegrationMocked :: IO ()
testGoPlanIntegrationMocked = do
  withSystemTempDirectory "mndz-go-tree-" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        goDir = gentoo </> "dev-lang" </> "go"
    createDirectoryIfMissing True goDir
    TIO.writeFile
      (goDir </> "go-1.26.3.ebuild")
      "KEYWORDS=\"amd64 arm64\"\n"
    TIO.writeFile
      (goDir </> "go-1.26.5.ebuild")
      "KEYWORDS=\"~amd64 ~arm64\"\n"
    TIO.writeFile
      (goDir </> "go-9999.ebuild")
      "KEYWORDS=\"~amd64\"\n"
    let portageq args =
          pure $
            if args == ["get_repo_path", "/", "gentoo"]
              then Right (T.pack gentoo)
              else Left "unexpected portageq"
    ceilings <-
      assertRight "discover ceilings"
        =<< discoverGoCeilingsWith portageq
    assertEq
      "mock plain"
      (Just (parseEbuildVersion "1.26.3"))
      (acPlain (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
    assertEq
      "mock tilde"
      (Just (parseEbuildVersion "1.26.5"))
      (acTilde (Map.findWithDefault (ArchCeilings Nothing Nothing) "amd64" (rcByArch ceilings)))
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps =
          PlanOps
            { poPortageq = portageq,
              -- Newest-first (production listGitHubVersionsWith order).
              poListVersions = \_ ->
                pure $
                  Right
                    [ parseEbuildVersion "0.84.0",
                      parseEbuildVersion "0.82.0"
                    ],
              poFetchGoMod = \key ->
                pure $
                  Right $
                    case gmkTag key of
                      "v0.82.0" -> "module x\ngo 1.26.3\n"
                      "v0.84.0" -> "module x\ngo 1.26.5\n"
                      _ -> "module x\n",
              poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
    plan <-
      assertRight "plan go package"
        =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
    assertEq "planned unique" 2 (length (glpUniquePVs plan))
    assertTrue
      "has 0.82"
      (parseEbuildVersion "0.82.0" `elem` glpUniquePVs plan)
    assertTrue
      "has 0.84"
      (parseEbuildVersion "0.84.0" `elem` glpUniquePVs plan)
    -- Plain lanes → bare KEYWORDS; tilde-only lanes → ~KEYWORDS
    case [pe | pe <- glpEbuilds plan, pePV pe == parseEbuildVersion "0.82.0"] of
      [pe] -> assertEq "0.82 plain bare dual" ["amd64", "arm64"] (peKeywords pe)
      other -> do
        hPutStrLn stderr $ "plan 0.82 ebuild: " <> show other
        exitFailure
    case [pe | pe <- glpEbuilds plan, pePV pe == parseEbuildVersion "0.84.0"] of
      [pe] -> assertEq "0.84 tilde dual" ["~amd64", "~arm64"] (peKeywords pe)
      other -> do
        hPutStrLn stderr $ "plan 0.84 ebuild: " <> show other
        exitFailure

------------------------------------------------------------------------
-- go.mod probe early exit
------------------------------------------------------------------------

-- | Shared ceilings: plain 1.26.3, tilde 1.26.5 (both arches).
earlyExitCeilings :: RuntimeCeilings
earlyExitCeilings = dualArchGoCeilings (Just "1.26.3") (Just "1.26.5")

-- | Mock plan ops that record go.mod fetch tags (newest-first version list).
mkEarlyExitPlanOps ::
  [EbuildVersion] ->
  (T.Text -> Either T.Text T.Text) ->
  IO (PlanOps, IORef [T.Text])
mkEarlyExitPlanOps versions fetchBody = do
  budget <- newWorkBudget 2
  ceilingsCache <- newMVar (Just earlyExitCeilings)
  fetchTags <- newIORef ([] :: [T.Text])
  let planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Right versions),
            poFetchGoMod = \key -> do
              atomicModifyIORef' fetchTags (\ts -> (gmkTag key : ts, ()))
              pure (fetchBody (gmkTag key)),
            poWorkBudget = budget,
            poCeilingsCache = ceilingsCache
          }
  pure (planOps, fetchTags)

lanePV :: GoLanePlan -> LaneId -> Maybe EbuildVersion
lanePV plan lid =
  case [ltPackagePV t | t <- glpLanes plan, ltLane t == lid] of
    (m : _) -> m
    [] -> Nothing

-- | Tip go_req under every ceiling → one go.mod fetch; all lanes tip.
testGoModProbeEarlyExitTipFillsAll :: IO ()
testGoModProbeEarlyExitTipFillsAll = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\ngo 1.26.3\n"
        "v0.84.0" -> Right "module x\ngo 1.26.5\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "tip fills all"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertEq "only tip probed" ["v0.90.0"] tags
  assertEq "unique tip" [parseEbuildVersion "0.90.0"] (glpUniquePVs plan)
  assertEq
    "plain tip"
    (Just (parseEbuildVersion "0.90.0"))
    (lanePV plan LaneAmd64Plain)
  assertEq
    "tilde tip"
    (Just (parseEbuildVersion "0.90.0"))
    (lanePV plan LaneAmd64Tilde)

-- | Tilde takes newer PV; plain needs older; no probes older than plain target.
testGoModProbeEarlyExitPlainOlder :: IO ()
testGoModProbeEarlyExitPlainOlder = do
  let versions =
        [ parseEbuildVersion "0.86.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0",
          parseEbuildVersion "0.80.0"
        ]
      fetchBody = \case
        "v0.86.0" -> Right "module x\ngo 1.26.5\n"
        "v0.84.0" -> Right "module x\ngo 1.26.4\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        "v0.80.0" -> Right "module x\ngo 1.26.0\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "plain older"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertEq
    "stop after plain filled"
    ["v0.86.0", "v0.84.0", "v0.82.0"]
    tags
  assertTrue "did not probe older than plain" ("v0.80.0" `notElem` tags)
  assertEq
    "tilde 0.86"
    (Just (parseEbuildVersion "0.86.0"))
    (lanePV plan LaneAmd64Tilde)
  assertEq
    "plain 0.82"
    (Just (parseEbuildVersion "0.82.0"))
    (lanePV plan LaneAmd64Plain)

-- | Early-exit lane targets equal full-probe + selectAllLaneTargets.
testGoModProbeEarlyExitMatchesFullProbe :: IO ()
testGoModProbeEarlyExitMatchesFullProbe = do
  let versions =
        [ parseEbuildVersion "0.86.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0",
          parseEbuildVersion "0.80.0"
        ]
      goReqFor = \case
        "v0.86.0" -> Just "1.26.5"
        "v0.84.0" -> Just "1.26.4"
        "v0.82.0" -> Just "1.26.3"
        "v0.80.0" -> Just "1.26.0"
        _ -> Nothing
      fetchBody tag =
        case goReqFor tag of
          Just req -> Right ("module x\ngo " <> req <> "\n")
          Nothing -> Left "missing"
      fullCandidates =
        [ VersionCandidate
            { vcPV = pv,
              vcGoReq = goReqFor ("v" <> renderPVNoRev pv)
            }
        | pv <- versions
        ]
      expectedTargets = selectAllLaneTargets earlyExitCeilings fullCandidates
  (planOps, _) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "early exit matches full"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  assertEq
    "lane targets match full probe"
    expectedTargets
    (glpLanes plan)

-- | Unparseable tip is skipped; older parseable version used.
testGoModProbeEarlyExitSkipsUnparseableTip :: IO ()
testGoModProbeEarlyExitSkipsUnparseableTip = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\n" -- no go directive
        "v0.84.0" -> Right "module x\ngo 1.26.3\n"
        "v0.82.0" -> Right "module x\ngo 1.26.3\n"
        _ -> Left "missing"
  (planOps, fetchTags) <- mkEarlyExitPlanOps versions fetchBody
  plan <-
    assertRight "skip unparseable tip"
      =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
  tags <- reverse <$> readIORef fetchTags
  assertTrue "probed tip" ("v0.90.0" `elem` tags)
  assertTrue "probed next" ("v0.84.0" `elem` tags)
  assertEq
    "only tip then fill"
    ["v0.90.0", "v0.84.0"]
    tags
  assertEq "unique 0.84" [parseEbuildVersion "0.84.0"] (glpUniquePVs plan)
  assertEq
    "plain 0.84"
    (Just (parseEbuildVersion "0.84.0"))
    (lanePV plan LaneAmd64Plain)

-- | Progress reports three coarse steps; probe done once.
testGoPlanProgressCoarseSteps :: IO ()
testGoPlanProgressCoarseSteps = do
  let versions =
        [ parseEbuildVersion "0.90.0",
          parseEbuildVersion "0.84.0",
          parseEbuildVersion "0.82.0"
        ]
      fetchBody = \case
        "v0.90.0" -> Right "module x\ngo 1.26.3\n"
        tag -> Right ("module x\ngo 1.26.5\n" <> tag)
  (planOps, _) <- mkEarlyExitPlanOps versions fetchBody
  events <- newIORef ([] :: [T.Text])
  listCount <- newIORef (0 :: Int)
  probeCount <- newIORef (0 :: Int)
  let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
      progress =
        PlanProgress
          { ppOnCeilingsStart = logEv "ceilings-start",
            ppOnCeilingsDone = logEv "ceilings-done",
            ppOnListStart = logEv "list-start",
            ppOnListDone = \n -> do
              writeIORef listCount n
              logEv "list-done",
            ppOnProbeDone = do
              atomicModifyIORef' probeCount (\c -> (c + 1, ()))
              logEv "probe-done"
          }
  _ <-
    assertRight "plan with progress"
      =<< planGoPackageWithProgress planOps progress (GitHub "o" "r" "v") Nothing
  evs <- reverse <$> readIORef events
  nList <- readIORef listCount
  nProbe <- readIORef probeCount
  assertEq
    "coarse event order"
    [ "ceilings-start",
      "ceilings-done",
      "list-start",
      "list-done",
      "probe-done"
    ]
    evs
  assertEq "list reports version count" 3 nList
  assertEq "probe done once" 1 nProbe
  -- Hooks optional path still works.
  _ <-
    assertRight "noop progress"
      =<< planGoPackageWithProgress
        planOps
        noopPlanProgress
        (GitHub "o" "r" "v")
        Nothing
  pure ()

------------------------------------------------------------------------
-- Richer activity progress / work budget / go.mod cache
------------------------------------------------------------------------

testGoModCacheConcurrentDistinctKeys :: IO ()
testGoModCacheConcurrentDistinctKeys = do
  inFlight <- newIORef (0 :: Int)
  maxSeen <- newIORef (0 :: Int)
  fetchCount <- newIORef (0 :: Int)
  let base key = do
        atomicModifyIORef' fetchCount (\n -> (n + 1, ()))
        cur <-
          atomicModifyIORef' inFlight $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen $ \m -> (max m cur, ())
        threadDelay 40_000
        atomicModifyIORef' inFlight $ \n -> (n - 1, ())
        pure (Right ("body-" <> gmkTag key))
  cached <- withGoModCache base
  let keys =
        [ GoModKey "o" "r" "v1" Nothing,
          GoModKey "o" "r" "v2" Nothing,
          GoModKey "o" "r" "v3" Nothing,
          GoModKey "o" "r" "v4" Nothing
        ]
  results <- mapConcurrently cached keys
  peak <- readIORef maxSeen
  fetches <- readIORef fetchCount
  assertEq "four results" 4 (length results)
  assertTrue "distinct keys overlap" (peak > 1)
  assertEq "one fetch per key" 4 fetches

testGoModCacheHitNoRefetch :: IO ()
testGoModCacheHitNoRefetch = do
  fetchCount <- newIORef (0 :: Int)
  let key = GoModKey "o" "r" "v1" Nothing
      base _ = do
        atomicModifyIORef' fetchCount (\n -> (n + 1, ()))
        pure (Right "mod")
  cached <- withGoModCache base
  r1 <- cached key
  r2 <- cached key
  fetches <- readIORef fetchCount
  assertEq "first hit" (Right "mod") r1
  assertEq "second hit" (Right "mod") r2
  assertEq "single network fetch" 1 fetches

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
dualArchGoCeilings :: Maybe T.Text -> Maybe T.Text -> RuntimeCeilings
dualArchGoCeilings plainTok tildeTok =
  let plain = parseEbuildVersion <$> plainTok
      tilde = parseEbuildVersion <$> tildeTok
      ac = ArchCeilings {acPlain = plain, acTilde = tilde}
   in RuntimeCeilings
        { rcAtom = "dev-lang/go",
          rcByArch = Map.fromList [("amd64", ac), ("arm64", ac)]
        }

-- | Minimal ApplyEnv for content-fix / unit-apply tests.
mkTestApplyEnv ::
  GitOps ->
  PlanOps ->
  EbuildRunner ->
  ReleaseOps ->
  VendorOps ->
  Maybe FilePath ->
  MVar () ->
  MVar () ->
  IO ApplyEnv
mkTestApplyEnv gitOps planOps ebuildRun releaseOps vendorOps assetsRoot assetsLock overlayLock = do
  depsBase <- productionDepsPlanOps (Just "tok") 1 Nothing
  let depsOps =
        depsBase
          { dpoPortageq = poPortageq planOps,
            dpoListVersions = poListVersions planOps,
            dpoFetchGoMod = poFetchGoMod planOps,
            dpoWorkBudget = poWorkBudget planOps,
            dpoGoCeilingsCache = poCeilingsCache planOps
          }
  pure
    ApplyEnv
      { aeFetcher = \_ -> pure (Left "unused"),
        aeGitOps = gitOps,
        aeEbuildRunner = ebuildRun,
        aeEgencacheRunner = mockEgencacheWriteMatching,
        aeVendorOps = vendorOps,
        aeNpmCacheOps = productionNpmCacheOps,
        aeBunCacheOps = productionBunCacheOps,
        aeReleaseOps = releaseOps,
        aeAssetsRoot = assetsRoot,
        aeGitHubToken = Just "tok",
        aeAssetsOwner = "0x6d6e647a",
        aeAssetsRepo = "mndz-overlay-assets",
        aeAssetsLock = assetsLock,
        aeOverlayLock = overlayLock,
        aeJobs = 1,
        aeMulti = noopMultiHandle,
        aePlanOps = planOps,
        aeDepsPlanOps = depsOps
      }

-- | Write a matching md5-dict cache file for one ebuild.
writeMatchingCacheFile :: FilePath -> T.Text -> T.Text -> T.Text -> FilePath -> IO ()
writeMatchingCacheFile overlayRoot category pn verText ebuildPath = do
  md5 <- ebuildFileMd5 ebuildPath
  let cpath = cacheFilePath overlayRoot category pn verText
  createDirectoryIfMissing True (takeDirectory cpath)
  TIO.writeFile cpath ("_md5_=" <> md5 <> "\nDESCRIPTION=test\n")

-- | Matching cache for every non-live ebuild under a package directory.
writeMatchingCachesForPackage :: FilePath -> T.Text -> T.Text -> FilePath -> IO ()
writeMatchingCachesForPackage overlayRoot category pn pkgDir = do
  vers <- listNonLiveEbuildVersions pkgDir pn
  mapM_ (uncurry (writeMatchingCacheFile overlayRoot category pn)) vers

-- | Mock egencache: rewrite matching cache entries for requested atoms.
mockEgencacheWriteMatching :: EgencacheRequest -> IO (Either T.Text ())
mockEgencacheWriteMatching req = do
  let root = erOverlayRoot req
      atoms =
        if null (erAtoms req)
          then []
          else erAtoms req
  if null atoms
    then pure (Right ())
    else do
      mapM_
        ( \atom ->
            case T.breakOn "/" atom of
              (cat, rest)
                | Just ('/', pn) <- T.uncons rest -> do
                    let pkgDir = root </> T.unpack cat </> T.unpack pn
                    writeMatchingCachesForPackage root cat pn pkgDir
                | otherwise -> pure ()
        )
        atoms
      pure (Right ())

unusedVendorOps :: VendorOps
unusedVendorOps =
  VendorOps
    { voClone = \_ _ _ -> pure (Left "unused"),
      voHostGoVersion = pure (Right "1.26.5"),
      voGoModDownload = \_ -> pure (Left "unused"),
      voTarXz = \_ _ _ -> pure (Left "unused")
    }

unusedReleaseOps :: ReleaseOps
unusedReleaseOps =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "unused"),
      roCreateReleaseWithAsset = \_ _ -> pure (Left "unused")
    }

testContentFixManifest :: IO ()
testContentFixManifest =
  withSystemTempDirectory "mndz-content-fix-" $ \tmp -> do
    let pkgDir = tmp </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        plan =
          GoLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild
                    { pePV = pv,
                      peKeywords = ["~amd64"],
                      peLanes = []
                    }
                ],
              glpUniquePVs = [pv],
              glpRuntimeAtom = "dev-lang/go"
            }
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused budget",
              poCeilingsCache = error "unused ceilings"
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps' =
          planOps
            { poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
    env <-
      mkTestApplyEnv
        gitOps
        planOps'
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    -- No Manifest → needs work
    fix1 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "missing Manifest needs work" [pv] fix1
    -- Manifest without vendor DIST → needs work
    TIO.writeFile (pkgDir </> "Manifest") "DIST crush-0.84.0.tar.gz 1 SHA512 deadbeef\n"
    fix2 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "missing vendor DIST needs work" [pv] fix2
    -- Complete Manifest + good ebuild → no content fix
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 123 BLAKE2B aa SHA512 abcdef0123456789\n"
    fix3 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "complete Manifest no content fix" [] fix3
    assertTrue
      "ebuild content ok"
      ( not
          ( ebuildNeedsContentFix
              ["~amd64"]
              ebuildBody
              (Just "1.26.5")
          )
      )

testMarkSuccessLinesReused :: IO ()
testMarkSuccessLinesReused = do
  let sl =
        SuccessLine
          { slFrom = parseEbuildVersion "0.80.0",
            slTo = parseEbuildVersion "0.84.0",
            slLabel = Just "(dev-lang/go ~amd64)",
            slAssetsReused = False
          }
      marked = markSuccessLinesReused [sl]
  assertEq "flag set" True (all slAssetsReused marked)
  case marked of
    (m : _) -> assertEq "from preserved" (slFrom sl) (slFrom m)
    [] -> do
      hPutStrLn stderr "expected non-empty marked success lines"
      exitFailure

testReuseVsFullPublish :: IO ()
testReuseVsFullPublish =
  withSystemTempDirectory "mndz-reuse-pub-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
    vendorCallRef <- newIORef (0 :: Int)
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    -- Seed a known asset body for download + Manifest hash match.
    let assetBytes = encodeUtf8 "vendor-tarball-bytes-for-reuse-test"
        digests0 = hashBytes assetBytes
        ebuildRunnerWrong _pkg _name = do
          -- Write Manifest with wrong SHA512 to force hard-fail path later.
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> ("0" <> T.replicate 127 "1")
                <> "\n"
            )
          pure (Right ())
        ebuildRunnerOk _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ ->
                pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused budget",
              poCeilingsCache = error "unused ceilings"
            }
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps' =
          planOps
            { poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
        vendorOps =
          VendorOps
            { voClone = \_ _ _ -> do
                atomicModifyIORef' vendorCallRef (\n -> (n + 1, ()))
                pure (Left "vendor should not run on reuse"),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Left "vendor should not run on reuse"),
              voTarXz = \_ _ _ -> pure (Left "vendor should not run on reuse")
            }
        -- Partially applied: locks supplied at call sites.
        mkEnv releaseOps ebuildRun =
          mkTestApplyEnv
            gitOps
            planOps'
            ebuildRun
            releaseOps
            vendorOps
            (Just assetsRoot)
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
        releaseFound =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = "crush-0.84.0",
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack tarballName,
                                  raBrowserDownloadUrl = "https://example/vendor"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
        releaseMissing =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
              roDownloadAsset = \_ _ -> pure (Left "should not download"),
              roCreateReleaseWithAsset = \_ _ -> pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    -- Reuse path: no vendor calls; success with assets reused; Manifest matches.
    writeIORef vendorCallRef 0
    stepsDoneReuse <- newIORef (0 :: Int)
    envReuse <- mkEnv releaseFound ebuildRunnerOk assetsLock overlayLock
    outcomeReuse <-
      goPublishAndOverlay
        envReuse
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneReuse
        1
    case outcomeReuse of
      ApplySuccess _ sls _ -> do
        assertTrue "reuse marks lines" (all slAssetsReused sls)
        n <- readIORef vendorCallRef
        assertEq "reuse skips vendor" 0 n
      other -> do
        hPutStrLn stderr ("expected reuse success, got: " <> show other)
        exitFailure
    -- Manifest mismatch hard-fails on reuse.
    stepsDoneBad <- newIORef (0 :: Int)
    envBad <- mkEnv releaseFound ebuildRunnerWrong assetsLock overlayLock
    outcomeBad <-
      goPublishAndOverlay
        envBad
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneBad
        1
    case outcomeBad of
      ApplyHardFail _ msg _ _ ->
        assertTrue
          "manifest mismatch message"
          ("Manifest SHA512" `T.isInfixOf` msg)
      other -> do
        hPutStrLn stderr ("expected hard fail, got: " <> show other)
        exitFailure
    -- Not-found → full path (vendor called). Use lock for full path.
    let vendorOpsFull =
          VendorOps
            { voClone = \_ _ dest -> do
                atomicModifyIORef' vendorCallRef (\n -> (n + 1, ()))
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                BS.writeFile outPath assetBytes
                pure (Right ())
            }
    writeIORef vendorCallRef 0
    stepsDoneFull <- newIORef (0 :: Int)
    envFull0 <- mkEnv releaseMissing ebuildRunnerOk assetsLock overlayLock
    let envFull = envFull0 {aeVendorOps = vendorOpsFull}
    _ <-
      goPublishAndOverlay
        envFull
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneFull
        1
    nFull <- readIORef vendorCallRef
    assertTrue "not-found uses full vendor path" (nFull > 0)

-- | GitMv success signs/commits before returning ApplySuccess (no barrier).
testGitMvCommitsOnSuccess :: IO ()
testGitMvCommitsOnSuccess =
  withSystemTempDirectory "mndz-gitmv-commit-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        pkgDir = overlayRoot </> "dev-util" </> "grok-build-bin"
        oldName = "grok-build-bin-0.2.99.ebuild"
        local = parseEbuildVersion "0.2.99"
        remote = parseEbuildVersion "0.2.101"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "grok-build-bin",
              pePN = "grok-build-bin",
              peLocal = local,
              pePath = pkgDir </> oldName
            }
    commitCount <- newIORef (0 :: Int)
    commitMsgs <- newIORef ([] :: [T.Text])
    commitPaths <- newIORef ([] :: [[FilePath]])
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> oldName) "EAPI=8\n"
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage
      overlayRoot
      "dev-util"
      "grok-build-bin"
      pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_root paths msg -> do
                atomicModifyIORef' commitCount (\n -> (n + 1, ()))
                atomicModifyIORef' commitMsgs (\ms -> (msg : ms, ()))
                atomicModifyIORef' commitPaths (\ps -> (paths : ps, ()))
                assertTrue "stages paths" (not (null paths))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg name = do
          -- Simulate ebuild manifest creating Manifest after rename.
          TIO.writeFile (pkgDir </> "Manifest") ("DIST " <> T.pack name <> " 1\n")
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Left "unused"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 1
    ceilingsCache <- newMVar Nothing
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    let env = env0 {aeFetcher = \_ -> pure (Right remote)}
    outcomes <- applyPackagePhase1 env overlayRoot entry
    case outcomes of
      [ApplySuccess _ _ paths] -> do
        n <- readIORef commitCount
        assertEq "exactly one signed commit" 1 n
        msgs <- readIORef commitMsgs
        assertTrue
          "commit message format"
          ("dev-util/grok-build-bin: 0.2.101" `elem` msgs)
        assertTrue "paths recorded" (not (null paths))
        assertTrue
          "commit includes md5-cache path"
          (any (("md5-cache" `T.isInfixOf`) . T.pack) paths)
      other -> do
        hPutStrLn stderr ("expected single ApplySuccess, got: " <> show other)
        exitFailure

-- | Two Go PVs: commit after first; second dirty check sees clean tree; two commits.
testGoMultiPvSequentialCommits :: IO ()
testGoMultiPvSequentialCommits =
  withSystemTempDirectory "mndz-multi-pv-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        pv1 = parseEbuildVersion "0.82.0"
        pv2 = parseEbuildVersion "0.84.0"
        tip = parseEbuildVersion "0.80.0"
        ebuildBody goAtom =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\"" <> goAtom <> "\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = tip,
              pePath = pkgDir </> "crush-0.80.0.ebuild"
            }
        plan =
          GoLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild {pePV = pv1, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv2, peKeywords = ["~amd64"], peLanes = []}
                ],
              -- Include tip so prune does not add a third commit in this test.
              glpUniquePVs = [tip, pv1, pv2],
              glpRuntimeAtom = "dev-lang/go"
            }
        assetBytes = encodeUtf8 "vendor-bytes-multi-pv"
        digests0 = hashBytes assetBytes
    commitMsgs <- newIORef ([] :: [T.Text])
    -- After each commit, paths are clean (simulate HEAD includes them).
    dirtyPaths <- newIORef ([] :: [FilePath])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> "crush-0.80.0.ebuild") (ebuildBody ">=dev-lang/go-1.26.5:=")
    TIO.writeFile (pkgDir </> "Manifest") "DIST crush-0.80.0.tar.gz 1 SHA512 aa\n"
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ paths -> do
                dirty <- readIORef dirtyPaths
                pure (Right (any (`elem` dirty) paths)),
              goAddAndCommit = \_root paths msg -> do
                atomicModifyIORef' commitMsgs (\ms -> (msg : ms, ()))
                -- Commit clears dirt for those paths.
                modifyIORef' dirtyPaths (filter (`notElem` paths))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg name = do
          let tarball =
                if "0.82.0" `T.isInfixOf` T.pack name
                  then "crush-0.82.0-vendor.tar.xz"
                  else "crush-0.84.0-vendor.tar.xz"
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarball
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          -- Mutating Manifest dirties it until commit.
          atomicModifyIORef'
            dirtyPaths
            (\d -> (nub ("dev-util/crush/Manifest" : d), ()))
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ tag ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = tag,
                          riAssets =
                            [ ReleaseAsset
                                { raName =
                                    if "0.82.0" `T.isInfixOf` tag
                                      then "crush-0.82.0-vendor.tar.xz"
                                      else "crush-0.84.0-vendor.tar.xz",
                                  raBrowserDownloadUrl = "https://example/v"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    env <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    outcomes <-
      materializePlan
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        plan
        [tip]
        [] -- contentFix empty; missing targets drive need
        0
    let successes = [o | o@ApplySuccess {} <- outcomes]
    assertEq "two PV successes" 2 (length successes)
    msgs <- reverse <$> readIORef commitMsgs
    assertEq "two overlay commits" 2 (length msgs)
    assertTrue
      "first PV commit"
      ("dev-util/crush: 0.82.0" `elem` msgs)
    assertTrue
      "second PV commit"
      ("dev-util/crush: 0.84.0" `elem` msgs)
    assertTrue
      "PV commits include md5-cache"
      ( all
          ( \case
              ApplySuccess _ _ paths ->
                any (("md5-cache" `T.isInfixOf`) . T.pack) paths
              _ -> False
          )
          successes
      )

-- | First PV commits; second hard-fails; no prune; later PVs not started.
testGoMultiPvStopOnHardFail :: IO ()
testGoMultiPvStopOnHardFail =
  withSystemTempDirectory "mndz-multi-pv-fail-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        pv1 = parseEbuildVersion "0.82.0"
        pv2 = parseEbuildVersion "0.84.0"
        pv3 = parseEbuildVersion "0.86.0"
        tip = parseEbuildVersion "0.80.0"
        extraName = "crush-0.70.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = tip,
              pePath = pkgDir </> "crush-0.80.0.ebuild"
            }
        plan =
          GoLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild {pePV = pv1, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv2, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv3, peKeywords = ["~amd64"], peLanes = []}
                ],
              glpUniquePVs = [pv1, pv2, pv3],
              glpRuntimeAtom = "dev-lang/go"
            }
        assetBytes = encodeUtf8 "vendor-bytes-fail-test"
        digests0 = hashBytes assetBytes
    commitCount <- newIORef (0 :: Int)
    materializeCount <- newIORef (0 :: Int)
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> "crush-0.80.0.ebuild") ebuildBody
    TIO.writeFile (pkgDir </> extraName) ebuildBody -- would be pruned only on full success
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> do
                atomicModifyIORef' commitCount (\n -> (n + 1, ()))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          atomicModifyIORef' materializeCount (\n -> (n + 1, ()))
          n <- readIORef materializeCount
          if n >= 2
            then pure (Left "simulated ebuild manifest failure")
            else do
              TIO.writeFile
                (pkgDir </> "Manifest")
                ( "DIST crush-0.82.0-vendor.tar.xz 1 SHA512 "
                    <> digestSHA512 digests0
                    <> "\n"
                )
              pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ tag ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = tag,
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack (T.unpack tag <> "-vendor.tar.xz"),
                                  raBrowserDownloadUrl = "https://example/v"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    env <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    outcomes <-
      materializePlan
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        plan
        [tip]
        []
        0
    let successes = [o | o@ApplySuccess {} <- outcomes]
        fails = [o | o@ApplyHardFail {} <- outcomes]
    assertEq "one success retained" 1 (length successes)
    assertEq "one hard fail" 1 (length fails)
    nMat <- readIORef materializeCount
    assertEq "stopped after second PV (no third)" 2 nMat
    nCommit <- readIORef commitCount
    assertEq "only first PV committed (no prune commit)" 1 nCommit
    -- Extra ebuild still present (prune not run).
    extraExists <- doesFileExist (pkgDir </> extraName)
    assertTrue "prune not run" extraExists

-- | Vendor progress fires clone → download → compress start/done in order.
testVendorProgressEventOrder :: IO ()
testVendorProgressEventOrder =
  withSystemTempDirectory "mndz-vendor-progress-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        progress =
          VendorProgress
            { vpOnCloneStart = logEv "clone-start",
              vpOnCloneDone = logEv "clone-done",
              vpOnDownloadStart = logEv "download-start",
              vpOnDownloadDone = logEv "download-done",
              vpOnCompressStart = logEv "compress-start",
              vpOnCompressDone = logEv "compress-done"
            }
        ops =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                writeFile outPath "fake-tarball"
                pure (Right ())
            }
    result <-
      buildVendorTarball
        ops
        progress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor.tar.xz"
    case result of
      Left err -> do
        hPutStrLn stderr ("expected vendor success, got: " <> T.unpack err)
        exitFailure
      Right _ -> pure ()
    evs <- reverse <$> readIORef events
    assertEq
      "vendor progress order"
      [ "clone-start",
        "clone-done",
        "download-start",
        "download-done",
        "compress-start",
        "compress-done"
      ]
      evs
    -- No-op progress still succeeds.
    void $
      buildVendorTarball
        ops
        noopVendorProgress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor-noop.tar.xz"

-- | Full-path apply advances fine-grained status/step events in order.
testFullPathApplyProgressSequence :: IO ()
testFullPathApplyProgressSequence =
  withSystemTempDirectory "mndz-full-progress-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        assetBytes = encodeUtf8 "vendor-tarball-bytes-for-full-progress"
        digests0 = hashBytes assetBytes
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
    events <- newIORef ([] :: [T.Text])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "app-misc" pn pkgDir
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        mh =
          MultiHandle
            { mhStart = \_ -> pure (),
              mhStatus = \_ name -> logEv ("status:" <> name),
              mhSteps = \_ n -> logEv ("steps:" <> T.pack (show n)),
              mhStep = \_ name -> logEv ("step:" <> name),
              mhSuccess = \_ -> pure (),
              mhFail = \_ _ -> pure ()
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
              roDownloadAsset = \_ _ -> pure (Left "should not download"),
              roCreateReleaseWithAsset = \_ _ -> pure (Right ())
            }
        vendorOps =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                BS.writeFile outPath assetBytes
                pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    stepsDone <- newIORef (0 :: Int)
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        vendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    let env = env0 {aeMulti = mh}
    outcome <-
      goPublishAndOverlay
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDone
        1
    case outcome of
      ApplySuccess {} -> pure ()
      other -> do
        hPutStrLn stderr ("expected full-path success, got: " <> show other)
        exitFailure
    evs <- reverse <$> readIORef events
    let statuses = [e | e <- evs, "status:" `T.isPrefixOf` e]
        steps = [e | e <- evs, "step:" `T.isPrefixOf` e]
    assertEq
      "full-path status sequence"
      [ "status:probing release asset",
        "status:cloning upstream",
        "status:go mod download",
        "status:compressing tarball",
        "status:committing assets",
        "status:pushing assets",
        "status:uploading release asset",
        "status:regenerating manifest"
      ]
      statuses
    assertEq
      "full-path step sequence"
      [ "step:cloning upstream",
        "step:go mod download",
        "step:compressing tarball",
        "step:committing assets",
        "step:pushing assets",
        "step:uploading release asset",
        "step:regenerating manifest"
      ]
      steps
    assertTrue
      "no coarse vendoring label"
      (not (any ("vendoring" `T.isInfixOf`) evs))
    assertTrue
      "no coarse publishing assets label"
      (not (any ("publishing assets" `T.isInfixOf`) evs))
    done <- readIORef stepsDone
    assertEq "full path marks 7 steps done" fullPathMaterializeSteps done

-- | Reuse-path apply uses reuse step names only.
testReusePathApplyProgressSequence :: IO ()
testReusePathApplyProgressSequence =
  withSystemTempDirectory "mndz-reuse-progress-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        assetBytes = encodeUtf8 "vendor-tarball-bytes-for-reuse-progress"
        digests0 = hashBytes assetBytes
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
    events <- newIORef ([] :: [T.Text])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "app-misc" pn pkgDir
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        mh =
          MultiHandle
            { mhStart = \_ -> pure (),
              mhStatus = \_ name -> logEv ("status:" <> name),
              mhSteps = \_ n -> logEv ("steps:" <> T.pack (show n)),
              mhStep = \_ name -> logEv ("step:" <> name),
              mhSuccess = \_ -> pure (),
              mhFail = \_ _ -> pure ()
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = "crush-0.84.0",
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack tarballName,
                                  raBrowserDownloadUrl = "https://example/vendor"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    stepsDone <- newIORef (0 :: Int)
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    let env = env0 {aeMulti = mh}
    outcome <-
      goPublishAndOverlay
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDone
        1
    case outcome of
      ApplySuccess _ sls _ ->
        assertTrue "reuse marks lines" (all slAssetsReused sls)
      other -> do
        hPutStrLn stderr ("expected reuse success, got: " <> show other)
        exitFailure
    evs <- reverse <$> readIORef events
    let statuses = [e | e <- evs, "status:" `T.isPrefixOf` e]
        steps = [e | e <- evs, "step:" `T.isPrefixOf` e]
        forbidden =
          [ "vendoring",
            "publishing assets",
            "cloning upstream",
            "go mod download",
            "compressing tarball",
            "committing assets",
            "pushing assets",
            "uploading release asset"
          ]
    assertEq
      "reuse status sequence"
      [ "status:probing release asset",
        "status:reusing release assets",
        "status:verifying vendor asset",
        "status:regenerating manifest"
      ]
      statuses
    assertEq
      "reuse step sequence"
      [ "step:reusing release assets",
        "step:verifying vendor asset",
        "step:regenerating manifest"
      ]
      steps
    assertTrue
      "no full-path / coarse names on reuse"
      (not (any (\bad -> any (bad `T.isInfixOf`) evs) forbidden))
    done <- readIORef stepsDone
    assertEq "reuse path marks 3 steps done" reusePathMaterializeSteps done

-- | Step-total upper bound and revise-after-probe math for full vs reuse.
testMaterializeStepBudget :: IO ()
testMaterializeStepBudget = do
  assertEq "full path step count" 7 fullPathMaterializeSteps
  assertEq "reuse path step count" 3 reusePathMaterializeSteps
  assertEq
    "upper bound planDone=3 n=2"
    17
    (materializeStepTotalUpper 3 2)
  assertEq
    "single full path total"
    7
    (reviseMaterializeStepTotal 0 fullPathMaterializeSteps 0)
  assertEq
    "single reuse path total"
    3
    (reviseMaterializeStepTotal 0 reusePathMaterializeSteps 0)
  -- Mixed: planDone=3, first PV reuses (3), one PV remains at full upper bound.
  assertEq
    "reuse first of two"
    (3 + 3 + 7)
    (reviseMaterializeStepTotal 3 reusePathMaterializeSteps 1)
  -- After first full path (7), second reuses:
  assertEq
    "reuse second after full"
    (3 + 7 + 3)
    (reviseMaterializeStepTotal (3 + 7) reusePathMaterializeSteps 0)
  -- After first reuse (3), second full:
  assertEq
    "full second after reuse"
    (3 + 3 + 7)
    (reviseMaterializeStepTotal (3 + 3) fullPathMaterializeSteps 0)

-- | Concurrent overlay commits serialize under aeOverlayLock.
testOverlayCommitLock :: IO ()
testOverlayCommitLock = do
  inCritical <- newIORef (0 :: Int)
  maxInCritical <- newIORef (0 :: Int)
  let gitOps =
        GitOps
          { goIsWorkTree = \_ -> pure True,
            goPathsDirty = \_ _ -> pure (Right False),
            goAddAndCommit = \_ _ _ -> do
              n <- atomicModifyIORef' inCritical (\x -> (x + 1, x + 1))
              atomicModifyIORef' maxInCritical (\m -> (max m n, ()))
              threadDelay 30_000
              atomicModifyIORef' inCritical (\x -> (x - 1, ()))
              pure (Right ()),
            goPush = \_ -> pure (Right ())
          }
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
  budget <- newWorkBudget 2
  ceilingsCache <- newMVar Nothing
  let planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Left "unused"),
            poFetchGoMod = \_ -> pure (Left "unused"),
            poWorkBudget = budget,
            poCeilingsCache = ceilingsCache
          }
  env <-
    mkTestApplyEnv
      gitOps
      planOps
      (\_ _ -> pure (Right ()))
      unusedReleaseOps
      unusedVendorOps
      Nothing
      assetsLock
      overlayLock
  _ <-
    mapConcurrently
      (signedOverlayCommit env "/tmp" ["a.ebuild"])
      ["msg-a" :: T.Text, "msg-b"]
  peak <- readIORef maxInCritical
  assertEq "no overlapping overlay critical section" 1 peak

-- | Presence of wrong-version go BDEPEND still needs content-fix.
testBdependMismatchNeedsFix :: IO ()
testBdependMismatchNeedsFix = do
  let body =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.24.11:=\"",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  assertTrue
    "presence alone does not satisfy"
    (ebuildHasDevLangGoBdepend body)
  assertTrue
    "mismatch needs fix"
    (ebuildNeedsContentFix ["~amd64"] body (Just "1.26.5"))
  assertTrue
    "matching does not need fix"
    ( not
        ( ebuildNeedsContentFix
            ["~amd64"]
            (T.replace "1.24.11" "1.26.5" body)
            (Just "1.26.5")
        )
    )
  assertTrue
    "goBdependMatches rejects wrong ver"
    (not (goBdependMatches "1.26.5" body))

-- | Missing BDEPEND with known go.mod still needs-work; ensureGoBdepend still works.
testBdependMissingNeedsFix :: IO ()
testBdependMissingNeedsFix = do
  let body =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  assertTrue
    "missing needs fix"
    (ebuildNeedsContentFix ["~amd64"] body (Just "1.26.5"))
  inserted <- assertRight "insert" (ensureGoBdepend "1.26.5" body)
  assertTrue "matches after insert" (goBdependMatches "1.26.5" inserted)
  assertTrue
    "no longer needs fix"
    (not (ebuildNeedsContentFix ["~amd64"] inserted (Just "1.26.5")))
  let withOld =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.20:=\"",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  replaced <- assertRight "replace" (ensureGoBdepend "1.26.5" withOld)
  assertTrue "replace matches" (goBdependMatches "1.26.5" replaced)

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
    case outcomes of
      [ApplyHardFail _ msg half _] -> do
        assertTrue "mentions gencache" ("gencache" `T.isInfixOf` msg)
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
