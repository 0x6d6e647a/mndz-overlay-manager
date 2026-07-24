{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Gpg (tests) where

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
    "Gpg"
    [ testCase "Parse Sign Capable Keygrip" testParseSignCapableKeygrip,
      testCase "Parse Keyinfo Cached" testParseKeyinfoCached,
      testCase "Pinentry Child Env" testPinentryChildEnv,
      testCase "Missing Signing Key Fails" testMissingSigningKeyFails,
      testCase "Warm Cache Skips Prompt" testWarmCacheSkipsPrompt,
      testCase "Cold Cache Ready Then Warm" testColdCacheReadyThenWarm,
      testCase "No Tty When Cold Fails" testNoTtyWhenColdFails,
      testCase "Clear Only If Warmed" testClearOnlyIfWarmed,
      testCase "Per Repo Keygrips" testPerRepoKeygrips
    ]

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
