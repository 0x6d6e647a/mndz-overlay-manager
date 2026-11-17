{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for the smoke tree snapshot and the smoke container
-- adapter with scripted Docker fakes (no daemon).
module Test.SmokeContainer (tests) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Metrics.Container (CgroupRoots (..))
import Metrics.Core (noopMetrics)
import Overlay.Types (Ebuild (..))
import Overlay.Version (parseEbuildVersion)
import Smoke.Check
  ( Check (..),
    SmokeDef (..),
    argv,
    check,
    exitsWith,
    networked,
    smokeDef,
    step,
  )
import Smoke.CompileCache
  ( CacheReport (..),
    CacheUse (..),
    TrimCheck (..),
    configureCacheNote,
    goTrimCheckScript,
    newGoChecks,
    portageBashrc,
    reportScript,
  )
import Smoke.Container
  ( ExecUser (..),
    FailStage (..),
    RunOutcome (..),
    RunResult (..),
    SmokeContainerCfg (..),
    SmokeSession (..),
    dependenciesArgv,
    packageArgv,
    performRun,
    portageConfigFiles,
    runSandboxProbe,
    setupScript,
    smokeContainerName,
    smokeCreateArgs,
    smokeDistDir,
    withSmokeContainer,
  )
import Smoke.Plan (LaneRuntime (..), RuntimeCap (..), SmokeRun (..))
import Smoke.Tree
  ( SnapshotCfg (..),
    createSnapshot,
    snapshotPipeline,
    snapshotTag,
    sweepStaleSnapshots,
    withSnapshot,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Process (ProcessMode (..), ProcessRequest (..), ProcessResult (..))
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Types (PackageKey, mkPackageKey)

tests :: TestTree
tests =
  testGroup
    "SmokeContainer"
    [ testGroup
        "tree"
        [ testCase "snapshot pipeline argv" testSnapshotArgv,
          testCase "snapshot removed on normal exit" testSnapshotRemovedNormal,
          testCase "snapshot removed on exception" testSnapshotRemovedException,
          testCase "failed tar fails the snapshot" testSnapshotTarFails,
          testCase "leftover removed, live command's snapshot kept" testSweep
        ],
      testGroup
        "container"
        [ testCase "create argv" testCreateArgs,
          testCase "container removed in every outcome" testRemovedAlways,
          testCase "portage files: plain-lane run" testConfigPlain,
          testCase "portage files: tilde-lane run" testConfigTilde,
          testCase "portage files: Cargo caps both rust packages" testConfigCargo,
          testCase "portage files: Bun run" testConfigBun,
          testCase "portage files: Uv run accepts its slot" testConfigUv,
          testCase "portage files: unlabeled run" testConfigUnlabeled,
          testCase "portage files: definition USE lines" testConfigUse,
          testCase "setup script: make.conf and check user" testSetupScript,
          testCase "sandbox probe failure names the requirement" testProbeFails,
          testCase "emerge steps: overlay names and empty DISTDIR" testEmergeArgv,
          testCase "dependency failure skips the package step" testDepsFailure,
          testCase "build failure runs no check" testBuildFailure,
          testCase "build failure reason is Portage's ERROR line" testErrorNote,
          testCase "network detach after installs, attach around a network check" testNetworkOrder,
          testCase "check user, timeout wrapper, failed check named" testCheckExec,
          testCase "check groups joined after the installs, before checks" testCheckGroups,
          testCase "check group failure runs no check" testCheckGroupsFail
        ],
      testGroup
        "compile cache"
        [ testCase "create argv: cache on and off" testCreateArgsCache,
          testCase "setup: plain-lane Go run" testCacheSetupPlain,
          testCase "setup: tilde-lane and unlabeled runs" testCacheSetupLanes,
          testCase "setup: cache off" testCacheSetupOff,
          testCase "trim check once per Go version" testTrimCheckOnce,
          testCase "failed trim check leaves the result unchanged" testTrimCheckFail,
          testCase "no Go, no trim check" testTrimCheckNoGo,
          testCase "configure failure names the configure cache" testConfigureNote,
          testCase "report collected with the cache on, not off" testReportCollected
        ]
    ]

------------------------------------------------------------------------
-- Fakes

data Fake = Fake
  { fCalls :: IORef [ProcessRequest],
    fRespond :: [String] -> Maybe ProcessResult
  }

newFake :: ([String] -> Maybe ProcessResult) -> IO Fake
newFake respond = Fake <$> newIORef [] <*> pure respond

runFake :: Fake -> ProcessRequest -> IO ProcessResult
runFake fake req = do
  modifyIORef' (fCalls fake) (++ [req])
  let args = case prMode req of
        ExecCmd c as -> c : as
        ShellCmd s -> ["sh", "-c", s]
  pure $ case fRespond fake args of
    Just r -> r
    Nothing -> case args of
      ["docker", "inspect", "--format", "{{.State.Running}}", _] -> ok "true\n"
      _ -> ok ""

ok :: String -> ProcessResult
ok out = ProcessResult ExitSuccess out ""

failWith :: Int -> String -> ProcessResult
failWith n = ProcessResult (ExitFailure n) ""

dockerCalls :: Fake -> IO [[String]]
dockerCalls fake = do
  reqs <- readIORef (fCalls fake)
  pure [args | ProcessRequest {prMode = ExecCmd "docker" args} <- reqs]

------------------------------------------------------------------------
-- Tree

snapCfg :: SnapshotCfg
snapCfg =
  SnapshotCfg
    { scRunId = "20261115T120000+0100-4242.ab12",
      scCliPid = "4242",
      scImage = "mndz-overlay-manager/smoke:local",
      scTree = "/cache/gentoo"
    }

testSnapshotArgv :: IO ()
testSnapshotArgv = do
  let p = snapshotPipeline snapCfg
  assertEq "tag is docker-safe" "mndz-overlay-manager/smoke-tree:20261115T120000_0100-4242.ab12" (snapshotTag (scRunId snapCfg))
  mapM_
    (\needle -> assertTrue ("pipeline has " <> needle) (needle `isInfixOf` p))
    [ "'docker' 'run'",
      "'--network' 'none'",
      "'type=bind,src=/cache/gentoo,dst=/t,readonly'",
      "'--exclude=./.git'",
      "'--owner=0' '--group=0'",
      " | 'docker' 'import'",
      "'--change' 'LABEL mndz.overlay-manager=1'",
      "'--change' 'LABEL mndz.overlay-manager.pid=4242'",
      "'-' 'mndz-overlay-manager/smoke-tree:"
    ]
  fake <- newFake tarOk
  got <- createSnapshot (runFake fake) snapCfg
  assertEq "tag" (Right (snapshotTag (scRunId snapCfg))) got

tarOk :: [String] -> Maybe ProcessResult
tarOk = \case
  ["docker", "inspect", "--format", "{{.State.ExitCode}}", _] -> Just (ok "0\n")
  _ -> Nothing

testSnapshotRemovedNormal :: IO ()
testSnapshotRemovedNormal = do
  fake <- newFake tarOk
  got <- withSnapshot (runFake fake) snapCfg (pure . length)
  assertTrue "ran" (either (const False) (> 0) got)
  calls <- dockerCalls fake
  assertEq "removed last" ["rmi", snapshotTag (scRunId snapCfg)] (last calls)

testSnapshotRemovedException :: IO ()
testSnapshotRemovedException = do
  fake <- newFake tarOk
  r <- try @ErrorCall (withSnapshot (runFake fake) snapCfg (\_ -> throwIO (ErrorCall "boom")))
  assertTrue "rethrown" (either (const True) (const False) r)
  calls <- dockerCalls fake
  assertTrue "removed" (["rmi", snapshotTag (scRunId snapCfg)] `elem` calls)

testSnapshotTarFails :: IO ()
testSnapshotTarFails = do
  fake <- newFake $ \case
    ["docker", "inspect", "--format", "{{.State.ExitCode}}", _] -> Just (ok "2\n")
    _ -> Nothing
  got <- createSnapshot (runFake fake) snapCfg
  _ <- assertLeft "fails" got
  calls <- dockerCalls fake
  assertTrue "tar container removed" (any (\c -> take 2 c == ["rm", "-f"]) calls)
  assertTrue "partial image removed" (["rmi", snapshotTag (scRunId snapCfg)] `elem` calls)

testSweep :: IO ()
testSweep = do
  fake <- newFake $ \case
    "docker" : "images" : _ -> Just (ok "mndz-overlay-manager/smoke-tree:dead\nmndz-overlay-manager/smoke-tree:live\n")
    ["docker", "image", "inspect", "--format", _, "mndz-overlay-manager/smoke-tree:dead"] -> Just (ok "111\n")
    ["docker", "image", "inspect", "--format", _, "mndz-overlay-manager/smoke-tree:live"] -> Just (ok "222\n")
    _ -> Nothing
  sweepStaleSnapshots (runFake fake) (pure . (== "222"))
  calls <- dockerCalls fake
  listing <- case [c | c@("images" : _) <- calls] of
    c : _ -> pure c
    [] -> assertFailure "no images listing"
  assertTrue "filters by product label" ("label=mndz.overlay-manager" `elem` listing)
  assertTrue "filters by repository" ("reference=mndz-overlay-manager/smoke-tree:*" `elem` listing)
  assertTrue "dead removed" (["rmi", "mndz-overlay-manager/smoke-tree:dead"] `elem` calls)
  assertTrue "live kept" (["rmi", "mndz-overlay-manager/smoke-tree:live"] `notElem` calls)

------------------------------------------------------------------------
-- Container

cfg :: SmokeContainerCfg
cfg =
  SmokeContainerCfg
    { sccRunId = "r1",
      sccCliPid = "4242",
      sccImage = "mndz-overlay-manager/smoke:local",
      sccSnapshot = "mndz-overlay-manager/smoke-tree:r1",
      sccOverlay = "/ov",
      sccTimeDir = Nothing,
      sccOperatorUid = 1000,
      sccJobs = 8,
      sccOverlayNames = ["dev-util/crush", "dev-lang/bun-bin"],
      sccCache = CacheOff
    }

mkRun :: Text -> Text -> Text -> Maybe RuntimeCap -> Maybe Text -> SmokeRun
mkRun cat pn ver cap slot =
  SmokeRun
    { srKey = mkPackageKey cat pn,
      srEbuild = Ebuild cat pn ver ("/ov/" <> T.unpack cat <> "/" <> T.unpack pn <> "/x.ebuild"),
      srVersion = parseEbuildVersion ver,
      srArch = "amd64",
      srCap = cap,
      srPythonSlot = slot
    }

crushTilde :: SmokeRun
crushTilde = mkRun "dev-util" "crush" "0.101.0" (Just (RuntimeCap RuntimeGo Tilde (parseEbuildVersion "1.27.4"))) Nothing

crushPlain :: SmokeRun
crushPlain = mkRun "dev-util" "crush" "0.101.0" (Just (RuntimeCap RuntimeGo Plain (parseEbuildVersion "1.27.3"))) Nothing

testCreateArgs :: IO ()
testCreateArgs = do
  let args = smokeCreateArgs cfg crushTilde
  assertEq "name" "mndz-smoke-r1-dev-util-crush-0.101.0-tilde" (smokeContainerName cfg crushTilde)
  assertTrue "SYS_ADMIN" (isSub ["--cap-add", "SYS_ADMIN"] args)
  assertEq "one capability" 1 (length (filter (== "--cap-add") args))
  assertTrue "no privileged" ("--privileged" `notElem` args)
  assertTrue "no seccomp option" (not (any ("seccomp" `isInfixOf`) args))
  assertTrue "tree image mount" (isSub ["--mount", "type=image,source=mndz-overlay-manager/smoke-tree:r1,target=/var/db/repos/gentoo"] args)
  assertTrue "overlay read-only" (isSub ["--mount", "type=bind,src=/ov,dst=/var/db/repos/mndz,readonly"] args)
  assertTrue "binpkgs volume" (isSub ["--mount", "type=volume,src=mndz-smoke-binpkgs,dst=/var/cache/binpkgs"] args)
  assertTrue "distfiles volume" (isSub ["--mount", "type=volume,src=mndz-smoke-distfiles,dst=/var/cache/distfiles"] args)
  assertTrue "product label" (isSub ["--label", "mndz.overlay-manager=1"] args)
  assertTrue "no secrets" (not (any (\a -> any (`isInfixOf` a) ["GITHUB_TOKEN", "GH_TOKEN", "GNUPGHOME", "SSH_AUTH_SOCK", "SSH_AGENT_PID"]) args))
  assertTrue "no env at all" ("--env" `notElem` args)
  assertTrue "no time bind" (length (filter (== "--mount") args) == 4)
  let timed = smokeCreateArgs cfg {sccTimeDir = Just "/m/time"} crushTilde
  assertTrue "time bind" (isSub ["--mount", "type=bind,src=/m/time,dst=/m/time"] timed)
  assertEq "image last" ["mndz-overlay-manager/smoke:local", "sleep", "infinity"] (drop (length args - 3) args)

isSub :: (Eq a) => [a] -> [a] -> Bool
isSub needle hay = any (needle `isPrefixOf`) (tailsOf hay)
  where
    tailsOf [] = [[]]
    tailsOf xs@(_ : rest) = xs : tailsOf rest

testRemovedAlways :: IO ()
testRemovedAlways = do
  let name = smokeContainerName cfg crushTilde
      rmCall = ["rm", "-f", name]
  fake <- newFake (const Nothing)
  r1 <- withSmokeContainer noopMetrics noRoots (runFake fake) cfg crushTilde (\_ -> pure ())
  assertEq "ok" (Right ()) r1
  c1 <- dockerCalls fake
  assertEq "removed after success" rmCall (last c1)
  fake2 <- newFake (const Nothing)
  r2 <- try @ErrorCall (withSmokeContainer noopMetrics noRoots (runFake fake2) cfg crushTilde (\_ -> throwIO (ErrorCall "boom")))
  assertTrue "rethrown" (either (const True) (const False) r2)
  c2 <- dockerCalls fake2
  assertTrue "removed after exception" (rmCall `elem` c2)
  fake3 <- newFake $ \case
    ["docker", "start", _] -> Just (failWith 1 "no such image")
    _ -> Nothing
  r3 <- withSmokeContainer noopMetrics noRoots (runFake fake3) cfg crushTilde (\_ -> pure ())
  _ <- assertLeft "start fails" r3
  c3 <- dockerCalls fake3
  assertTrue "removed after start failure" (rmCall `elem` c3)

noRoots :: CgroupRoots
noRoots = CgroupRoots "/nonexistent" "/nonexistent"

configText :: SmokeRun -> [Text] -> FilePath -> Maybe Text
configText run extra path = lookup path (portageConfigFiles run extra [])

testConfigPlain :: IO ()
testConfigPlain = do
  assertEq
    "accepts"
    (Just "*/*::mndz ~amd64\n<=dev-lang/go-1.27.3 ~amd64\n")
    (configText crushPlain [] "/etc/portage/package.accept_keywords/smoke")
  assertEq "mask" (Just ">dev-lang/go-1.27.3\n") (configText crushPlain [] "/etc/portage/package.mask/smoke")
  assertEq
    "repos.conf"
    (Just "[mndz]\nlocation = /var/db/repos/mndz\nmasters = gentoo\nauto-sync = no\n")
    (configText crushPlain [] "/etc/portage/repos.conf/mndz.conf")

testConfigTilde :: IO ()
testConfigTilde = do
  assertEq
    "accepts"
    (Just "*/*::mndz ~amd64\n<=dev-lang/go-1.27.4 ~amd64\n")
    (configText crushTilde [] "/etc/portage/package.accept_keywords/smoke")
  assertEq "mask" (Just ">dev-lang/go-1.27.4\n") (configText crushTilde [] "/etc/portage/package.mask/smoke")

testConfigCargo :: IO ()
testConfigCargo = do
  let run = mkRun "dev-util" "mise" "2026.11.8" (Just (RuntimeCap RuntimeRust Plain (parseEbuildVersion "1.95.0"))) Nothing
  assertEq
    "accepts"
    (Just "*/*::mndz ~amd64\n<=dev-lang/rust-1.95.0 ~amd64\n<=dev-lang/rust-bin-1.95.0 ~amd64\n")
    (configText run [] "/etc/portage/package.accept_keywords/smoke")
  assertEq
    "masks"
    (Just ">dev-lang/rust-1.95.0\n>dev-lang/rust-bin-1.95.0\n")
    (configText run [] "/etc/portage/package.mask/smoke")

testConfigBun :: IO ()
testConfigBun = do
  let run = mkRun "dev-util" "opencode" "2.3.0" (Just (RuntimeCap RuntimeBun Tilde (parseEbuildVersion "1.4.4"))) Nothing
  assertEq
    "accepts"
    (Just "*/*::mndz ~amd64\n<=dev-lang/bun-bin-1.4.4 ~amd64\n")
    (configText run [] "/etc/portage/package.accept_keywords/smoke")
  assertEq "mask" (Just ">dev-lang/bun-bin-1.4.4\n") (configText run [] "/etc/portage/package.mask/smoke")

testConfigUv :: IO ()
testConfigUv = do
  let run = mkRun "dev-util" "codex-as-mcp" "2026.6.29.1" Nothing (Just "3.13")
  assertEq
    "accepts"
    (Just "*/*::mndz ~amd64\ndev-lang/python:3.13 ~amd64\n")
    (configText run [] "/etc/portage/package.accept_keywords/smoke")
  assertEq "no mask" Nothing (configText run [] "/etc/portage/package.mask/smoke")

testConfigUnlabeled :: IO ()
testConfigUnlabeled = do
  let run = mkRun "dev-lang" "deno-bin" "2.9.8" Nothing Nothing
  assertEq
    "accepts with a definition extra"
    (Just "*/*::mndz ~amd64\ndev-libs/foo ~amd64\n")
    (configText run ["dev-libs/foo"] "/etc/portage/package.accept_keywords/smoke")
  assertEq "no mask" Nothing (configText run [] "/etc/portage/package.mask/smoke")

testConfigUse :: IO ()
testConfigUse = do
  let run = mkRun "app-office" "deckcraft" "0.18.1" Nothing Nothing
      path = "/etc/portage/package.use/smoke"
  assertEq "no file without lines" Nothing (lookup path (portageConfigFiles run [] []))
  assertEq
    "lines"
    (Just "x11-libs/libxkbcommon X\nmedia-libs/libpulse X\n")
    (lookup path (portageConfigFiles run [] ["x11-libs/libxkbcommon X", "media-libs/libpulse X"]))
  assertTrue
    "setup writes it"
    ("/etc/portage/package.use/smoke" `T.isInfixOf` setupScript 1000 8 CacheOff run [] ["x11-libs/libxkbcommon X"])

testSetupScript :: IO ()
testSetupScript = do
  let script = setupScript 1000 8 CacheOff crushTilde [] []
  assertTrue "MAKEOPTS" ("'MAKEOPTS=\"-j8 -l9\"'" `T.isInfixOf` script)
  assertTrue "FEATURES" ("'FEATURES=\"getbinpkg buildpkg\"'" `T.isInfixOf` script)
  assertTrue "license" ("'ACCEPT_LICENSE=\"*\"'" `T.isInfixOf` script)
  assertTrue "appends make.conf" (">> /etc/portage/make.conf" `T.isInfixOf` script)
  assertTrue "check user" ("useradd --create-home --uid 1000 --user-group smoke" `T.isInfixOf` script)
  assertTrue "no sandbox opt-out" (not ("-sandbox" `T.isInfixOf` script))

testProbeFails :: IO ()
testProbeFails = do
  fake <- newFake $ \case
    "docker" : "run" : _ -> Just (failWith 1 "unshare: unshare failed: Operation not permitted")
    _ -> Nothing
  got <- runSandboxProbe (runFake fake) cfg
  err <- assertLeft "probe fails" got
  assertTrue "names the sandbox requirement" ("sandboxes cannot be enforced" `T.isInfixOf` err)
  calls <- dockerCalls fake
  case calls of
    [args] -> do
      assertTrue "same capability" (isSub ["--cap-add", "SYS_ADMIN"] args)
      assertTrue "probes three namespaces" (any ("unshare --pid --fork true" `isInfixOf`) args)
    other -> assertFailure ("expected one probe call, got " <> show other)

testEmergeArgv :: IO ()
testEmergeArgv = do
  let deps = dependenciesArgv (sccOverlayNames cfg) crushTilde
      pkg = packageArgv crushTilde
  assertTrue "usepkg-exclude names" (isSub ["--usepkg-exclude", "dev-util/crush dev-lang/bun-bin"] deps)
  assertTrue "buildpkg-exclude names" (isSub ["--buildpkg-exclude", "dev-util/crush dev-lang/bun-bin"] deps)
  assertTrue "onlydeps" ("--onlydeps" `elem` deps)
  assertTrue "one job" ("--jobs=1" `elem` deps && "--jobs=1" `elem` pkg)
  assertEq "exact atom" "=dev-util/crush-0.101.0::mndz" (last pkg)
  assertTrue "from source" ("--usepkg=n" `elem` pkg && "--buildpkg=n" `elem` pkg)
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession (const (Just okOutcome))
    r <- runPlain session cfg (srKey crushTilde) defOneCheck crushTilde tmp (\_ -> pure ())
    assertEq "pass" RunPass r
    reqs <- seen
    case [req | (AsRoot, req@ProcessRequest {prMode = ExecCmd "emerge" as}) <- reqs, "--usepkg=n" `elem` as] of
      [req] -> assertEq "empty DISTDIR" (Just [("DISTDIR", smokeDistDir)]) (prEnv req)
      other -> assertFailure ("expected one package step, got " <> show other)

-- | 'performRun' with a fresh trim-check state, result only.
runPlain :: SmokeSession -> SmokeContainerCfg -> PackageKey -> SmokeDef -> SmokeRun -> FilePath -> (Text -> IO ()) -> IO RunResult
runPlain session c key def run dir progress = do
  checks <- newGoChecks
  roResult <$> performRun session c checks key def run dir progress

okOutcome :: ProcessResult
okOutcome = ok "ok 0.101.0\n"

defOneCheck :: SmokeDef
defOneCheck = smokeDef (check "version" (step (const (argv ["crush", "--version"])) (exitsWith 0)) []) []

-- | Session fake: records (user, request) and network calls in order.
scriptedSession ::
  ((ExecUser, ProcessRequest) -> Maybe ProcessResult) ->
  IO (SmokeSession, IO [(ExecUser, ProcessRequest)])
scriptedSession respond = do
  seen <- newIORef []
  let exec user req = do
        modifyIORef' seen (++ [(user, req)])
        pure (fromMaybe (ok "") (respond (user, req)))
      session =
        SmokeSession
          { ssName = "c",
            ssExec = exec,
            ssNetwork = \_ -> pure (Right ())
          }
  pure (session, readIORef seen)

isEmerge :: ProcessRequest -> Bool
isEmerge req = case prMode req of
  ExecCmd "emerge" _ -> True
  _ -> False

testDepsFailure :: IO ()
testDepsFailure =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession $ \(_, req) -> case prMode req of
      ExecCmd "emerge" as | "--onlydeps" `elem` as -> Just (ProcessResult (ExitFailure 1) "emerge: there are no ebuilds to satisfy foo\n" "")
      _ -> Nothing
    r <- runPlain session cfg (srKey crushTilde) defOneCheck crushTilde tmp (\_ -> pure ())
    case r of
      RunFail FailDependencies _ file -> do
        assertEq "log file" (tmp </> "dependencies.log") file
        body <- TIO.readFile file
        assertTrue "portage output logged" ("no ebuilds to satisfy" `T.isInfixOf` body)
      other -> assertFailure ("expected dependencies failure, got " <> show other)
    reqs <- seen
    assertEq "only the dependencies emerge" 1 (length (filter (isEmerge . snd) reqs))
    assertTrue "no check command" (null [() | (AsCheckUser, _) <- reqs])

testBuildFailure :: IO ()
testBuildFailure =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession $ \(_, req) -> case prMode req of
      ExecCmd "emerge" as | "--usepkg=n" `elem` as -> Just (ProcessResult (ExitFailure 1) "" "!!! Fetch failed for crush-0.101.0.tar.gz\n")
      _ -> Nothing
    r <- runPlain session cfg (srKey crushTilde) defOneCheck crushTilde tmp (\_ -> pure ())
    case r of
      RunFail FailBuild why file -> do
        assertEq "log" (tmp </> "build.log") file
        assertTrue "reason carries the tail" ("Fetch failed" `T.isInfixOf` why)
      other -> assertFailure ("expected build failure, got " <> show other)
    reqs <- seen
    assertTrue "no check command" (null [() | (AsCheckUser, _) <- reqs])

testErrorNote :: IO ()
testErrorNote =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, _) <- scriptedSession $ \(_, req) -> case prMode req of
      ExecCmd "emerge" as
        | "--usepkg=n" `elem` as ->
            Just
              ( ProcessResult
                  (ExitFailure 1)
                  ">>> Compiling source\n"
                  " \ESC[31;01m*\ESC[0m ERROR: media-fonts/craft-fonts-0.0.1::mndz failed (compile phase):\n \ESC[31;01m*\ESC[0m   intentional smoke failure\n *\n * noise after\n"
              )
      _ -> Nothing
    r <- runPlain session cfg (srKey crushTilde) defOneCheck crushTilde tmp (\_ -> pure ())
    case r of
      RunFail FailBuild why _ ->
        assertEq
          "portage error"
          "exit 1: * ERROR: media-fonts/craft-fonts-0.0.1::mndz failed (compile phase): | *   intentional smoke failure"
          why
      other -> assertFailure ("expected build failure, got " <> show other)

testNetworkOrder :: IO ()
testNetworkOrder =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    fake <- newFake (const Nothing)
    let def =
          smokeDef
            (check "offline" (step (const (argv ["tool", "--version"])) (exitsWith 0)) [])
            [networked (check "online" (step (const (argv ["tool", "fetch"])) (exitsWith 0)) [])]
    r <-
      withSmokeContainer noopMetrics noRoots (runFake fake) cfg crushTilde $ \session ->
        runPlain session cfg (srKey crushTilde) def crushTilde tmp (\_ -> pure ())
    assertEq "pass" (Right RunPass) r
    calls <- dockerCalls fake
    let name = smokeContainerName cfg crushTilde
        interesting =
          [ describe c
          | c <- calls,
            take 1 c == ["network"] || (take 1 c == ["exec"] && ("emerge" `elem` c || "tool" `elem` c))
          ]
        describe c
          | take 1 c == ["network"] = unwords (take 2 c ++ drop 3 c)
          | "emerge" `elem` c = if "--onlydeps" `elem` c then "emerge deps" else "emerge package"
          | "fetch" `elem` c = "check online"
          | otherwise = "check offline"
    assertEq
      "order"
      [ "emerge deps",
        "emerge package",
        "network disconnect " <> name,
        "check offline",
        "network connect " <> name,
        "check online",
        "network disconnect " <> name
      ]
      interesting

testCheckExec :: IO ()
testCheckExec =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession $ \(user, req) -> case (user, prMode req) of
      (AsCheckUser, ExecCmd "timeout" as) | "help" `elem` as -> Just (ProcessResult (ExitFailure 2) "" "unknown flag\n")
      _ -> Nothing
    let def =
          smokeDef
            (check "version" (step (const (argv ["crush", "--version"])) (exitsWith 0)) [])
            [check "help" (step (const (argv ["crush", "help"])) (exitsWith 0)) []]
    r <- runPlain session cfg (srKey crushTilde) def crushTilde tmp (\_ -> pure ())
    case r of
      RunFail (FailCheck names) _ file -> do
        assertEq "only help failed" ["help"] names
        assertEq "log" (tmp </> "check-help.log") file
      other -> assertFailure ("expected check failure, got " <> show other)
    reqs <- seen
    case [as | (AsCheckUser, ProcessRequest {prMode = ExecCmd "timeout" as}) <- reqs] of
      (first : _) -> assertEq "timeout wrapper" ["--kill-after=5", "60", "sh", "-c", ". /etc/profile && exec \"$@\"", "sh", "crush", "--version"] first
      [] -> assertFailure "no check command ran"
    assertTrue "checks are not root" (null [() | (AsRoot, ProcessRequest {prMode = ExecCmd "timeout" _}) <- reqs])

groupsDef :: SmokeDef
groupsDef = defOneCheck {sdCheckGroups = ["witen-warden"]}

testCheckGroups :: IO ()
testCheckGroups =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession (const Nothing)
    r <- runPlain session cfg (srKey crushTilde) groupsDef crushTilde tmp (\_ -> pure ())
    assertEq "pass" RunPass r
    reqs <- seen
    let order =
          [ label
          | (user, req) <- reqs,
            Just label <- [describe user (prMode req)]
          ]
        describe user = \case
          ExecCmd "emerge" as | "--usepkg=n" `elem` as -> Just "build"
          ExecCmd "usermod" as -> Just (show user <> " usermod " <> unwords as)
          ExecCmd "timeout" _ -> Just "check"
          _ -> Nothing
    assertEq "order" ["build", "AsRoot usermod --append --groups witen-warden smoke", "check"] order

testCheckGroupsFail :: IO ()
testCheckGroupsFail =
  withSystemTempDirectory "om-smoke-run" $ \tmp -> do
    (session, seen) <- scriptedSession $ \(_, req) -> case prMode req of
      ExecCmd "usermod" _ -> Just (ProcessResult (ExitFailure 6) "" "usermod: group 'witen-warden' does not exist\n")
      _ -> Nothing
    r <- runPlain session cfg (srKey crushTilde) groupsDef crushTilde tmp (\_ -> pure ())
    case r of
      RunFail (FailCheck ["groups"]) why file -> do
        assertEq "log" (tmp </> "groups.log") file
        assertTrue "reason" ("does not exist" `T.isInfixOf` why)
      other -> assertFailure ("expected groups failure, got " <> show other)
    reqs <- seen
    assertTrue "no check command" (null [() | (AsCheckUser, _) <- reqs])

------------------------------------------------------------------------
-- Compile cache

gib :: Integer
gib = 1024 * 1024 * 1024

cacheCfg :: SmokeContainerCfg
cacheCfg = cfg {sccCache = CacheOn gib}

testCreateArgsCache :: IO ()
testCreateArgsCache = do
  let on = smokeCreateArgs cacheCfg crushTilde
      off = smokeCreateArgs cfg crushTilde
  assertTrue
    "package subpath mount"
    (isSub ["--mount", "type=volume,src=mndz-smoke-compile-cache,dst=/var/cache/mndz-compile,volume-subpath=dev-util/crush"] on)
  assertEq "one mount more" (length (filter (== "--mount") off) + 1) (length (filter (== "--mount") on))
  assertTrue "off has no compile cache mount" (not (any ("mndz-smoke-compile-cache" `isInfixOf`) off))
  assertEq "still one capability" 1 (length (filter (== "--cap-add") on))
  assertTrue "still SYS_ADMIN" (isSub ["--cap-add", "SYS_ADMIN"] on)
  assertTrue "still no seccomp option" (not (any ("seccomp" `isInfixOf`) on))
  assertTrue "still no privileged" ("--privileged" `notElem` on)

testCacheSetupPlain :: IO ()
testCacheSetupPlain = do
  let script = setupScript 1000 8 (CacheOn gib) crushPlain [] []
  mapM_
    (\needle -> assertTrue ("setup has " <> T.unpack needle) (needle `T.isInfixOf` script))
    [ "'FEATURES=\"getbinpkg buildpkg ccache\"'",
      "'CCACHE_DIR=\"/var/cache/mndz-compile/ccache\"'",
      "'CCACHE_CONFIGPATH=\"/etc/mndz-ccache.conf\"'",
      "'CCACHE_MAXSIZE=\"1048576Ki\"'",
      "'CCACHE_STATSLOG=\"/var/tmp/mndz-ccache-stats.log\"'",
      "'MNDZ_SMOKE_LANE=\"plain\"'",
      "> '/etc/mndz-ccache.conf'",
      "max_size = 1048576Ki",
      "> '/etc/portage/bashrc'",
      "date +%s > /var/cache/mndz-compile/.last-used",
      "> /var/tmp/mndz-go-entries-before",
      "install -m 0664 -o root -g portage /dev/null /var/tmp/mndz-ccache-stats.log",
      "install -d -m 2775 -o root -g portage /var/tmp/mndz-confcache-used"
    ]
  assertTrue "no CCACHE_SIZE (Portage would rewrite the config)" (not ("CCACHE_SIZE" `T.isInfixOf` script))
  mapM_
    (\needle -> assertTrue ("bashrc has " <> T.unpack needle) (needle `T.isInfixOf` portageBashrc))
    [ "pre_src_compile() { mndz_cache_hook; }",
      "pre_src_test() { mndz_cache_hook; }",
      "pre_src_install() { mndz_cache_hook; }",
      "export GOCACHE=${root}/go",
      "export GOFLAGS=\"${GOFLAGS} -trimpath\"",
      "trim.txt",
      "export ZIG_GLOBAL_CACHE_DIR=${root}/zig",
      "--cache-file=${T}/mndz-confcache/\\${ABI:-default}",
      "ac_cv_env_|ac_cv_lib_|ac_cv_path_install"
    ]
  assertTrue "no top-level conditionals: every if is inside a function" (not (any ("if " `T.isPrefixOf`) (T.lines portageBashrc)))

testCacheSetupLanes :: IO ()
testCacheSetupLanes = do
  assertTrue "tilde" ("'MNDZ_SMOKE_LANE=\"tilde\"'" `T.isInfixOf` setupScript 1000 8 (CacheOn gib) crushTilde [] [])
  let unlabeled = mkRun "dev-lang" "deno-bin" "2.9.8" Nothing Nothing
  assertTrue "unlabeled" ("'MNDZ_SMOKE_LANE=\"none\"'" `T.isInfixOf` setupScript 1000 8 (CacheOn gib) unlabeled [] [])

testCacheSetupOff :: IO ()
testCacheSetupOff = do
  let script = setupScript 1000 8 CacheOff crushPlain [] []
  assertTrue "no ccache feature" ("'FEATURES=\"getbinpkg buildpkg\"'" `T.isInfixOf` script)
  mapM_
    (\needle -> assertTrue ("off has no " <> T.unpack needle) (not (needle `T.isInfixOf` script)))
    ["ccache", "CCACHE", "bashrc", "mndz-compile", "MNDZ_SMOKE_LANE"]

-- | A session whose container has @go1.27.3@ and whose trim check prints
-- @verdict@; build steps succeed.
goSession :: Text -> IO (SmokeSession, IO [(ExecUser, ProcessRequest)])
goSession verdict = scriptedSession $ \(_, req) -> case prMode req of
  ExecCmd "sh" ["-c", s] | "go env GOVERSION" `isInfixOf` s -> Just (ok "go1.27.3\n")
  ExecCmd "sh" ["-s"] | prStdin req == T.unpack goTrimCheckScript -> Just (ok (T.unpack verdict <> "\n"))
  _ -> Nothing

trimChecks :: [(ExecUser, ProcessRequest)] -> Int
trimChecks reqs = length [() | (AsRoot, req) <- reqs, prStdin req == T.unpack goTrimCheckScript]

testTrimCheckOnce :: IO ()
testTrimCheckOnce =
  withSystemTempDirectory "om-smoke-trim" $ \tmp -> do
    (session, seen) <- goSession "ok"
    checks <- newGoChecks
    o1 <- performRun session cacheCfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "plain") (\_ -> pure ())
    o2 <- performRun session cacheCfg checks (srKey crushTilde) defOneCheck crushTilde (tmp </> "tilde") (\_ -> pure ())
    reqs <- seen
    assertEq "one check for two runs with the same Go" 1 (trimChecks reqs)
    assertEq "first run reports it" (Just (Just ("go1.27.3", TrimOk))) (crTrimCheck <$> roCache o1)
    assertEq "second run does not" (Just Nothing) (crTrimCheck <$> roCache o2)
    case [req | (AsRoot, req) <- reqs, prStdin req == T.unpack goTrimCheckScript] of
      [req] -> assertEq "runs in /var/tmp" (Just [("TMPDIR", "/var/tmp")]) (prEnv req)
      _ -> assertFailure "expected one trim check"
    let order = [label | (_, req) <- reqs, Just label <- [describe req]]
        describe :: ProcessRequest -> Maybe String
        describe req = case prMode req of
          ExecCmd "emerge" as | "--onlydeps" `elem` as -> Just "deps"
          ExecCmd "emerge" as | "--usepkg=n" `elem` as -> Just "build"
          ExecCmd "sh" ["-s"] | prStdin req == T.unpack goTrimCheckScript -> Just "trim"
          _ -> Nothing
    assertEq "after the dependencies step, before the package step" ["deps", "trim", "build", "deps", "build"] order

testTrimCheckFail :: IO ()
testTrimCheckFail =
  withSystemTempDirectory "om-smoke-trim" $ \tmp -> do
    (session, _) <- goSession "fail"
    checks <- newGoChecks
    o <- performRun session cacheCfg checks (srKey crushPlain) defOneCheck crushPlain tmp (\_ -> pure ())
    assertEq "run still passes" RunPass (roResult o)
    assertEq "failure reported" (Just (Just ("go1.27.3", TrimFail))) (crTrimCheck <$> roCache o)
    body <- TIO.readFile (tmp </> "go-trim-check.log")
    assertEq "check log" "fail\n" body

testTrimCheckNoGo :: IO ()
testTrimCheckNoGo =
  withSystemTempDirectory "om-smoke-trim" $ \tmp -> do
    (session, seen) <- scriptedSession (const Nothing)
    checks <- newGoChecks
    o <- performRun session cacheCfg checks (srKey crushPlain) defOneCheck crushPlain tmp (\_ -> pure ())
    reqs <- seen
    assertEq "no check" 0 (trimChecks reqs)
    assertEq "nothing reported" (Just Nothing) (crTrimCheck <$> roCache o)

configureFailure :: ProcessResult
configureFailure =
  ProcessResult
    (ExitFailure 1)
    ""
    " * ERROR: dev-libs/foo-1.0::gentoo failed (configure phase):\n *   econf failed\n"

testConfigureNote :: IO ()
testConfigureNote =
  withSystemTempDirectory "om-smoke-conf" $ \tmp -> do
    let failingDeps markers = scriptedSession $ \(_, req) -> case prMode req of
          ExecCmd "emerge" as | "--onlydeps" `elem` as -> Just configureFailure
          ExecCmd "sh" ["-c", s] | "mndz-confcache-used" `isInfixOf` s -> Just (ok markers)
          _ -> Nothing
    (session, _) <- failingDeps "dev-libs_foo\n"
    checks <- newGoChecks
    o <- performRun session cacheCfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "a") (\_ -> pure ())
    case roResult o of
      RunFail FailDependencies why _ -> do
        assertTrue "names the configure cache" (configureCacheNote `T.isInfixOf` why)
        assertTrue "names --no-compile-cache" ("--no-compile-cache" `T.isInfixOf` why)
      other -> assertFailure ("expected a dependencies failure, got " <> show other)
    (noMarker, _) <- failingDeps ""
    o2 <- performRun noMarker cacheCfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "b") (\_ -> pure ())
    case roResult o2 of
      RunFail FailDependencies why _ -> assertTrue "no note without a marker" (not (configureCacheNote `T.isInfixOf` why))
      other -> assertFailure ("expected a dependencies failure, got " <> show other)
    (off, _) <- failingDeps "dev-libs_foo\n"
    o3 <- performRun off cfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "c") (\_ -> pure ())
    case roResult o3 of
      RunFail FailDependencies why _ -> assertTrue "no note with the cache off" (not (configureCacheNote `T.isInfixOf` why))
      other -> assertFailure ("expected a dependencies failure, got " <> show other)

testReportCollected :: IO ()
testReportCollected =
  withSystemTempDirectory "om-smoke-report" $ \tmp -> do
    let respond (_, req) = case prMode req of
          ExecCmd "sh" ["-c", s]
            | s == T.unpack reportScript ->
                Just (ok "ccache direct_cache_hit\t5\nccache preprocessed_cache_hit\t1\nccache cache_miss\t2\ngo-before 10\ngo-after 14\n")
          _ -> Nothing
    (session, _) <- scriptedSession respond
    checks <- newGoChecks
    on <- performRun session cacheCfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "on") (\_ -> pure ())
    assertEq "report" (Just (CacheReport 6 2 4 Nothing)) (roCache on)
    (offSession, offSeen) <- scriptedSession respond
    off <- performRun offSession cfg checks (srKey crushPlain) defOneCheck crushPlain (tmp </> "off") (\_ -> pure ())
    assertEq "no report with the cache off" Nothing (roCache off)
    reqs <- offSeen
    assertTrue "no statistics collected" (null [() | (_, ProcessRequest {prMode = ExecCmd "sh" ["-c", s]}) <- reqs, s == T.unpack reportScript])
    assertTrue "no go version probe" (null [() | (_, ProcessRequest {prMode = ExecCmd "sh" ["-c", s]}) <- reqs, "GOVERSION" `isInfixOf` s])
