{-# LANGUAGE OverloadedStrings #-}

-- | Machine telemetry samples from @/proc@ (design D8).
--
-- A @sample@ event is written at run start, every 5 seconds, and at run end:
-- CPU by mode, load, memory and swap, pressure stall averages (when the
-- kernel has @/proc/pressure@), whole-disk IO bytes since the previous
-- sample, every process of this run, and the 10 busiest other processes.
-- All reads go through a 'ProcRoot' so tests use fixture directories.
module Metrics.Sampler
  ( SamplerConfig (..),
    productionSamplerConfig,
    startSampler,

    -- * Parsers
    CpuTimes (..),
    parseCpuTimes,
    cpuPercents,
    parseLoadAvg,
    parseMemInfo,
    parsePressure,
    DiskTotals (..),
    parseDiskStats,
    PidStat (..),
    parsePidStat,

    -- * Sampling
    SampleState,
    initialSampleState,
    takeSample,
    selectProcesses,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (IOException, try)
import Control.Monad (forever)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair)
import Data.Char (isDigit)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Foreign.C.Types (CLong (..))
import GHC.Clock (getMonotonicTimeNSec)
import Metrics.Core (Metrics (..), trySync)
import Metrics.Recorder (Recorder, recCgroups, recMetrics)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.Unistd (SysVar (ClockTick), getSysVar)
import Text.Read (readMaybe)

-- | Sampler inputs (fixtures and a manual tick in tests).
data SamplerConfig = SamplerConfig
  { -- | @/proc@ or a fixture directory with the same layout.
    scProcRoot :: FilePath,
    -- | Waits between periodic samples (5 seconds in production).
    scWait :: IO (),
    -- | The manager's own PID (root of "ours").
    scSelfPid :: IO Int,
    scClockTicks :: Integer,
    scPageSize :: Integer
  }

foreign import ccall unsafe "mndz_page_size"
  c_pageSize :: IO CLong

productionSamplerConfig :: IO SamplerConfig
productionSamplerConfig = do
  ticks <- getSysVar ClockTick
  page <- c_pageSize
  pure
    SamplerConfig
      { scProcRoot = "/proc",
        scWait = threadDelay 5_000_000,
        scSelfPid = fromIntegral <$> getProcessID,
        scClockTicks = ticks,
        scPageSize = fromIntegral page
      }

-- | Write the start sample, sample every 'scWait', and return the stop
-- action: cancel the thread, then write the final sample.
startSampler :: SamplerConfig -> Recorder -> IO (IO ())
startSampler cfg rec = do
  let m = recMetrics rec
  stateRef <- newIORef =<< initialSampleState
  let one = sampleOnce cfg m (recCgroups rec) stateRef
  one
  thread <- async (forever (scWait cfg >> one))
  pure $ do
    cancel thread
    one

-- | One sample; failures never escape (recording must not change the run),
-- but asynchronous exceptions do so Ctrl-C and 'cancel' still work.
sampleOnce :: SamplerConfig -> Metrics -> IO [Text] -> IORef SampleState -> IO ()
sampleOnce cfg m cgroups stateRef = do
  r <- trySync $ do
    prev <- readIORef stateRef
    cgs <- cgroups
    (attrs, next) <- takeSample cfg cgs prev
    writeIORef stateRef next
    mEvent m "sample" attrs
  case r of
    Left _ -> pure ()
    Right () -> pure ()

------------------------------------------------------------------------
-- Parsers
------------------------------------------------------------------------

-- | Aggregate CPU jiffies by mode from the first @/proc/stat@ line.
data CpuTimes = CpuTimes
  { ctUser, ctNice, ctSystem, ctIdle, ctIowait, ctIrq, ctSoftirq, ctSteal :: Integer
  }
  deriving (Eq, Show)

parseCpuTimes :: Text -> Maybe CpuTimes
parseCpuTimes body = case T.words <$> listToMaybe' (T.lines body) of
  Just ("cpu" : rest) -> case mapMaybe (readMaybe . T.unpack) rest of
    (u : n : s : i : io : irq : sirq : st : _) -> Just (CpuTimes u n s i io irq sirq st)
    _ -> Nothing
  _ -> Nothing
  where
    listToMaybe' = \case
      (x : _) -> Just x
      [] -> Nothing

-- | Percent of elapsed jiffies per mode between two readings.
cpuPercents :: CpuTimes -> CpuTimes -> [Pair]
cpuPercents a b =
  [ k .= pct (f b - f a)
  | (k, f) <-
      [ ("user", ctUser),
        ("nice", ctNice),
        ("system", ctSystem),
        ("idle", ctIdle),
        ("iowait", ctIowait),
        ("irq", ctIrq),
        ("softirq", ctSoftirq),
        ("steal", ctSteal)
      ]
  ]
  where
    total = sum (map ($ b) modes) - sum (map ($ a) modes)
    modes = [ctUser, ctNice, ctSystem, ctIdle, ctIowait, ctIrq, ctSoftirq, ctSteal]
    pct :: Integer -> Double
    pct d
      | total <= 0 = 0
      | otherwise = round2 (100 * fromIntegral d / fromIntegral total)

-- | @load1@, @load5@, @load15@, running and total process counts.
parseLoadAvg :: Text -> Maybe [Pair]
parseLoadAvg body = case T.words body of
  (l1 : l5 : l15 : rt : _)
    | Just a <- num l1,
      Just b <- num l5,
      Just c <- num l15,
      (r, t) <- T.breakOn "/" rt,
      Just running <- (readMaybe (T.unpack r) :: Maybe Int),
      Just total <- (readMaybe (T.unpack (T.drop 1 t)) :: Maybe Int) ->
        Just
          [ "load1" .= a,
            "load5" .= b,
            "load15" .= c,
            "running" .= running,
            "total" .= total
          ]
  _ -> Nothing
  where
    num t = readMaybe (T.unpack t) :: Maybe Double

-- | Memory and swap use in KiB from @/proc/meminfo@.
parseMemInfo :: Text -> [Pair]
parseMemInfo body =
  catMaybes
    [ ("total_kb" .=) <$> get "MemTotal",
      ("available_kb" .=) <$> get "MemAvailable",
      ("used_kb" .=) <$> ((-) <$> get "MemTotal" <*> get "MemAvailable"),
      ("swap_total_kb" .=) <$> get "SwapTotal",
      ("swap_used_kb" .=) <$> ((-) <$> get "SwapTotal" <*> get "SwapFree")
    ]
  where
    fields =
      Map.fromList
        [ (T.dropWhileEnd (== ':') k, n)
        | l <- T.lines body,
          (k : v : _) <- [T.words l],
          Just n <- [readMaybe (T.unpack v) :: Maybe Integer]
        ]
    get k = Map.lookup k fields

-- | @some@ and @full@ @avg10@/@avg60@/@avg300@ from one pressure file.
parsePressure :: Text -> [Pair]
parsePressure body =
  [ Key.fromText kind .= object [k .= v | (k, v) <- avgs]
  | l <- T.lines body,
    (kind : rest) <- [T.words l],
    kind `elem` ["some", "full"],
    let avgs =
          [ (keyOf name, v :: Double)
          | kv <- rest,
            (name, val) <- [T.breakOn "=" kv],
            name `elem` ["avg10", "avg60", "avg300"],
            Just v <- [readMaybe (T.unpack (T.drop 1 val))]
          ]
  ]
  where
    keyOf = \case
      "avg10" -> "avg10"
      "avg60" -> "avg60"
      _ -> "avg300"

-- | Bytes read and written, summed over whole disks.
data DiskTotals = DiskTotals
  { dtReadBytes :: Integer,
    dtWriteBytes :: Integer
  }
  deriving (Eq, Show)

-- | Whole-disk totals from @/proc/diskstats@. Partitions (a name whose
-- base device is also listed) and virtual or stacked devices (loop, ram,
-- zram, dm, md, sr) are skipped so IO is not counted twice.
parseDiskStats :: Text -> DiskTotals
parseDiskStats body =
  DiskTotals
    { dtReadBytes = sum [r * 512 | (_, r, _) <- disks],
      dtWriteBytes = sum [w * 512 | (_, _, w) <- disks]
    }
  where
    rows =
      [ (name, r, w)
      | l <- T.lines body,
        (_ : _ : name : _ : _ : sr : _ : _ : _ : sw : _) <- [T.words l],
        Just r <- [readMaybe (T.unpack sr) :: Maybe Integer],
        Just w <- [readMaybe (T.unpack sw) :: Maybe Integer]
      ]
    names = Set.fromList [n | (n, _, _) <- rows]
    virtual n = any (`T.isPrefixOf` n) ["loop", "ram", "zram", "dm-", "md", "sr", "fd"]
    partitionOf n =
      let base = T.dropWhileEnd isDigit n
          base' = fromMaybe base (T.stripSuffix "p" base)
       in base /= n && (base `Set.member` names || (base' /= base && base' `Set.member` names))
    disks = [row | row@(n, _, _) <- rows, not (virtual n), not (partitionOf n)]

-- | Fields of @/proc/\<pid\>/stat@ the sampler uses.
data PidStat = PidStat
  { psPid :: Int,
    psComm :: Text,
    psState :: Text,
    psPpid :: Int,
    -- | utime + stime in clock ticks.
    psTicks :: Integer,
    psRssPages :: Integer
  }
  deriving (Eq, Show)

-- | Parse @/proc/\<pid\>/stat@; @comm@ is everything inside the outer
-- parentheses (it may contain spaces or parentheses).
parsePidStat :: Text -> Maybe PidStat
parsePidStat body = do
  let (pidPart, rest0) = T.breakOn " (" body
      (commRev, afterRev) = T.breakOn ")" (T.reverse rest0)
      comm = T.drop 2 (T.reverse (T.drop 1 afterRev))
      fields = T.words (T.reverse commRev)
  pid <- readMaybe (T.unpack pidPart)
  case fields of
    (st : ppid : rest) | length rest >= 20 -> do
      p <- readMaybe (T.unpack ppid)
      ut <- readMaybe (T.unpack (rest !! 9))
      stime <- readMaybe (T.unpack (rest !! 10))
      rss <- readMaybe (T.unpack (rest !! 19))
      pure
        PidStat
          { psPid = pid,
            psComm = comm,
            psState = st,
            psPpid = p,
            psTicks = ut + stime,
            psRssPages = rss
          }
    _ -> Nothing

------------------------------------------------------------------------
-- Sampling
------------------------------------------------------------------------

-- | Previous reading for deltas.
data SampleState = SampleState
  { ssAtNs :: Word,
    ssCpu :: Maybe CpuTimes,
    ssDisk :: Maybe DiskTotals,
    ssPidTicks :: Maybe (Map Int Integer)
  }

initialSampleState :: IO SampleState
initialSampleState = do
  now <- getMonotonicTimeNSec
  pure SampleState {ssAtNs = fromIntegral now, ssCpu = Nothing, ssDisk = Nothing, ssPidTicks = Nothing}

-- | Read @/proc@ once and build the @sample@ attributes. @cgroups@ are the
-- registered materialize container cgroups (their processes are ours).
takeSample :: SamplerConfig -> [Text] -> SampleState -> IO ([Pair], SampleState)
takeSample cfg cgroups prev = do
  let root = scProcRoot cfg
  now <- fromIntegral <$> getMonotonicTimeNSec
  cpu <- (>>= parseCpuTimes) <$> readMaybeFile (root </> "stat")
  load <- (>>= parseLoadAvg) <$> readMaybeFile (root </> "loadavg")
  mem <- fmap parseMemInfo <$> readMaybeFile (root </> "meminfo")
  psi <-
    mapM
      (\k -> fmap (\b -> Key.fromText k .= object (parsePressure b)) <$> readMaybeFile (root </> "pressure" </> T.unpack k))
      ["cpu", "memory", "io"]
  disk <- fmap parseDiskStats <$> readMaybeFile (root </> "diskstats")
  self <- scSelfPid cfg
  pids <- readPidStats root
  oursByCgroup <-
    if null cgroups
      then pure Set.empty
      else Set.fromList . catMaybes <$> mapM (inCgroups root cgroups . psPid) pids
  let elapsedS = fromIntegral (now - ssAtNs prev) / 1e9 :: Double
      procs = selectProcesses cfg self oursByCgroup (ssPidTicks prev) elapsedS pids
      diskDelta = case (ssDisk prev, disk) of
        (Just a, Just b) ->
          Just
            [ "read_bytes" .= max 0 (dtReadBytes b - dtReadBytes a),
              "write_bytes" .= max 0 (dtWriteBytes b - dtWriteBytes a)
            ]
        (Nothing, Just _) -> Just ["read_bytes" .= (0 :: Int), "write_bytes" .= (0 :: Int)]
        _ -> Nothing
      attrs =
        catMaybes
          [ (\(a, b) -> "cpu" .= object (cpuPercents a b)) <$> ((,) <$> ssCpu prev <*> cpu),
            ("load" .=) . object <$> load,
            ("mem" .=) . object <$> mem,
            if null (catMaybes psi) then Nothing else Just ("psi" .= object (catMaybes psi)),
            ("disk" .=) . object <$> diskDelta,
            Just ("procs" .= procs)
          ]
      next =
        SampleState
          { ssAtNs = now,
            ssCpu = cpu,
            ssDisk = disk,
            ssPidTicks = Just (Map.fromList [(psPid p, psTicks p) | p <- pids])
          }
  pure (attrs, next)

-- | Every process of ours (descendants of @self@, or in a registered
-- container cgroup) plus the 10 other processes with the most CPU since the
-- previous sample. Only the short command name is recorded.
selectProcesses ::
  SamplerConfig ->
  Int ->
  Set.Set Int ->
  Maybe (Map Int Integer) ->
  Double ->
  [PidStat] ->
  [Value]
selectProcesses cfg self byCgroup prevTicks elapsedS pids =
  map entry (ours <> take 10 (sortOn (Down . delta) others))
  where
    children = Map.fromListWith (<>) [(psPpid p, [psPid p]) | p <- pids]
    descendants = go Set.empty [self]
      where
        go seen [] = seen
        go seen (x : xs)
          | x `Set.member` seen = go seen xs
          | otherwise = go (Set.insert x seen) (Map.findWithDefault [] x children <> xs)
    oursSet = descendants `Set.union` byCgroup
    isOurs p = psPid p `Set.member` oursSet
    ours = sortOn psPid (filter isOurs pids)
    others = filter (not . isOurs) pids
    -- First sample: rank by lifetime ticks; later samples: by delta.
    delta p = case prevTicks of
      Nothing -> psTicks p
      Just mp -> psTicks p - Map.findWithDefault 0 (psPid p) mp
    cpuPct p = case prevTicks of
      Just _
        | elapsedS > 0 ->
            Number (realToFrac (round2 (100 * fromIntegral (delta p) / (fromIntegral (scClockTicks cfg) * elapsedS))))
      _ -> Null
    entry p =
      object
        [ "pid" .= psPid p,
          "ppid" .= psPpid p,
          "comm" .= psComm p,
          "cpu_pct" .= cpuPct p,
          "rss_kb" .= (psRssPages p * scPageSize cfg `div` 1024),
          "state" .= psState p,
          "ours" .= isOurs p
        ]

round2 :: Double -> Double
round2 x = fromIntegral (round (x * 100) :: Integer) / 100

readPidStats :: FilePath -> IO [PidStat]
readPidStats root = do
  r <- try @IOException (listDirectory root)
  let pidDirs = either (const []) (filter (all isDigit)) r
  catMaybes <$> mapM (\d -> (>>= parsePidStat) <$> readMaybeFile (root </> d </> "stat")) pidDirs

-- | @Just pid@ when the process sits in (or under) a registered cgroup.
inCgroups :: FilePath -> [Text] -> Int -> IO (Maybe Int)
inCgroups root cgroups pid = do
  body <- readMaybeFile (root </> show pid </> "cgroup")
  pure $ case body of
    Just b
      | any (\l -> any (\cg -> T.stripPrefix "0::" l `elemPath` cg) cgroups) (T.lines b) -> Just pid
    _ -> Nothing
  where
    elemPath mPath cg = case mPath of
      Just p -> p == cg || (cg <> "/") `T.isPrefixOf` p
      Nothing -> False

readMaybeFile :: FilePath -> IO (Maybe Text)
readMaybeFile path = do
  r <- try @IOException (TIO.readFile path) -- allow-non-ebuild: proc
  pure (either (const Nothing) Just r)
