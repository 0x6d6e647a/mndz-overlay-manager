{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Ssh (tests) where

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
    defaultIdentityCandidates,
    ensureSshAgent,
    parseIdentityFiles,
    teardownSshSession,
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
    "Ssh"
    [ testCase "Ssh Agent Reuse" testSshAgentReuse,
      testCase "Ssh Ensure Empty Then Add" testSshEnsureEmptyThenAdd,
      testCase "Ssh Ensure Empty Add Fails" testSshEnsureEmptyAddFails,
      testCase "Ssh Ensure Unreachable Starts Fresh" testSshEnsureUnreachableStartsFresh,
      testCase "Ssh Ensure Fresh Success" testSshEnsureFreshSuccess,
      testCase "Ssh Ensure Fresh RunAgent Fails" testSshEnsureFreshRunAgentFails,
      testCase "Ssh Ensure Fresh Add Fails Kills" testSshEnsureFreshAddFailsKills,
      testCase "Ssh Ensure Fresh Still Empty" testSshEnsureFreshStillEmpty,
      testCase "Ssh Ensure Fresh Unreachable After Add" testSshEnsureFreshUnreachableAfterAdd,
      testCase "Ssh Teardown Reused And Owned" testSshTeardownReusedAndOwned,
      testCase "Default Identity Candidates" testDefaultIdentityCandidates,
      testCase "Parse Identity Files Edges" testParseIdentityFilesEdges
    ]

baseSshOps :: SshAgentOps
baseSshOps =
  SshAgentOps
    { saoLookupEnv = \_ -> pure Nothing,
      saoSetEnv = \_ _ -> pure (),
      saoUnsetEnv = \_ -> pure (),
      saoRunAgent = pure (Left "should not start"),
      saoSshAdd = pure (Left "should not add"),
      saoListIdentities = pure HasIdentities,
      saoKillAgent = \_ -> pure ()
    }

testSshAgentReuse :: IO ()
testSshAgentReuse = do
  let opsWithKeys =
        baseSshOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoListIdentities = pure HasIdentities
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
  -- empty sock string treated as missing → start fresh path
  let opsEmptySock =
        baseSshOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "" else Nothing,
            saoRunAgent = pure (Left "agent boom")
          }
  errSock <- assertLeft "empty sock starts fresh" =<< ensureSshAgent opsEmptySock
  assertTrue "agent fail" ("agent boom" `T.isInfixOf` errSock)
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

testSshEnsureEmptyThenAdd :: IO ()
testSshEnsureEmptyThenAdd = do
  listRef <- newIORef (0 :: Int)
  addRef <- newIORef (0 :: Int)
  let ops =
        baseSshOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoSshAdd = do
              atomicModifyIORef' addRef (\n -> (n + 1, ()))
              pure (Right ()),
            saoListIdentities = do
              n <- atomicModifyIORef' listRef (\i -> (i + 1, i))
              pure $ if n == 0 then NoIdentities else HasIdentities
          }
  session <- assertRight "reuse after add" =<< ensureSshAgent ops
  assertEq "reused session" SshSessionReused session
  adds <- readIORef addRef
  assertEq "ssh-add once" 1 adds

testSshEnsureEmptyAddFails :: IO ()
testSshEnsureEmptyAddFails = do
  let ops =
        baseSshOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoListIdentities = pure NoIdentities,
            saoSshAdd = pure (Left "add failed")
          }
  err <- assertLeft "add fail" =<< ensureSshAgent ops
  assertEq "propagates add error" "add failed" err

testSshEnsureUnreachableStartsFresh :: IO ()
testSshEnsureUnreachableStartsFresh = do
  killRef <- newIORef ([] :: [String])
  setRef <- newIORef ([] :: [(String, String)])
  listRef <- newIORef (0 :: Int)
  let ops =
        baseSshOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/stale" else Nothing,
            -- first list: stale agent; after restart+add: identities present
            saoListIdentities = do
              n <- atomicModifyIORef' listRef (\i -> (i + 1, i))
              pure $
                if n == 0
                  then AgentUnreachable "exit 2"
                  else HasIdentities,
            saoRunAgent = pure (Right ("/tmp/new.sock", "4242")),
            saoSetEnv = \k v -> atomicModifyIORef' setRef (\xs -> (xs <> [(k, v)], ())),
            saoSshAdd = pure (Right ()),
            saoKillAgent = \pid -> atomicModifyIORef' killRef (\xs -> (xs <> [pid], ()))
          }
  session <- assertRight "fresh after unreachable" =<< ensureSshAgent ops
  assertEq "owned session" (SshSessionOwned "4242") session
  sets <- readIORef setRef
  assertTrue "set sock" (("SSH_AUTH_SOCK", "/tmp/new.sock") `elem` sets)
  assertTrue "set pid" (("SSH_AGENT_PID", "4242") `elem` sets)
  kills <- readIORef killRef
  assertEq "no kill on success" [] kills

testSshEnsureFreshSuccess :: IO ()
testSshEnsureFreshSuccess = do
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "99")),
            saoSshAdd = pure (Right ()),
            saoListIdentities = pure HasIdentities
          }
  session <- assertRight "fresh owned" =<< ensureSshAgent ops
  assertEq "owned" (SshSessionOwned "99") session

testSshEnsureFreshRunAgentFails :: IO ()
testSshEnsureFreshRunAgentFails = do
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Left "ssh-agent failed: no binary")
          }
  err <- assertLeft "run agent" =<< ensureSshAgent ops
  assertTrue "mentions agent" ("ssh-agent" `T.isInfixOf` err)

testSshEnsureFreshAddFailsKills :: IO ()
testSshEnsureFreshAddFailsKills = do
  killRef <- newIORef ([] :: [String])
  unsetRef <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "77")),
            saoSshAdd = pure (Left "no keys"),
            saoKillAgent = \pid -> atomicModifyIORef' killRef (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsetRef (\xs -> (xs <> [k], ()))
          }
  err <- assertLeft "add fail kills" =<< ensureSshAgent ops
  assertEq "add error" "no keys" err
  kills <- readIORef killRef
  assertEq "killed owned agent" ["77"] kills
  unsets <- readIORef unsetRef
  assertTrue "unset sock" ("SSH_AUTH_SOCK" `elem` unsets)
  assertTrue "unset pid" ("SSH_AGENT_PID" `elem` unsets)

testSshEnsureFreshStillEmpty :: IO ()
testSshEnsureFreshStillEmpty = do
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "1")),
            saoSshAdd = pure (Right ()),
            saoListIdentities = pure NoIdentities
          }
  err <- assertLeft "still empty" =<< ensureSshAgent ops
  assertTrue "no identities msg" ("no identities" `T.isInfixOf` err)

testSshEnsureFreshUnreachableAfterAdd :: IO ()
testSshEnsureFreshUnreachableAfterAdd = do
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "1")),
            saoSshAdd = pure (Right ()),
            saoListIdentities = pure (AgentUnreachable "gone")
          }
  err <- assertLeft "unreachable after add" =<< ensureSshAgent ops
  assertTrue "usable msg" ("not usable" `T.isInfixOf` err)
  assertTrue "carries cause" ("gone" `T.isInfixOf` err)

testSshTeardownReusedAndOwned :: IO ()
testSshTeardownReusedAndOwned = do
  killRef <- newIORef ([] :: [String])
  unsetRef <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoKillAgent = \pid -> atomicModifyIORef' killRef (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsetRef (\xs -> (xs <> [k], ()))
          }
  teardownSshSession ops SshSessionReused
  kills0 <- readIORef killRef
  unsets0 <- readIORef unsetRef
  assertEq "no kill reused" [] kills0
  assertEq "no unset reused" [] unsets0
  teardownSshSession ops (SshSessionOwned "1234")
  kills1 <- readIORef killRef
  unsets1 <- readIORef unsetRef
  assertEq "kill owned" ["1234"] kills1
  assertTrue "unset sock owned" ("SSH_AUTH_SOCK" `elem` unsets1)
  assertTrue "unset pid owned" ("SSH_AGENT_PID" `elem` unsets1)

testDefaultIdentityCandidates :: IO ()
testDefaultIdentityCandidates = do
  let cands = defaultIdentityCandidates "/home/u/.ssh"
  assertEq
    "default identity paths"
    [ "/home/u/.ssh/id_rsa",
      "/home/u/.ssh/id_ecdsa",
      "/home/u/.ssh/id_ecdsa_sk",
      "/home/u/.ssh/id_ed25519",
      "/home/u/.ssh/id_ed25519_sk",
      "/home/u/.ssh/id_xmss",
      "/home/u/.ssh/id_dsa"
    ]
    cands

testParseIdentityFilesEdges :: IO ()
testParseIdentityFilesEdges = do
  assertEq "empty config" [] (parseIdentityFiles "/home/u" "")
  assertEq
    "tilde only home"
    ["/home/u"]
    (parseIdentityFiles "/home/u" "IdentityFile ~\n")
  assertEq
    "case insensitive keyword"
    ["/abs/key"]
    (parseIdentityFiles "/home/u" "identityfile /abs/key\n")
  assertEq
    "inline comment stripped"
    ["/home/u/.ssh/id_ed25519"]
    (parseIdentityFiles "/home/u" "IdentityFile ~/.ssh/id_ed25519 # comment\n")
  assertEq
    "comment only line ignored"
    []
    (parseIdentityFiles "/home/u" "# IdentityFile ~/.ssh/skip\nHost *\n")
  assertEq
    "non identity keywords ignored"
    []
    (parseIdentityFiles "/home/u" "Host github.com\n  User git\n")
  assertEq
    "multiple files order preserved"
    ["/a", "/b"]
    (parseIdentityFiles "/home/u" "IdentityFile /a\nIdentityFile /b\n")
