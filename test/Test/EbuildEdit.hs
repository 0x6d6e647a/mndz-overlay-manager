{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.EbuildEdit (tests) where

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
    "EbuildEdit"
    [ testCase "Ebuild Edit" testEbuildEdit,
      testCase "Go Version Parse" testGoVersionParse,
      testCase "Go Bdepend Edit" testGoBdependEdit,
      testCase "Nodejs Bdepend Use Replace" testNodejsBdependUseReplace,
      testCase "Vendor Go Version Gate" testVendorGoVersionGate,
      testCase "Cargo Content Fix" testCargoContentFix,
      testCase "Go Keywords Assembly" testGoKeywordsAssembly,
      testCase "Set Keywords" testSetKeywords
    ]

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

testCargoContentFix :: IO ()
testCargoContentFix = do
  let listEra =
        T.unlines
          [ "inherit cargo",
            "KEYWORDS=\"~amd64\"",
            "CRATES=\"foo-1 bar-2\"",
            "SRC_URI=\"",
            "\thttps://github.com/jdx/mise/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz",
            "\t${CARGO_CRATE_URIS}",
            "\""
          ]
      fixed0 = ensureCargoAssetsSrcUri "mise" listEra
  assertTrue "no CARGO_CRATE_URIS" (not ("CARGO_CRATE_URIS" `T.isInfixOf` fixed0))
  assertTrue "has crates asset" ("-crates.tar.xz" `T.isInfixOf` fixed0)
  assertTrue "parameterized" ("${PV}" `T.isInfixOf` fixed0)
  assertTrue
    "preserves github source"
    ("github.com/jdx/mise/archive" `T.isInfixOf` fixed0)
  assertTrue
    "SRC_URI+= not nested in string"
    ( not
        ( "SRC_URI=\"\nSRC_URI+=" `T.isInfixOf` fixed0
            || "SRC_URI=\"\r\nSRC_URI+=" `T.isInfixOf` fixed0
        )
    )
  msrvEd <- assertRight "rust min" (ensureRustMinVer "1.88" fixed0)
  assertTrue "RUST_MIN_VER" ("RUST_MIN_VER=\"1.88.0\"" `T.isInfixOf` msrvEd)
  assertTrue
    "list-era needs fix"
    (ebuildNeedsCargoContentFix ["~amd64"] listEra (Just "1.88.0"))
  let good =
        T.unlines
          [ "inherit cargo",
            "KEYWORDS=\"~amd64\"",
            "CRATES=\"\"",
            "RUST_MIN_VER=\"1.88.0\"",
            "SRC_URI=\"https://github.com/jdx/mise/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/mise-${PV}/mise-${PV}-crates.tar.xz\""
          ]
  assertTrue
    "tarball form ok"
    (not (ebuildNeedsCargoContentFix ["~amd64"] good (Just "1.88.0")))

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
