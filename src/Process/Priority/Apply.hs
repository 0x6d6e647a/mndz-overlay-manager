{-# LANGUAGE OverloadedStrings #-}

-- | Apply the effective priority to every thread of the manager process.
--
-- Nice and I/O priority belong to each Linux thread, and a new thread
-- inherits from the thread that creates it. 'sweepThreads' repeats passes
-- over @/proc/self/task@ until one changes nothing: every thread alive when
-- that pass started was already at the target, so any later thread
-- inherits it from an updated parent.
module Process.Priority.Apply
  ( OpError (..),
    ThreadOps (..),
    productionThreadOps,
    decodeIoprio,
    encodeIoprio,
    SweepTarget (..),
    sweepThreads,
    readInherited,
    applyCommandPriority,
  )
where

import Control.Exception (IOException, try)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (Errno (..), eSRCH, errnoToIOError)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Metrics.Core (Metrics (..))
import Process.Priority
  ( EffectivePriority (..),
    InheritedPriority (..),
    IoPriority (..),
    PriorityRequest (..),
    Resolved (..),
    floorWarnings,
    ioRank,
    mergePriority,
    priorityEventAttrs,
    renderIoPriority,
    resolvePriority,
  )
import System.Directory (listDirectory)
import Text.Read (readMaybe)

-- | Why a thread operation failed.
data OpError
  = -- | The thread exited (@ESRCH@); not a failure of the run.
    ThreadGone
  | OpFailed Text
  deriving (Eq, Show)

-- | Thread priority operations, injected so tests never change the real
-- priority of the test process.
data ThreadOps = ThreadOps
  { toSelf :: IO Int,
    toListTasks :: IO (Either Text [Int]),
    toGetNice :: Int -> IO (Either OpError Int),
    toSetNice :: Int -> Int -> IO (Either OpError ()),
    toGetIoprio :: Int -> IO (Either OpError IoPriority),
    toSetIoprio :: Int -> IoPriority -> IO (Either OpError ())
  }

foreign import ccall unsafe "mndz_getpriority"
  c_getpriority :: CInt -> Ptr CInt -> IO CInt

foreign import ccall unsafe "mndz_setpriority"
  c_setpriority :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "mndz_ioprio_get"
  c_ioprio_get :: CInt -> Ptr CInt -> IO CInt

foreign import ccall unsafe "mndz_ioprio_set"
  c_ioprio_set :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "mndz_gettid"
  c_gettid :: IO CInt

-- | Raw @ioprio@ value: class in the top bits, level in the low three.
decodeIoprio :: Int -> IoPriority
decodeIoprio raw = case raw `shiftR` 13 of
  1 -> IoRealtime level
  2 -> IoBestEffort level
  3 -> IoIdle
  _ -> IoNone
  where
    level = raw .&. 7

encodeIoprio :: IoPriority -> Int
encodeIoprio = \case
  IoNone -> 0
  IoRealtime l -> (1 `shiftL` 13) .|. l
  IoBestEffort l -> (2 `shiftL` 13) .|. l
  IoIdle -> 3 `shiftL` 13

-- | The real syscalls on threads of this process.
productionThreadOps :: ThreadOps
productionThreadOps =
  ThreadOps
    { toSelf = fromIntegral <$> c_gettid,
      toListTasks = do
        r <- try @IOException (listDirectory "/proc/self/task")
        pure $ case r of
          Left e -> Left ("cannot list /proc/self/task: " <> T.pack (show e))
          Right names -> Right (mapMaybe readMaybe names),
      toGetNice = getWith "getpriority" c_getpriority,
      toSetNice = \tid n -> setWith "setpriority" (c_setpriority (fromIntegral tid) (fromIntegral n)),
      toGetIoprio = fmap (fmap decodeIoprio) . getWith "ioprio_get" c_ioprio_get,
      toSetIoprio = \tid io -> setWith "ioprio_set" (c_ioprio_set (fromIntegral tid) (fromIntegral (encodeIoprio io)))
    }
  where
    getWith name call tid = alloca $ \out -> do
      rc <- call (fromIntegral tid) out
      if rc == 0
        then Right . fromIntegral <$> peek out
        else pure (Left (opError name rc))
    setWith name call = do
      rc <- call
      pure (if rc == 0 then Right () else Left (opError name rc))
    opError name rc
      | Errno rc == eSRCH = ThreadGone
      | otherwise = OpFailed (T.pack (show (errnoToIOError name (Errno rc) Nothing Nothing)))

-- | Values to set on every thread. 'Nothing' leaves that setting alone.
data SweepTarget = SweepTarget
  { stNice :: Maybe Int,
    stIo :: Maybe IoPriority
  }
  deriving (Eq, Show)

-- | Outcome of one thread in a pass.
data ThreadStep = StepChanged | StepUnchanged | StepFailed Text

-- | Repeat passes until one changes no thread. Only values above the
-- target's priority are changed. Returns the number of passes.
sweepThreads :: ThreadOps -> SweepTarget -> IO (Either Text Int)
sweepThreads ops target = go 1
  where
    maxPasses = 100 :: Int
    go n
      | n > maxPasses = pure (Left ("manager threads did not settle after " <> tshow maxPasses <> " passes"))
      | otherwise =
          toListTasks ops >>= \case
            Left err -> pure (Left err)
            Right tids ->
              pass False tids >>= \case
                Left err -> pure (Left err)
                Right False -> pure (Right n)
                Right True -> go (n + 1)
    pass changed = \case
      [] -> pure (Right changed)
      tid : rest ->
        sweepThread ops target tid >>= \case
          StepFailed err -> pure (Left err)
          StepChanged -> pass True rest
          StepUnchanged -> pass changed rest

sweepThread :: ThreadOps -> SweepTarget -> Int -> IO ThreadStep
sweepThread ops target tid =
  toGetNice ops tid >>= \case
    Left ThreadGone -> pure StepUnchanged
    Left (OpFailed err) -> pure (StepFailed ("cannot read the nice value of manager thread " <> tshow tid <> ": " <> err))
    Right cur -> case stNice target of
      Just t
        | cur < t ->
            toSetNice ops tid t >>= \case
              Left ThreadGone -> pure StepUnchanged
              Left (OpFailed err) -> pure (StepFailed ("cannot set the nice value of manager thread " <> tshow tid <> " to " <> tshow t <> ": " <> err))
              Right () -> ioStep t >>= \step -> pure (changedEither step)
      _ -> ioStep cur
  where
    changedEither = \case
      StepFailed err -> StepFailed err
      _ -> StepChanged
    ioStep nice = case stIo target of
      Nothing -> pure StepUnchanged
      Just t ->
        toGetIoprio ops tid >>= \case
          Left ThreadGone -> pure StepUnchanged
          Left (OpFailed err) -> pure (StepFailed ("cannot read the I/O priority of manager thread " <> tshow tid <> ": " <> err))
          Right cur
            | cur /= t && ioRank nice cur <= ioRank nice t ->
                toSetIoprio ops tid t >>= \case
                  Left ThreadGone -> pure StepUnchanged
                  Left (OpFailed err) ->
                    pure (StepFailed ("cannot set the I/O priority of manager thread " <> tshow tid <> " to " <> renderIoPriority t <> ": " <> err))
                  Right () -> pure StepChanged
            | otherwise -> pure StepUnchanged

-- | The calling thread's nice value and I/O priority.
readInherited :: ThreadOps -> IO (Either Text InheritedPriority)
readInherited ops = do
  tid <- toSelf ops
  nice <- toGetNice ops tid
  io <- toGetIoprio ops tid
  pure $ case (nice, io) of
    (Right n, Right i) -> Right (InheritedPriority n i)
    (Left e, _) -> Left ("cannot read the inherited nice value: " <> opText e)
    (_, Left e) -> Left ("cannot read the inherited I/O priority: " <> opText e)
  where
    opText = \case
      ThreadGone -> "thread not found"
      OpFailed err -> err

-- | Resolve @cli@ over @config@ against the inherited priority, warn once
-- per floor, apply the result to every thread, and record the @priority@
-- event. Run once per command, after its config load and before any
-- workload process.
applyCommandPriority ::
  ThreadOps ->
  Metrics ->
  (Text -> IO ()) ->
  PriorityRequest ->
  PriorityRequest ->
  IO (Either Text EffectivePriority)
applyCommandPriority ops m warn cli config =
  readInherited ops >>= \case
    Left err -> pure (Left ("cannot apply process priority: " <> err))
    Right inh -> do
      let request = mergePriority cli config
          r = resolvePriority request inh
          eff = rsEffective r
      mapM_ warn (floorWarnings r)
      swept <- sweepThreads ops SweepTarget {stNice = epNice eff <$ reqNice request, stIo = rsIoTarget r}
      case swept of
        Left err -> pure (Left ("cannot apply process priority: " <> err))
        Right _ -> do
          mEvent m "priority" (priorityEventAttrs r)
          pure (Right eff)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
