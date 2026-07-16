{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module CLI.Progress
  ( ProgressConfig (..),
    MultiHandle (..),
    StepHandle (..),
    mkProgressConfig,
    progressEnabled,
    noopMultiHandle,
    noopStepHandle,
    withMultiProgress,
    withStepProgress,
  )
where

import CLI.Parser (ColorMode (..))
import Colog (LogAction, Message)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Exception (bracket, finally)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Layoutz
  ( Color (..),
    Element (renderElement),
    L,
    SpinnerStyle (SpinnerDots),
    inlineBar,
    layout,
    spinner,
    text,
    withColor,
  )
import Logging.Bootstrap (LogHold, beginLogHold, flushLogHold)
import System.IO (Handle, hFlush, hIsTerminalDevice, hPutStr, stderr)
import Update.Types (PackageKey, packageKeyText)

-- | Runtime configuration for activity indicators.
data ProgressConfig = ProgressConfig
  { pcEnabled :: Bool,
    pcColor :: ColorMode,
    pcLogHold :: LogHold,
    pcLogger :: LogAction IO Message,
    pcHandle :: Handle
  }

-- | Handle for multi-progress package rows.
data MultiHandle = MultiHandle
  { mhStart :: PackageKey -> IO (),
    mhStatus :: PackageKey -> Text -> IO (),
    mhSuccess :: PackageKey -> IO (),
    mhFail :: PackageKey -> Text -> IO ()
  }

-- | Handle for sequential step bars.
newtype StepHandle = StepHandle
  { shStep :: Text -> IO ()
  }

noopMultiHandle :: MultiHandle
noopMultiHandle =
  MultiHandle
    { mhStart = \_ -> pure (),
      mhStatus = \_ _ -> pure (),
      mhSuccess = \_ -> pure (),
      mhFail = \_ _ -> pure ()
    }

noopStepHandle :: StepHandle
noopStepHandle = StepHandle {shStep = \_ -> pure ()}

-- | True when stderr is a TTY and @--no-progress@ is not set.
progressEnabled :: Bool -> IO Bool
progressEnabled noProgress
  | noProgress = pure False
  | otherwise = hIsTerminalDevice stderr

mkProgressConfig ::
  Bool ->
  ColorMode ->
  LogHold ->
  LogAction IO Message ->
  IO ProgressConfig
mkProgressConfig enabled color hold logger =
  pure
    ProgressConfig
      { pcEnabled = enabled,
        pcColor = color,
        pcLogHold = hold,
        pcLogger = logger,
        pcHandle = stderr
      }

------------------------------------------------------------------------
-- Multi-progress
------------------------------------------------------------------------

data JobRow
  = JobActive Text
  | JobFailed Text
  deriving (Eq, Show)

data MultiState = MultiState
  { msLabel :: Text,
    msTotal :: Int,
    msSucceeded :: Int,
    msJobs :: Map PackageKey JobRow,
    msTick :: Int
  }

withMultiProgress ::
  ProgressConfig ->
  Text ->
  Int ->
  (MultiHandle -> IO a) ->
  IO a
withMultiProgress cfg label total action
  | not (pcEnabled cfg) || total <= 0 = action noopMultiHandle
  | otherwise = do
      beginLogHold (pcLogHold cfg)
      stateRef <-
        newIORef
          MultiState
            { msLabel = label,
              msTotal = total,
              msSucceeded = 0,
              msJobs = Map.empty,
              msTick = 0
            }
      stopVar <- newEmptyMVar
      doneVar <- newEmptyMVar
      let h = pcHandle cfg
          color = pcColor cfg
          handle = multiHandle stateRef
      bracket
        (forkIO (multiPanelLoop h color stateRef stopVar doneVar))
        ( \_ -> do
            putMVar stopVar ()
            takeMVar doneVar
            flushLogHold (pcLogHold cfg) (pcLogger cfg)
        )
        (\_ -> action handle)

multiHandle :: IORef MultiState -> MultiHandle
multiHandle stateRef =
  MultiHandle
    { mhStart = \key ->
        atomicModifyIORef' stateRef $ \s ->
          ( s {msJobs = Map.insert key (JobActive "") (msJobs s)},
            ()
          ),
      mhStatus = \key phase ->
        atomicModifyIORef' stateRef $ \s ->
          ( s
              { msJobs =
                  Map.adjust
                    ( \case
                        JobActive _ -> JobActive phase
                        other -> other
                    )
                    key
                    (msJobs s)
              },
            ()
          ),
      mhSuccess = \key ->
        atomicModifyIORef' stateRef $ \s ->
          let jobs' = Map.delete key (msJobs s)
              succ' = msSucceeded s + 1
           in (s {msJobs = jobs', msSucceeded = succ'}, ()),
      mhFail = \key reason ->
        atomicModifyIORef' stateRef $ \s ->
          ( s {msJobs = Map.insert key (JobFailed reason) (msJobs s)},
            ()
          )
    }

multiPanelLoop ::
  Handle ->
  ColorMode ->
  IORef MultiState ->
  MVar () ->
  MVar () ->
  IO ()
multiPanelLoop h color stateRef stopVar doneVar = do
  lineCountRef <- newIORef 0
  let cleanup = do
        clearLines h =<< readIORef lineCountRef
        putMVar doneVar ()
      tickLoop = do
        stopped <- tryTakeMVar stopVar
        s0 <- readIORef stateRef
        let s = s0 {msTick = msTick s0 + 1}
        writeIORef stateRef s
        let frame = renderMulti color s
        prev <- readIORef lineCountRef
        drawFrame h prev frame
        writeIORef lineCountRef (length (lines frame))
        case stopped of
          Just () -> pure ()
          Nothing -> do
            threadDelay 80_000
            tickLoop
  tickLoop `finally` cleanup

renderMulti :: ColorMode -> MultiState -> String
renderMulti color MultiState {..} =
  renderElement $
    layout $
      top : rows
  where
    failedCount = length [() | JobFailed _ <- Map.elems msJobs]
    done = msSucceeded + failedCount
    progress =
      if msTotal == 0
        then 1.0
        else fromIntegral (min done msTotal) / fromIntegral msTotal
    label = T.unpack msLabel <> " " <> show done <> "/" <> show msTotal
    bar = inlineBar label progress
    top = maybeColor color ColorBrightCyan bar
    rows =
      [ renderJob color msTick k j
      | (k, j) <- sortOn (packageKeyText . fst) (Map.toList msJobs)
      ]

renderJob :: ColorMode -> Int -> PackageKey -> JobRow -> L
renderJob color tick key = \case
  JobActive phase ->
    let base = T.unpack (packageKeyText key)
        label =
          if T.null phase
            then base
            else base <> "  " <> T.unpack phase
     in maybeColor color ColorBrightWhite $
          spinner label tick SpinnerDots
  JobFailed reason ->
    let line =
          "✗ "
            <> T.unpack (packageKeyText key)
            <> if T.null reason
              then ""
              else "  " <> T.unpack reason
     in maybeColor color ColorBrightRed (text line)

maybeColor :: ColorMode -> Color -> L -> L
maybeColor ColorOff _ el = el
maybeColor ColorOn c el = withColor c el

------------------------------------------------------------------------
-- Sequential step bar
------------------------------------------------------------------------

data StepState = StepState
  { ssTotal :: Int,
    ssDone :: Int,
    ssDesc :: Text,
    ssTick :: Int
  }

withStepProgress ::
  ProgressConfig ->
  Int ->
  (StepHandle -> IO a) ->
  IO a
withStepProgress cfg total action
  | not (pcEnabled cfg) || total <= 0 = action noopStepHandle
  | otherwise = do
      beginLogHold (pcLogHold cfg)
      stateRef <-
        newIORef
          StepState
            { ssTotal = total,
              ssDone = 0,
              ssDesc = "",
              ssTick = 0
            }
      stopVar <- newEmptyMVar
      doneVar <- newEmptyMVar
      let h = pcHandle cfg
          color = pcColor cfg
          handle =
            StepHandle
              { shStep = \desc ->
                  atomicModifyIORef' stateRef $ \s ->
                    ( s {ssDone = min (ssTotal s) (ssDone s + 1), ssDesc = desc},
                      ()
                    )
              }
      bracket
        (forkIO (stepPanelLoop h color stateRef stopVar doneVar))
        ( \_ -> do
            putMVar stopVar ()
            takeMVar doneVar
            flushLogHold (pcLogHold cfg) (pcLogger cfg)
        )
        (\_ -> action handle)

stepPanelLoop ::
  Handle ->
  ColorMode ->
  IORef StepState ->
  MVar () ->
  MVar () ->
  IO ()
stepPanelLoop h color stateRef stopVar doneVar = do
  lineCountRef <- newIORef 0
  let cleanup = do
        clearLines h =<< readIORef lineCountRef
        putMVar doneVar ()
      tickLoop = do
        stopped <- tryTakeMVar stopVar
        s0 <- readIORef stateRef
        let s = s0 {ssTick = ssTick s0 + 1}
        writeIORef stateRef s
        let frame = renderStep color s
        prev <- readIORef lineCountRef
        drawFrame h prev frame
        writeIORef lineCountRef (length (lines frame))
        case stopped of
          Just () -> pure ()
          Nothing -> do
            threadDelay 80_000
            tickLoop
  tickLoop `finally` cleanup

renderStep :: ColorMode -> StepState -> String
renderStep color StepState {..} =
  renderElement $
    maybeColor color ColorBrightCyan $
      inlineBar label progress
  where
    progress =
      if ssTotal == 0
        then 1.0
        else fromIntegral (min ssDone ssTotal) / fromIntegral ssTotal
    label =
      show ssDone
        <> "/"
        <> show ssTotal
        <> if T.null ssDesc
          then ""
          else "  " <> T.unpack ssDesc

------------------------------------------------------------------------
-- stderr frame drawing
------------------------------------------------------------------------

drawFrame :: Handle -> Int -> String -> IO ()
drawFrame h prevLineCount frame = do
  let renderedLines = lines frame
      moveUp =
        if prevLineCount > 0
          then "\ESC[" <> show prevLineCount <> "A\r"
          else ""
      body =
        concatMap (<> "\ESC[K\n") renderedLines
          <> concat
            ( replicate
                (max 0 (prevLineCount - length renderedLines))
                "\ESC[K\n"
            )
  hPutStr h (moveUp <> body)
  hFlush h

clearLines :: Handle -> Int -> IO ()
clearLines h n = when (n > 0) $ do
  let moveUp = "\ESC[" <> show n <> "A\r"
      clear = concat (replicate n "\ESC[K\n")
  hPutStr h (moveUp <> clear)
  hPutStr h ("\ESC[" <> show n <> "A\r")
  hFlush h
