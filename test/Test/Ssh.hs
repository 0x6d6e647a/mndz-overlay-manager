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
import Control.Monad (forever, join, unless, void)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
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
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
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
  ( SshAgentOps (..),
    SshSession (..),
    ensureSshAgent,
    mkSshAgentOps,
    prepareSshIdentity,
    resolveSshIdentity,
    spawnSshSessionSupervisorIn,
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
    [ testCase "Resolve ssh-identity" testResolveSshIdentity,
      testCase "Prepare missing ssh-identity file" testPrepareMissingFile,
      testCase "Ssh reuse when the token is present" testSshReuseToken,
      testCase "Ssh other tokens start an owned agent" testSshOtherTokensOwned,
      testCase "Ssh empty agent is not the add target" testSshEmptyAgentOwned,
      testCase "Ssh unreachable socket starts an owned agent" testSshUnreachableOwned,
      testCase "Ssh keygen failure does not ssh-add" testSshKeygenFailure,
      testCase "Ssh add without the token kills the owned agent" testSshAddMissesToken,
      testCase "Ssh add failure kills the owned agent" testSshAddFailsKills,
      testCase "Ssh supervisor failure before ssh-add" testSshSupervisorFailure,
      testCase "Ssh supervisor kill records the agent pid" testSshSupervisorKill,
      testCase "Ssh teardown reused and owned" testSshTeardownReusedAndOwned,
      testCase "Go missing among assets tools" testGoMissingAmongAssetsTools,
      testCase "Ssh mk CommandRunner success lifecycle" testSshMkCommandRunnerSuccess,
      testCase "Ssh mk CommandRunner failure edges" testSshMkCommandRunnerFailures
    ]

configuredKey :: FilePath
configuredKey = "/home/u/.ssh/keys/shanty_github_id"

token :: T.Text
token = "SHA256:abc"

baseSshOps :: SshAgentOps
baseSshOps =
  SshAgentOps
    { saoLookupEnv = \_ -> pure Nothing,
      saoSetEnv = \_ _ -> pure (),
      saoUnsetEnv = \_ -> pure (),
      saoRunAgent = pure (Left "should not start"),
      saoSshAdd = \_ -> pure (Left "should not add"),
      saoFingerprint = \_ -> pure (Right token),
      saoListTokens = pure (Right [token]),
      saoKillAgent = \_ -> pure (),
      saoStartSupervisor = \_ -> pure (Right (pure ())),
      saoOperatorHome = pure "/home/u",
      saoFileExists = \_ -> pure True
    }

noQuotedPath :: T.Text -> IO ()
noQuotedPath err = do
  assertTrue "names ssh-identity" ("ssh-identity" `T.isInfixOf` err)
  assertTrue "does not quote a path" (not ("\"" `T.isInfixOf` err))
  assertTrue "does not include a path" (not ("/" `T.isInfixOf` err))

testResolveSshIdentity :: IO ()
testResolveSshIdentity = do
  let home = "/home/mndz"
  assertEq
    "tilde key"
    (Right "/home/mndz/.ssh/keys/shanty_github_id")
    (resolveSshIdentity home (Just "~/.ssh/keys/shanty_github_id"))
  rel <- assertLeft "relative" (resolveSshIdentity home (Just "keys/github"))
  assertTrue "relative includes the configured text" ("keys/github" `T.isInfixOf` rel)
  pub <-
    assertLeft "pub" (resolveSshIdentity home (Just "/home/u/.ssh/id_ed25519.pub"))
  assertTrue
    "pub includes the configured text"
    ("/home/u/.ssh/id_ed25519.pub" `T.isInfixOf` pub)
  user <- assertLeft "tilde user" (resolveSshIdentity home (Just "~other/key"))
  assertTrue "tilde user includes the configured text" ("~other/key" `T.isInfixOf` user)
  empty <- assertLeft "empty" (resolveSshIdentity home (Just ""))
  omitted <- assertLeft "omitted" (resolveSshIdentity home Nothing)
  noQuotedPath empty
  noQuotedPath omitted

testPrepareMissingFile :: IO ()
testPrepareMissingFile = do
  let ops = baseSshOps {saoFileExists = \_ -> pure False}
  err <-
    assertLeft "missing file" =<< prepareSshIdentity ops (Just "/no/such/key")
  assertTrue "includes the path" ("/no/such/key" `T.isInfixOf` err)

testSshReuseToken :: IO ()
testSshReuseToken = do
  kills <- newIORef ([] :: [String])
  sets <- newIORef ([] :: [(String, String)])
  adds <- newIORef ([] :: [FilePath])
  sups <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoLookupEnv = \k ->
              pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoSetEnv = \k v -> atomicModifyIORef' sets (\xs -> (xs <> [(k, v)], ())),
            saoSshAdd = \path -> do
              atomicModifyIORef' adds (\xs -> (xs <> [path], ()))
              pure (Right ()),
            saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoStartSupervisor = \pid -> do
              atomicModifyIORef' sups (\xs -> (xs <> [pid], ()))
              pure (Right (pure ()))
          }
  session <- assertRight "reuse" =<< ensureSshAgent ops configuredKey
  case session of
    SshSessionReused -> pure ()
    SshSessionOwned pid _ -> do
      hPutStrLn stderr $ "expected reuse, owned " <> pid
      exitFailure
  assertEq "add not called" [] =<< readIORef adds
  assertEq "no setEnv" [] =<< readIORef sets
  assertEq "no kill" [] =<< readIORef kills
  assertEq "no supervisor" [] =<< readIORef sups

-- | Existing socket has some other identity. Add only the configured key,
-- and only after the owned socket is current.
testSshOtherTokensOwned :: IO ()
testSshOtherTokensOwned = assertOwnedAdd (Right ["SHA256:other"])

testSshEmptyAgentOwned :: IO ()
testSshEmptyAgentOwned = assertOwnedAdd (Right [])

testSshUnreachableOwned :: IO ()
testSshUnreachableOwned = assertOwnedAdd (Left "exit 2")

assertOwnedAdd :: Either T.Text [T.Text] -> IO ()
assertOwnedAdd firstList = do
  envRef <- newIORef (Map.fromList [("SSH_AUTH_SOCK", "/tmp/existing")])
  listRef <- newIORef (0 :: Int)
  adds <- newIORef ([] :: [(FilePath, Maybe String)])
  kills <- newIORef ([] :: [String])
  order <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoLookupEnv = \k -> Map.lookup k <$> readIORef envRef,
            saoSetEnv = \k v -> modifyIORef' envRef (Map.insert k v),
            saoListTokens = do
              n <- atomicModifyIORef' listRef (\i -> (i + 1, i))
              pure $ if n == 0 then firstList else Right [token],
            saoRunAgent = pure (Right ("/tmp/owned.sock", "5150")),
            saoSshAdd = \path -> do
              sock <- Map.lookup "SSH_AUTH_SOCK" <$> readIORef envRef
              atomicModifyIORef' adds (\xs -> (xs <> [(path, sock)], ()))
              atomicModifyIORef' order (\xs -> (xs <> ["add"], ()))
              pure (Right ()),
            saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoStartSupervisor = \pid -> do
              atomicModifyIORef' order (\xs -> (xs <> ["supervisor:" <> pid], ()))
              pure (Right (pure ()))
          }
  session <- assertRight "owned" =<< ensureSshAgent ops configuredKey
  case session of
    SshSessionOwned pid _ -> assertEq "owned pid" "5150" pid
    SshSessionReused -> do
      hPutStrLn stderr "expected an owned agent"
      exitFailure
  assertEq
    "add only the configured key on the owned socket"
    [(configuredKey, Just "/tmp/owned.sock")]
    =<< readIORef adds
  assertEq "existing agent stays up" [] =<< readIORef kills
  events <- readIORef order
  assertEq
    "supervisor before ssh-add"
    ["supervisor:5150", "add"]
    events

testSshKeygenFailure :: IO ()
testSshKeygenFailure = do
  lookups <- newIORef (0 :: Int)
  adds <- newIORef (0 :: Int)
  starts <- newIORef (0 :: Int)
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> do
              atomicModifyIORef' lookups (\n -> (n + 1, ()))
              pure (Just "/tmp/agent"),
            saoFingerprint = \_ -> pure (Left "ssh-keygen: invalid format"),
            saoSshAdd = \_ -> do
              atomicModifyIORef' adds (\n -> (n + 1, ()))
              pure (Right ()),
            saoRunAgent = do
              atomicModifyIORef' starts (\n -> (n + 1, ()))
              pure (Right ("/tmp/owned.sock", "1"))
          }
  err <- assertLeft "keygen" =<< ensureSshAgent ops configuredKey
  assertTrue "stderr" ("invalid format" `T.isInfixOf` err)
  assertEq "no socket choice" 0 =<< readIORef lookups
  assertEq "no ssh-add" 0 =<< readIORef adds
  assertEq "no agent" 0 =<< readIORef starts

testSshAddMissesToken :: IO ()
testSshAddMissesToken = do
  kills <- newIORef ([] :: [String])
  unsets <- newIORef ([] :: [String])
  reaped <- newIORef False
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "77")),
            saoSshAdd = \_ -> pure (Right ()),
            saoListTokens = pure (Right ["SHA256:other"]),
            saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsets (\xs -> (xs <> [k], ())),
            saoStartSupervisor = \_ -> pure (Right (writeIORef reaped True))
          }
  err <- assertLeft "token missing" =<< ensureSshAgent ops configuredKey
  assertTrue "not loaded" ("not loaded" `T.isInfixOf` err)
  assertEq "killed owned pid only" ["77"] =<< readIORef kills
  assertTrue "unset sock" . ("SSH_AUTH_SOCK" `elem`) =<< readIORef unsets
  assertTrue "reaped" =<< readIORef reaped

testSshAddFailsKills :: IO ()
testSshAddFailsKills = do
  kills <- newIORef ([] :: [String])
  unsets <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "77")),
            saoSshAdd = \_ -> pure (Left "no keys"),
            saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsets (\xs -> (xs <> [k], ()))
          }
  err <- assertLeft "add fail kills" =<< ensureSshAgent ops configuredKey
  assertEq "add error" "no keys" err
  assertEq "killed owned pid only" ["77"] =<< readIORef kills
  unsets' <- readIORef unsets
  assertTrue "unset sock" ("SSH_AUTH_SOCK" `elem` unsets')
  assertTrue "unset pid" ("SSH_AGENT_PID" `elem` unsets')

testSshSupervisorFailure :: IO ()
testSshSupervisorFailure = do
  adds <- newIORef (0 :: Int)
  kills <- newIORef ([] :: [String])
  unsets <- newIORef ([] :: [String])
  let ops =
        baseSshOps
          { saoLookupEnv = \_ -> pure Nothing,
            saoRunAgent = pure (Right ("/tmp/s", "88")),
            saoSshAdd = \_ -> do
              atomicModifyIORef' adds (\n -> (n + 1, ()))
              pure (Right ()),
            saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsets (\xs -> (xs <> [k], ())),
            saoStartSupervisor = \_ -> pure (Left "SSH supervisor did not become ready")
          }
  err <- assertLeft "supervisor" =<< ensureSshAgent ops configuredKey
  assertTrue "names supervisor" ("supervisor" `T.isInfixOf` err)
  assertEq "no ssh-add" 0 =<< readIORef adds
  assertEq "killed the agent it started" ["88"] =<< readIORef kills
  assertTrue "sock unset" . ("SSH_AUTH_SOCK" `elem`) =<< readIORef unsets

testSshSupervisorKill :: IO ()
testSshSupervisorKill =
  withSystemTempDirectory "mndz-ssh-sup-" $ \tmp -> do
    let bin = tmp </> "bin"
        record = tmp </> "kill-args"
        pid = "424242"
    createDirectoryIfMissing True bin
    writeFile (bin </> "kill") $
      unlines
        [ "#!/bin/sh",
          "printf '%s\\n' \"$*\" > " <> show record
        ]
    setFileMode (bin </> "kill") 0o755
    env0 <- getEnvironment
    let env1 =
          ("PATH", bin <> ":" <> fromMaybe "" (lookup "PATH" env0))
            : filter (\(k, _) -> k /= "PATH") env0
    started <- spawnSshSessionSupervisorIn env1 pid
    join (assertRight "supervisor started" started)
    body <- readFile record
    assertTrue "kill saw the agent pid" (pid `isInfixOf` body)

testSshTeardownReusedAndOwned :: IO ()
testSshTeardownReusedAndOwned = do
  kills <- newIORef ([] :: [String])
  unsets <- newIORef ([] :: [String])
  reaped <- newIORef False
  let ops =
        baseSshOps
          { saoKillAgent = \pid -> atomicModifyIORef' kills (\xs -> (xs <> [pid], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsets (\xs -> (xs <> [k], ()))
          }
  teardownSshSession ops SshSessionReused
  assertEq "no kill reused" [] =<< readIORef kills
  assertEq "no unset reused" [] =<< readIORef unsets
  teardownSshSession ops (SshSessionOwned "1234" (writeIORef reaped True))
  assertEq "kill owned" ["1234"] =<< readIORef kills
  assertTrue "reaped after kill" =<< readIORef reaped
  unsets' <- readIORef unsets
  assertTrue "unset sock owned" ("SSH_AUTH_SOCK" `elem` unsets')
  assertTrue "unset pid owned" ("SSH_AGENT_PID" `elem` unsets')

testGoMissingAmongAssetsTools :: IO ()
testGoMissingAmongAssetsTools = do
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
-- Production mkSshAgentOps via scripted CommandRunner (captured I/O)
------------------------------------------------------------------------

okResult :: String -> ProcessResult
okResult out =
  ProcessResult
    { prExitCode = ExitSuccess,
      prStdout = out,
      prStderr = ""
    }

failResult :: Int -> String -> ProcessResult
failResult n err =
  ProcessResult
    { prExitCode = ExitFailure n,
      prStdout = "",
      prStderr = err
    }

execCmd :: ProcessRequest -> Maybe (String, [String])
execCmd req = case prMode req of
  ExecCmd cmd args -> Just (cmd, args)
  ShellCmd _ -> Nothing

agentEnvOut :: String
agentEnvOut =
  "SSH_AUTH_SOCK=/tmp/mk-agent.sock; export SSH_AUTH_SOCK;\n"
    <> "SSH_AGENT_PID=4242; export SSH_AGENT_PID;\n"

keygenOut :: String
keygenOut = "256 SHA256:abc filecomment (ED25519)\n"

listOut :: String
listOut = "256 SHA256:abc agentcomment (ED25519)\n"

matchesKeygen :: [String] -> Bool
matchesKeygen args = args == ["-lf", configuredKey, "-E", "sha256"]

matchesList :: [String] -> Bool
matchesList args = args == ["-E", "sha256", "-l"]

testSshMkCommandRunnerSuccess :: IO ()
testSshMkCommandRunnerSuccess = do
  killRef <- newIORef ([] :: [String])
  setRef <- newIORef ([] :: [(String, String)])
  unsetRef <- newIORef ([] :: [String])
  addRef <- newIORef ([] :: [FilePath])
  let lifecycleRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-agent", ["-s"]) -> pure (okResult agentEnvOut)
        Just ("ssh-add", args)
          | matchesList args ->
              pure (okResult listOut)
        Just ("kill", [pid]) -> do
          atomicModifyIORef' killRef (\xs -> (xs <> [pid], ()))
          pure (okResult "")
        _ -> pure (failResult 1 ("unexpected: " <> show (prMode req)))
      ops =
        (mkSshAgentOps lifecycleRun)
          { saoLookupEnv = \_ -> pure Nothing,
            saoSetEnv = \k v -> atomicModifyIORef' setRef (\xs -> (xs <> [(k, v)], ())),
            saoUnsetEnv = \k -> atomicModifyIORef' unsetRef (\xs -> (xs <> [k], ())),
            saoSshAdd = \path -> do
              atomicModifyIORef' addRef (\xs -> (xs <> [path], ()))
              pure (Right ()),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  session <- assertRight "mk fresh success" =<< ensureSshAgent ops configuredKey
  case session of
    SshSessionOwned pid _ -> assertEq "owned pid" "4242" pid
    SshSessionReused -> do
      hPutStrLn stderr "expected owned session"
      exitFailure
  sets <- readIORef setRef
  assertTrue "set sock" (("SSH_AUTH_SOCK", "/tmp/mk-agent.sock") `elem` sets)
  assertTrue "set pid" (("SSH_AGENT_PID", "4242") `elem` sets)
  assertEq "added the configured path" [configuredKey] =<< readIORef addRef

  -- Reuse: comments differ, the SHA256 token matches, ssh-add is not called.
  let reuseRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-add", args)
          | matchesList args ->
              pure (okResult listOut)
        _ -> pure (failResult 1 ("unexpected reuse: " <> show (prMode req)))
      opsReuse =
        (mkSshAgentOps reuseRun)
          { saoLookupEnv = \k ->
              pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/existing" else Nothing,
            saoSetEnv = \k v -> atomicModifyIORef' setRef (\xs -> (xs <> [(k, v)], ())),
            saoSshAdd = \_ -> pure (Left "should not add"),
            saoKillAgent = \pid -> atomicModifyIORef' killRef (\xs -> (xs <> [pid], ()))
          }
  writeIORef setRef []
  writeIORef killRef []
  reused <- assertRight "mk reuse" =<< ensureSshAgent opsReuse configuredKey
  case reused of
    SshSessionReused -> pure ()
    SshSessionOwned pid _ -> do
      hPutStrLn stderr $ "expected reuse, owned " <> pid
      exitFailure
  assertEq "reuse does not setEnv" [] =<< readIORef setRef
  assertEq "reuse does not kill" [] =<< readIORef killRef

  teardownSshSession ops session
  assertEq "killed via CommandRunner" ["4242"] =<< readIORef killRef
  unsets <- readIORef unsetRef
  assertTrue "unset sock" ("SSH_AUTH_SOCK" `elem` unsets)
  assertTrue "unset pid" ("SSH_AGENT_PID" `elem` unsets)

testSshMkCommandRunnerFailures :: IO ()
testSshMkCommandRunnerFailures = do
  let failAgentRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-agent", ["-s"]) -> pure (failResult 1 "no ssh-agent binary")
        _ -> pure (failResult 1 "should not run")
      opsAgentFail =
        (mkSshAgentOps failAgentRun)
          { saoLookupEnv = \_ -> pure Nothing,
            saoSshAdd = \_ -> pure (Left "should not add"),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  errAgent <- assertLeft "run agent fail" =<< ensureSshAgent opsAgentFail configuredKey
  assertTrue "ssh-agent failed" ("ssh-agent failed" `T.isInfixOf` errAgent)
  assertTrue "stderr" ("no ssh-agent binary" `T.isInfixOf` errAgent)

  let badEnvRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-agent", ["-s"]) -> pure (okResult "not an env dump\n")
        _ -> pure (failResult 1 "should not run")
      opsBadEnv =
        (mkSshAgentOps badEnvRun)
          { saoLookupEnv = \_ -> pure Nothing,
            saoSshAdd = \_ -> pure (Left "should not add"),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  errParse <- assertLeft "parse agent env" =<< ensureSshAgent opsBadEnv configuredKey
  assertTrue "parse err" ("could not parse ssh-agent" `T.isInfixOf` errParse)

  let listFailRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-add", args)
          | matchesList args ->
              pure (failResult 2 "Cannot connect to agent")
        Just ("ssh-agent", ["-s"]) -> pure (failResult 127 "ssh-agent: not found")
        _ -> pure (failResult 1 ("unexpected: " <> show (prMode req)))
      opsListFail =
        (mkSshAgentOps listFailRun)
          { saoLookupEnv = \k ->
              pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/stale" else Nothing,
            saoSshAdd = \_ -> pure (Left "should not add"),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  errList <- assertLeft "list then agent fail" =<< ensureSshAgent opsListFail configuredKey
  assertTrue "agent after list fail" ("ssh-agent failed" `T.isInfixOf` errList)

  killRef <- newIORef ([] :: [String])
  let killEdgeRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-agent", ["-s"]) -> pure (okResult agentEnvOut)
        Just ("kill", [pid]) -> do
          atomicModifyIORef' killRef (\xs -> (xs <> [pid], ()))
          pure (okResult "")
        _ -> pure (failResult 1 ("unexpected: " <> show (prMode req)))
      opsKill =
        (mkSshAgentOps killEdgeRun)
          { saoLookupEnv = \_ -> pure Nothing,
            saoSetEnv = \_ _ -> pure (),
            saoUnsetEnv = \_ -> pure (),
            saoSshAdd = \_ -> pure (Left "no keys on host"),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  errAdd <- assertLeft "add fail kills" =<< ensureSshAgent opsKill configuredKey
  assertEq "add error" "no keys on host" errAdd
  assertEq "kill via runner" ["4242"] =<< readIORef killRef

  let stillEmptyRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (okResult keygenOut)
        Just ("ssh-agent", ["-s"]) -> pure (okResult agentEnvOut)
        Just ("ssh-add", args)
          | matchesList args ->
              pure (failResult 1 "")
        Just ("kill", _) -> pure (okResult "")
        _ -> pure (failResult 1 ("unexpected: " <> show (prMode req)))
      opsEmpty =
        (mkSshAgentOps stillEmptyRun)
          { saoLookupEnv = \_ -> pure Nothing,
            saoSetEnv = \_ _ -> pure (),
            saoUnsetEnv = \_ -> pure (),
            saoSshAdd = \_ -> pure (Right ()),
            saoStartSupervisor = \_ -> pure (Right (pure ()))
          }
  errEmpty <- assertLeft "still empty" =<< ensureSshAgent opsEmpty configuredKey
  assertTrue "not loaded" ("not loaded" `T.isInfixOf` errEmpty)

  let keygenFailRun req = case execCmd req of
        Just ("ssh-keygen", args)
          | matchesKeygen args ->
              pure (failResult 1 "not a private key")
        _ -> pure (failResult 1 ("ssh-add or agent ran: " <> show (prMode req)))
      opsKeygen =
        (mkSshAgentOps keygenFailRun)
          { saoLookupEnv = \_ -> pure (Just "/tmp/desktop"),
            saoSshAdd = \_ -> pure (Left "should not add")
          }
  errKeygen <- assertLeft "keygen runner" =<< ensureSshAgent opsKeygen configuredKey
  assertTrue "keygen stderr" ("not a private key" `T.isInfixOf` errKeygen)
