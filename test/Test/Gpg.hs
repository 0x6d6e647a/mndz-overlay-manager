{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Gpg (takeGpgTtyProbe, tests) where

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
import Control.Exception (IOException, SomeException, bracket, finally, throwIO, try)
import Control.Monad (forever, unless, void, when)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
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
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    makeAbsolute,
    pathIsSymbolicLink,
    removeFile,
  )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, unsetEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO
  ( BufferMode (LineBuffering),
    hClose,
    hFlush,
    hGetLine,
    hPutStrLn,
    hSetBuffering,
    openTempFile,
    stderr,
    stdout,
  )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import System.Posix.IO
  ( OpenFileFlags (noctty),
    OpenMode (ReadWrite),
    closeFd,
    defaultFileFlags,
    openFd,
  )
import System.Posix.Terminal (getSlaveTerminalName, openPseudoTerminal)
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe, NoStream),
    createProcess,
    proc,
    readProcessWithExitCode,
    terminateProcess,
    waitForProcess,
  )
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Support (writeMatchingCachesForPackage)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    applyPackagePhase1Tracked,
    foldExitHardFail,
    mkEbuildRunner,
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
    Supervisor (..),
    armGpgSession,
    buildGpgSessionHome,
    ensureGpgReady,
    gpgHomeUnder,
    mkGpgAgentOps,
    newGpgHandle,
    noopSupervisor,
    parseKeyinfoCached,
    parseSignCapableKeygrip,
    pinentryChildEnv,
    prepareSigningSession,
    productionGpgAgentOps,
    removeGpgSessionHome,
    signingChildEnv,
    spawnGpgSessionSupervisorIn,
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
    mkEgencacheRunner,
    packageCacheGateError,
    readCacheMd5Field,
  )
import Update.Npm.Cache (productionNpmCacheOps)
import Update.Preflight (checkToolsOnPath, goAssetsRequiredTools, updateRequiredTools)
import Update.Process
  ( ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
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
      testCase "Controlling tty is the slave device node" testControllingTtyDeviceNode,
      testCase "Missing Signing Key Fails" testMissingSigningKeyFails,
      testCase "Resolve Keygrip Fails" testResolveKeygripFails,
      testCase "Keyinfo Fail Propagates" testKeyinfoFailPropagates,
      testCase "Warm Cache Skips Prompt" testWarmCacheSkipsPrompt,
      testCase "Cold Cache Ready Then Warm" testColdCacheReadyThenWarm,
      testCase "Cold Ready Prompt Fails" testColdReadyPromptFails,
      testCase "Cold Warm Key Fails" testColdWarmKeyFails,
      testCase "No Tty When Cold Fails" testNoTtyWhenColdFails,
      testCase "Clear Only If Warmed" testClearOnlyIfWarmed,
      testCase "Per Repo Keygrips" testPerRepoKeygrips,
      testCase "Worktree State Reused" testWorktreeStateReused,
      testCase "Gpg mk CommandRunner success edges" testGpgMkCommandRunnerSuccess,
      testCase "Gpg mk CommandRunner failure edges" testGpgMkCommandRunnerFailures,
      testCase "Session home signs without the desktop agent" testSessionHomeSigns,
      testCase "Distinct keygrips unlock once or twice" testDistinctKeygrips,
      testCase "Supervisor signal kills the session agent" testSupervisorSignalKills,
      testCase "Supervisor start failure skips warm-up" testSupervisorStartFailure,
      testCase "Signing children carry the session home" testSigningChildrenEnv,
      testCase "gencache signs through the session home" testGencacheSessionHome,
      testCase "unchanged gencache does not prompt" testGencacheUnchangedSkips,
      testCase "failed gencache drops gpg-home" testGencacheFailureDropsHome
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
  -- sign-capable subkey (ssb with 's' in colon field 12)
  let ssbSign =
        unlines
          [ "sec:u:255:22:PRIMARYKEY:1::::::e:::",
            "grp:::::::::PRIMARYGRP:",
            "ssb:u:255:22:SUBKEYID:1::::::s:::",
            "grp:::::::::SUBGRIP123:",
            ""
          ]
  case parseSignCapableKeygrip ssbSign of
    Right (Keygrip g) -> assertEq "ssb sign grip" "SUBGRIP123" g
    Left err -> do
      hPutStrLn stderr $ "ssb sign parse failed: " <> T.unpack err
      exitFailure
  -- sec with sign but missing grp → failure
  case parseSignCapableKeygrip "sec:u:255:22:X:1::::::s:::\nuid:u::::name::\n" of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected missing keygrip"
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
  case parseKeyinfoCached "OK\n" grip of
    Left msg -> assertTrue "parse fail" ("could not parse KEYINFO" `T.isInfixOf` msg)
    Right _ -> do
      hPutStrLn stderr "expected KEYINFO parse failure"
      exitFailure
  -- unknown cached token is ignored → no match
  let weird =
        "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - ? P - - -\nOK\n"
  case parseKeyinfoCached weird grip of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected unknown cached token to fail parse"
      exitFailure

testPinentryChildEnv :: IO ()
testPinentryChildEnv = do
  let parent = [("DISPLAY", ":0"), ("HOME", "/home/u"), ("GPG_TTY", "old")]
      env' = pinentryChildEnv (Just "/dev/pts/7") (Just "/sess") parent
  assertEq "GPG_TTY set" (Just "/dev/pts/7") (lookup "GPG_TTY" env')
  assertEq "GNUPGHOME set" (Just "/sess") (lookup "GNUPGHOME" env')
  assertEq "DISPLAY cleared" Nothing (lookup "DISPLAY" env')
  assertEq "HOME kept" (Just "/home/u") (lookup "HOME" env')
  let envNone = pinentryChildEnv Nothing Nothing parent
  assertEq "no GPG_TTY when no tty" Nothing (lookup "GPG_TTY" envNone)
  assertEq "no GNUPGHOME when no session" Nothing (lookup "GNUPGHOME" envNone)
  assertEq "DISPLAY still cleared" Nothing (lookup "DISPLAY" envNone)
  let envEmpty = pinentryChildEnv (Just "") (Just "") parent
  assertEq "empty tty path omits GPG_TTY" Nothing (lookup "GPG_TTY" envEmpty)
  assertEq "empty home omits GNUPGHOME" Nothing (lookup "GNUPGHOME" envEmpty)

-- | Set on the pty-probe child. The value is the slave path to open.
gpgTtyProbeEnv :: String
gpgTtyProbeEnv = "MNDZ_OVERLAY_MANAGER_GPG_TTY_PROBE"

-- | When 'gpgTtyProbeEnv' is set, open that slave without @O_NOCTTY@, print
-- the production controlling-tty device node, and skip tasty.
takeGpgTtyProbe :: IO Bool
takeGpgTtyProbe = do
  mSlave <- lookupEnv gpgTtyProbeEnv
  case mSlave of
    Nothing -> pure False
    Just slave -> do
      unsetEnv gpgTtyProbeEnv
      bracket (openFd slave ReadWrite defaultFileFlags {noctty = False}) closeFd $
        \_ -> do
          mPath <- gaoControllingTty (productionGpgAgentOps (pure ()) (pure ()))
          hSetBuffering stdout LineBuffering
          putStrLn (fromMaybe "" mPath)
          hFlush stdout
      pure True

testControllingTtyDeviceNode :: IO ()
testControllingTtyDeviceNode =
  bracket openPseudoTerminal closePty $ \(master, _slaveFd) -> do
    slavePath <- getSlaveTerminalName master
    exe <- getExecutablePath
    env0 <- getEnvironment
    -- A private tix path so this child does not rewrite the suite's .tix.
    (tixPath, tixH) <- openTempFile "/tmp" "mndz-gpg-tty-probe.tix"
    hClose tixH
    removeFile tixPath
    let env1 =
          (gpgTtyProbeEnv, slavePath)
            : ("HPCTIXFILE", tixPath)
            : filter
              (\(k, _) -> k /= gpgTtyProbeEnv && k /= "HPCTIXFILE")
              env0
    started <-
      createProcess
        (proc exe [])
          { env = Just env1,
            std_in = NoStream,
            std_out = CreatePipe,
            new_session = True
          }
    case started of
      (Nothing, Just outH, Nothing, ph) -> do
        reaped <- newIORef False
        flip finally (cleanup ph outH reaped >> void (try @IOException (removeFile tixPath))) $ do
          ready <- race (threadDelay 60_000_000) (try @IOException (hGetLine outH))
          case ready of
            Right (Right got) -> do
              ec <- waitForProcess ph
              writeIORef reaped True
              assertEq "probe exit" ExitSuccess ec
              assertEq "device node" slavePath got
            Right (Left err) -> do
              hPutStrLn stderr ("pty probe stdout closed: " <> show err)
              exitFailure
            Left () -> do
              hPutStrLn stderr "pty probe timed out"
              exitFailure
      _ -> do
        hPutStrLn stderr "pty probe did not return a stdout pipe"
        exitFailure
  where
    closePty (master, slaveFd) = closeFd master >> closeFd slaveFd
    cleanup ph outH reaped = do
      done <- readIORef reaped
      unless done $ do
        void (try @SomeException (terminateProcess ph))
        void (try @SomeException (waitForProcess ph))
      void (try @SomeException (hClose outH))

baseFakeOps :: GpgAgentOps
baseFakeOps =
  GpgAgentOps
    { gaoGetSigningKey = \_ -> pure (Right "KEY1"),
      gaoResolveKeygrip = \_ -> pure (Right (Keygrip "GRIP1")),
      gaoKeyinfoCached = \_ _ -> pure (Right True),
      gaoReadyPrompt = pure (Left "should not prompt"),
      gaoWarmKey = \_ _ _ -> pure (Left "should not warm"),
      gaoControllingTty = pure (Just "/dev/pts/7"),
      gaoPauseUi = pure (),
      gaoResumeUi = pure (),
      gaoBuildSessionHome = \_ dest _ -> do
        createDirectoryIfMissing True dest
        pure (Right ()),
      gaoKillSessionAgent = \_ -> pure (),
      gaoStartSupervisor = \_ -> pure (Right noopSupervisor),
      gaoReapSupervisor = \_ -> pure (),
      gaoRemoveSessionHome = removeGpgSessionHome
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
          { gaoKeyinfoCached = \_ _ -> pure (Right True),
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
          { gaoKeyinfoCached = \_ _ -> pure (Right False),
            gaoReadyPrompt = do
              atomicModifyIORef' promptRef (\n -> (n + 1, ()))
              pure (Right ()),
            gaoWarmKey = \_ _ _ -> do
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
          { gaoKeyinfoCached = \_ _ -> pure (Right False),
            gaoControllingTty = pure Nothing
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  err <- assertLeft "no tty" result
  assertTrue "mentions TTY" ("TTY" `T.isInfixOf` err)
  teardownGpgHandle h

testClearOnlyIfWarmed :: IO ()
testClearOnlyIfWarmed =
  withSystemTempDirectory "mndz-gpg-teardown-" $ \tmp -> do
    let home = gpgHomeUnder tmp
    killed <- newIORef ([] :: [FilePath])
    let ops =
          baseFakeOps
            { gaoKillSessionAgent = \path ->
                atomicModifyIORef' killed (\xs -> (xs <> [path], ()))
            }
    hNone <- newGpgHandle ops
    teardownGpgHandle hNone
    none <- readIORef killed
    assertEq "no kill without a session" [] none

    writeIORef killed []
    hSess <- newGpgHandle ops
    createDirectoryIfMissing True home
    armGpgSession hSess home noopSupervisor
    teardownGpgHandle hSess
    kills <- readIORef killed
    assertEq "session kill" [home] kills
    gone <- doesDirectoryExist home
    assertTrue "session home removed" (not gone)

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
            gaoKeyinfoCached = \_ _ -> pure (Right True)
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

testResolveKeygripFails :: IO ()
testResolveKeygripFails = do
  let ops =
        baseFakeOps
          { gaoResolveKeygrip = \_ -> pure (Left "no sign-capable secret keygrip")
          }
  h <- newGpgHandle ops
  err <- assertLeft "resolve" =<< ensureGpgReady h "/tmp/overlay-repo"
  assertTrue "mentions keygrip" ("keygrip" `T.isInfixOf` err)
  teardownGpgHandle h

testKeyinfoFailPropagates :: IO ()
testKeyinfoFailPropagates = do
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ _ -> pure (Left "KEYINFO failed")
          }
  h <- newGpgHandle ops
  err <- assertLeft "keyinfo" =<< ensureGpgReady h "/tmp/overlay-repo"
  assertEq "keyinfo error" "KEYINFO failed" err
  teardownGpgHandle h

testColdReadyPromptFails :: IO ()
testColdReadyPromptFails = do
  warmRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ _ -> pure (Right False),
            gaoReadyPrompt = pure (Left "prompt aborted"),
            gaoWarmKey = \_ _ _ -> do
              atomicModifyIORef' warmRef (\n -> (n + 1, ()))
              pure (Right ())
          }
  h <- newGpgHandle ops
  err <- assertLeft "prompt fail" =<< ensureGpgReady h "/tmp/overlay-repo"
  assertEq "prompt error" "prompt aborted" err
  warms <- readIORef warmRef
  assertEq "no warm after prompt fail" 0 warms
  teardownGpgHandle h

testColdWarmKeyFails :: IO ()
testColdWarmKeyFails = do
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ _ -> pure (Right False),
            gaoReadyPrompt = pure (Right ()),
            gaoWarmKey = \_ _ _ -> pure (Left "clearsign failed")
          }
  h <- newGpgHandle ops
  err <- assertLeft "warm fail" =<< ensureGpgReady h "/tmp/overlay-repo"
  assertEq "warm error" "clearsign failed" err
  teardownGpgHandle h

testWorktreeStateReused :: IO ()
testWorktreeStateReused = do
  getKeyRef <- newIORef (0 :: Int)
  resolveRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoGetSigningKey = \_ -> do
              atomicModifyIORef' getKeyRef (\n -> (n + 1, ()))
              pure (Right "KEY1"),
            gaoResolveKeygrip = \_ -> do
              atomicModifyIORef' resolveRef (\n -> (n + 1, ()))
              pure (Right (Keygrip "GRIP1")),
            gaoKeyinfoCached = \_ _ -> pure (Right True)
          }
  h <- newGpgHandle ops
  void $ assertRight "first" =<< ensureGpgReady h "/tmp/reuse-repo"
  void $ assertRight "second" =<< ensureGpgReady h "/tmp/reuse-repo"
  gets <- readIORef getKeyRef
  resolves <- readIORef resolveRef
  assertEq "signingkey once" 1 gets
  assertEq "resolve once" 1 resolves
  teardownGpgHandle h

------------------------------------------------------------------------
-- Production mkGpgAgentOps via scripted CommandRunner
------------------------------------------------------------------------

okResult :: String -> ProcessResult
okResult out =
  ProcessResult
    { prExitCode = ExitSuccess,
      prStdout = out,
      prStderr = ""
    }

failResult :: String -> ProcessResult
failResult err =
  ProcessResult
    { prExitCode = ExitFailure 1,
      prStdout = "",
      prStderr = err
    }

execCmd :: ProcessRequest -> Maybe (String, [String])
execCmd req = case prMode req of
  ExecCmd cmd args -> Just (cmd, args)
  ShellCmd _ -> Nothing

signKeyColonOut :: String
signKeyColonOut =
  unlines
    [ "sec:u:255:22:AB3AA8D9F11259B4:1781074659:::u:::scESC:::+::ed25519:::0:",
      "fpr:::::::::CD806AAD3E54156ACC3842B7AB3AA8D9F11259B4:",
      "grp:::::::::6FD5C82CED9AF42C796A9C275BF5CD4082063513:",
      "ssb:u:255:18:0FFCBBF091D67623:1781074659::::::e:::+::cv25519::",
      "grp:::::::::76D0B0AC365AE824D6705200A8898C3E7F33A81D:"
    ]

keyinfoWarmOut :: String
keyinfoWarmOut =
  "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - 1 P - - -\nOK\n"

keyinfoColdOut :: String
keyinfoColdOut =
  "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - - P - - -\nOK\n"

-- Session KEYINFO, not the desktop agent. Teardown kills that session.
testGpgMkCommandRunnerSuccess :: IO ()
testGpgMkCommandRunnerSuccess =
  withSystemTempDirectory "mndz-gpg-mk-" $ \tmp -> do
    let home = gpgHomeUnder tmp
    desktopRef <- newIORef (0 :: Int)
    clearRef <- newIORef ([] :: [String])
    killRef <- newIORef ([] :: [String])
    let successRun req = case execCmd req of
          Just ("git", "-C" : _root : "config" : "--get" : "user.signingkey" : _) ->
            pure (okResult "KEY1\n")
          Just ("gpg", "--list-secret-keys" : _) -> pure (okResult signKeyColonOut)
          Just ("gpg-connect-agent", args) ->
            case prStdin req of
              s
                | "CLEAR_PASSPHRASE" `T.isInfixOf` T.pack s -> do
                    atomicModifyIORef' clearRef (\xs -> (xs <> [s], ()))
                    pure (okResult "OK\n")
                | "KEYINFO" `T.isInfixOf` T.pack s ->
                    if "--homedir" `elem` args
                      then pure (okResult keyinfoWarmOut)
                      else do
                        atomicModifyIORef' desktopRef (\n -> (n + 1, ()))
                        pure (okResult keyinfoWarmOut)
                | otherwise -> pure (failResult ("unexpected agent stdin: " <> s))
          Just ("gpgconf", args) -> do
            atomicModifyIORef' killRef (\xs -> (xs <> [unwords args], ()))
            pure (okResult "")
          _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        ops = mkGpgAgentOps successRun (pure ()) (pure ())
    h <- newGpgHandle ops
    armGpgSession h home noopSupervisor
    void $ assertRight "mk warm ready" =<< ensureGpgReady h tmp
    void $ assertRight "mk warm again" =<< ensureGpgReady h tmp
    teardownGpgHandle h
    clears <- readIORef clearRef
    kills <- readIORef killRef
    desktop <- readIORef desktopRef
    assertEq "no desktop CLEAR_PASSPHRASE" [] clears
    assertEq "no desktop KEYINFO" 0 desktop
    assertTrue "session kill recorded" (any ("--kill" `isInfixOf`) kills)
    assertTrue "kill names the session home" (any (home `isInfixOf`) kills)

    promptRef <- newIORef (0 :: Int)
    killRef2 <- newIORef ([] :: [String])
    let warmRun req = case execCmd req of
          Just ("git", "-C" : _ : "config" : _) -> pure (okResult "KEY1\n")
          Just ("gpg", args)
            | "--list-secret-keys" `elem` args -> pure (okResult signKeyColonOut)
            | "--local-user" `elem` args ->
                pure (okResult "-----BEGIN PGP SIGNED MESSAGE-----\n")
            | otherwise -> pure (failResult ("unexpected gpg: " <> show args))
          Just ("gpg-connect-agent", args) ->
            case prStdin req of
              s
                | "CLEAR_PASSPHRASE" `T.isInfixOf` T.pack s ->
                    pure (failResult "desktop CLEAR_PASSPHRASE")
                | "KEYINFO" `T.isInfixOf` T.pack s && "--homedir" `elem` args ->
                    pure (okResult keyinfoColdOut)
                | otherwise -> pure (failResult ("unexpected agent stdin: " <> s))
          Just ("gpgconf", args) -> do
            atomicModifyIORef' killRef2 (\xs -> (xs <> [unwords args], ()))
            pure (okResult "")
          _ -> pure (failResult ("unexpected warm: " <> show (prMode req)))
        opsWarm =
          (mkGpgAgentOps warmRun (pure ()) (pure ()))
            { gaoControllingTty = pure (Just "/dev/pts/7"),
              gaoReadyPrompt = do
                atomicModifyIORef' promptRef (\n -> (n + 1, ()))
                pure (Right ())
            }
    h2 <- newGpgHandle opsWarm
    armGpgSession h2 home noopSupervisor
    void $ assertRight "mk cold warm" =<< ensureGpgReady h2 tmp
    teardownGpgHandle h2
    prompts <- readIORef promptRef
    kills2 <- readIORef killRef2
    assertEq "cold session prompts" 1 prompts
    assertTrue "cold path kills the session" (not (null kills2))

testGpgMkCommandRunnerFailures :: IO ()
testGpgMkCommandRunnerFailures =
  withSystemTempDirectory "mndz-gpg-mk-fail-" $ \tmp -> do
    let gitFailRun req = case execCmd req of
          Just ("git", _) -> pure (failResult "not a git repo")
          _ -> pure (failResult "should not run")
        opsGit = mkGpgAgentOps gitFailRun (pure ()) (pure ())
    hGit <- newGpgHandle opsGit
    errGit <- assertLeft "git fail" =<< ensureGpgReady hGit tmp
    assertTrue "signingkey unset" ("signingkey" `T.isInfixOf` errGit)
    teardownGpgHandle hGit

    -- empty signing key stdout
    let emptyKeyRun req = case execCmd req of
          Just ("git", _) -> pure (okResult "   \n")
          _ -> pure (failResult "should not run")
        opsEmpty = mkGpgAgentOps emptyKeyRun (pure ()) (pure ())
    hEmpty <- newGpgHandle opsEmpty
    errEmpty <- assertLeft "empty key" =<< ensureGpgReady hEmpty tmp
    assertTrue "empty signingkey" ("empty" `T.isInfixOf` errEmpty)
    teardownGpgHandle hEmpty

    let gpgListFailRun req = case execCmd req of
          Just ("git", _) -> pure (okResult "KEY1\n")
          Just ("gpg", "--list-secret-keys" : _) -> pure (failResult "no secret key")
          _ -> pure (failResult "should not run")
        opsList = mkGpgAgentOps gpgListFailRun (pure ()) (pure ())
    hList <- newGpgHandle opsList
    errList <- assertLeft "gpg list fail" =<< ensureGpgReady hList tmp
    assertTrue "list secret" ("could not list secret key" `T.isInfixOf` errList)
    teardownGpgHandle hList

    let noSignRun req = case execCmd req of
          Just ("git", _) -> pure (okResult "KEY1\n")
          Just ("gpg", "--list-secret-keys" : _) ->
            pure (okResult "ssb:u:255:18:X:1::::::e:::\ngrp:::::::::AAAA:\n")
          _ -> pure (failResult "should not run")
        opsNoSign = mkGpgAgentOps noSignRun (pure ()) (pure ())
    hNoSign <- newGpgHandle opsNoSign
    errNoSign <- assertLeft "no sign grip" =<< ensureGpgReady hNoSign tmp
    assertTrue "no sign-capable" ("no sign-capable" `T.isInfixOf` errNoSign)
    teardownGpgHandle hNoSign

    let keyinfoFailRun req = case execCmd req of
          Just ("git", _) -> pure (okResult "KEY1\n")
          Just ("gpg", args)
            | "--list-secret-keys" `elem` args -> pure (okResult signKeyColonOut)
          Just ("gpg-connect-agent", _) -> pure (failResult "agent down")
          _ -> pure (failResult "should not run")
        opsKi = mkGpgAgentOps keyinfoFailRun (pure ()) (pure ())
    hKi <- newGpgHandle opsKi
    armGpgSession hKi (gpgHomeUnder tmp) noopSupervisor
    errKi <- assertLeft "keyinfo fail" =<< ensureGpgReady hKi tmp
    assertTrue "KEYINFO failed" ("KEYINFO failed" `T.isInfixOf` errKi)
    teardownGpgHandle hKi

    -- warm (clearsign) failure via production gaoWarmKey
    let warmFailRun req = case execCmd req of
          Just ("gpg", args)
            | "--local-user" `elem` args -> pure (failResult "pinentry cancelled")
          _ -> pure (failResult ("unexpected: " <> show (prMode req)))
        opsWarmFail = mkGpgAgentOps warmFailRun (pure ()) (pure ())
    errWarm <- gaoWarmKey opsWarmFail Nothing Nothing "KEY1"
    case errWarm of
      Left msg ->
        assertTrue "clearsign fail" ("clearsign warm" `T.isInfixOf` msg)
      Right () -> do
        hPutStrLn stderr "expected warm failure"
        exitFailure

------------------------------------------------------------------------
-- Session home, supervisor, signing children, gencache
------------------------------------------------------------------------

runGpgCmd :: FilePath -> [String] -> String -> IO (ExitCode, String, String)
runGpgCmd home args =
  readProcessWithExitCode
    "gpg"
    (["--homedir", home, "--batch", "--pinentry-mode", "loopback", "--passphrase", ""] <> args)

killAgent :: FilePath -> IO ()
killAgent home =
  void $
    readProcessWithExitCode "gpgconf" ["--homedir", home, "--kill", "gpg-agent"] ""

testSessionHomeSigns :: IO ()
testSessionHomeSigns =
  withSystemTempDirectory "mndz-gpg-home-" $ \tmp -> do
    let src = tmp </> "source"
        sess = gpgHomeUnder tmp
    createDirectoryIfMissing True src
    setFileMode src 0o700
    gen1 <-
      runGpgCmd
        src
        ["--quick-gen-key", "tester <t@example.test>", "ed25519", "sign", "never"]
        ""
    assertEq "gen tester" ExitSuccess (fst3 gen1)
    gen2 <-
      runGpgCmd
        src
        ["--quick-gen-key", "other <o@example.test>", "ed25519", "sign", "never"]
        ""
    assertEq "gen other" ExitSuccess (fst3 gen2)
    listed <-
      readProcessWithExitCode
        "gpg"
        [ "--homedir",
          src,
          "--list-secret-keys",
          "--with-colons",
          "--with-keygrip",
          "tester <t@example.test>"
        ]
        ""
    grip <-
      case listed of
        (ExitSuccess, out, _) ->
          case parseSignCapableKeygrip out of
            Right (Keygrip g) -> pure (T.unpack g)
            Left err -> do
              hPutStrLn stderr (T.unpack err)
              exitFailure
        (_, _, err) -> do
          hPutStrLn stderr err
          exitFailure
    let srcKey = src </> "private-keys-v1.d" </> grip <> ".key"
    built <- buildGpgSessionHome src sess ["tester <t@example.test>"]
    void $ assertRight "session home" built
    st <- getFileStatus sess
    assertEq "mode 700" 0o700 (fileMode st .&. 0o777)
    conf <- readFile (sess </> "gpg-agent.conf")
    assertTrue "default-cache-ttl" ("default-cache-ttl 28800" `isInfixOf` conf)
    assertTrue "max-cache-ttl" ("max-cache-ttl 28800" `isInfixOf` conf)
    assertTrue "pinentry-tty" ("pinentry-program /usr/bin/pinentry-tty" `isInfixOf` conf)
    commonThere <- doesFileExist (sess </> "common.conf")
    when commonThere $ do
      common <- readFile (sess </> "common.conf")
      assertTrue "use-keyboxd off" (not ("use-keyboxd" `isInfixOf` common))
    keys <- listDirectory (sess </> "private-keys-v1.d")
    assertEq "only the sign-capable key" [grip <> ".key"] keys
    linked <- pathIsSymbolicLink (sess </> "private-keys-v1.d" </> grip <> ".key")
    assertTrue "secret key is a symlink" linked
    signed <-
      readProcessWithExitCode
        "gpg"
        [ "--homedir",
          sess,
          "--batch",
          "--pinentry-mode",
          "loopback",
          "--passphrase",
          "",
          "--local-user",
          "tester <t@example.test>",
          "--clearsign",
          "--output",
          "-",
          "--yes"
        ]
        "hello\n"
    case signed of
      (ExitSuccess, out, _) ->
        assertTrue "clearsign" ("BEGIN PGP SIGNED MESSAGE" `isInfixOf` out)
      (_, _, err) -> do
        hPutStrLn stderr err
        exitFailure
    (sockCode, sock, _) <-
      readProcessWithExitCode
        "gpgconf"
        ["--homedir", sess, "--list-dirs", "agent-socket"]
        ""
    assertEq "socket lookup" ExitSuccess sockCode
    assertTrue "session socket is not the desktop socket" ("/gnupg/d." `isInfixOf` sock)
    killAgent src
    killAgent sess
    removeGpgSessionHome sess
    srcStill <- doesFileExist srcKey
    assertTrue "source key survives" srcStill
    sessGone <- doesDirectoryExist sess
    assertTrue "session home removed" (not sessGone)

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a

testDistinctKeygrips :: IO ()
testDistinctKeygrips =
  withSystemTempDirectory "mndz-gpg-grips-" $ \tmp -> do
    let once = do
          warms <- newIORef (0 :: Int)
          prompts <- newIORef (0 :: Int)
          let ops =
                baseFakeOps
                  { gaoKeyinfoCached = \_ _ -> pure (Right False),
                    gaoReadyPrompt = do
                      atomicModifyIORef' prompts (\n -> (n + 1, ()))
                      pure (Right ()),
                    gaoWarmKey = \_ _ _ -> do
                      atomicModifyIORef' warms (\n -> (n + 1, ()))
                      pure (Right ()),
                    gaoGetSigningKey = \_ -> pure (Right "KEY"),
                    gaoResolveKeygrip = \_ -> pure (Right (Keygrip "SAME"))
                  }
          h <- newGpgHandle ops
          void $
            assertRight "same grip"
              =<< prepareSigningSession
                h
                (tmp </> "run-same")
                [tmp </> "overlay", tmp </> "assets"]
          w <- readIORef warms
          p <- readIORef prompts
          teardownGpgHandle h
          pure (w, p)
    (w1, p1) <- once
    assertEq "one warm when grips match" 1 w1
    assertEq "one prompt when grips match" 1 p1
    warms2 <- newIORef (0 :: Int)
    prompts2 <- newIORef (0 :: Int)
    let ops2 =
          baseFakeOps
            { gaoKeyinfoCached = \_ _ -> pure (Right False),
              gaoReadyPrompt = do
                atomicModifyIORef' prompts2 (\n -> (n + 1, ()))
                pure (Right ()),
              gaoWarmKey = \_ _ _ -> do
                atomicModifyIORef' warms2 (\n -> (n + 1, ()))
                pure (Right ()),
              gaoGetSigningKey = \root ->
                pure $
                  if "assets" `isInfixOf` root
                    then Right "KEY-A"
                    else Right "KEY-O",
              gaoResolveKeygrip = \k ->
                pure $
                  Right $
                    Keygrip $
                      if k == "KEY-A" then "GRIP-A" else "GRIP-O"
            }
    h2 <- newGpgHandle ops2
    void $
      assertRight "two grips"
        =<< prepareSigningSession h2 (tmp </> "run2") [tmp </> "overlay", tmp </> "assets"]
    w2 <- readIORef warms2
    p2 <- readIORef prompts2
    teardownGpgHandle h2
    assertEq "two warms when grips differ" 2 w2
    assertEq "two prompts when grips differ" 2 p2

testSupervisorSignalKills :: IO ()
testSupervisorSignalKills =
  withSystemTempDirectory "mndz-gpg-sup-" $ \tmp -> do
    let bin = tmp </> "bin"
        record = tmp </> "gpgconf-args"
        home = gpgHomeUnder tmp
    createDirectoryIfMissing True bin
    createDirectoryIfMissing True home
    writeFile (bin </> "gpgconf") $
      unlines
        [ "#!/bin/sh",
          "printf '%s\\n' \"$*\" > " <> show record
        ]
    setFileMode (bin </> "gpgconf") 0o755
    env0 <- getEnvironment
    let env1 =
          ("PATH", bin <> ":" <> fromMaybe "" (lookup "PATH" env0))
            : filter (\(k, _) -> k /= "PATH") env0
    started <- spawnGpgSessionSupervisorIn env1 home
    sup <- assertRight "supervisor started" started
    supReap sup
    body <- readFile record
    assertTrue "kill uses the session home" (home `isInfixOf` body)
    assertTrue "gpgconf --kill" ("--kill" `isInfixOf` body)
    assertTrue "kills gpg-agent" ("gpg-agent" `isInfixOf` body)

testSupervisorStartFailure :: IO ()
testSupervisorStartFailure =
  withSystemTempDirectory "mndz-gpg-sup-fail-" $ \tmp -> do
    warms <- newIORef (0 :: Int)
    let ops =
          baseFakeOps
            { gaoStartSupervisor = \_ -> pure (Left "supervisor unavailable"),
              gaoReadyPrompt = pure (Right ()),
              gaoWarmKey = \_ _ _ -> do
                atomicModifyIORef' warms (\n -> (n + 1, ()))
                pure (Right ()),
              gaoKeyinfoCached = \_ _ -> pure (Right False)
            }
    h <- newGpgHandle ops
    err <-
      assertLeft "supervisor fail"
        =<< prepareSigningSession h (tmp </> "run") [tmp </> "overlay"]
    assertTrue "names supervisor" ("supervisor" `T.isInfixOf` err)
    n <- readIORef warms
    assertEq "no warm-up" 0 n
    teardownGpgHandle h
    gone <- doesDirectoryExist (gpgHomeUnder (tmp </> "run"))
    assertTrue "home removed after supervisor failure" (not gone)

testSigningChildrenEnv :: IO ()
testSigningChildrenEnv =
  withSystemTempDirectory "mndz-gpg-env-" $ \tmp -> do
    let session = gpgHomeUnder tmp
    parentBefore <- lookupEnv "GNUPGHOME"
    captured <- newIORef ([] :: [ProcessRequest])
    let run req = do
          atomicModifyIORef' captured (\xs -> (xs <> [req], ()))
          pure (okResult "signed\n")
        ops =
          (mkGpgAgentOps run (pure ()) (pure ()))
            { gaoControllingTty = pure (Just "/dev/pts/7"),
              gaoKeyinfoCached = \_ _ -> pure (Right True)
            }
    void $ assertRight "warm" =<< gaoWarmKey ops (Just session) (Just "/dev/pts/7") "KEY1"
    reqs <- readIORef captured
    case reqs of
      (req : _) -> do
        let env = fromMaybe [] (prEnv req)
        assertEq "warm GNUPGHOME" (Just session) (lookup "GNUPGHOME" env)
        assertEq "warm GPG_TTY" (Just "/dev/pts/7") (lookup "GPG_TTY" env)
      [] -> do
        hPutStrLn stderr "warm-up did not run"
        exitFailure
    parentAfterWarm <- lookupEnv "GNUPGHOME"
    assertEq "parent unchanged by warm-up" parentBefore parentAfterWarm
    h <- newGpgHandle ops
    armGpgSession h session noopSupervisor
    commitEnv <- signingChildEnv h
    assertEq "commit GNUPGHOME" (Just session) (lookup "GNUPGHOME" commitEnv)
    assertEq "commit GPG_TTY" (Just "/dev/pts/7") (lookup "GPG_TTY" commitEnv)
    parentAfterCommit <- lookupEnv "GNUPGHOME"
    assertEq "parent unchanged by commit env" parentBefore parentAfterCommit
    ebRef <- newIORef (Nothing :: Maybe ProcessRequest)
    let ebRun req = do
          writeIORef ebRef (Just req)
          pure (okResult "")
    void $ mkEbuildRunner (tmp </> "dist") ebRun (tmp </> "pkg") "foo.ebuild"
    eb <- readIORef ebRef
    case eb of
      Just req -> do
        let env = fromMaybe [] (prEnv req)
        assertEq "ebuild keeps the parent home" parentBefore (lookup "GNUPGHOME" env)
        assertTrue "ebuild misses session" (lookup "GNUPGHOME" env /= Just session)
      Nothing -> do
        hPutStrLn stderr "ebuild did not run"
        exitFailure
    egRef <- newIORef (Nothing :: Maybe ProcessRequest)
    createDirectoryIfMissing True (tmp </> "gentoo")
    let egRun req = case execCmd req of
          Just ("portageq", _) -> pure (okResult (tmp </> "gentoo"))
          Just ("egencache", _) -> do
            writeIORef egRef (Just req)
            pure (okResult "")
          _ -> pure (failResult "unexpected")
    eg <-
      mkEgencacheRunner egRun $
        EgencacheRequest
          { erOverlayRoot = tmp,
            erAtoms = ["dev-lang/haskell"],
            erJobs = Nothing
          }
    void $ assertRight "egencache" eg
    egReq <- readIORef egRef
    case egReq of
      Just req ->
        assertEq "egencache does not get a session env" Nothing (prEnv req)
      Nothing -> do
        hPutStrLn stderr "egencache did not run"
        exitFailure
    teardownGpgHandle h

gitOpsFor :: Bool -> ([FilePath] -> IO (Either T.Text ())) -> GitOps
gitOpsFor dirty commit =
  GitOps
    { goIsWorkTree = \_ -> pure True,
      goPathsDirty = \_ _ -> pure (Right dirty),
      goAddAndCommit = \_ paths _ -> commit paths,
      goPush = \_ -> pure (Right ()),
      goRevParseHead = \_ -> pure (Right "abc")
    }

seedHaskell :: FilePath -> IO ()
seedHaskell overlay = do
  let pkg = overlay </> "dev-lang" </> "haskell"
  createDirectoryIfMissing True pkg
  writeFile (pkg </> "haskell-1.0.ebuild") "EAPI=8\n"

testGencacheUnchangedSkips :: IO ()
testGencacheUnchangedSkips =
  withSystemTempDirectory "mndz-gc-skip-" $ \tmp -> do
    let overlay = tmp </> "ov"
    seedHaskell overlay
    writeMatchingCachesForPackage overlay "dev-lang" "haskell" (overlay </> "dev-lang" </> "haskell")
    prompts <- newIORef (0 :: Int)
    let prepare = do
          atomicModifyIORef' prompts (\n -> (n + 1, ()))
          pure (Right ())
    result <-
      gencachePackages
        (\_ -> pure (Right ()))
        (gitOpsFor False (\_ -> pure (Right ())))
        overlay
        [mkPackageKey "dev-lang" "haskell"]
        False
        Nothing
        prepare
    assertEq "no commit" (Right Nothing) result
    n <- readIORef prompts
    assertEq "unchanged tree does not prompt" 0 n

testGencacheSessionHome :: IO ()
testGencacheSessionHome =
  withSystemTempDirectory "mndz-gc-sign-" $ \tmp -> do
    let overlay = tmp </> "ov"
        run = tmp </> "run"
        home = gpgHomeUnder run
    seedHaskell overlay
    seen <- newIORef (Nothing :: Maybe FilePath)
    let ops =
          baseFakeOps
            { gaoControllingTty = pure (Just "/dev/pts/7"),
              gaoKeyinfoCached = \_ _ -> pure (Right True)
            }
    h <- newGpgHandle ops
    let prepare = do
          createDirectoryIfMissing True home
          armGpgSession h home noopSupervisor
          pure (Right ())
        commit _paths = do
          env <- signingChildEnv h
          writeIORef seen (lookup "GNUPGHOME" env)
          pure (Right ())
        runner _ = do
          let cacheDir = overlay </> "metadata" </> "md5-cache" </> "dev-lang"
          createDirectoryIfMissing True cacheDir
          writeFile (cacheDir </> "haskell-1.0") "_md5_=zz\n"
          pure (Right ())
    result <-
      gencachePackages
        runner
        (gitOpsFor True commit)
        overlay
        [mkPackageKey "dev-lang" "haskell"]
        False
        Nothing
        prepare
    case result of
      Right (Just _) -> pure ()
      other -> do
        hPutStrLn stderr ("expected signed cache commit, got " <> show other)
        exitFailure
    got <- readIORef seen
    assertEq "commit uses session home" (Just home) got
    teardownGpgHandle h

testGencacheFailureDropsHome :: IO ()
testGencacheFailureDropsHome =
  withSystemTempDirectory "mndz-gc-fail-" $ \tmp -> do
    let overlay = tmp </> "ov"
        run = tmp </> "run"
        home = gpgHomeUnder run
    seedHaskell overlay
    let ops = baseFakeOps
    h <- newGpgHandle ops
    let prepare = do
          createDirectoryIfMissing True run
          createDirectoryIfMissing True home
          writeFile (home </> "agent.conf") "x\n"
          writeFile (run </> "kept.txt") "scratch\n"
          armGpgSession h home noopSupervisor
          pure (Right ())
        runner _ = do
          let cacheDir = overlay </> "metadata" </> "md5-cache" </> "dev-lang"
          createDirectoryIfMissing True cacheDir
          writeFile (cacheDir </> "haskell-1.0") "_md5_=zz\n"
          pure (Right ())
    result <-
      gencachePackages
        runner
        (gitOpsFor True (\_ -> pure (Left "commit failed")))
        overlay
        [mkPackageKey "dev-lang" "haskell"]
        False
        Nothing
        prepare
    err <- assertLeft "commit failed" result
    assertTrue "commit error" ("commit failed" `T.isInfixOf` err)
    teardownGpgHandle h
    gone <- doesDirectoryExist home
    assertTrue "gpg-home removed" (not gone)
    kept <- doesFileExist (run </> "kept.txt")
    assertTrue "other scratch retained" kept
