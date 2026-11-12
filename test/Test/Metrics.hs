{-# LANGUAGE OverloadedStrings #-}

module Test.Metrics
  ( unitTests,

    -- * Helpers for other metrics tests
    withRecorded,
    Event,
    evKind,
    spanStarts,
    spanEndOutcome,
    field,
  )
where

import Build.Info
  ( BuildInfo (..),
    buildInfo,
    flavorFromDefine,
    sha256File,
  )
import CLI.Jobs (mapConcurrentlyN)
import CLI.Parser (Command (..))
import CLI.Parser qualified as Cmd
import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig (..),
    instrumentMultiHandle,
    mkProgressConfig,
    noopMultiHandle,
    pauseActivePanel,
    resumeActivePanel,
  )
import Colog (LogAction (..), Message, Msg (..), logWarning, usingLoggerT)
import Config.Types (CheckCacheTtl (..))
import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (AsyncException (..), IOException, SomeException, fromException, throwIO, try)
import Control.Monad (join, void, when)
import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isHexDigit)
import Data.Foldable (toList)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Logging.Bootstrap (mkLogHold)
import Metrics.Container (CgroupRoots (..), cgroupOfPid, cgroupSnapshot)
import Metrics.Core
  ( Metrics (..),
    Outcome (..),
    noopMetrics,
    openLifecycleSpan,
    redactArgs,
    trySync,
    withSpan,
  )
import Metrics.Http (githubRouteTemplate, instrumentManagerSettings)
import Metrics.Process (requestMarkerVar, timeFormat, timedRunner)
import Metrics.Recorder
  ( HeaderInputs (..),
    HostFacts (..),
    Invocation (..),
    Recorder,
    finishRecorder,
    openRecorder,
    recMetrics,
    redactSecrets,
    runHeaderPairs,
  )
import Metrics.Run (RunSetup (..), invocationFor, withRunMetrics)
import Metrics.Sampler
  ( CpuTimes (..),
    DiskTotals (..),
    PidStat (..),
    SamplerConfig (..),
    cpuPercents,
    initialSampleState,
    parseCpuTimes,
    parseDiskStats,
    parseLoadAvg,
    parseMemInfo,
    parsePidStat,
    parsePressure,
    selectProcesses,
    startSampler,
    takeSample,
  )
import Metrics.Startup
  ( MetricsStart (..),
    MetricsStartupOps (..),
    metricsGate,
    metricsRunDir,
    stateHomeFrom,
  )
import Metrics.Writer (LineSink (..), closeWriter, handleSink, newWriter, writeLine)
import Network.HTTP.Client
  ( ManagerSettings (..),
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    requestHeaders,
  )
import Network.HTTP.Client.Internal (makeConnection)
import Overlay.Version (parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Check (PackageEntry (..), checkPackage)
import Update.CheckCache (flushCheckCache, openCheckCacheAt, recordCacheCounters)
import Update.Git (gitPush, isGitWorkTree, pathsDirty)
import Update.Process
  ( Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Process.Docker
  ( MaterializeDockerCfg (..),
    MaterializeUnitRef (..),
    materializeCreateArgs,
    materializeExecArgs,
    withUnitMaterializeSession,
  )
import Update.TempWorkspace (UnitDirs (..))
import Update.Types (mkPackageKey)

unitTests :: TestTree
unitTests =
  testGroup
    "Metrics"
    [ testGroup
        "BuildInfo"
        [ testCase "git revision is 40 hex or unknown" testGitRevShape,
          testCase "flavor define mapping" testFlavorMapping,
          testCase "compiled flavor is a known name" testCompiledFlavor,
          testCase "sha256File matches sha256sum of fixture" testSha256Fixture
        ],
      testGroup
        "Startup"
        [ testCase "state home fallback and run dir" testStateHome,
          testCase "missing GNU time fails naming tool and --no-metrics" testGateMissingTime,
          testCase "non-GNU time fails with the same guidance" testGateNonGnuTime,
          testCase "unwritable metrics directory fails naming path" testGateUnwritable,
          testCase "--no-metrics bypasses checks and warns" testGateNoMetricsBypass,
          testCase "list and github-token warn that --no-metrics has no effect" testGateNoEffect,
          testCase "recording work command creates run dir without warnings" testGateOn
        ],
      testGroup
        "Writer"
        [ testCase "lines are valid JSON in order" testWriterOrder,
          testCase "first write failure warns once and drops later lines" testWriterDegrade
        ],
      testGroup
        "Spans"
        [ testCase "nested spans get the enclosing parent" testNestedParent,
          testCase "mapConcurrentlyN child inherits the caller span" testForkParent,
          testCase "killed run leaves span_start without span_end" testOpenSpanVisible,
          testCase "withSpan ends fail on exception" testSpanException,
          testCase "phases are children of the command span" testPhases,
          testCase "lifecycle span is detached from later work" testLifecycleDetached
        ],
      testGroup
        "HeaderFooter"
        [ testCase "header keys (golden)" testHeaderKeys,
          testCase "invocation from update flags" testInvocationFor,
          testCase "unknown target exit is early-exit status 1" testFooterEarlyExit,
          testCase "UserInterrupt is interrupted" testFooterInterrupted,
          testCase "interrupt while the sampler starts still writes the footer" testFooterInterruptSamplerStart,
          testCase "trySync catches sync and rethrows async exceptions" testTrySync,
          testCase "counters reach the footer" testFooterCounters,
          testCase "outdated cache counters: cold misses, warm hits" testCacheCounters
        ],
      testGroup
        "Redaction"
        [ testCase "token in argv is redacted" testRedaction
        ],
      testGroup
        "Process"
        [ testCase "Timed exec is rewritten under GNU time" testTimedRewrite,
          testCase "shell command runs as /bin/sh -c under GNU time" testTimedShell,
          testCase "missing tool runs unwrapped" testTimedMissingTool,
          testCase "parsed time file is attached and deleted" testTimedIngest,
          testCase "malformed time file is kept with time_parse_error" testTimedMalformed,
          testCase "Lifecycle and Untimed pass through" testTimedPassThrough,
          testCase "TimedInteractive is wrapped and marked interactive" testTimedInteractive,
          testCase "interrupt during a TimedInteractive run ends the span fail and leaves no child" testTimedInterrupted,
          testCase "wrapped request is marked, original env kept" testTimedMarker,
          testCase "completed request leaves its background processes alone" testTimedNoReapOnSuccess,
          testCase "missing tool under TimedInteractive raises as without metrics" testTimedInteractiveMissingTool,
          testCase "argv token is redacted in proc span" testTimedRedaction,
          testCase "real GNU time keeps stderr and exit 2" testTimedRealBinary,
          testCase "git ops record measured proc spans" testGitProcSpans,
          testCase "git argv token is redacted in proc span" testGitArgvRedaction
        ],
      testGroup
        "Container"
        [ testCase "create mounts time dir only when recording" testCreateArgsMount,
          testCase "exec wraps the inner command only when recording" testExecArgsInnerWrap,
          testCase "recorded exec: inner/outer under one parent, lifecycle create" testSessionRecorded,
          testCase "image without GNU time hard-fails naming image and --no-metrics" testSessionNoGnuTime,
          testCase "--no-metrics skips the in-container time check" testSessionNoMetricsSkipsCheck,
          testCase "cgroup snapshot from fixture proc and sysfs" testCgroupSnapshot,
          testCase "cgroup snapshot records the reason when a file is missing" testCgroupMissing
        ],
      testGroup
        "Http"
        [ testCase "GitHub route templating" testRouteTemplate,
          testCase "manager span: template, status, bytes, no token" testHttpManagerSpan,
          testCase "failed request ends the span fail" testHttpManagerFailure
        ],
      testGroup
        "Sampler"
        [ testCase "proc parsers on fixture text" testProcParsers,
          testCase "sample from fixture /proc with and without pressure" testSampleFixture,
          testCase "process selection: our tree, containers, top 10 others" testProcessSelection,
          testCase "short run has a start and an end sample" testSamplerStartEnd
        ],
      testGroup
        "ProgressSpans"
        [ testCase "start, step, step, skip gives three spans ending skip" testMultiHandleSpans,
          testCase "pause then resume yields one prompt span" testPromptSpan,
          testCase "capacity-1 slot contention is a slot.wait span" testSlotWait
        ]
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

type Event = KM.KeyMap Value

-- | Run @act@ against a recording 'Metrics', finish the run, and return the
-- parsed event lines.
withRecorded :: (Metrics -> IO a) -> IO (a, [Event])
withRecorded act =
  withSystemTempDirectory "mndz-metrics-" $ \tmp -> do
    h <- openBinaryFile (tmp </> "run.jsonl") WriteMode
    w <- newWriter (\_ -> pure ()) (handleSink h)
    createDirectoryIfMissing True (tmp </> "time")
    rec <- openRecorder w (tmp </> "time")
    a <- act (recMetrics rec)
    finishRecorder rec (Right ())
    evs <- readEvents (tmp </> "run.jsonl")
    pure (a, evs)

readEvents :: FilePath -> IO [Event]
readEvents path = do
  bytes <- BS.readFile path
  mapM decodeEvent (filter (not . BS.null) (BS8.lines bytes))

decodeEvent :: BS.ByteString -> IO Event
decodeEvent line = case decodeStrict line of
  Just (Object o) -> pure o
  _ -> assertFailure ("not a JSON object line: " <> BS8.unpack line)

field :: Text -> Event -> Maybe Value
field k = KM.lookup (Key.fromText k)

evKind :: Event -> Text
evKind e = case field "ev" e of
  Just (String s) -> s
  _ -> ""

intField :: Text -> Event -> Maybe Int
intField k e = case field k e of
  Just (Number n) -> Just (truncate n)
  _ -> Nothing

textField :: Text -> Event -> Maybe Text
textField k e = case field k e of
  Just (String s) -> Just s
  _ -> Nothing

-- | @(id, parent, name, attrs)@ for every span_start.
spanStarts :: [Event] -> [(Int, Maybe Int, Text, Event)]
spanStarts evs =
  [ (sid, intField "parent" e, name, attrs)
  | e <- evs,
    evKind e == "span_start",
    let attrs = case field "attrs" e of
          Just (Object o) -> o
          _ -> KM.empty,
    Just sid <- [intField "id" e],
    Just name <- [textField "name" e]
  ]

spanEndOutcome :: [Event] -> Int -> Maybe Text
spanEndOutcome evs sid =
  case [e | e <- evs, evKind e == "span_end", intField "id" e == Just sid] of
    (e : _) -> textField "outcome" e
    [] -> Nothing

spanEndT :: [Event] -> Int -> Maybe Int
spanEndT evs sid =
  case [e | e <- evs, evKind e == "span_end", intField "id" e == Just sid] of
    (e : _) -> intField "t_ns" e
    [] -> Nothing

spanStartT :: [Event] -> Int -> Maybe Int
spanStartT evs sid =
  case [e | e <- evs, evKind e == "span_start", intField "id" e == Just sid] of
    (e : _) -> intField "t_ns" e
    [] -> Nothing

spanEndAttrs :: [Event] -> Int -> Event
spanEndAttrs evs sid =
  case [e | e <- evs, evKind e == "span_end", intField "id" e == Just sid] of
    (e : _) | Just (Object o) <- field "attrs" e -> o
    _ -> KM.empty

firstId :: Text -> [Event] -> IO Int
firstId name evs = case idsNamed name evs of
  (sid : _) -> pure sid
  [] -> assertFailure ("no span named " <> T.unpack name)

idsNamed :: Text -> [Event] -> [Int]
idsNamed name evs = [sid | (sid, _, n, _) <- spanStarts evs, n == name]

------------------------------------------------------------------------
-- Build info
------------------------------------------------------------------------

testGitRevShape :: IO ()
testGitRevShape = do
  let rev = biGitRev buildInfo
  assertTrue
    ("revision shape: " <> T.unpack rev)
    (rev == "unknown" || (T.length rev == 40 && T.all isHexDigit rev))
  assertTrue "unknown revision is never dirty" (rev /= "unknown" || not (biGitDirty buildInfo))

testFlavorMapping :: IO ()
testFlavorMapping = do
  assertEq "dev" "dev" (flavorFromDefine "DEV")
  assertEq "release" "release" (flavorFromDefine "RELEASE")
  assertEq "coverage-dev" "coverage-dev" (flavorFromDefine "COVERAGE_DEV")
  assertEq "coverage-release" "coverage-release" (flavorFromDefine "COVERAGE_RELEASE")
  assertEq "no define" "unknown" (flavorFromDefine "")
  assertEq "other" "unknown" (flavorFromDefine "PROFILING")

testCompiledFlavor :: IO ()
testCompiledFlavor =
  assertTrue
    ("flavor: " <> T.unpack (biFlavor buildInfo))
    ( biFlavor buildInfo
        `elem` ["dev", "release", "coverage-dev", "coverage-release", "unknown"]
    )

testSha256Fixture :: IO ()
testSha256Fixture = do
  digest <- sha256File "test/fixtures/sha256-sample.txt"
  assertEq
    "sha256sum"
    "0631970ee68cdfaadc2b318ab51d745146cbddc7b6a973782ec1a7f72d1bf964"
    digest

------------------------------------------------------------------------
-- Startup gate
------------------------------------------------------------------------

sampleRunId :: String
sampleRunId = "20261111T101500-0700-4242.a8f3"

gnuVersion :: Text
gnuVersion = "time (GNU Time) 1.9\nCopyright (C) 2018 Free Software Foundation, Inc.\n"

-- | Ops whose effects record calls; @createResult@ is the dir creation result.
fakeOps :: Either Text Text -> Either Text () -> IO (MetricsStartupOps, IO [String])
fakeOps timeResult createResult = do
  calls <- newIORef []
  let note c = atomicModifyIORef' calls (\xs -> (xs <> [c], ()))
  pure
    ( MetricsStartupOps
        { msoTimeVersion = note "time" >> pure timeResult,
          msoLookupEnv = \k -> do
            note ("env:" <> k)
            pure $ case k of
              "HOME" -> Just "/home/op"
              _ -> Nothing,
          msoCreateRunDir = \dir -> note ("mkdir:" <> dir) >> pure createResult
        },
      readIORef calls
    )

-- | Run the gate with a capturing logger; returns result and logged warnings.
runGate :: MetricsStartupOps -> Bool -> Command -> IO (Either Text MetricsStart, [Text])
runGate ops noMetrics cmd = do
  captured <- newIORef []
  let capture :: LogAction IO Message
      capture = LogAction $ \msg -> atomicModifyIORef' captured (\xs -> (xs <> [msgText msg], ()))
  r <- metricsGate ops (usingLoggerT capture . logWarning) noMetrics cmd sampleRunId
  ws <- readIORef captured
  pure (r, ws)

outdatedCmd :: Command
outdatedCmd = Cmd.Outdated False [] []

testStateHome :: IO ()
testStateHome = do
  assertEq "xdg wins" (Just "/x/state") (stateHomeFrom (Just "/x/state") (Just "/home/op"))
  assertEq "empty xdg falls back" (Just "/home/op/.local/state") (stateHomeFrom (Just "") (Just "/home/op"))
  assertEq "home fallback" (Just "/home/op/.local/state") (stateHomeFrom Nothing (Just "/home/op"))
  assertEq "neither" Nothing (stateHomeFrom Nothing Nothing)
  assertEq
    "spec example path"
    "/home/op/.local/state/mndz/overlay-manager/metrics/20261111T101500-0700-4242.a8f3-update/run.jsonl"
    (metricsRunDir "/home/op/.local/state" sampleRunId "update" </> "run.jsonl")

testGateMissingTime :: IO ()
testGateMissingTime = do
  (ops, calls) <- fakeOps (Left "/usr/bin/time: does not exist") (Right ())
  (r, _) <- runGate ops False (Cmd.Update False [] [])
  case r of
    Left err -> do
      assertTrue "names /usr/bin/time" ("/usr/bin/time" `T.isInfixOf` err)
      assertTrue "names --no-metrics" ("--no-metrics" `T.isInfixOf` err)
    Right other -> assertFailure ("expected failure, got " <> show other)
  cs <- calls
  assertTrue "no directory created" (not (any (("mkdir:" `T.isPrefixOf`) . T.pack) cs))

testGateNonGnuTime :: IO ()
testGateNonGnuTime = do
  (ops, _) <- fakeOps (Right "BusyBox v1.36.1 multi-call binary.") (Right ())
  (r, _) <- runGate ops False (Cmd.Gencache [] False [])
  case r of
    Left err -> do
      assertTrue "names /usr/bin/time" ("/usr/bin/time" `T.isInfixOf` err)
      assertTrue "names --no-metrics" ("--no-metrics" `T.isInfixOf` err)
      assertTrue "says not GNU" ("not GNU Time" `T.isInfixOf` err)
    Right other -> assertFailure ("expected failure, got " <> show other)

testGateUnwritable :: IO ()
testGateUnwritable = do
  (ops, _) <- fakeOps (Right gnuVersion) (Left "permission denied")
  (r, _) <- runGate ops False outdatedCmd
  case r of
    Left err -> do
      assertTrue
        "names the directory"
        ( T.pack (metricsRunDir "/home/op/.local/state" sampleRunId "outdated")
            `T.isInfixOf` err
        )
      assertTrue "names --no-metrics" ("--no-metrics" `T.isInfixOf` err)
    Right other -> assertFailure ("expected failure, got " <> show other)

testGateNoMetricsBypass :: IO ()
testGateNoMetricsBypass = do
  (ops, calls) <- fakeOps (Left "absent") (Left "unwritable")
  (r, ws) <- runGate ops True outdatedCmd
  assertEq "off" (Right MetricsOff) r
  cs <- calls
  assertEq "no startup effect ran" [] cs
  assertEq "one warning" ["metrics disabled by --no-metrics"] ws
  (rU, wsU) <- runGate ops True (Cmd.Update False [] [])
  assertEq "update off" (Right MetricsOff) rU
  assertEq "update warns" ["metrics disabled by --no-metrics"] wsU
  (rE, wsE) <- runGate ops True Cmd.Eclean
  assertEq "eclean off" (Right MetricsOff) rE
  assertEq "eclean warns" ["metrics disabled by --no-metrics"] wsE
  (rG, wsG) <- runGate ops True (Cmd.Gencache [] False [])
  assertEq "gencache off" (Right MetricsOff) rG
  assertEq "gencache warns" ["metrics disabled by --no-metrics"] wsG

testGateNoEffect :: IO ()
testGateNoEffect = do
  (ops, calls) <- fakeOps (Left "absent") (Left "unwritable")
  (rL, wsL) <- runGate ops True Cmd.List
  assertEq "list off" (Right MetricsOff) rL
  assertEq
    "list warning"
    ["metrics are not collected for list; --no-metrics has no effect"]
    wsL
  (rT, wsT) <- runGate ops True (Cmd.GitHubToken False)
  assertEq "github-token off" (Right MetricsOff) rT
  assertEq
    "github-token warning"
    ["metrics are not collected for github-token; --no-metrics has no effect"]
    wsT
  (rL2, wsL2) <- runGate ops False Cmd.List
  assertEq "list without flag off" (Right MetricsOff) rL2
  assertEq "list without flag is silent" [] wsL2
  cs <- calls
  assertEq "never checks time for list" [] cs

testGateOn :: IO ()
testGateOn = do
  (ops, calls) <- fakeOps (Right gnuVersion) (Right ())
  (r, ws) <- runGate ops False outdatedCmd
  let dir = metricsRunDir "/home/op/.local/state" sampleRunId "outdated"
  assertEq "on" (Right (MetricsOn dir "time (GNU Time) 1.9")) r
  assertEq "no warnings" [] ws
  cs <- calls
  assertTrue "created run dir" (("mkdir:" <> dir) `elem` cs)

------------------------------------------------------------------------
-- Writer
------------------------------------------------------------------------

testWriterOrder :: IO ()
testWriterOrder =
  withSystemTempDirectory "mndz-writer-" $ \tmp -> do
    let path = tmp </> "run.jsonl"
    h <- openBinaryFile path WriteMode
    w <- newWriter (\_ -> pure ()) (handleSink h)
    mapM_ (\i -> writeLine w ["ev" .=: "x", "i" .=: Number (fromIntegral i)]) [1 .. 200 :: Int]
    closeWriter w
    evs <- readEvents path
    assertEq "count" 200 (length evs)
    assertEq "in order" [1 .. 200] (mapMaybe (intField "i") evs)
  where
    k .=: v = (Key.fromText k, toValue v)
    toValue :: Value -> Value
    toValue = id

testWriterDegrade :: IO ()
testWriterDegrade = do
  written <- newIORef (0 :: Int)
  warnings <- newIORef []
  let sink =
        LineSink
          { sinkWrite = \_ -> do
              n <- atomicModifyIORef' written (\c -> (c + 1, c + 1))
              when (n >= 3) $ ioError (userError "disk full"),
            sinkClose = pure ()
          }
  w <- newWriter (\msg -> atomicModifyIORef' warnings (\xs -> (xs <> [msg], ()))) sink
  mapM_ (\_ -> writeLine w [(Key.fromText "ev", String "x")]) [1 .. 10 :: Int]
  closeWriter w
  ws <- readIORef warnings
  assertEq "one warning" 1 (length ws)
  assertTrue "warning says recording stopped" (all ("metrics recording stopped" `T.isInfixOf`) ws)
  attempts <- readIORef written
  assertEq "no write after the failure" 3 attempts
  -- The command result is unaffected: a failing sink under a whole run.
  r <-
    withSystemTempDirectory "mndz-writer-run-" $ \_ -> do
      w2 <- newWriter (\_ -> pure ()) sink
      rec <- openRecorder w2 "/nonexistent/time"
      out <- withSpan (recMetrics rec) "work" [] (pure (42 :: Int))
      finishRecorder rec (Right ())
      pure out
  assertEq "result unchanged" 42 r

------------------------------------------------------------------------
-- Spans
------------------------------------------------------------------------

testNestedParent :: IO ()
testNestedParent = do
  (_, evs) <- withRecorded $ \m ->
    withSpan m "outer" [] $
      withSpan m "inner" [] $
        withSpan m "leaf" [] (pure ())
  case spanStarts evs of
    [(o, po, "outer", _), (i, pi', "inner", _), (_, pl, "leaf", _)] -> do
      assertEq "outer root" Nothing po
      assertEq "inner under outer" (Just o) pi'
      assertEq "leaf under inner" (Just i) pl
    other -> assertFailure ("unexpected spans: " <> show [(a, b, c) | (a, b, c, _) <- other])
  assertTrue "ids increase" (let ids = [s | (s, _, _, _) <- spanStarts evs] in ids == [1 .. length ids])

testForkParent :: IO ()
testForkParent = do
  (_, evs) <- withRecorded $ \m ->
    withSpan m "caller" [] $
      void $
        mapConcurrentlyN m 2 (\i -> withSpan m "child" ["i" `pairI` i] (pure ())) [1 .. 3 :: Int]
  callerId <- firstId "caller" evs
  let children = [p | (_, p, "child", _) <- spanStarts evs]
  assertEq "three children" 3 (length children)
  assertTrue "children under caller" (all (== Just callerId) children)
  assertTrue
    "slot waits under caller"
    (all (== Just callerId) [p | (_, p, "slot.wait", _) <- spanStarts evs])
  where
    pairI k v = (Key.fromText k, Number (fromIntegral v))

testOpenSpanVisible :: IO ()
testOpenSpanVisible = do
  (_, evs) <- withRecorded $ \m -> void (mSpanStart m "running" [])
  sid <- firstId "running" evs
  assertEq "no span_end" Nothing (spanEndOutcome evs sid)
  assertEq "footer still last" "run_end" (evKind (last evs))

testSpanException :: IO ()
testSpanException = do
  (r, evs) <- withRecorded $ \m ->
    try @ExitCode (withSpan m "boom" [] (throwIO (ExitFailure 3) :: IO ()))
  assertEq "rethrown" (Left (ExitFailure 3)) r
  sid <- firstId "boom" evs
  assertEq "fail outcome" (Just "fail") (spanEndOutcome evs sid)

testPhases :: IO ()
testPhases = do
  (_, evs) <- withRecorded $ \m ->
    withSpan m "command" [] $ do
      mEnterPhase m "config"
      mEnterPhase m "select"
      withSpan m "inside" [] (pure ())
      mEnterPhase m "check"
  cmdId <- firstId "command" evs
  let phases = [(n, p) | (_, p, n, _) <- spanStarts evs, "phase." `T.isPrefixOf` n]
  assertEq
    "phases under command"
    [("phase.config", Just cmdId), ("phase.select", Just cmdId), ("phase.check", Just cmdId)]
    phases
  selectId <- firstId "phase.select" evs
  assertEq "work nests in phase" [Just selectId] [p | (_, p, "inside", _) <- spanStarts evs]
  assertEq "previous phase closed ok" (Just "ok") (spanEndOutcome evs selectId)
  case filter ((== "run_end") . evKind) evs of
    [footer] -> assertEq "last phase" (Just (String "check")) (field "last_phase" footer)
    _ -> assertFailure "expected one run_end"

------------------------------------------------------------------------
-- Header and footer
------------------------------------------------------------------------

fakeHeader :: HeaderInputs
fakeHeader =
  HeaderInputs
    { hiRunId = T.pack sampleRunId,
      hiCommand = "update",
      hiStartedAt = "2026-11-11T10:15:00-07:00",
      hiBuild =
        BuildInfo
          { biVersion = "0.1.0.0",
            biGitRev = "0123456789abcdef0123456789abcdef01234567",
            biGitDirty = False,
            biFlavor = "release",
            biGhcVersion = "9.10.3"
          },
      hiExeSha256 = "ab",
      hiHost = HostFacts {hfCpus = 8, hfKernel = "6.18.0", hfMachine = "x86_64", hfMemTotalKb = Just 1024},
      hiInvocation = Invocation {invJobs = 4, invRefresh = Just True, invTargets = ["dev-util/foo"], invExcludes = []},
      hiTimePath = "/usr/bin/time",
      hiTimeVersion = "time (GNU Time) 1.9",
      hiCapabilities = 8
    }

testHeaderKeys :: IO ()
testHeaderKeys = do
  let kvs = runHeaderPairs fakeHeader
      keys = map (Key.toText . fst) kvs
      sub k = case lookup (Key.fromText k) kvs of
        Just (Object o) -> map Key.toText (KM.keys o)
        _ -> []
  assertEq
    "top-level keys"
    ["ev", "schema", "run_id", "command", "started_at", "build", "host", "invocation", "time", "capabilities"]
    keys
  assertEq "schema" (Just (Number 1)) (lookup (Key.fromText "schema") kvs)
  assertEq "build keys" ["exe_sha256", "flavor", "ghc", "git_dirty", "git_rev", "version"] (sub "build")
  assertEq "host keys" ["cpus", "kernel", "machine", "mem_total_kb"] (sub "host")
  assertEq "invocation keys" ["excludes", "jobs", "refresh", "targets"] (sub "invocation")
  assertEq "time keys" ["path", "version"] (sub "time")

testInvocationFor :: IO ()
testInvocationFor = do
  assertEq
    "update --jobs 4 --refresh dev-util/foo"
    Invocation {invJobs = 4, invRefresh = Just True, invTargets = ["dev-util/foo"], invExcludes = []}
    (invocationFor 4 (Cmd.Update True ["dev-util/foo"] []))
  assertEq
    "eclean has no refresh"
    Nothing
    (invRefresh (invocationFor 2 Cmd.Eclean))

-- | 'withRunMetrics' over a temp run dir; returns the body result and events.
runRecorded :: (Metrics -> IO ()) -> IO (Either ExitCodeOrInterrupt (), [Event])
runRecorded = runRecordedWith (\_ -> pure (pure ()))

runRecordedWith ::
  (Recorder -> IO (IO ())) ->
  (Metrics -> IO ()) ->
  IO (Either ExitCodeOrInterrupt (), [Event])
runRecordedWith sampler body =
  withSystemTempDirectory "mndz-run-" $ \dir -> do
    let setup =
          RunSetup
            { rsRunDir = dir,
              rsRunId = sampleRunId,
              rsCommand = "update",
              rsTimeVersion = "time (GNU Time) 1.9",
              rsInvocation = invocationFor 1 (Cmd.Update False ["nope"] []),
              rsWarn = \_ -> pure (),
              rsStartSampler = sampler
            }
    r1 <- try @ExitCode (try @AsyncException (withRunMetrics setup body))
    evs <- readEvents (dir </> "run.jsonl")
    let r = case r1 of
          Left code -> Left (ByExit code)
          Right (Left ae) -> Left (ByAsync ae)
          Right (Right ()) -> Right ()
    pure (r, evs)

data ExitCodeOrInterrupt = ByExit ExitCode | ByAsync AsyncException
  deriving (Eq, Show)

footerOf :: [Event] -> IO Event
footerOf evs = case filter ((== "run_end") . evKind) evs of
  [f] | evKind (last evs) == "run_end" -> pure f
  _ -> assertFailure "expected exactly one run_end as the last line"

testFooterEarlyExit :: IO ()
testFooterEarlyExit = do
  (r, evs) <- runRecorded $ \m -> do
    mEnterPhase m "config"
    mEnterPhase m "select"
    throwIO (ExitFailure 1)
  assertEq "exit passes through" (Left (ByExit (ExitFailure 1))) r
  assertEq "header first" ["run_start"] (map evKind (take 1 evs))
  footer <- footerOf evs
  assertEq "outcome" (Just (String "early-exit")) (field "outcome" footer)
  assertEq "status" (Just 1) (intField "exit_status" footer)
  assertEq "phase" (Just (String "select")) (field "last_phase" footer)
  assertTrue "rusage present" (isJust (field "rusage" footer))

testFooterInterrupted :: IO ()
testFooterInterrupted = do
  (r, evs) <- runRecorded $ \m -> do
    mEnterPhase m "mutate"
    void (mSpanStart m "package" [])
    throwIO UserInterrupt
  assertEq "interrupt passes through" (Left (ByAsync UserInterrupt)) r
  footer <- footerOf evs
  assertEq "outcome" (Just (String "interrupted")) (field "outcome" footer)
  assertEq "phase" (Just (String "mutate")) (field "last_phase" footer)

testFooterInterruptSamplerStart :: IO ()
testFooterInterruptSamplerStart = do
  (r, evs) <- runRecordedWith (\_ -> throwIO UserInterrupt) (\_ -> pure ())
  assertEq "interrupt passes through" (Left (ByAsync UserInterrupt)) r
  assertEq "header first" ["run_start"] (map evKind (take 1 evs))
  footer <- footerOf evs
  assertEq "outcome" (Just (String "interrupted")) (field "outcome" footer)

testTrySync :: IO ()
testTrySync = do
  sync <- trySync (throwIO (userError "boom") :: IO ())
  assertTrue "sync caught" (either (const True) (const False) sync)
  async <- try @AsyncException (trySync (throwIO UserInterrupt :: IO ()))
  assertEq "async rethrown" (Left UserInterrupt) (void async)

testFooterCounters :: IO ()
testFooterCounters = do
  (_, evs) <- runRecorded $ \m -> do
    void (mSpanStart m "package" [])
    mBump m "check_cache.hits" 2
    mBump m "check_cache.hits" 3
    mSetCounter m "image" (String "reused")
    throwIO (ExitFailure 1)
  footer <- footerOf evs
  assertEq "late failure is completed" (Just (String "completed")) (field "outcome" footer)
  case field "counters" footer of
    Just (Object cs) -> do
      assertEq "summed" (Just (Number 5)) (KM.lookup "check_cache.hits" cs)
      assertEq "set" (Just (String "reused")) (KM.lookup "image" cs)
    other -> assertFailure ("counters: " <> show other)

------------------------------------------------------------------------
-- Redaction
------------------------------------------------------------------------

testRedaction :: IO ()
testRedaction = do
  assertEq "replace all" "a <redacted> b <redacted>" (redactSecrets ["ghp_x"] "a ghp_x b ghp_x")
  assertEq "empty secret ignored" "abc" (redactSecrets [""] "abc")
  (args, evs) <- withRecorded $ \m -> do
    mAddSecret m "github_pat_SECRET"
    redactArgs m ["https://x-access-token:github_pat_SECRET@github.com/o/r", "plain"]
  assertEq
    "argv redacted"
    ["https://x-access-token:<redacted>@github.com/o/r", "plain"]
    args
  assertTrue "no env key in any event" (not (any (KM.member "env") evs))
  noop <- redactArgs noopMetrics ["github_pat_SECRET"]
  assertEq "noop redactor is identity" ["github_pat_SECRET"] noop

------------------------------------------------------------------------
-- Progress-derived spans
------------------------------------------------------------------------

testMultiHandleSpans :: IO ()
testMultiHandleSpans = do
  let key = mkPackageKey "dev-util" "foo"
  (_, evs) <- withRecorded $ \m ->
    instrumentMultiHandle m "Updating packages" noopMultiHandle $ \mh -> do
      mhStart mh key
      mhStep mh key "fetching"
      mhStep mh key "vendoring"
      mhSkip mh key "already current"
  let starts = spanStarts evs
  assertEq "three spans" 3 (length starts)
  case starts of
    [(p, _, "package", pa), (s1, ps1, "step", _), (s2, ps2, "step", _)] -> do
      assertEq "package attr" (Just (String "dev-util/foo")) (KM.lookup "package" pa)
      assertEq "step 1 under package" (Just p) ps1
      assertEq "step 2 under package" (Just p) ps2
      assertEq "package skip" (Just "skip") (spanEndOutcome evs p)
      assertEq "step 1 ok" (Just "ok") (spanEndOutcome evs s1)
      assertEq "last step skip" (Just "skip") (spanEndOutcome evs s2)
    other -> assertFailure ("unexpected spans: " <> show [(a, b, c) | (a, b, c, _) <- other])

testPromptSpan :: IO ()
testPromptSpan = do
  hold <- mkLogHold
  pcfg0 <- mkProgressConfig False Cmd.ColorOff hold (LogAction (\_ -> pure ()))
  (_, evs) <- withRecorded $ \m -> do
    let pcfg = pcfg0 {pcMetrics = m}
    pauseActivePanel pcfg
    resumeActivePanel pcfg
  case spanStarts evs of
    [(sid, _, "prompt", attrs)] -> do
      assertEq "interactive" (Just (Bool True)) (KM.lookup "interactive" attrs)
      assertEq "closed" (Just "ok") (spanEndOutcome evs sid)
    other -> assertFailure ("unexpected spans: " <> show [(a, b, c) | (a, b, c, _) <- other])

testSlotWait :: IO ()
testSlotWait = do
  (_, evs) <- withRecorded $ \m ->
    void $
      mapConcurrentlyN m 1 (\_ -> withSpan m "work" [] (threadDelay 60_000)) [1, 2 :: Int]
  let waits = idsNamed "slot.wait" evs
      works = idsNamed "work" evs
      endsOf = mapMaybe (spanEndT evs)
      durOf sid = (-) <$> spanEndT evs sid <*> spanStartT evs sid
      longWaits = [w | w <- waits, Just d <- [durOf w], d >= 30_000_000]
  assertEq "two waits (one per job)" 2 (length waits)
  -- The blocked job's wait lasts most of the other job's 60 ms run and ends
  -- only after that run released the slot.
  case longWaits of
    [w] ->
      assertTrue
        "wait ends after the other run"
        (maybe False (>= minimum (endsOf works)) (spanEndT evs w))
    other -> assertFailure ("expected one long wait, got " <> show (mapMaybe durOf other))
  assertTrue
    "kind jobs with capacity 1"
    ( all
        (\(_, _, _, a) -> KM.lookup "kind" a == Just (String "jobs") && KM.lookup "capacity" a == Just (Number 1))
        [s | s@(_, _, "slot.wait", _) <- spanStarts evs]
    )

------------------------------------------------------------------------
-- Process measurement
------------------------------------------------------------------------

execReq :: FilePath -> [String] -> ProcessRequest
execReq c as =
  ProcessRequest
    { prMode = ExecCmd c as,
      prCwd = Nothing,
      prEnv = Nothing,
      prStdin = "",
      prMeasure = Timed
    }

cannedResult :: ProcessResult
cannedResult =
  ProcessResult
    { prExitCode = ExitFailure 2,
      prStdout = "out\n",
      prStderr = "x\n"
    }

-- | Fake inner runner: records requests and writes @timeBody@ to the @-o@
-- file of a GNU time invocation.
fakeInner :: BS.ByteString -> IO (ProcessRequest -> IO ProcessResult, IO [ProcessRequest])
fakeInner timeBody = do
  seen <- newIORef []
  let run req = do
        atomicModifyIORef' seen (\xs -> (xs <> [req], ()))
        case prMode req of
          ExecCmd "/usr/bin/time" ("-o" : file : _) -> BS.writeFile file timeBody
          _ -> pure ()
        pure cannedResult
  pure (run, readIORef seen)

validTime :: BS.ByteString
validTime =
  "{\"wall_s\":0.50,\"user_s\":0.10,\"sys_s\":0.02,\"cpu_pct\":\"24%\",\"max_rss_kb\":3712,\
  \\"major_faults\":0,\"minor_faults\":193,\"swaps\":0,\"invol_ctx\":1,\"vol_ctx\":0,\
  \\"fs_in\":0,\"fs_out\":0,\"exit\":2}"

-- | Run one request through 'timedRunner' over a fake inner runner.
runTimed ::
  BS.ByteString ->
  ProcessRequest ->
  IO (ProcessResult, [ProcessRequest], [Event], [FilePath])
runTimed body req = do
  (inner, seen) <- fakeInner body
  ((res, left), evs) <- withRecorded $ \m -> do
    r <- timedRunner m inner req
    files <- maybe (pure []) listDirectory (mTimeDir m)
    pure (r, files)
  reqs <- seen
  pure (res, reqs, evs, left)

procSpan :: [Event] -> IO (Int, Event)
procSpan evs = case [(sid, a) | (sid, _, "proc", a) <- spanStarts evs] of
  [one] -> pure one
  other -> assertFailure ("expected one proc span, got " <> show (length other))

testTimedRewrite :: IO ()
testTimedRewrite = do
  (res, reqs, evs, _) <- runTimed validTime (execReq "sh" ["-c", "x"])
  assertEq "result unchanged" cannedResult res
  (sid, attrs) <- procSpan evs
  case reqs of
    [ProcessRequest {prMode = ExecCmd timeCmd (o : file : rest)}] -> do
      assertEq "time binary" "/usr/bin/time" timeCmd
      assertEq "-o" "-o" o
      assertTrue "file named by span id and command" ((show sid <> "-sh.json") `isSuffixOfS` file)
      assertEq
        "rest of argv"
        ["--quiet", "-f", timeFormat, "--", "sh", "-c", "x"]
        rest
    other -> assertFailure ("unexpected inner requests: " <> show other)
  assertEq "cmd attr" (Just (String "sh")) (KM.lookup "cmd" attrs)
  let end = spanEndAttrs evs sid
  assertEq "exit attr" (Just (Number 2)) (KM.lookup "exit" end)
  assertEq "stdout bytes" (Just (Number 4)) (KM.lookup "stdout_bytes" end)
  assertEq "stderr bytes" (Just (Number 2)) (KM.lookup "stderr_bytes" end)
  assertEq "fail outcome" (Just "fail") (spanEndOutcome evs sid)
  where
    isSuffixOfS suf str = reverse suf == take (length suf) (reverse str)

testTimedShell :: IO ()
testTimedShell = do
  (_, reqs, _, _) <- runTimed validTime (execReq "unused" []) {prMode = ShellCmd "echo hi"}
  case reqs of
    [ProcessRequest {prMode = ExecCmd "/usr/bin/time" args}] ->
      assertEq "shell argv" ["--", "/bin/sh", "-c", "echo hi"] (dropWhile (/= "--") args)
    other -> assertFailure ("unexpected inner requests: " <> show other)

testTimedMissingTool :: IO ()
testTimedMissingTool = do
  let req = execReq "mndz-no-such-tool-xyz" ["--flag"]
  (res, reqs, evs, _) <- runTimed validTime req
  assertEq "inner got the original request" [req] reqs
  assertEq "result unchanged" cannedResult res
  (sid, _) <- procSpan evs
  assertTrue "marked unwrapped" (KM.member "unwrapped" (spanEndAttrs evs sid))

testTimedIngest :: IO ()
testTimedIngest = do
  (_, _, evs, left) <- runTimed validTime (execReq "sh" [])
  assertEq "time dir empty" [] left
  (sid, _) <- procSpan evs
  case KM.lookup "time" (spanEndAttrs evs sid) of
    Just (Object t) -> do
      assertEq "max_rss_kb" (Just (Number 3712)) (KM.lookup "max_rss_kb" t)
      assertEq "cpu_pct string" (Just (String "24%")) (KM.lookup "cpu_pct" t)
    other -> assertFailure ("time object: " <> show other)

testTimedMalformed :: IO ()
testTimedMalformed = do
  (_, _, evs, left) <- runTimed "Command terminated by signal 9" (execReq "sh" [])
  assertEq "file kept" 1 (length left)
  (sid, _) <- procSpan evs
  let end = spanEndAttrs evs sid
  assertTrue "time_parse_error" (KM.member "time_parse_error" end)
  assertTrue "no time object" (not (KM.member "time" end))
  (_, _, evsEmpty, leftEmpty) <- runTimed "" (execReq "sh" [])
  assertEq "empty file kept" 1 (length leftEmpty)
  (sidE, _) <- procSpan evsEmpty
  assertTrue "empty parse error" (KM.member "time_parse_error" (spanEndAttrs evsEmpty sidE))

testTimedPassThrough :: IO ()
testTimedPassThrough = do
  let lifecycle = (execReq "docker" ["create", "img"]) {prMeasure = Lifecycle}
      untimed = (execReq "sh" []) {prMeasure = Untimed}
  (_, reqsL, evsL, _) <- runTimed validTime lifecycle
  assertEq "lifecycle unwrapped" [lifecycle] reqsL
  assertEq "lifecycle no proc span" [] [n | (_, _, n, _) <- spanStarts evsL]
  (_, reqsU, _, _) <- runTimed validTime untimed
  assertEq "untimed unwrapped" [untimed] reqsU
  (inner, seen) <- fakeInner validTime
  _ <- timedRunner noopMetrics inner (execReq "sh" [])
  reqsN <- seen
  assertEq "recording off: unwrapped" [execReq "sh" []] reqsN

testTimedInteractive :: IO ()
testTimedInteractive = do
  (_, reqs, evs, left) <-
    runTimed validTime (execReq "sh" ["-c", "x"]) {prMeasure = TimedInteractive}
  case reqs of
    [ProcessRequest {prMode = ExecCmd "/usr/bin/time" ("-o" : file : _)}] ->
      assertTrue "json time file" (".json" `isSuffixOf` file)
    other -> assertFailure ("unexpected inner requests: " <> show other)
  assertEq "time dir empty" [] left
  (sid, attrs) <- procSpan evs
  assertEq "interactive" (Just (Bool True)) (KM.lookup "interactive" attrs)
  assertTrue "time object" (KM.member "time" (spanEndAttrs evs sid))
  (_, _, evsPlain, _) <- runTimed validTime (execReq "sh" ["-c", "x"])
  (_, plainAttrs) <- procSpan evsPlain
  assertEq "Timed has no interactive key" Nothing (KM.lookup "interactive" plainAttrs)

testTimedInteractiveMissingTool :: IO ()
testTimedInteractiveMissingTool = do
  let req =
        (execReq "mndz-no-such-tool-xyz" [])
          { prEnv = Just [("PATH", "")],
            prMeasure = TimedInteractive
          }
  plain <- try @IOException (productionCommandRunner req)
  timed <- try @IOException $ do
    (res, _) <- withRecorded $ \m -> timedRunner m productionCommandRunner req
    pure res
  case (plain, timed) of
    (Left a, Left b) -> assertEq "same failure" (show a) (show b)
    _ -> assertFailure "expected IOException from both runners"

-- | A real GNU time wrapper around a real long-running child, interrupted the
-- way Ctrl-C reaches the program (@UserInterrupt@ in the running thread).
testTimedInterrupted :: IO ()
testTimedInterrupted = do
  let marker = "7313"
      req = (execReq "sleep" [marker]) {prMeasure = TimedInteractive}
  (r, evs) <- withRecorded $ \m -> do
    done <- newEmptyMVar
    tid <- forkIO (try @SomeException (timedRunner m productionCommandRunner req) >>= putMVar done)
    threadDelay 500000
    throwTo tid UserInterrupt
    takeMVar done
  case r of
    Left e -> assertEq "interrupt propagates" (Just UserInterrupt) (fromException e)
    Right _ -> assertFailure "expected the interrupt to propagate"
  (sid, attrs) <- procSpan evs
  assertEq "interactive" (Just (Bool True)) (KM.lookup "interactive" attrs)
  assertEq "span ends fail" (Just "fail") (spanEndOutcome evs sid)
  assertTrue "error recorded" (KM.member "error" (spanEndAttrs evs sid))
  (code, _, _) <- readProcessWithExitCode "pgrep" ["-f", "sleep " <> marker] ""
  assertEq "no child left running" (ExitFailure 1) code

testTimedMarker :: IO ()
testTimedMarker = do
  let req = (execReq "sh" []) {prEnv = Just [("KEEP", "1")]}
  (_, reqs, _, _) <- runTimed validTime req
  case reqs of
    [ProcessRequest {prEnv = Just env1}] -> do
      assertEq "original env kept" (Just "1") (lookup "KEEP" env1)
      assertTrue "marker names the time file" (maybe False (".json" `isSuffixOf`) (lookup requestMarkerVar env1))
    other -> assertFailure ("unexpected inner requests: " <> show other)
  (_, reqsInherit, _, _) <- runTimed validTime (execReq "sh" [])
  case reqsInherit of
    [ProcessRequest {prEnv = Just env1}] -> do
      assertTrue "inherited env carried over" (any ((== "PATH") . fst) env1)
      assertTrue "marker present" (any ((== requestMarkerVar) . fst) env1)
    other -> assertFailure ("unexpected inner requests: " <> show other)

-- | Reaping is for interrupted requests only: a request that completes may
-- legitimately leave a background process behind.
testTimedNoReapOnSuccess :: IO ()
testTimedNoReapOnSuccess = do
  let req = execReq "sh" ["-c", "sleep 7314 >/dev/null 2>&1 & exit 0"]
  (_, _) <- withRecorded $ \m -> timedRunner m productionCommandRunner req
  threadDelay 200000
  (code, _, _) <- readProcessWithExitCode "pgrep" ["-f", "sleep 7314"] ""
  void (readProcessWithExitCode "pkill" ["-f", "sleep 7314"] "")
  assertEq "background process still running" ExitSuccess code

testTimedRedaction :: IO ()
testTimedRedaction = do
  (inner, _) <- fakeInner validTime
  let req =
        (execReq "sh" ["-c", "git push https://x:github_pat_SECRET@github.com/o/r"])
          { prEnv = Just [("GITHUB_TOKEN", "github_pat_SECRET"), ("PATH", "/bin:/usr/bin")]
          }
  (_, evs) <- withRecorded $ \m -> do
    mAddSecret m "github_pat_SECRET"
    timedRunner m inner req
  (_, attrs) <- procSpan evs
  assertEq
    "redacted argv"
    (Just (toJSONList ["-c", "git push https://x:<redacted>@github.com/o/r"]))
    (KM.lookup "args" attrs)
  assertTrue "no env key in any event or attrs" (all noEnv evs)
  where
    toJSONList = Array . foldMap (pure . String)
    noEnv e =
      not (KM.member "env" e)
        && case field "attrs" e of
          Just (Object a) -> not (KM.member "env" a)
          _ -> True

testTimedRealBinary :: IO ()
testTimedRealBinary = do
  ((res, left), evs) <- withRecorded $ \m -> do
    r <- timedRunner m productionCommandRunner (execReq "sh" ["-c", "echo x >&2; exit 2"])
    files <- maybe (pure []) listDirectory (mTimeDir m)
    pure (r, files)
  assertEq "stderr" "x\n" (prStderr res)
  assertEq "exit 2" (ExitFailure 2) (prExitCode res)
  assertEq "time file deleted" [] left
  (sid, _) <- procSpan evs
  case KM.lookup "time" (spanEndAttrs evs sid) of
    Just (Object t) -> do
      assertTrue "wall_s numeric" (isNumber (KM.lookup "wall_s" t))
      assertTrue "max_rss_kb numeric" (isNumber (KM.lookup "max_rss_kb" t))
      assertTrue "cpu_pct string" (isString (KM.lookup "cpu_pct" t))
      assertEq "time exit" (Just (Number 2)) (KM.lookup "exit" t)
    other -> assertFailure ("time object: " <> show other)
  where
    isNumber = \case
      Just (Number _) -> True
      _ -> False
    isString = \case
      Just (String _) -> True
      _ -> False

-- | Fake inner runner for git: writes @validTime@ for GNU time wrappers and
-- succeeds with @true@ on stdout.
fakeGitInner :: ProcessRequest -> IO ProcessResult
fakeGitInner req = do
  case prMode req of
    ExecCmd "/usr/bin/time" ("-o" : file : _) -> BS.writeFile file validTime
    _ -> pure ()
  pure ProcessResult {prExitCode = ExitSuccess, prStdout = "true\n", prStderr = ""}

testGitProcSpans :: IO ()
testGitProcSpans = do
  ((inside, dirty, pushed), evs) <- withRecorded $ \m -> do
    let run = timedRunner m fakeGitInner
    i <- isGitWorkTree run "/repo"
    d <- pathsDirty run "/repo" ["README"]
    p <- gitPush run "/repo"
    pure (i, d, p)
  assertTrue "work tree" inside
  assertEq "dirty from stdout" (Right True) dirty
  assertEq "push ok" (Right ()) pushed
  let gitSpans = [(sid, a) | (sid, _, "proc", a) <- spanStarts evs, KM.lookup "cmd" a == Just (String "git")]
  assertEq "three git spans" 3 (length gitSpans)
  case gitSpans of
    [(s1, a1), _, (s3, pushAttrs)] -> do
      assertEq "rev-parse exit 0" (Just (Number 0)) (KM.lookup "exit" (spanEndAttrs evs s1))
      assertTrue "rev-parse time object" (KM.member "time" (spanEndAttrs evs s1))
      assertEq "rev-parse is not interactive" Nothing (KM.lookup "interactive" a1)
      assertEq "push is interactive" (Just (Bool True)) (KM.lookup "interactive" pushAttrs)
      assertTrue "push time object" (KM.member "time" (spanEndAttrs evs s3))
    _ -> assertFailure "unexpected git spans"

testGitArgvRedaction :: IO ()
testGitArgvRedaction = do
  (_, evs) <- withRecorded $ \m -> do
    mAddSecret m "github_pat_SECRET"
    pathsDirty (timedRunner m fakeGitInner) "/repo" ["github_pat_SECRET/file"]
  (_, attrs) <- procSpan evs
  case KM.lookup "args" attrs of
    Just (Array args) ->
      assertTrue "token redacted in git argv" (not (any (isInfixOfS "github_pat_SECRET") (mapMaybe asString (toList args))))
    other -> assertFailure ("args attr: " <> show other)
  where
    asString = \case
      String t -> Just (T.unpack t)
      _ -> Nothing
    isInfixOfS needle = T.isInfixOf (T.pack needle) . T.pack

------------------------------------------------------------------------
-- Materialize container
------------------------------------------------------------------------

dockerCfg :: Maybe FilePath -> MaterializeDockerCfg
dockerCfg timeDir =
  MaterializeDockerCfg
    { mdcImage = "example/no-time:1",
      mdcUser = "1000:1000",
      mdcRunId = sampleRunId,
      mdcCliPid = "4242",
      mdcTimeDir = timeDir
    }

unitRef :: MaterializeUnitRef
unitRef = MaterializeUnitRef {murCategory = "dev-util", murPackage = "crush", murPV = "0.77.0"}

unitDirsAt :: FilePath -> UnitDirs
unitDirsAt root =
  UnitDirs
    { udPath = root </> "unit",
      udOut = root </> "unit" </> "out",
      udWork = root </> "unit" </> "work"
    }

mountsOf :: [String] -> [String]
mountsOf = \case
  ("--mount" : v : rest) -> v : mountsOf rest
  (_ : rest) -> mountsOf rest
  [] -> []

testCreateArgsMount :: IO ()
testCreateArgsMount = do
  let dirs = unitDirsAt "/tmp/mndz/overlay-manager/run"
      timeDir = "/state/mndz/overlay-manager/metrics/run-update/time"
      on = materializeCreateArgs (dockerCfg (Just timeDir)) unitRef dirs
      off = materializeCreateArgs (dockerCfg Nothing) unitRef dirs
      bind p = "type=bind,src=" <> p <> ",dst=" <> p
  assertEq
    "recording mounts work, out, time"
    [bind (udWork dirs), bind (udOut dirs), bind timeDir]
    (mountsOf on)
  assertEq "opted out mounts work and out only" [bind (udWork dirs), bind (udOut dirs)] (mountsOf off)
  assertTrue "image then sleep infinity last" (drop (length on - 3) on == ["example/no-time:1", "sleep", "infinity"])

testExecArgsInnerWrap :: IO ()
testExecArgsInnerWrap = do
  let req = execReq "go" ["mod", "vendor"]
      inner = "/state/time/7-dev-util_crush-go.inner.json"
      wrapped = materializeExecArgs (dockerCfg (Just "/state/time")) "sess" (Just inner) req
      plain = materializeExecArgs (dockerCfg Nothing) "sess" Nothing req
  assertEq
    "inner wrap after the container name"
    ["sess", "/usr/bin/time", "-o", inner, "--quiet", "-f", timeFormat, "--", "go", "mod", "vendor"]
    (dropWhile (/= "sess") wrapped)
  assertEq "plain exec" ["sess", "go", "mod", "vendor"] (dropWhile (/= "sess") plain)

-- | Fake docker CLI for a session. @timeVersion@ is what the in-container
-- @/usr/bin/time --version@ prints. Inner GNU time files are written as if
-- the bind mount carried them to the host.
fakeDocker :: String -> IO (ProcessRequest -> IO ProcessResult, IO [ProcessRequest])
fakeDocker timeVersion = do
  seen <- newIORef []
  let ok out = pure ProcessResult {prExitCode = ExitSuccess, prStdout = out, prStderr = ""}
      run req = do
        atomicModifyIORef' seen (\xs -> (xs <> [req], ()))
        case prMode req of
          ExecCmd "docker" ("inspect" : "--format" : "{{.State.Running}}" : _) -> ok "true\n"
          ExecCmd "docker" ("inspect" : "--format" : "{{.State.Pid}}" : _) -> ok "1234\n"
          ExecCmd "docker" ("exec" : _ : "/usr/bin/time" : "--version" : _) -> ok timeVersion
          ExecCmd "docker" args
            | Just file <- innerFile args -> do
                BS.writeFile file validTime
                ok "go: vendored\n"
          _ -> ok ""
      innerFile args = case dropWhile (/= "/usr/bin/time") args of
        (_ : "-o" : file : _) -> Just file
        _ -> Nothing
  pure (run, readIORef seen)

-- | Fixture @/proc@ and @/sys/fs/cgroup@ for container pid 1234.
withCgroupFixture :: (CgroupRoots -> IO a) -> IO a
withCgroupFixture act =
  withSystemTempDirectory "mndz-cgroup-" $ \tmp -> do
    let roots = CgroupRoots {crProc = tmp </> "proc", crSys = tmp </> "sys"}
        cgDir = crSys roots </> "system.slice" </> "docker-abc.scope"
    createDirectoryIfMissing True (crProc roots </> "1234")
    createDirectoryIfMissing True cgDir
    BS.writeFile (crProc roots </> "1234" </> "cgroup") "0::/system.slice/docker-abc.scope\n"
    BS.writeFile (cgDir </> "cpu.stat") "usage_usec 1500\nuser_usec 1000\nsystem_usec 500\nnr_periods 0\n"
    BS.writeFile (cgDir </> "memory.peak") "4194304\n"
    act roots

testSessionRecorded :: IO ()
testSessionRecorded =
  withCgroupFixture $ \roots ->
    withSystemTempDirectory "mndz-session-" $ \tmp -> do
      (run, seen) <- fakeDocker "time (GNU Time) 1.9\n"
      ((result, timeLeft), evs) <- withRecorded $ \m -> do
        let cfg = dockerCfg (mTimeDir m)
        r <-
          withUnitMaterializeSession m roots run cfg unitRef (unitDirsAt tmp) $ \runner ->
            Right <$> runner (execReq "go" ["mod", "vendor"])
        left <- maybe (pure []) listDirectory (mTimeDir m)
        pure (r, left)
      case result of
        Right res -> assertEq "exec ok" ExitSuccess (prExitCode res)
        Left err -> assertFailure (T.unpack err)
      assertEq "inner time file ingested" [] timeLeft
      reqs <- seen
      let measureOf verb = [prMeasure r | r@ProcessRequest {prMode = ExecCmd "docker" (v : _)} <- reqs, v == verb]
      assertEq "create is lifecycle" [Lifecycle] (measureOf "create")
      assertTrue "exec of the unit command is the outer half" (TimedContainerExec `elem` measureOf "exec")
      let starts = spanStarts evs
      parent <- firstId "container.exec" evs
      sessionId <- firstId "container.session" evs
      assertEq "exec under session" [Just sessionId] [p | (_, p, "container.exec", _) <- starts]
      case [(sid, a) | (sid, Just p, "proc", a) <- starts, p == parent] of
        [(innerSid, attrs)] -> do
          assertEq "inner names container" (Just (String "mndz-mat-20261111T101500-0700-4242.a8f3-dev-util-crush-0.77.0")) (KM.lookup "container" attrs)
          assertTrue "inner has time" (KM.member "time" (spanEndAttrs evs innerSid))
        other -> assertFailure ("expected the inner proc under container.exec, got " <> show (length other))
      case filter ((== "container") . evKind) evs of
        [e] -> do
          assertEq "cpu usage" (Just (Number 1500)) (field "cpu_usage_usec" e)
          assertEq "memory peak" (Just (Number 4194304)) (field "memory_peak_bytes" e)
        other -> assertFailure ("expected one container event, got " <> show (length other))

testSessionNoGnuTime :: IO ()
testSessionNoGnuTime =
  withCgroupFixture $ \roots ->
    withSystemTempDirectory "mndz-session-" $ \tmp -> do
      (run, seen) <- fakeDocker "BusyBox v1.36.1 multi-call binary.\n"
      called <- newIORef False
      (result, _) <- withRecorded $ \m ->
        withUnitMaterializeSession m roots run (dockerCfg (mTimeDir m)) unitRef (unitDirsAt tmp) $ \_ -> do
          atomicModifyIORef' called (const (True, ()))
          pure (Right ())
      case result of
        Left err -> do
          assertTrue "names the image" ("example/no-time:1" `T.isInfixOf` err)
          assertTrue "names --no-metrics" ("--no-metrics" `T.isInfixOf` err)
        Right () -> assertFailure "expected a hard-fail"
      ran <- readIORef called
      assertTrue "unit work did not run" (not ran)
      reqs <- seen
      assertTrue "no docker build" (null [() | ProcessRequest {prMode = ExecCmd "docker" ("build" : _)} <- reqs])
      assertTrue "container removed" (not (null [() | ProcessRequest {prMode = ExecCmd "docker" ("rm" : _)} <- reqs]))

testSessionNoMetricsSkipsCheck :: IO ()
testSessionNoMetricsSkipsCheck =
  withSystemTempDirectory "mndz-session-" $ \tmp -> do
    (run, seen) <- fakeDocker "BusyBox v1.36.1 multi-call binary.\n"
    result <-
      withUnitMaterializeSession noopMetrics (CgroupRoots "/nonexistent" "/nonexistent") run (dockerCfg Nothing) unitRef (unitDirsAt tmp) $ \runner ->
        Right <$> runner (execReq "go" ["version"])
    case result of
      Right res -> assertEq "exec ok" ExitSuccess (prExitCode res)
      Left err -> assertFailure (T.unpack err)
    reqs <- seen
    assertTrue
      "no in-container time check"
      (null [() | ProcessRequest {prMode = ExecCmd "docker" ("exec" : _ : "/usr/bin/time" : _)} <- reqs])
    assertTrue
      "no pid inspect"
      (null [() | ProcessRequest {prMode = ExecCmd "docker" (_ : _ : "{{.State.Pid}}" : _)} <- reqs])

testCgroupSnapshot :: IO ()
testCgroupSnapshot =
  withCgroupFixture $ \roots -> do
    cg <- cgroupOfPid roots 1234
    assertEq "cgroup path" (Right "/system.slice/docker-abc.scope") cg
    attrs <- cgroupSnapshot roots "/system.slice/docker-abc.scope"
    let get k = lookup (Key.fromText k) attrs
    assertEq "usage" (Just (Number 1500)) (get "cpu_usage_usec")
    assertEq "user" (Just (Number 1000)) (get "cpu_user_usec")
    assertEq "system" (Just (Number 500)) (get "cpu_system_usec")
    assertEq "peak" (Just (Number 4194304)) (get "memory_peak_bytes")
    assertEq "no error" Nothing (get "error")

testCgroupMissing :: IO ()
testCgroupMissing =
  withCgroupFixture $ \roots -> do
    missingPid <- cgroupOfPid roots 99
    assertTrue "missing pid is Left" (either (const True) (const False) missingPid)
    removeFile (crSys roots </> "system.slice" </> "docker-abc.scope" </> "memory.peak")
    attrs <- cgroupSnapshot roots "/system.slice/docker-abc.scope"
    case lookup (Key.fromText "error") attrs of
      Just (String reason) -> assertTrue "names memory.peak" ("memory.peak" `T.isInfixOf` reason)
      other -> assertFailure ("expected error reason, got " <> show other)

------------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------------

testRouteTemplate :: IO ()
testRouteTemplate = do
  assertEq "latest" "/repos/{owner}/{repo}/releases/latest" (githubRouteTemplate "/repos/o/r/releases/latest")
  assertEq "by tag" "/repos/{owner}/{repo}/releases/tags/{tag}" (githubRouteTemplate "/repos/o/r/releases/tags/v1.2.3")
  assertEq "release assets" "/repos/{owner}/{repo}/releases/{id}/assets" (githubRouteTemplate "/repos/o/r/releases/123/assets")
  assertEq "asset" "/repos/{owner}/{repo}/releases/assets/{asset_id}" (githubRouteTemplate "/repos/o/r/releases/assets/99")
  assertEq "tags list" "/repos/{owner}/{repo}/tags" (githubRouteTemplate "/repos/o/r/tags")
  assertEq "contents" "/repos/{owner}/{repo}/contents/{path}" (githubRouteTemplate "/repos/o/r/contents/a/b/go.mod")
  assertEq "rate limit" "/rate_limit" (githubRouteTemplate "/rate_limit")

-- | Manager settings whose connections replay one canned HTTP response.
cannedSettings :: BS.ByteString -> ManagerSettings
cannedSettings response =
  defaultManagerSettings
    { managerRawConnection = pure $ \_ _ _ -> do
        sent <- newIORef False
        makeConnection
          (atomicModifyIORef' sent (\done -> (True, if done then "" else response)))
          (\_ -> pure ())
          (pure ())
    }

testHttpManagerSpan :: IO ()
testHttpManagerSpan = do
  let response =
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nx-ratelimit-remaining: 4999\r\n\r\nhello"
  (body, evs) <- withRecorded $ \m -> do
    mgr <- newManager (instrumentManagerSettings m (cannedSettings response))
    req0 <- parseRequest "http://api.github.com/repos/o/r/releases/latest?per_page=1"
    let req = req0 {requestHeaders = [("Authorization", "Bearer github_pat_SECRET")]}
    res <- httpLbs req mgr
    pure (show res)
  assertTrue "body read" ("hello" `T.isInfixOf` T.pack body)
  case [(sid, a) | (sid, _, "http", a) <- spanStarts evs] of
    [(sid, attrs)] -> do
      assertEq "method" (Just (String "GET")) (KM.lookup "method" attrs)
      assertEq "host" (Just (String "api.github.com")) (KM.lookup "host" attrs)
      assertEq "path template" (Just (String "/repos/{owner}/{repo}/releases/latest")) (KM.lookup "path" attrs)
      let end = spanEndAttrs evs sid
      assertEq "status" (Just (Number 200)) (KM.lookup "status" end)
      assertEq "body bytes" (Just (Number 5)) (KM.lookup "body_bytes" end)
      assertEq "ok" (Just "ok") (spanEndOutcome evs sid)
    other -> assertFailure ("expected one http span, got " <> show (length other))
  let encoded = T.pack (show evs)
  assertTrue "no token" (not ("SECRET" `T.isInfixOf` encoded))
  assertTrue "no Authorization" (not ("Authorization" `T.isInfixOf` encoded))
  assertTrue "no query" (not ("per_page" `T.isInfixOf` encoded))
  footer <- footerOf evs
  case field "counters" footer of
    Just (Object cs) -> do
      assertEq "api calls" (Just (Number 1)) (KM.lookup "github.api_calls" cs)
      assertEq "rate limit" (Just (Number 4999)) (KM.lookup "github.rate_limit_remaining" cs)
    other -> assertFailure ("counters: " <> show other)

testHttpManagerFailure :: IO ()
testHttpManagerFailure = do
  (r, evs) <- withRecorded $ \m -> do
    mgr <- newManager (instrumentManagerSettings m (cannedSettings "garbage"))
    req <- parseRequest "http://registry.npmjs.org/left-pad"
    try @SomeException (httpLbs req mgr)
  assertTrue "request failed" (either (const True) (const False) r)
  case [sid | (sid, _, "http", _) <- spanStarts evs] of
    [sid] -> assertEq "fail" (Just "fail") (spanEndOutcome evs sid)
    other -> assertFailure ("expected one http span, got " <> show (length other))

------------------------------------------------------------------------
-- Counters
------------------------------------------------------------------------

testCacheCounters :: IO ()
testCacheCounters =
  withSystemTempDirectory "mndz-metrics-cache-" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "check-cache"
        pkgDir = overlay </> "dev-lang" </> "deno-bin"
        ebuild = pkgDir </> "deno-bin-0.1.0.ebuild"
        e =
          PackageEntry
            { peKey = mkPackageKey "dev-lang" "deno-bin",
              pePN = "deno-bin",
              peLocal = parseEbuildVersion "0.1.0",
              pePath = ebuild
            }
        fetch _ = pure (Right (parseEbuildVersion "0.2.0"))
        outdatedRun = withRecorded $ \m -> do
          now <- getCurrentTime
          (cache, _) <- openCheckCacheAt (pure now) (Just cacheDir) (CacheTtl (5 * 60)) False overlay
          _ <- checkPackage fetch cache e []
          flushCheckCache cache
          recordCacheCounters m cache
        counters evs = do
          footer <- footerOf evs
          case field "counters" footer of
            Just (Object cs) -> pure cs
            other -> assertFailure ("counters: " <> show other)
    createDirectoryIfMissing True pkgDir
    BS.writeFile ebuild "EAPI=8\nKEYWORDS=\"~amd64\"\n"
    (_, coldEvs) <- outdatedRun
    cold <- counters coldEvs
    assertEq "cold misses" (Just (Number 1)) (KM.lookup "check_cache.misses" cold)
    assertEq "cold hits" (Just (Number 0)) (KM.lookup "check_cache.hits" cold)
    (_, warmEvs) <- outdatedRun
    warm <- counters warmEvs
    assertEq "warm hits" (Just (Number 1)) (KM.lookup "check_cache.hits" warm)
    assertEq "warm misses" (Just (Number 0)) (KM.lookup "check_cache.misses" warm)

------------------------------------------------------------------------
-- Sampler
------------------------------------------------------------------------

pidStatLine :: Int -> String -> Int -> Integer -> String
pidStatLine pid comm ppid ticks =
  show pid
    <> " ("
    <> comm
    <> ") S "
    <> show ppid
    <> " 1 1 0 -1 4194304 100 0 0 0 "
    <> show ticks
    <> " 0 0 0 20 0 1 0 1000 6316032 256 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 5 0 0 0 0 0"

-- | Fixture @/proc@: system files plus the given pids (pid, comm, ppid,
-- ticks, cgroup path).
writeProcFixture :: FilePath -> Bool -> [(Int, String, Int, Integer, String)] -> IO ()
writeProcFixture root withPressure procs = do
  createDirectoryIfMissing True root
  writeFile (root </> "stat") "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 100 0 50 800 50 0 0 0 0 0\n"
  writeFile (root </> "loadavg") "1.50 1.25 1.00 3/512 4242\n"
  writeFile
    (root </> "meminfo")
    "MemTotal:       16000 kB\nMemFree:  1000 kB\nMemAvailable:   12000 kB\nSwapTotal:  8000 kB\nSwapFree:  6000 kB\n"
  writeFile
    (root </> "diskstats")
    " 259 0 nvme0n1 10 0 200 0 5 0 100 0 0 0 0 0 0 0 0 0 0\n 259 1 nvme0n1p1 10 0 200 0 5 0 100 0 0 0 0 0 0 0 0 0 0\n   7 0 loop0 1 0 999 0 0 0 999 0 0 0 0 0 0 0 0 0 0\n"
  when withPressure $ do
    createDirectoryIfMissing True (root </> "pressure")
    mapM_
      (\k -> writeFile (root </> "pressure" </> k) "some avg10=1.50 avg60=2.00 avg300=3.00 total=1\nfull avg10=0.50 avg60=1.00 avg300=1.50 total=1\n")
      ["cpu", "memory", "io"]
  mapM_
    ( \(pid, comm, ppid, ticks, cg) -> do
        createDirectoryIfMissing True (root </> show pid)
        writeFile (root </> show pid </> "stat") (pidStatLine pid comm ppid ticks)
        writeFile (root </> show pid </> "cgroup") ("0::" <> cg <> "\n")
        writeFile (root </> show pid </> "cmdline") "secret-arg\0"
    )
    procs

fixtureCfg :: FilePath -> SamplerConfig
fixtureCfg root =
  SamplerConfig
    { scProcRoot = root,
      scWait = threadDelay 60_000_000,
      scSelfPid = pure 100,
      scClockTicks = 100,
      scPageSize = 4096
    }

testProcParsers :: IO ()
testProcParsers = do
  let a = CpuTimes 100 0 50 800 50 0 0 0
      b = CpuTimes 200 0 100 1600 100 0 0 0
  assertEq "cpu" (Just a) (parseCpuTimes "cpu  100 0 50 800 50 0 0 0 0 0\n")
  assertEq "user pct" (Just (Number 10)) (lookup (Key.fromText "user") (cpuPercents a b))
  assertEq "idle pct" (Just (Number 80)) (lookup (Key.fromText "idle") (cpuPercents a b))
  case parseLoadAvg "1.50 1.25 1.00 3/512 4242\n" of
    Just kvs -> do
      assertEq "load1" (Just (Number 1.5)) (lookup (Key.fromText "load1") kvs)
      assertEq "running" (Just (Number 3)) (lookup (Key.fromText "running") kvs)
      assertEq "total" (Just (Number 512)) (lookup (Key.fromText "total") kvs)
    Nothing -> assertFailure "loadavg"
  let mem = parseMemInfo "MemTotal: 16000 kB\nMemAvailable: 12000 kB\nSwapTotal: 8000 kB\nSwapFree: 6000 kB\n"
  assertEq "used" (Just (Number 4000)) (lookup (Key.fromText "used_kb") mem)
  assertEq "swap used" (Just (Number 2000)) (lookup (Key.fromText "swap_used_kb") mem)
  let psi = parsePressure "some avg10=1.50 avg60=2.00 avg300=3.00 total=1\nfull avg10=0.50 avg60=1.00 avg300=1.50 total=1\n"
  assertEq "psi kinds" ["some", "full"] (map (Key.toText . fst) psi)
  assertEq
    "whole disks only (no partition, no loop)"
    DiskTotals {dtReadBytes = 200 * 512, dtWriteBytes = 100 * 512}
    ( parseDiskStats " 259 0 nvme0n1 10 0 200 0 5 0 100 0\n 259 1 nvme0n1p1 10 0 200 0 5 0 100 0\n 8 0 sda 1 0 4 0 1 0 8 0\n 8 1 sda1 1 0 4 0 1 0 8 0\n 7 0 loop0 1 0 999 0 0 0 999 0\n"
        `plusDisk` DiskTotals 0 0
        `minusDisk` DiskTotals (4 * 512) (8 * 512)
    )
  case parsePidStat (T.pack (pidStatLine 77 "tmux: server (x)" 1 42)) of
    Just ps -> do
      assertEq "comm with spaces and parens" "tmux: server (x)" (psComm ps)
      assertEq "ppid" 1 (psPpid ps)
      assertEq "ticks" 42 (psTicks ps)
      assertEq "rss pages" 256 (psRssPages ps)
    Nothing -> assertFailure "pid stat"
  where
    plusDisk (DiskTotals r w) (DiskTotals r2 w2) = DiskTotals (r + r2) (w + w2)
    minusDisk (DiskTotals r w) (DiskTotals r2 w2) = DiskTotals (r - r2) (w - w2)

testSampleFixture :: IO ()
testSampleFixture =
  withSystemTempDirectory "mndz-proc-" $ \tmp -> do
    let withPsi = tmp </> "a"
        noPsi = tmp </> "b"
        self = [(100, "mndz-overlay-ma", 1, 10, "/user.slice")]
    writeProcFixture withPsi True self
    writeProcFixture noPsi False self
    st <- initialSampleState
    (attrs, _) <- takeSample (fixtureCfg withPsi) [] st
    let keys = map (Key.toText . fst) attrs
    assertTrue ("psi present: " <> show keys) ("psi" `elem` keys)
    case lookup (Key.fromText "psi") attrs of
      Just (Object o) -> assertTrue "io pressure" (KM.member "io" o)
      other -> assertFailure ("psi: " <> show other)
    assertTrue "load present" ("load" `elem` keys)
    assertTrue "mem present" ("mem" `elem` keys)
    assertTrue "disk present" ("disk" `elem` keys)
    (attrs2, _) <- takeSample (fixtureCfg noPsi) [] st
    assertTrue "no psi without /proc/pressure" ("psi" `notElem` map (Key.toText . fst) attrs2)

testProcessSelection :: IO ()
testProcessSelection = do
  let cg = "/system.slice/docker-abc.scope"
      ps pid comm ppid ticks = PidStat {psPid = pid, psComm = comm, psState = "S", psPpid = ppid, psTicks = ticks, psRssPages = 256}
      ours =
        [ ps 100 "mndz-overlay-ma" 1 10,
          ps 101 "time" 100 1,
          ps 102 "docker" 101 1,
          ps 200 "sleep" 50 0,
          ps 201 "go" 200 5
        ]
      foreign_ = [ps (300 + i) ("busy" <> T.pack (show i)) 1 (fromIntegral (i * 100)) | i <- [0 .. 11]]
      prev = Map.fromList [(psPid p, 0) | p <- ours <> foreign_]
      selected = selectProcesses (fixtureCfg "/nonexistent") 100 (Set.fromList [200, 201]) (Just prev) 5 (ours <> foreign_)
      objs = [o | Object o <- selected]
      oursPids = [n | o <- objs, KM.lookup "ours" o == Just (Bool True), Just (Number n) <- [KM.lookup "pid" o]]
      others = [o | o <- objs, KM.lookup "ours" o == Just (Bool False)]
  assertEq "our tree and container processes" [100, 101, 102, 200, 201] oursPids
  assertEq "ten others" 10 (length others)
  assertTrue
    "busiest others kept"
    (all (maybe False aboveFloor . KM.lookup "pid") others)
  assertTrue "no cmdline" (not (any (KM.member "cmdline") objs))
  assertTrue "comm only" (all (KM.member "comm") objs)
  -- Container membership comes from /proc/<pid>/cgroup through the sampler.
  withSystemTempDirectory "mndz-proc-sel-" $ \tmp -> do
    writeProcFixture tmp False [(100, "mndz", 1, 0, "/user.slice"), (200, "sleep", 50, 0, cg), (201, "go", 200, 0, cg <> "/sub"), (300, "other", 1, 0, "/user.slice")]
    st <- initialSampleState
    (attrs, _) <- takeSample (fixtureCfg tmp) [T.pack cg] st
    case lookup (Key.fromText "procs") attrs of
      Just (Array arr) -> do
        let oursFromProc = [n | Object o <- foldr (:) [] arr, KM.lookup "ours" o == Just (Bool True), Just (Number n) <- [KM.lookup "pid" o]]
        assertEq "cgroup members are ours" [100, 200, 201] oursFromProc
      other -> assertFailure ("procs: " <> show other)

aboveFloor :: Value -> Bool
aboveFloor = \case
  Number n -> n >= 302
  _ -> False

testSamplerStartEnd :: IO ()
testSamplerStartEnd =
  withSystemTempDirectory "mndz-sampler-" $ \tmp -> do
    let root = tmp </> "proc"
    writeProcFixture root True [(100, "mndz", 1, 0, "/user.slice")]
    never <- newEmptyMVar
    h <- openBinaryFile (tmp </> "run.jsonl") WriteMode
    w <- newWriter (\_ -> pure ()) (handleSink h)
    rec <- openRecorder w (tmp </> "time")
    join (startSampler (fixtureCfg root) {scWait = readMVar never} rec)
    finishRecorder rec (Right ())
    evs <- readEvents (tmp </> "run.jsonl")
    assertEq "start and end samples" 2 (length (filter ((== "sample") . evKind) evs))
    assertEq "footer after samples" "run_end" (evKind (last evs))

testLifecycleDetached :: IO ()
testLifecycleDetached = do
  (_, evs) <- withRecorded $ \m ->
    withSpan m "command" [] $ do
      close <- openLifecycleSpan m "gpg-session-supervisor"
      withSpan m "work" [] (pure ())
      close OutcomeOk
  cmdId <- firstId "command" evs
  life <- firstId "lifecycle" evs
  assertEq "lifecycle under command" [Just cmdId] [p | (_, p, "lifecycle", _) <- spanStarts evs]
  assertEq "work not under lifecycle" [Just cmdId] [p | (_, p, "work", _) <- spanStarts evs]
  assertEq "closed" (Just "ok") (spanEndOutcome evs life)
