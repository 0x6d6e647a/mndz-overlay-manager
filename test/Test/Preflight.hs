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
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, prettyVersion)
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
    ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    EbuildRunner,
    PackagePlanResult (..),
    PlannedWork (..),
    applyPackagePhase1Tracked,
    foldExitHardFail,
    needsWorkCargo,
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
import Update.DiskSpace (MaterializeClass (..))
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
import Update.Go.Lanes (GapLine (..), LaneId (..), LaneTarget (..), PlanError (..), PlannedEbuild (..), RuntimeLanePlan (..), VersionCandidate (..), assembleKeywords, buildGapLines, collapsePlannedEbuilds, extrasToDelete, filterCandidateVersions, laneLabel, laneLabelWith, ltLane, maxVersionUnder, missingTargets, planErrorMessage, planFromTargets, planNeedsWork, selectAllLaneTargets, zeroPlannedPVsError, pattern LaneAmd64Plain, pattern LaneAmd64Tilde, pattern LaneArm64Plain, pattern LaneArm64Tilde)
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
    assetsPreflightFromPlan,
    assetsRequiredTools,
    bunRequiredTools,
    cargoFetcherAdvisories,
    cargoFetcherAria2Advisory,
    cargoFetcherTools,
    cargoRequiredTools,
    checkToolsOnPath,
    dockerRequiredTools,
    goAssetsRequiredTools,
    goRequiredTools,
    npmRequiredTools,
    preflightUpdateToolsWith,
    preflightUpdateToolsWithImage,
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
      testCase "Bare aria2 does not satisfy cargo fetcher hard check" testBareAria2NotEnough,
      testCase "Cargo fetcher soft advisory full-path wget only" testCargoFetcherAdvisoryFullPath,
      testCase "Cargo fetcher soft advisory aria2c present none" testCargoFetcherAdvisoryAria2cPresent,
      testCase "Cargo fetcher soft advisory reuse-only none" testCargoFetcherAdvisoryReuseOnly,
      testCase "Cargo fetcher advisories merge into run warnings list" testCargoFetcherAdvisoryMergeWarnings,
      testCase "Strip Surrounding Quotes" testStripSurroundingQuotes,
      testCase "Assets preflight bare binary needs-work skips go" testAssetsPfBinaryOnly,
      testCase "Assets preflight reuse-only Go skips go" testAssetsPfReuseOnlyGo,
      testCase "Assets preflight cargo reuse-only skips docker and pycargo" testAssetsPfCargo,
      testCase "Full-path missing docker hard-fails" testFullPathMissingDocker,
      testCase "Reuse-only without docker is ok" testReuseOnlyWithoutDocker,
      testCase "Reuse-only cargo without pycargoebuild is ok" testReuseCargoWithoutPycargo,
      testCase "Full-path unusable image hard-fails" testFullPathMissingImage
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
  assertEq "docker tools" ["docker"] dockerRequiredTools
  assertEq "assets tools" ["xz"] assetsRequiredTools
  assertEq "go tools" ["go"] goRequiredTools
  assertEq "npm tools" ["npm"] npmRequiredTools
  assertEq "bun tools" ["bun"] bunRequiredTools
  assertEq "cargo tools" ["pycargoebuild"] cargoRequiredTools
  assertEq "cargo fetchers" ["wget", "aria2c"] cargoFetcherTools
  assertEq
    "cargo aria2 advisory text"
    "pycargoebuild is using wget; install aria2 for faster crate fetches"
    cargoFetcherAria2Advisory
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
      apNeedCargo = False,
      apNeedDocker = False
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
            apNeedCargo = True,
            apNeedDocker = True
          }
  okFull <-
    preflightUpdateToolsWith
      ( \name ->
          pure $
            if name `elem` ["aria2c", "go", "npm", "bun", "xz", "pycargoebuild"]
              then Nothing
              else Just ("/bin/" <> name)
      )
      full
  assertEq "full-path ok without host language tools" (Right ()) okFull
  missDocker <-
    preflightUpdateToolsWith
      (missingNamed ["docker"])
      full
  errDocker <- assertLeft "missing docker" missDocker
  assertTrue "lists docker" ("docker" `T.isInfixOf` errDocker)

-- | Bare host @aria2@ does not satisfy full-path cargo; docker + image do.
testBareAria2NotEnough :: IO ()
testBareAria2NotEnough = do
  let full = basePreflight {apNeedDocker = True}
  miss <-
    preflightUpdateToolsWith
      ( \name ->
          pure $
            if name == "docker"
              then Nothing
              else Just ("/bin/" <> name)
      )
      full
  err <- assertLeft "missing docker; host aria2 is irrelevant" miss
  assertTrue "lists docker" ("docker" `T.isInfixOf` err)

cargoFullPathClassify :: [ClassifyPackageResult]
cargoFullPathClassify =
  let key = PackageKey "dev-util/mise"
      pv = parseEbuildVersion "2025.1.0"
   in [ ClassifyOk
          key
          [ ClassifiedPvUnit
              { cpuKey = key,
                cpuPN = "mise",
                cpuPV = pv,
                cpuEco = Cargo Nothing Nothing,
                cpuClass = FullCargo,
                cpuTempBaseline = Just (5 * 1024 * 1024)
              }
          ]
      ]

cargoReuseOnlyClassify :: [ClassifyPackageResult]
cargoReuseOnlyClassify =
  let key = PackageKey "dev-util/mise"
      pv = parseEbuildVersion "2025.1.0"
   in [ ClassifyOk
          key
          [ ClassifiedPvUnit
              { cpuKey = key,
                cpuPN = "mise",
                cpuPV = pv,
                cpuEco = Cargo Nothing Nothing,
                cpuClass = ReusePath,
                cpuTempBaseline = Just (5 * 1024 * 1024)
              }
          ]
      ]

testCargoFetcherAdvisoryFullPath :: IO ()
testCargoFetcherAdvisoryFullPath = do
  advisories <-
    cargoFetcherAdvisories
      ( \name ->
          pure $
            if name == "aria2c"
              then Nothing
              else Just ("/bin/" <> name)
      )
      cargoFullPathClassify
  assertEq "no host wget/aria2 advisory" [] advisories

testCargoFetcherAdvisoryAria2cPresent :: IO ()
testCargoFetcherAdvisoryAria2cPresent = do
  advisories <-
    cargoFetcherAdvisories
      (\name -> pure (Just ("/bin/" <> name)))
      cargoFullPathClassify
  assertEq "no advisory when aria2c present" [] advisories

testCargoFetcherAdvisoryReuseOnly :: IO ()
testCargoFetcherAdvisoryReuseOnly = do
  advisories <-
    cargoFetcherAdvisories
      (\_ -> pure Nothing)
      cargoReuseOnlyClassify
  assertEq "no advisory for reuse-only cargo" [] advisories

-- | Spine merges disk-gate warns with cargo advisories on @usrWarnings@;
-- hard language preflight failure short-circuits before this merge runs.
testCargoFetcherAdvisoryMergeWarnings :: IO ()
testCargoFetcherAdvisoryMergeWarnings = do
  cargoAds <-
    cargoFetcherAdvisories
      ( \name ->
          pure $
            if name == "aria2c"
              then Nothing
              else Just ("/bin/" <> name)
      )
      cargoFullPathClassify
  let diskWarns = ["Portage DISTDIR low free space"]
      usrWarnings = diskWarns <> cargoAds
  assertEq
    "disk warns only; cargo host advisory suppressed"
    ["Portage DISTDIR low free space"]
    usrWarnings
  -- Missing host fetchers no longer hard-fail (image provides them).
  okFetchers <-
    preflightUpdateToolsWith
      (missingNamed cargoFetcherTools)
      (basePreflight {apNeedCargo = True})
  assertEq "reuse-style cargo tools not required" (Right ()) okFetchers

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

emptyDepsPlan :: RuntimeLanePlan
emptyDepsPlan = planFromTargets []

-- | Up-to-date Go inventory + binary needs work → no go.
testAssetsPfBinaryOnly :: IO ()
testAssetsPfBinaryOnly = do
  let plans =
        [ PlanSoftSkip (PackageKey "dev-util/crush") "already matches runtime-lane plan",
          PlanNeedsWork
            (PackageKey "dev-util/grok-build-bin")
            (PlannedGitMv (parseEbuildVersion "1.2.3"))
        ]
      classify = [ClassifyOk (PackageKey "dev-util/crush") []]
      pf = assetsPreflightFromPlan plans classify
  assertEq "no assets" False (apNeedAssets pf)
  assertEq "no go" False (apNeedGo pf)
  assertEq "no cargo" False (apNeedCargo pf)
  assertEq "no docker" False (apNeedDocker pf)

testAssetsPfReuseOnlyGo :: IO ()
testAssetsPfReuseOnlyGo = do
  let key = PackageKey "dev-util/crush"
      pv = parseEbuildVersion "0.84.0"
      plans =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Go Nothing,
                pdSource = GitHub "o" "r" "v",
                pdPlan = emptyDepsPlan,
                pdLocalPVs = [],
                pdContentFix = [pv]
              }
        ]
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "crush",
                  cpuPV = pv,
                  cpuEco = Go Nothing,
                  cpuClass = ReusePath,
                  cpuTempBaseline = Just (10 * 1024 * 1024)
                }
            ]
        ]
      pf = assetsPreflightFromPlan plans classify
  assertEq "assets needed" True (apNeedAssets pf)
  assertEq "reuse-only no go" False (apNeedGo pf)
  assertEq "reuse-only no docker" False (apNeedDocker pf)

testAssetsPfCargo :: IO ()
testAssetsPfCargo = do
  let key = PackageKey "dev-util/mise"
      pv = parseEbuildVersion "2025.1.0"
      plans =
        [ PlanNeedsWork
            key
            PlannedDeps
              { pdEco = Cargo Nothing Nothing,
                pdSource = GitHub "o" "r" "v",
                pdPlan = emptyDepsPlan,
                pdLocalPVs = [],
                pdContentFix = [pv]
              }
        ]
      classify =
        [ ClassifyOk
            key
            [ ClassifiedPvUnit
                { cpuKey = key,
                  cpuPN = "mise",
                  cpuPV = pv,
                  cpuEco = Cargo Nothing Nothing,
                  cpuClass = ReusePath,
                  cpuTempBaseline = Just (5 * 1024 * 1024)
                }
            ]
        ]
      pf = assetsPreflightFromPlan plans classify
  assertEq "assets" True (apNeedAssets pf)
  assertEq "plan still needs cargo work" True (any needsWorkCargo plans)
  assertEq "reuse-only cargo no host pycargo" False (apNeedCargo pf)
  assertEq "reuse-only no docker" False (apNeedDocker pf)
  assertEq "no go" False (apNeedGo pf)

testFullPathMissingDocker :: IO ()
testFullPathMissingDocker = do
  miss <-
    preflightUpdateToolsWith
      (missingNamed ["docker"])
      (basePreflight {apNeedDocker = True})
  err <- assertLeft "full-path needs docker" miss
  assertTrue "names docker" ("docker" `T.isInfixOf` err)

testReuseOnlyWithoutDocker :: IO ()
testReuseOnlyWithoutDocker = do
  ok <-
    preflightUpdateToolsWith
      (missingNamed ["docker", "go", "npm", "bun", "xz"])
      basePreflight
  assertEq "reuse-only without docker" (Right ()) ok

testReuseCargoWithoutPycargo :: IO ()
testReuseCargoWithoutPycargo = do
  let pf = assetsPreflightFromPlan cargoReusePlans cargoReuseOnlyClassify
  assertEq "reuse cargo no docker" False (apNeedDocker pf)
  ok <-
    preflightUpdateToolsWith
      (missingNamed ["docker", "pycargoebuild", "wget", "aria2c"])
      pf
  assertEq "reuse cargo without host pycargo" (Right ()) ok
  where
    cargoReusePlans =
      let key = PackageKey "dev-util/mise"
          pv = parseEbuildVersion "2025.1.0"
       in [ PlanNeedsWork
              key
              PlannedDeps
                { pdEco = Cargo Nothing Nothing,
                  pdSource = GitHub "o" "r" "v",
                  pdPlan = emptyDepsPlan,
                  pdLocalPVs = [],
                  pdContentFix = [pv]
                }
          ]

testFullPathMissingImage :: IO ()
testFullPathMissingImage = do
  let inspect _ = pure (Left "materialize image is not usable: missing")
  miss <-
    preflightUpdateToolsWithImage
      allPresent
      inspect
      "mndz-overlay-manager/materialize:local"
      (basePreflight {apNeedDocker = True})
  err <- assertLeft "unusable image" miss
  assertTrue "names image" ("materialize image" `T.isInfixOf` err)
