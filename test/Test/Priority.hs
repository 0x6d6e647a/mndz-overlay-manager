{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Process priority: request validation and merging, resolution with the
-- floor, the thread sweep over fake operations, and the container prelude.
module Test.Priority (takePriorityProbe, tests) where

import CLI.Parser (Options (..), parseOptionsPure, parserInfo)
import CLI.Parser qualified as CLI
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, finally, try)
import Control.Monad (forM, void, when)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Metrics.Core (Metrics (..), noopMetrics)
import Options.Applicative (ParseError (ShowHelpText), ParserResult (..), defaultPrefs, parserFailure, renderFailure)
import Process.Priority
  ( EffectivePriority (..),
    InheritedPriority (..),
    IoClass (..),
    IoPriority (..),
    IoRequest (..),
    PriorityRequest (..),
    Resolved (..),
    SettingSource (..),
    checkIoLevel,
    checkNice,
    mergePriority,
    noPriorityRequest,
    parseIoClass,
    priorityPrelude,
    priorityRequest,
    priorityToolCheck,
    priorityToolsNeeded,
    priorityWrap,
    resolvePriority,
  )
import Process.Priority.Apply
  ( OpError (..),
    SweepTarget (..),
    ThreadOps (..),
    applyCommandPriority,
    decodeIoprio,
    encodeIoprio,
    productionThreadOps,
    readInherited,
    sweepThreads,
  )
import System.Directory (listDirectory, removeFile)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (..), hClose, hFlush, hGetLine, hSetBuffering, stdout)
import System.IO.Temp (emptySystemTempFile, withSystemTempDirectory)
import System.Posix.Process (getProcessID)
import System.Process (CreateProcess (..), Pid, StdStream (..), callProcess, createProcess, getPid, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Text.Read (readMaybe)

tests :: TestTree
tests =
  testGroup
    "Priority"
    [ testGroup
        "Model"
        [ testCase "Targets are absolute" testAbsoluteTargets,
          testCase "Nice floor keeps the inherited value" testNiceFloor,
          testCase "I/O floor keeps the inherited class" testIoFloor,
          testCase "Inherited none ranks by the inherited nice" testNoneRanksByNice,
          testCase "A level alone means best-effort" testLevelImpliesBestEffort,
          testCase "Best-effort without a level derives it from nice" testBestEffortDerived,
          testCase "Idle with a level is rejected" testIdleWithLevel,
          testCase "Out-of-range values are rejected" testOutOfRange,
          testCase "Unknown I/O classes are rejected" testUnknownClass,
          testCase "Command-line I/O replaces config I/O as a unit" testMergeIoUnit,
          testCase "Unset settings keep the inherited priority" testUnset
        ],
      testGroup
        "Options"
        [ testCase "Valid priority options" testOptionsValid,
          testCase "Out-of-range and negative values are usage errors" testOptionsOutOfRange,
          testCase "Realtime is not offered" testOptionsRealtime,
          testCase "Idle with a level is a usage error" testOptionsIdleWithLevel,
          testCase "Help documents the priority options" testHelpPriority
        ],
      testGroup
        "Sweep"
        [ testCase "One pass when nothing changes" testSweepNoChange,
          testCase "A thread added mid-pass needs another pass" testSweepAddedThread,
          testCase "A vanished thread is skipped" testSweepVanished,
          testCase "The floor leaves lower priorities alone" testSweepFloor,
          testCase "Other set failures are errors" testSweepFailure,
          testCase "ioprio values round-trip" testIoprioCodec,
          testCase "Production ops read the current thread" testProductionRead
        ],
      testGroup
        "Apply"
        [ testCase "Floor warnings name both values, once each" testApplyWarnings,
          testCase "Priority event without a floor" testApplyEvent,
          testCase "Priority event with a floor" testApplyEventFloor,
          testCase "Unset priority event" testApplyEventUnset,
          testCase "Apply failure is an error" testApplyFailure,
          testCase "Every thread and a spawned child run at the priority" testChildProcessPriority
        ],
      testGroup
        "Prelude"
        [ testCase "Default priority leaves argv unchanged" testWrapDefault,
          testCase "Wrapped argv execs the command" testWrapShape,
          testCase "Tools needed and their check" testToolsNeeded,
          testCase "Raises nice and I/O priority in one process" testPreludeRaise,
          testCase "Nice floor keeps the current value with one line" testPreludeNiceFloor,
          testCase "I/O class and level parsing" testPreludeIoParsing
        ]
    ]

inherited :: Int -> IoPriority -> InheritedPriority
inherited = InheritedPriority

req :: Maybe Int -> Maybe IoRequest -> PriorityRequest
req = PriorityRequest

testAbsoluteTargets :: IO ()
testAbsoluteTargets = do
  let r = resolvePriority (req (Just 10) (Just IoIdleReq)) (inherited 5 IoNone)
  assertEq "nice 10, not 15" (EffectivePriority 10 IoIdle) (rsEffective r)
  assertEq "no floor" (False, False) (rsNiceFloor r, rsIoFloor r)
  assertEq "idle is set" (Just IoIdle) (rsIoTarget r)

testNiceFloor :: IO ()
testNiceFloor = do
  let r = resolvePriority (req (Just 10) Nothing) (inherited 15 IoNone)
  assertEq "keeps 15" 15 (epNice (rsEffective r))
  assertTrue "nice floor" (rsNiceFloor r)
  let zero = resolvePriority (req (Just 0) Nothing) (inherited 7 IoNone)
  assertEq "--nice 0 leaves 7" 7 (epNice (rsEffective zero))

testIoFloor :: IO ()
testIoFloor = do
  let r = resolvePriority (req Nothing (Just (IoBestEffortReq (Just 4)))) (inherited 0 IoIdle)
  assertEq "stays idle" IoIdle (epIo (rsEffective r))
  assertTrue "I/O floor" (rsIoFloor r)
  assertEq "nothing set" Nothing (rsIoTarget r)
  let be = resolvePriority (req Nothing (Just (IoBestEffortReq (Just 2)))) (inherited 0 (IoBestEffort 6))
  assertEq "keeps best-effort 6" (IoBestEffort 6) (epIo (rsEffective be))
  assertTrue "floor over best-effort" (rsIoFloor be)

testNoneRanksByNice :: IO ()
testNoneRanksByNice = do
  -- Inherited nice 19 and no class: best-effort 7, so level 4 is a raise.
  let r = resolvePriority (req (Just 0) (Just (IoBestEffortReq (Just 4)))) (inherited 19 IoNone)
  assertEq "kept none" IoNone (epIo (rsEffective r))
  assertTrue "I/O floor" (rsIoFloor r)
  -- The target nice does not lower the inherited rank.
  let raised = resolvePriority (req (Just 19) (Just (IoBestEffortReq (Just 4)))) (inherited 0 IoNone)
  assertEq "best-effort 4 applies" (IoBestEffort 4) (epIo (rsEffective raised))
  assertTrue "no floor" (not (rsIoFloor raised))

testLevelImpliesBestEffort :: IO ()
testLevelImpliesBestEffort = do
  r <- assertRight "level alone" (priorityRequest FromCommandLine Nothing Nothing (Just 7))
  assertEq "best-effort 7" (Just (IoBestEffortReq (Just 7))) (reqIo r)
  assertEq "applies" (IoBestEffort 7) (epIo (rsEffective (resolvePriority r (inherited 0 IoNone))))

testBestEffortDerived :: IO ()
testBestEffortDerived = do
  r <- assertRight "class alone" (priorityRequest FromConfig (Just 10) (Just ClassBestEffort) Nothing)
  assertEq "best-effort from nice 10" (IoBestEffort 6) (epIo (rsEffective (resolvePriority r (inherited 0 IoNone))))

testIdleWithLevel :: IO ()
testIdleWithLevel = do
  cli <- assertLeft "cli" (priorityRequest FromCommandLine Nothing (Just ClassIdle) (Just 3))
  assertEq "cli message" "--ionice-class idle takes no --ionice-level" cli
  cfg <- assertLeft "config" (priorityRequest FromConfig Nothing (Just ClassIdle) (Just 3))
  assertEq "config message" "ionice-class idle takes no ionice-level" cfg

testOutOfRange :: IO ()
testOutOfRange = do
  high <- assertLeft "nice 25" (checkNice FromCommandLine 25)
  assertEq "names --nice" "--nice must be between 0 and 19 (got 25)" high
  neg <- assertLeft "nice -5" (checkNice FromConfig (-5))
  assertTrue "names nice" ("nice must be between 0 and 19" `isInfixOf` neg)
  lvl <- assertLeft "level 8" (checkIoLevel FromConfig 8)
  assertTrue "names ionice-level" ("ionice-level must be between 0 and 7" `isInfixOf` lvl)
  assertEq "bounds accepted" (Right 19, Right 0, Right 7) (checkNice FromConfig 19, checkNice FromConfig 0, checkIoLevel FromConfig 7)

testUnknownClass :: IO ()
testUnknownClass = do
  e <- assertLeft "realtime" (parseIoClass FromCommandLine "realtime")
  assertTrue "names --ionice-class" ("--ionice-class must be idle or best-effort" `isInfixOf` e)
  assertEq "known classes" (Right ClassIdle, Right ClassBestEffort) (parseIoClass FromConfig "idle", parseIoClass FromConfig "best-effort")

testMergeIoUnit :: IO ()
testMergeIoUnit = do
  let config = req (Just 10) (Just IoIdleReq)
      merged = mergePriority (req Nothing (Just (IoBestEffortReq (Just 4)))) config
  assertEq "cli I/O replaces config I/O, config nice kept" (req (Just 10) (Just (IoBestEffortReq (Just 4)))) merged
  assertEq "cli nice replaces config nice" (req (Just 15) (Just IoIdleReq)) (mergePriority (req (Just 15) Nothing) config)
  assertEq "empty cli keeps config" config (mergePriority noPriorityRequest config)

testUnset :: IO ()
testUnset = do
  let r = resolvePriority noPriorityRequest (inherited 7 (IoBestEffort 3))
  assertEq "inherited kept" (EffectivePriority 7 (IoBestEffort 3)) (rsEffective r)
  assertEq "no floors" (False, False) (rsNiceFloor r, rsIoFloor r)
  assertEq "nothing set" Nothing (rsIoTarget r)

-- | Parse result: the request, or the rendered usage error and exit code.
parseArgs :: [String] -> Either (String, ExitCode) (Options, PriorityRequest)
parseArgs args = case parseOptionsPure args of
  Success r -> Right r
  Failure f -> Left (renderFailure f "mndz-overlay-manager")
  CompletionInvoked _ -> Left ("completion", ExitFailure 99)

usageError :: [String] -> IO String
usageError args = do
  (msg, code) <- assertLeft (unwords args) (parseArgs args)
  assertEq (unwords args <> " exit") (ExitFailure 1) code
  pure msg

testOptionsValid :: IO ()
testOptionsValid = do
  (opts, r) <- assertRight "valid" (parseArgs ["--nice", "10", "--ionice-class", "idle", "update"])
  assertEq "request" (req (Just 10) (Just IoIdleReq)) r
  assertEq "command" (Just "update") (cmdName <$> optCommand opts)
  (_, lvl) <- assertRight "level alone" (parseArgs ["--ionice-level", "7", "update"])
  assertEq "best-effort 7" (req Nothing (Just (IoBestEffortReq (Just 7)))) lvl
  (_, be) <- assertRight "class alone" (parseArgs ["--ionice-class", "best-effort", "smoke"])
  assertEq "best-effort derived" (req Nothing (Just (IoBestEffortReq Nothing))) be
  (_, none) <- assertRight "no options" (parseArgs ["update"])
  assertEq "unset" noPriorityRequest none
  where
    cmdName = \case
      CLI.Update {} -> "update" :: String
      _ -> "other"

testOptionsOutOfRange :: IO ()
testOptionsOutOfRange = do
  high <- usageError ["--nice", "25", "update"]
  assertTrue "names --nice range" ("--nice must be between 0 and 19" `isInfixOf` high)
  _ <- usageError ["--nice", "-5", "update"]
  lvl <- usageError ["--ionice-level", "8", "update"]
  assertTrue "names --ionice-level range" ("--ionice-level must be between 0 and 7" `isInfixOf` lvl)
  _ <- usageError ["--nice", "ten", "update"]
  pure ()

testOptionsRealtime :: IO ()
testOptionsRealtime = do
  msg <- usageError ["--ionice-class", "realtime", "update"]
  assertTrue "names the class option" ("--ionice-class must be idle or best-effort" `isInfixOf` msg)

testOptionsIdleWithLevel :: IO ()
testOptionsIdleWithLevel = do
  msg <- usageError ["--ionice-class", "idle", "--ionice-level", "3", "update"]
  assertTrue "idle takes no level" ("idle takes no --ionice-level" `isInfixOf` msg)

testHelpPriority :: IO ()
testHelpPriority = do
  let (msg, _) = renderFailure (parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty) "mndz-overlay-manager"
      flat = unwords (words msg)
  mapM_
    (\needle -> assertTrue ("help mentions " <> needle) (needle `isInfixOf` flat))
    ["--nice", "--ionice-class", "--ionice-level", "absolute", "never raises", "Container workloads", "I/O scheduler"]

------------------------------------------------------------------------
-- Fake thread operations

type Threads = IORef (Map.Map Int (Int, IoPriority))

data Fake = Fake
  { fThreads :: Threads,
    -- | Called after a successful nice set on a thread.
    fOnSetNice :: Int -> IO (),
    -- | Threads whose reads report that they exited.
    fGone :: [Int],
    -- | Threads whose nice set fails.
    fFailSet :: [Int]
  }

fakeFor :: [(Int, (Int, IoPriority))] -> IO Fake
fakeFor ts = do
  ref <- newIORef (Map.fromList ts)
  pure Fake {fThreads = ref, fOnSetNice = \_ -> pure (), fGone = [], fFailSet = []}

fakeOps :: Fake -> ThreadOps
fakeOps f =
  ThreadOps
    { toSelf = pure 1,
      toListTasks = Right . (<> fGone f) . Map.keys <$> readIORef (fThreads f),
      toGetNice = fmap (fmap fst) . look,
      toSetNice = \tid n ->
        if tid `elem` fFailSet f
          then pure (Left (OpFailed "permission denied"))
          else do
            modifyIORef' (fThreads f) (Map.adjust (\(_, io) -> (n, io)) tid)
            fOnSetNice f tid
            pure (Right ()),
      toGetIoprio = fmap (fmap snd) . look,
      toSetIoprio = \tid io -> Right () <$ modifyIORef' (fThreads f) (Map.adjust (\(n, _) -> (n, io)) tid)
    }
  where
    look tid = maybe (Left ThreadGone) Right . Map.lookup tid <$> readIORef (fThreads f)

testSweepNoChange :: IO ()
testSweepNoChange = do
  f <- fakeFor [(1, (10, IoIdle)), (2, (10, IoIdle))]
  passes <- assertRight "sweep" =<< sweepThreads (fakeOps f) (SweepTarget (Just 10) (Just IoIdle))
  assertEq "one pass" 1 passes

testSweepAddedThread :: IO ()
testSweepAddedThread = do
  f0 <- fakeFor [(1, (0, IoNone)), (2, (0, IoNone))]
  -- Thread 1 creates thread 3 while it still has the old values.
  let f = f0 {fOnSetNice = \tid -> when (tid == 1) (modifyIORef' (fThreads f0) (Map.insert 3 (0, IoNone)))}
  passes <- assertRight "sweep" =<< sweepThreads (fakeOps f) (SweepTarget (Just 12) (Just IoIdle))
  assertEq "third pass changes nothing" 3 passes
  final <- readIORef (fThreads f)
  assertEq "every thread updated" (Map.fromList [(t, (12, IoIdle)) | t <- [1, 2, 3]]) final

testSweepVanished :: IO ()
testSweepVanished = do
  f0 <- fakeFor [(1, (0, IoNone))]
  let f = f0 {fGone = [7]}
  passes <- assertRight "sweep" =<< sweepThreads (fakeOps f) (SweepTarget (Just 5) Nothing)
  assertEq "two passes" 2 passes

testSweepFloor :: IO ()
testSweepFloor = do
  f <- fakeFor [(1, (15, IoIdle)), (2, (19, IoBestEffort 7))]
  passes <- assertRight "sweep" =<< sweepThreads (fakeOps f) (SweepTarget (Just 10) (Just (IoBestEffort 4)))
  assertEq "nothing to change" 1 passes
  final <- readIORef (fThreads f)
  assertEq "lower priorities kept" (Map.fromList [(1, (15, IoIdle)), (2, (19, IoBestEffort 7))]) final

testSweepFailure :: IO ()
testSweepFailure = do
  f0 <- fakeFor [(1, (0, IoNone)), (2, (0, IoNone))]
  let f = f0 {fFailSet = [2]}
  err <- assertLeft "sweep" =<< sweepThreads (fakeOps f) (SweepTarget (Just 5) Nothing)
  assertEq "names the setting" "cannot set the nice value of manager thread 2 to 5: permission denied" err

testIoprioCodec :: IO ()
testIoprioCodec = do
  let all' = [IoNone, IoIdle] <> [IoBestEffort l | l <- [0 .. 7]] <> [IoRealtime l | l <- [0 .. 7]]
  assertEq "round trip" all' (map (decodeIoprio . encodeIoprio) all')
  assertEq "idle with data 7" IoIdle (decodeIoprio (3 * 8192 + 7))

testProductionRead :: IO ()
testProductionRead = do
  inh <- assertRight "inherited" =<< readInherited productionThreadOps
  assertTrue "nice in range" (ihNice inh >= -20 && ihNice inh <= 19)
  pid <- getProcessID
  nice <- toGetNice productionThreadOps (fromIntegral pid)
  assertTrue "main thread nice readable" (either (const False) (const True) nice)
  tasks <- assertRight "tasks" =<< toListTasks productionThreadOps
  assertTrue "main thread listed" (fromIntegral pid `elem` tasks)

------------------------------------------------------------------------
-- Apply helper

-- | Apply with fake threads at @inh@, collecting warnings and events.
applyWith :: (Int, IoPriority) -> PriorityRequest -> PriorityRequest -> IO (Either Text EffectivePriority, [Text], [(Text, Value)])
applyWith inh cli config = do
  f <- fakeFor [(1, inh), (2, inh)]
  warnings <- newIORef []
  events <- newIORef []
  let m = noopMetrics {mEvent = \kind attrs -> modifyIORef' events (<> [(kind, object attrs)])}
  r <- applyCommandPriority (fakeOps f) m (\w -> modifyIORef' warnings (<> [w])) cli config
  (,,) r <$> readIORef warnings <*> readIORef events

testApplyWarnings :: IO ()
testApplyWarnings = do
  (r, warnings, _) <- applyWith (15, IoIdle) (req (Just 10) (Just (IoBestEffortReq (Just 4)))) noPriorityRequest
  _ <- assertRight "continues" r
  assertEq
    "one warning per floor"
    [ "inherited nice 15 is kept instead of the requested 10: the manager never raises its priority",
      "inherited I/O priority idle is kept instead of the requested best-effort 4: the manager never raises its priority"
    ]
    warnings
  (_, none, _) <- applyWith (0, IoNone) (req (Just 10) Nothing) noPriorityRequest
  assertEq "no floor, no warning" [] none

testApplyEvent :: IO ()
testApplyEvent = do
  (r, _, events) <- applyWith (0, IoNone) (req (Just 12) (Just IoIdleReq)) noPriorityRequest
  eff <- assertRight "applied" r
  assertEq "effective" (EffectivePriority 12 IoIdle) eff
  assertEq
    "one priority event"
    [ ( "priority",
        object
          [ "requested_nice" .= (12 :: Int),
            "requested_io" .= ("idle" :: Text),
            "effective_nice" .= (12 :: Int),
            "effective_io" .= ("idle" :: Text),
            "nice_floor" .= False,
            "io_floor" .= False
          ]
      )
    ]
    events

testApplyEventFloor :: IO ()
testApplyEventFloor = do
  (_, _, events) <- applyWith (15, IoNone) noPriorityRequest (req (Just 10) Nothing)
  assertEq
    "floored nice"
    [ ( "priority",
        object
          [ "requested_nice" .= (10 :: Int),
            "effective_nice" .= (15 :: Int),
            "effective_io" .= ("none" :: Text),
            "nice_floor" .= True,
            "io_floor" .= False
          ]
      )
    ]
    events

testApplyEventUnset :: IO ()
testApplyEventUnset = do
  (r, warnings, events) <- applyWith (0, IoNone) noPriorityRequest noPriorityRequest
  assertEq "default" (Right (EffectivePriority 0 IoNone)) r
  assertEq "no warnings" [] warnings
  assertEq
    "no requested values"
    [("priority", object ["effective_nice" .= (0 :: Int), "effective_io" .= ("none" :: Text), "nice_floor" .= False, "io_floor" .= False])]
    events

testApplyFailure :: IO ()
testApplyFailure = do
  f0 <- fakeFor [(1, (0, IoNone)), (2, (0, IoNone))]
  events <- newIORef []
  let f = f0 {fFailSet = [2]}
      m = noopMetrics {mEvent = \kind _ -> modifyIORef' events (<> [kind])}
  r <- applyCommandPriority (fakeOps f) m (\_ -> pure ()) (req (Just 5) Nothing) noPriorityRequest
  err <- assertLeft "fails" r
  assertTrue "names priority" ("cannot apply process priority" `isInfixOf` show err)
  recorded <- readIORef events
  assertEq "no event" [] recorded

------------------------------------------------------------------------
-- Child-process probe

priorityProbeEnv :: String
priorityProbeEnv = "MNDZ_TEST_PRIORITY_PROBE"

-- | Probe mode of the test binary: parse the manager options in
-- 'priorityProbeEnv', apply their priority with the production operations,
-- spawn @sleep@ from a forked thread, print its pid, and wait for stdin to
-- close. 'False' when not in probe mode.
takePriorityProbe :: IO Bool
takePriorityProbe =
  lookupEnv priorityProbeEnv >>= \case
    Nothing -> pure False
    Just raw -> do
      unsetEnv priorityProbeEnv
      hSetBuffering stdout LineBuffering
      case parseOptionsPure (words raw) of
        Success (_, cli) -> do
          applied <- applyCommandPriority productionThreadOps noopMetrics (\_ -> pure ()) cli noPriorityRequest
          case applied of
            Left err -> putStrLn ("error " <> show err)
            Right _ -> do
              started <- newEmptyMVar
              _ <- forkIO $ do
                (_, _, _, ph) <- createProcess (proc "sleep" ["60"])
                getPid ph >>= putMVar started . fmap (,ph)
              takeMVar started >>= \case
                Nothing -> putStrLn "error no child"
                Just (childPid, ph) -> do
                  putStrLn ("ready " <> show childPid)
                  hFlush stdout
                  _ <- try @IOException getLine
                  terminateProcess ph
                  void (waitForProcess ph)
        _ -> putStrLn "error usage"
      pure True

-- | Field 19 (nice) of @/proc/<pid>/task/<tid>/stat@ or @/proc/<pid>/stat@.
statNice :: FilePath -> IO (Maybe Int)
statNice path = do
  r <- try @IOException (readFile path)
  pure $ case r of
    Left _ -> Nothing
    -- Fields after the last ')' (the command may contain one) start at field 3.
    Right body -> case drop 16 (words (reverse (takeWhile (/= ')') (reverse body)))) of
      n : _ -> readMaybe n
      [] -> Nothing

testChildProcessPriority :: IO ()
testChildProcessPriority = do
  exe <- getExecutablePath
  env0 <- getEnvironment
  -- A private tix path so this child does not rewrite the suite's .tix.
  tixPath <- emptySystemTempFile "mndz-priority-probe.tix"
  removeFile tixPath
  let env1 =
        (priorityProbeEnv, "--nice 19 --ionice-class idle list")
          : ("HPCTIXFILE", tixPath)
          : filter (\(k, _) -> k /= priorityProbeEnv && k /= "HPCTIXFILE") env0
  (Just inH, Just outH, _, ph) <-
    createProcess (proc exe []) {env = Just env1, std_in = CreatePipe, std_out = CreatePipe}
  flip finally (hClose inH >> void (waitForProcess ph) >> void (try @IOException (removeFile tixPath))) $ do
    line <- hGetLine outH
    childPid <- case words line of
      ["ready", p] | Just n <- readMaybe p -> pure (n :: Int)
      _ -> fail ("probe did not start: " <> line)
    Just probePid <- fmap (fromIntegral :: Pid -> Int) <$> getPid ph
    let taskDir = "/proc/" <> show probePid <> "/task"
    tids <- map read <$> listDirectory taskDir :: IO [Int]
    assertTrue "several threads" (length tids > 1)
    seen <- forM tids $ \tid -> do
      nice <- statNice (taskDir <> "/" <> show tid <> "/stat")
      io <- toGetIoprio productionThreadOps tid
      pure (tid, nice, either (const Nothing) Just io)
    assertEq "every thread at nice 19, idle" [(t, Just 19, Just IoIdle) | (t, _, _) <- seen] seen
    childNice <- statNice ("/proc/" <> show childPid <> "/stat")
    childIo <- toGetIoprio productionThreadOps childPid
    assertEq "spawned child" (Just 19, Right IoIdle) (childNice, childIo)

------------------------------------------------------------------------
-- Container prelude

testWrapDefault :: IO ()
testWrapDefault = do
  let argv = ["emerge", "--oneshot", "foo"]
  assertEq "default" argv (priorityWrap (EffectivePriority 0 IoNone) argv)
  assertEq "realtime is not propagated" argv (priorityWrap (EffectivePriority 0 (IoRealtime 2)) argv)
  assertEq "negative nice is not propagated" argv (priorityWrap (EffectivePriority (-5) IoNone) argv)
  assertEq "no prelude" Nothing (priorityPrelude (EffectivePriority 0 IoNone))

testWrapShape :: IO ()
testWrapShape = do
  let argv = ["go", "mod", "vendor"]
  case priorityWrap (EffectivePriority 10 IoIdle) argv of
    "sh" : "-c" : script : "mndz-priority" : rest -> do
      assertEq "command after the name" argv rest
      assertTrue "execs" ("exec nice -n" `isInfixOf` script && "exec \"$@\"" `isInfixOf` script)
      assertTrue "sets idle" ("ionice -c 3 -p $$" `isInfixOf` script)
    other -> fail ("unexpected argv: " <> show other)

testToolsNeeded :: IO ()
testToolsNeeded = do
  assertEq "both" ["nice", "ionice"] (priorityToolsNeeded (EffectivePriority 5 (IoBestEffort 3)))
  assertEq "nice only" ["nice"] (priorityToolsNeeded (EffectivePriority 5 IoNone))
  assertEq "ionice only" ["ionice"] (priorityToolsNeeded (EffectivePriority 0 IoIdle))
  assertEq "none" [] (priorityToolsNeeded (EffectivePriority 0 IoNone))
  assertEq "no check" Nothing (priorityToolCheck (EffectivePriority 0 IoNone))
  withSystemTempDirectory "mndz-prio-check" $ \dir -> do
    stub dir "nice" "exit 0"
    Just check <- pure (priorityToolCheck (EffectivePriority 5 IoIdle))
    -- Only the stub directory on PATH: the host's own ionice is hidden.
    (code, _, err) <- readCreateProcessWithExitCode (proc "/bin/sh" ["-c", T.unpack check]) {env = Just [("PATH", dir)]} ""
    assertEq "fails" (ExitFailure 1) code
    assertEq "names ionice" "ionice not found (needed for process priority)\n" err

-- | A stub tool in @dir@ with a shell body. Copied into place by
-- @install@, so no fd of this process is open for writing on the
-- executable while concurrent tests fork (exec would fail with ETXTBSY).
stub :: FilePath -> FilePath -> String -> IO ()
stub dir name body = do
  let src = dir </> (name <> ".src")
  writeFile src ("#!/bin/sh\n" <> body <> "\n")
  callProcess "install" ["-m", "755", src, dir </> name]

-- | Stub @nice@ and @ionice@ logging their changes to @dir/log@. @NICE@ is
-- the current nice value and @IONICE@ the @ionice -p@ output.
priorityStubs :: FilePath -> IO ()
priorityStubs dir = do
  stub dir "nice" $
    unlines
      [ "if [ $# -eq 0 ]; then echo \"$NICE\"; exit 0; fi",
        "echo \"nice $1 $2\" >> " <> dir </> "log",
        "shift 2",
        "exec \"$@\""
      ]
  stub dir "ionice" $
    unlines
      [ "if [ \"$1\" = -p ]; then printf '%s\\n' \"$IONICE\"; exit 0; fi",
        "echo \"ionice $*\" >> " <> dir </> "log"
      ]

-- | Run @sh -c script mndz-priority argv@ with only @dir@ and the system
-- directories on PATH.
runSh :: FilePath -> [(String, String)] -> String -> [String] -> IO (ExitCode, String, String)
runSh dir extra script argv =
  readCreateProcessWithExitCode
    (proc "/bin/sh" (["-c", script, "mndz-priority"] <> argv))
      { env = Just (("PATH", dir <> ":/usr/bin:/bin") : extra)
      }
    ""

-- | Run the prelude for @ep@ on a command printing its pid; the log and
-- outputs.
runPrelude :: EffectivePriority -> String -> String -> IO (String, String, String)
runPrelude ep nice ionice =
  withSystemTempDirectory "mndz-prelude" $ \dir -> do
    priorityStubs dir
    writeFile (dir </> "log") ""
    Just script <- pure (priorityPrelude ep)
    (code, out, err) <- runSh dir [("NICE", nice), ("IONICE", ionice)] (T.unpack script) ["/bin/sh", "-c", "echo pid=$$"]
    assertEq "exit" ExitSuccess code
    logged <- readFile (dir </> "log")
    length logged `seq` pure (logged, out, err)

testPreludeRaise :: IO ()
testPreludeRaise = do
  (logged, out, err) <- runPrelude (EffectivePriority 10 IoIdle) "0" "none: prio 4"
  case lines logged of
    [ionice, nice] -> do
      assertTrue "idle set on the shell" ("ionice -c 3 -p " `isInfixOf` ionice)
      assertEq "nice raised by the difference" "nice -n 10" nice
      -- ionice -p $$ names the shell; exec keeps that pid for the command.
      assertEq "one process" ("pid=" <> last (words ionice) <> "\n") out
    other -> fail ("unexpected log: " <> show other)
  assertEq "no stderr" "" err
  (fromFive, _, _) <- runPrelude (EffectivePriority 10 IoNone) "5" ""
  assertEq "absolute target" "nice -n 5\n" fromFive

testPreludeNiceFloor :: IO ()
testPreludeNiceFloor = do
  (logged, out, err) <- runPrelude (EffectivePriority 5 IoNone) "10" ""
  assertEq "nice left alone" "" logged
  assertTrue "command ran" ("pid=" `isInfixOf` out)
  assertEq "one line" "mndz-overlay-manager: keeping nice 10 instead of the requested 5\n" err

testPreludeIoParsing :: IO ()
testPreludeIoParsing = do
  let be4 = EffectivePriority 0 (IoBestEffort 4)
  (idle, _, idleErr) <- runPrelude be4 "0" "idle"
  assertEq "idle kept" "" idle
  assertEq "idle floor line" "mndz-overlay-manager: keeping I/O priority idle instead of the requested best-effort 4\n" idleErr
  (be7, _, be7Err) <- runPrelude be4 "0" "best-effort: prio 7"
  assertEq "best-effort 7 kept" ("", "mndz-overlay-manager: keeping I/O priority best-effort 7 instead of the requested best-effort 4\n") (be7, be7Err)
  (be2, _, _) <- runPrelude be4 "0" "best-effort: prio 2"
  assertTrue "best-effort 2 lowered" ("ionice -c 2 -n 4 -p" `isInfixOf` be2)
  (rt, _, _) <- runPrelude be4 "0" "realtime: prio 0"
  assertTrue "realtime lowered" ("ionice -c 2 -n 4 -p" `isInfixOf` rt)
  (junk, _, _) <- runPrelude be4 "0" "what is this"
  assertTrue "unparsed is none at nice 0" ("ionice -c 2 -n 4 -p" `isInfixOf` junk)
  (noLevel, _, _) <- runPrelude be4 "0" "best-effort"
  assertTrue "best-effort without level is none" ("ionice -c 2 -n 4 -p" `isInfixOf` noLevel)
  (niced, _, nicedErr) <- runPrelude be4 "19" "none: prio 7"
  assertEq "none at nice 19 ranks as best-effort 7" "" niced
  assertTrue "none floor line" ("keeping I/O priority none instead of the requested best-effort 4" `isInfixOf` nicedErr)
