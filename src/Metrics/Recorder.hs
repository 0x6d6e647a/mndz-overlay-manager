{-# LANGUAGE OverloadedStrings #-}

-- | Recording 'Metrics' instance: spans, counters, header, and footer
-- (design D1, D2, D4, D11, D12, D13).
module Metrics.Recorder
  ( Recorder,
    recMetrics,
    recCgroups,
    openRecorder,
    closeRecorderPhase,

    -- * Header
    HeaderInputs (..),
    HostFacts (..),
    Invocation (..),
    runHeaderPairs,
    writeRunHeader,
    readHostFacts,

    -- * Footer
    RunEnd (..),
    classifyRunEnd,
    finishRecorder,

    -- * Redaction
    redactSecrets,
  )
where

import Build.Info (BuildInfo (..))
import Control.Concurrent (ThreadId, myThreadId)
import Control.Exception (AsyncException (..), IOException, SomeException, finally, fromException, try)
import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumProcessors)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Metrics.Core (Metrics (..), Outcome (..), SpanId (..), outcomeText)
import Metrics.Writer (Writer, closeWriter, writeLine, writerDegraded)
import System.Exit (ExitCode (..))
import System.Posix.Unistd (SystemID (..), getSystemID)
import Text.Read (readMaybe)

-- | Event file format version written in @run_start.schema@.
schemaVersion :: Int
schemaVersion = 1

-- | Span name of a per-package progress span. The first one marks the run
-- as past its early-exit window.
packageSpanName :: Text
packageSpanName = "package"

data Recorder = Recorder
  { recMetrics :: Metrics,
    recWriter :: Writer,
    recStartNs :: Word64,
    recCounters :: IORef (Map Text Value),
    recPhase :: IORef (Maybe SpanId),
    recLastPhase :: IORef (Maybe Text),
    recWorkStarted :: IORef Bool,
    -- | Registered materialize container cgroup paths (sampler "ours" test).
    recCgroups :: IO [Text]
  }

-- | Build the recording 'Metrics' over an open writer.
--
-- @timeDir@ is the run's @time/@ directory for per-process GNU time files.
openRecorder :: Writer -> FilePath -> IO Recorder
openRecorder writer timeDir = do
  start <- getMonotonicTimeNSec
  nextId <- newIORef (1 :: Int)
  stacks <- newIORef (Map.empty :: Map ThreadId [SpanId])
  -- Open spans: parent and @package@ attribute, for package lookup.
  openSpans <- newIORef (Map.empty :: Map SpanId (Maybe SpanId, Maybe Text))
  counters <- newIORef Map.empty
  phase <- newIORef Nothing
  lastPhase <- newIORef Nothing
  workStarted <- newIORef False
  secrets <- newIORef ([] :: [Text])
  cgroups <- newIORef ([] :: [Text])
  let tNs = do
        now <- getMonotonicTimeNSec
        pure (fromIntegral (now - start) :: Integer)
      emit kind kvs = do
        t <- tNs
        writeLine writer (("ev" .= kind) : ("t_ns" .= t) : kvs)
      spanStartWith push name attrs = do
        sid <- atomicModifyIORef' nextId (\n -> (n + 1, n))
        tid <- myThreadId
        parent <-
          atomicModifyIORef' stacks $ \m ->
            let st = Map.findWithDefault [] tid m
             in (if push then Map.insert tid (SpanId sid : st) m else m, listToMaybe st)
        when (name == packageSpanName) $ writeIORef workStarted True
        let pkg = case lookup "package" attrs of
              Just (String p) -> Just p
              _ -> Nothing
        atomicModifyIORef' openSpans (\mp -> (Map.insert (SpanId sid) (parent, pkg) mp, ()))
        emit
          ("span_start" :: Text)
          [ "id" .= sid,
            "parent" .= fmap (\(SpanId p) -> p) parent,
            "name" .= name,
            "attrs" .= object attrs
          ]
        pure (SpanId sid)
      spanEnd sid@(SpanId n) outcome attrs = do
        tid <- myThreadId
        atomicModifyIORef' stacks $ \m -> (removeSpan tid sid m, ())
        atomicModifyIORef' openSpans (\mp -> (Map.delete sid mp, ()))
        emit
          ("span_end" :: Text)
          [ "id" .= n,
            "outcome" .= outcomeText outcome,
            "attrs" .= object attrs
          ]
      currentSpan = do
        tid <- myThreadId
        m <- readIORef stacks
        pure (listToMaybe (Map.findWithDefault [] tid m))
      currentPackage = do
        cur <- currentSpan
        mp <- readIORef openSpans
        let walk (0 :: Int) _ = Nothing
            walk n s = case s >>= (`Map.lookup` mp) of
              Nothing -> Nothing
              Just (_, Just p) -> Just p
              Just (parent, Nothing) -> walk (n - 1) parent
        pure (walk 64 cur)
      withParent :: Maybe SpanId -> IO a -> IO a
      withParent parent act = do
        tid <- myThreadId
        prev <-
          atomicModifyIORef' stacks $ \m ->
            (Map.alter (const (fmap pure parent)) tid m, Map.lookup tid m)
        act `finally` atomicModifyIORef' stacks (\m -> (Map.alter (const prev) tid m, ()))
      spanStart = spanStartWith True
      closePhase outcome = do
        open <- atomicModifyIORef' phase (Nothing,)
        for_ open $ \sid -> spanEnd sid outcome []
      enterPhase name = do
        closePhase OutcomeOk
        sid <- spanStart ("phase." <> name) []
        writeIORef phase (Just sid)
        writeIORef lastPhase (Just name)
      bump key n =
        atomicModifyIORef' counters $ \m ->
          (Map.alter (Just . addNumber n) key m, ())
      setCounter key v = atomicModifyIORef' counters (\m -> (Map.insert key v m, ()))
      addSecret s
        | T.null s = pure ()
        | otherwise = atomicModifyIORef' secrets (\xs -> (if s `elem` xs then xs else s : xs, ()))
      registerCgroup cg = atomicModifyIORef' cgroups (\xs -> (cg : xs, ()))
      metrics =
        Metrics
          { mEnabled = True,
            mSpanStart = spanStart,
            mSpanStartDetached = spanStartWith False,
            mSpanEnd = spanEnd,
            mCurrentSpan = currentSpan,
            mCurrentPackage = currentPackage,
            mEnterPhase = enterPhase,
            mWithParent = withParent,
            mBump = bump,
            mSetCounter = setCounter,
            mEvent = emit,
            mTimeDir = Just timeDir,
            mAddSecret = addSecret,
            mRedactor = redactSecrets <$> readIORef secrets,
            mRegisterCgroup = registerCgroup
          }
  pure
    Recorder
      { recMetrics = metrics,
        recWriter = writer,
        recStartNs = start,
        recCounters = counters,
        recPhase = phase,
        recLastPhase = lastPhase,
        recWorkStarted = workStarted,
        recCgroups = readIORef cgroups
      }

-- | Close the open command phase with @outcome@.
closeRecorderPhase :: Recorder -> Outcome -> IO ()
closeRecorderPhase rec outcome = do
  open <- atomicModifyIORef' (recPhase rec) (Nothing,)
  for_ open $ \sid -> mSpanEnd (recMetrics rec) sid outcome []

-- | Remove a span from the calling thread's stack, or from whichever thread
-- holds it (progress spans may close on another thread). Empty stacks are
-- dropped so finished threads do not accumulate.
removeSpan :: ThreadId -> SpanId -> Map ThreadId [SpanId] -> Map ThreadId [SpanId]
removeSpan tid sid m
  | maybe False (sid `elem`) (Map.lookup tid m) = Map.update dropIt tid m
  | otherwise = Map.mapMaybe dropIt m
  where
    dropIt st = case filter (/= sid) st of
      [] -> Nothing
      st' -> Just st'

addNumber :: Integer -> Maybe Value -> Value
addNumber n = \case
  Just (Number x) -> Number (x + fromIntegral n)
  _ -> Number (fromIntegral n)

-- | Replace every occurrence of each secret with @\<redacted\>@.
redactSecrets :: [Text] -> Text -> Text
redactSecrets secrets t =
  foldl' (\acc s -> T.replace s "<redacted>" acc) t (filter (not . T.null) secrets)

------------------------------------------------------------------------
-- Header
------------------------------------------------------------------------

data HostFacts = HostFacts
  { hfCpus :: Int,
    hfKernel :: Text,
    hfMachine :: Text,
    hfMemTotalKb :: Maybe Integer
  }
  deriving (Eq, Show)

data Invocation = Invocation
  { invJobs :: Int,
    -- | @--refresh@ for commands that take it.
    invRefresh :: Maybe Bool,
    invTargets :: [Text],
    invExcludes :: [Text]
  }
  deriving (Eq, Show)

data HeaderInputs = HeaderInputs
  { hiRunId :: Text,
    hiCommand :: Text,
    -- | Local start time, ISO 8601 extended with offset.
    hiStartedAt :: Text,
    hiBuild :: BuildInfo,
    hiExeSha256 :: Text,
    hiHost :: HostFacts,
    hiInvocation :: Invocation,
    hiTimePath :: Text,
    hiTimeVersion :: Text,
    hiCapabilities :: Int
  }
  deriving (Eq, Show)

-- | @run_start@ fields, in emit order.
runHeaderPairs :: HeaderInputs -> [Pair]
runHeaderPairs hi =
  [ "ev" .= ("run_start" :: Text),
    "schema" .= schemaVersion,
    "run_id" .= hiRunId hi,
    "command" .= hiCommand hi,
    "started_at" .= hiStartedAt hi,
    "build"
      .= object
        [ "version" .= biVersion b,
          "git_rev" .= biGitRev b,
          "git_dirty" .= biGitDirty b,
          "flavor" .= biFlavor b,
          "ghc" .= biGhcVersion b,
          "exe_sha256" .= hiExeSha256 hi
        ],
    "host"
      .= object
        [ "cpus" .= hfCpus h,
          "kernel" .= hfKernel h,
          "machine" .= hfMachine h,
          "mem_total_kb" .= hfMemTotalKb h
        ],
    "invocation"
      .= object
        ( [ "jobs" .= invJobs inv,
            "targets" .= invTargets inv,
            "excludes" .= invExcludes inv
          ]
            <> maybe [] (\r -> ["refresh" .= r]) (invRefresh inv)
        ),
    "time" .= object ["path" .= hiTimePath hi, "version" .= hiTimeVersion hi],
    "capabilities" .= hiCapabilities hi
  ]
  where
    b = hiBuild hi
    h = hiHost hi
    inv = hiInvocation hi

writeRunHeader :: Recorder -> HeaderInputs -> IO ()
writeRunHeader rec hi = writeLine (recWriter rec) (runHeaderPairs hi)

-- | Host CPU count, kernel release, architecture, and @MemTotal@.
readHostFacts :: FilePath -> IO HostFacts
readHostFacts procRoot = do
  cpus <- getNumProcessors
  sysId <- getSystemID
  memTxt <- readFileMaybe (procRoot <> "/meminfo")
  pure
    HostFacts
      { hfCpus = cpus,
        hfKernel = T.pack (release sysId),
        hfMachine = T.pack (machine sysId),
        hfMemTotalKb = memTxt >>= memTotal
      }
  where
    memTotal txt =
      listToMaybe
        [ n
        | l <- T.lines txt,
          Just rest <- [T.stripPrefix "MemTotal:" l],
          (w : _) <- [T.words rest],
          Just n <- [readMaybe (T.unpack w)]
        ]

readFileMaybe :: FilePath -> IO (Maybe Text)
readFileMaybe path = do
  r <- try @IOException (readFile path >>= \s -> length s `seq` pure s)
  pure (either (const Nothing) (Just . T.pack) r)

------------------------------------------------------------------------
-- Footer
------------------------------------------------------------------------

-- | How the command ended, for @run_end@.
data RunEnd = RunEnd
  { reExitStatus :: Int,
    -- | @completed@, @early-exit@, or @interrupted@.
    reOutcome :: Text
  }
  deriving (Eq, Show)

-- | Map the dispatch result to exit status and outcome (design D11).
--
-- @workStarted@ is whether package work began; an 'ExitFailure' before then
-- is an @early-exit@.
classifyRunEnd :: Bool -> Either SomeException () -> RunEnd
classifyRunEnd workStarted = \case
  Right () -> RunEnd 0 "completed"
  Left e
    | Just UserInterrupt <- fromException e -> RunEnd 130 "interrupted"
    | Just ExitSuccess <- fromException e -> RunEnd 0 "completed"
    | Just (ExitFailure n) <- fromException e ->
        RunEnd n (if workStarted then "completed" else "early-exit")
    | otherwise -> RunEnd 1 "completed"

-- | Write @run_end@ from the dispatch result, then drain and close the file.
finishRecorder :: Recorder -> Either SomeException () -> IO ()
finishRecorder rec result = do
  workStarted <- readIORef (recWorkStarted rec)
  let end = classifyRunEnd workStarted result
  now <- getMonotonicTimeNSec
  lastPhase <- readIORef (recLastPhase rec)
  counters <- readIORef (recCounters rec)
  self <- rusagePairs False
  children <- rusagePairs True
  ghc <- ghcStatsValue
  degraded <- writerDegraded (recWriter rec)
  let wallNs = fromIntegral (now - recStartNs rec) :: Integer
  writeLine
    (recWriter rec)
    [ "ev" .= ("run_end" :: Text),
      "t_ns" .= wallNs,
      "exit_status" .= reExitStatus end,
      "outcome" .= reOutcome end,
      "last_phase" .= lastPhase,
      "wall_ns" .= wallNs,
      "rusage" .= object ["self" .= self, "children" .= children],
      "ghc" .= ghc,
      "counters" .= object [(Key.fromText k, v) | (k, v) <- Map.toList counters],
      "metrics_degraded" .= degraded
    ]
  closeWriter (recWriter rec)

foreign import ccall unsafe "mndz_getrusage"
  c_getrusage :: CInt -> Ptr Int64 -> IO CInt

rusagePairs :: Bool -> IO Value
rusagePairs children =
  allocaArray 3 $ \buf -> do
    rc <- c_getrusage (if children then 1 else 0) buf
    if rc /= 0
      then pure Null
      else do
        vals <- peekArray 3 buf
        case vals of
          [utime, stime, maxrss] ->
            pure $
              object
                [ "user_s" .= micros utime,
                  "sys_s" .= micros stime,
                  "max_rss_kb" .= maxrss
                ]
          _ -> pure Null
  where
    micros :: Int64 -> Double
    micros us = fromIntegral us / 1e6

ghcStatsValue :: IO Value
ghcStatsValue = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then pure Null
    else do
      s <- getRTSStats
      pure $
        object
          [ "allocated_bytes" .= allocated_bytes s,
            "max_live_bytes" .= max_live_bytes s,
            "max_mem_in_use_bytes" .= max_mem_in_use_bytes s,
            "gcs" .= gcs s,
            "major_gcs" .= major_gcs s,
            "mutator_cpu_ns" .= mutator_cpu_ns s,
            "gc_cpu_ns" .= gc_cpu_ns s,
            "cpu_ns" .= cpu_ns s,
            "elapsed_ns" .= elapsed_ns s,
            "copied_bytes" .= copied_bytes s,
            "par_copied_bytes" .= par_copied_bytes s,
            "cumulative_par_balanced_copied_bytes" .= cumulative_par_balanced_copied_bytes s
          ]
