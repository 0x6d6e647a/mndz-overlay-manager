{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

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
    pauseActivePanel,
    resumeActivePanel,
    -- Test seam (production entry points wrap defaultPanelIO)
    PanelIO (..),
    defaultPanelIO,
    withMultiProgressIO,
    withStepProgressIO,
    -- Pure multi-progress state (for tests)
    ActiveJob (..),
    JobRow (..),
    MultiState (..),
    renderMulti,
    multiHandle,
    -- Pure frame draw plan (for tests)
    DrawPlan (..),
    planDraw,
    -- Metrics spans derived from progress handles
    instrumentMultiHandle,
    instrumentStepHandle,
  )
where

import CLI.Parser (ColorMode (..))
import Colog (LogAction, Message)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, cancel, race, waitCatch, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, tryPutMVar, tryTakeMVar, withMVar)
import Control.Exception (finally, onException)
import Control.Monad (unless, void, when)
import Data.Aeson ((.=))
import Data.Foldable (for_)
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
    row,
    spinner,
    text,
    withColor,
  )
import Logging.Bootstrap (LogHold, beginLogHold, flushLogHold)
import Metrics.Core
  ( Metrics (..),
    Outcome (..),
    SpanId,
    noopMetrics,
    withSpan,
  )
import System.IO (Handle, hFlush, hIsTerminalDevice, hPutStr, stderr)
import Update.Types (PackageKey, packageKeyText)

-- | Runtime configuration for activity indicators.
data ProgressConfig = ProgressConfig
  { pcEnabled :: Bool,
    pcColor :: ColorMode,
    pcLogHold :: LogHold,
    pcLogger :: LogAction IO Message,
    pcHandle :: Handle,
    -- | Active panel pause controller (set while a multi/step panel is running).
    pcPanelCtrl :: IORef (Maybe PanelController),
    -- | Run metrics recorder ('noopMetrics' unless this run records).
    pcMetrics :: Metrics,
    -- | Open @prompt@ span while the panel is paused for a prompt.
    pcPromptSpan :: IORef (Maybe SpanId)
  }

-- | Pause/resume an active activity panel so interactive prompts can own the TTY.
data PanelController = PanelController
  { panelPause :: IO (),
    panelResume :: IO ()
  }

-- | Handle for multi-progress package rows.
data MultiHandle = MultiHandle
  { mhStart :: PackageKey -> IO (),
    -- | Waiting (not in-flight, not skip, not hard-fail). Reason names the provider.
    mhWait :: PackageKey -> Text -> IO (),
    -- | Set current step/phase name without advancing the step counter.
    mhStatus :: PackageKey -> Text -> IO (),
    -- | Set or revise the per-package step total (keeps done, clamped to total).
    mhSteps :: PackageKey -> Int -> IO (),
    -- | Advance steps done by 1 and set the current step name.
    mhStep :: PackageKey -> Text -> IO (),
    mhSuccess :: PackageKey -> IO (),
    -- | Soft-skip terminal: retain row with skip/warning chrome (not hard-fail).
    mhSkip :: PackageKey -> Text -> IO (),
    mhFail :: PackageKey -> Text -> IO (),
    -- | Recorder for spans opened by work under this handle.
    mhMetrics :: Metrics
  }

-- | Handle for sequential step bars.
newtype StepHandle = StepHandle
  { shStep :: Text -> IO ()
  }

noopMultiHandle :: MultiHandle
noopMultiHandle =
  MultiHandle
    { mhStart = \_ -> pure (),
      mhWait = \_ _ -> pure (),
      mhStatus = \_ _ -> pure (),
      mhSteps = \_ _ -> pure (),
      mhStep = \_ _ -> pure (),
      mhSuccess = \_ -> pure (),
      mhSkip = \_ _ -> pure (),
      mhFail = \_ _ -> pure (),
      mhMetrics = noopMetrics
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
mkProgressConfig enabled color hold logger = do
  panelCtrl <- newIORef Nothing
  promptSpan <- newIORef Nothing
  pure
    ProgressConfig
      { pcEnabled = enabled,
        pcColor = color,
        pcLogHold = hold,
        pcLogger = logger,
        pcHandle = stderr,
        pcPanelCtrl = panelCtrl,
        pcMetrics = noopMetrics,
        pcPromptSpan = promptSpan
      }

-- | Clear and pause the active activity panel (if any).
--
-- Opens an interactive @prompt@ span that 'resumeActivePanel' closes.
pauseActivePanel :: ProgressConfig -> IO ()
pauseActivePanel cfg = do
  let m = pcMetrics cfg
  when (mEnabled m) $ do
    open <- readIORef (pcPromptSpan cfg)
    case open of
      Just _ -> pure ()
      Nothing -> do
        sid <- mSpanStart m "prompt" ["interactive" .= True]
        writeIORef (pcPromptSpan cfg) (Just sid)
  mCtrl <- readIORef (pcPanelCtrl cfg)
  for_ mCtrl panelPause

-- | Resume the active activity panel (if any) after 'pauseActivePanel'.
resumeActivePanel :: ProgressConfig -> IO ()
resumeActivePanel cfg = do
  mCtrl <- readIORef (pcPanelCtrl cfg)
  for_ mCtrl panelResume
  open <- atomicModifyIORef' (pcPromptSpan cfg) (Nothing,)
  for_ open $ \sid -> mSpanEnd (pcMetrics cfg) sid OutcomeOk []

------------------------------------------------------------------------
-- Injectable panel IO (test seam)
------------------------------------------------------------------------

-- | Side effects used by the progress panel host.
--
-- Production uses 'defaultPanelIO'. Tests inject draw/clear/delay failures
-- to prove teardown cannot hang on progress-internal MVars.
data PanelIO = PanelIO
  { pioDrawFrame :: Handle -> Int -> String -> IO Int,
    pioClearLines :: Handle -> Int -> IO (),
    pioDelay :: Int -> IO ()
  }

-- | Production panel IO: ANSI draw/clear on the handle and 'threadDelay'.
defaultPanelIO :: PanelIO
defaultPanelIO =
  PanelIO
    { pioDrawFrame = drawFrame,
      pioClearLines = clearLines,
      pioDelay = threadDelay
    }

-- | Grace period for cooperative panel stop before cancel (300ms).
panelStopGraceMicros :: Int
panelStopGraceMicros = 300_000

-- | Exception-safe draw mutex: always release on throw.
withDrawLock :: MVar () -> IO a -> IO a
withDrawLock lock action = withMVar lock (const action)

-- | Cooperative stop, grace wait, then cancel + reap. Swallows panel failures.
reapPanel :: Async () -> MVar () -> IO ()
reapPanel panel stopVar = do
  void (tryPutMVar stopVar ())
  raced <- race (waitCatch panel) (threadDelay panelStopGraceMicros)
  case raced of
    Left _ -> pure ()
    Right () -> do
      cancel panel
      void (waitCatch panel)

------------------------------------------------------------------------
-- Multi-progress
------------------------------------------------------------------------

-- | In-flight package row state (inner step counters; top bar is package-level).
data ActiveJob = ActiveJob
  { -- | 0 = unset / single-step (omit row bar and fraction).
    ajStepTotal :: Int,
    ajStepDone :: Int,
    ajName :: Text
  }
  deriving (Eq, Show)

data JobRow
  = JobActive ActiveJob
  | -- | Withheld on an overlay wait-edge provider (reason names the provider).
    JobWaiting Text
  | JobSkipped Text
  | JobFailed Text
  deriving (Eq, Show)

data MultiState = MultiState
  { msLabel :: Text,
    msTotal :: Int,
    msSucceeded :: Int,
    msJobs :: Map PackageKey JobRow,
    msTick :: Int
  }
  deriving (Eq, Show)

withMultiProgress ::
  ProgressConfig ->
  Text ->
  Int ->
  (MultiHandle -> IO a) ->
  IO a
withMultiProgress = withMultiProgressIO defaultPanelIO

-- | Multi-progress host with injectable panel IO (for tests).
withMultiProgressIO ::
  PanelIO ->
  ProgressConfig ->
  Text ->
  Int ->
  (MultiHandle -> IO a) ->
  IO a
withMultiProgressIO pio cfg label total action0 =
  withMultiProgressRaw pio cfg label total $ \mh ->
    instrumentMultiHandle (pcMetrics cfg) label mh action0

withMultiProgressRaw ::
  PanelIO ->
  ProgressConfig ->
  Text ->
  Int ->
  (MultiHandle -> IO a) ->
  IO a
withMultiProgressRaw pio cfg label total action
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
      drawLock <- newMVar ()
      pausedRef <- newIORef False
      lineCountRef <- newIORef 0
      let h = pcHandle cfg
          color = pcColor cfg
          handle = multiHandle stateRef
          ctrl =
            PanelController
              { panelPause = pausePanel pio drawLock pausedRef lineCountRef h,
                panelResume = resumePanel drawLock pausedRef
              }
      writeIORef (pcPanelCtrl cfg) (Just ctrl)
      withAsync
        (multiPanelLoop pio h color stateRef stopVar drawLock pausedRef lineCountRef)
        $ \panel ->
          action handle `finally` do
            reapPanel panel stopVar
            writeIORef (pcPanelCtrl cfg) Nothing
            flushLogHold (pcLogHold cfg) (pcLogger cfg)

multiHandle :: IORef MultiState -> MultiHandle
multiHandle stateRef =
  MultiHandle
    { mhStart = \key ->
        atomicModifyIORef' stateRef $ \s ->
          ( s
              { msJobs =
                  Map.insert
                    key
                    ( JobActive
                        ActiveJob
                          { ajStepTotal = 0,
                            ajStepDone = 0,
                            ajName = ""
                          }
                    )
                    (msJobs s)
              },
            ()
          ),
      mhWait = \key reason ->
        atomicModifyIORef' stateRef $ \s ->
          ( s {msJobs = Map.insert key (JobWaiting reason) (msJobs s)},
            ()
          ),
      mhStatus = \key phase ->
        atomicModifyIORef' stateRef $ \s ->
          ( s
              { msJobs =
                  Map.adjust
                    ( \case
                        JobActive aj -> JobActive aj {ajName = phase}
                        JobWaiting _ -> JobWaiting phase
                        other -> other
                    )
                    key
                    (msJobs s)
              },
            ()
          ),
      mhSteps = \key total ->
        atomicModifyIORef' stateRef $ \s ->
          ( s
              { msJobs =
                  Map.adjust
                    ( \case
                        JobActive aj ->
                          JobActive
                            aj
                              { ajStepTotal = total,
                                ajStepDone = min (ajStepDone aj) total
                              }
                        other -> other
                    )
                    key
                    (msJobs s)
              },
            ()
          ),
      mhStep = \key name ->
        atomicModifyIORef' stateRef $ \s ->
          ( s
              { msJobs =
                  Map.adjust
                    ( \case
                        JobActive aj ->
                          let total = ajStepTotal aj
                              done' =
                                if total > 0
                                  then min total (ajStepDone aj + 1)
                                  else ajStepDone aj + 1
                           in JobActive
                                aj
                                  { ajStepDone = done',
                                    ajName = name
                                  }
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
      mhSkip = \key reason ->
        atomicModifyIORef' stateRef $ \s ->
          ( s {msJobs = Map.insert key (JobSkipped reason) (msJobs s)},
            ()
          ),
      mhFail = \key reason ->
        atomicModifyIORef' stateRef $ \s ->
          ( s {msJobs = Map.insert key (JobFailed reason) (msJobs s)},
            ()
          ),
      mhMetrics = noopMetrics
    }

multiPanelLoop ::
  PanelIO ->
  Handle ->
  ColorMode ->
  IORef MultiState ->
  MVar () ->
  MVar () ->
  IORef Bool ->
  IORef Int ->
  IO ()
multiPanelLoop pio h color stateRef stopVar drawLock pausedRef lineCountRef = do
  let cleanup =
        withDrawLock drawLock $ do
          pioClearLines pio h =<< readIORef lineCountRef
          writeIORef lineCountRef 0
      tickLoop = do
        stopped <- tryTakeMVar stopVar
        withDrawLock drawLock $ do
          paused <- readIORef pausedRef
          unless paused $ do
            s0 <- readIORef stateRef
            let s = s0 {msTick = msTick s0 + 1}
            writeIORef stateRef s
            let frame = renderMulti color s
            prev <- readIORef lineCountRef
            store <- pioDrawFrame pio h prev frame
            writeIORef lineCountRef store
        case stopped of
          Just () -> pure ()
          Nothing -> do
            pioDelay pio 80_000
            tickLoop
  tickLoop `finally` cleanup

renderMulti :: ColorMode -> MultiState -> String
renderMulti color MultiState {..} =
  renderElement $
    layout $
      top : rows
  where
    -- Retained terminals (skip + hard-fail) count as package-done alongside success.
    retainedTerminal =
      length
        [ ()
        | j <- Map.elems msJobs,
          case j of
            JobSkipped _ -> True
            JobFailed _ -> True
            JobActive _ -> False
            JobWaiting _ -> False
        ]
    done = msSucceeded + retainedTerminal
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
  JobActive ActiveJob {..} ->
    let pkg = T.unpack (packageKeyText key)
        name = T.unpack ajName
     in if ajStepTotal > 1
          then
            let frac =
                  if ajStepTotal == 0
                    then 1.0
                    else fromIntegral (min ajStepDone ajStepTotal) / fromIntegral ajStepTotal
                barLabel = show ajStepDone <> "/" <> show ajStepTotal
                bar = inlineBar barLabel frac
                nameEl =
                  if null name
                    then text ""
                    else text ("  " <> name)
             in maybeColor color ColorBrightWhite $
                  row
                    [ spinner pkg tick SpinnerDots,
                      text "  ",
                      bar,
                      nameEl
                    ]
          else
            let label =
                  if null name
                    then pkg
                    else pkg <> "  " <> name
             in maybeColor color ColorBrightWhite $
                  spinner label tick SpinnerDots
  JobWaiting reason ->
    let line =
          "… "
            <> T.unpack (packageKeyText key)
            <> if T.null reason
              then ""
              else "  " <> T.unpack reason
     in maybeColor color ColorBrightCyan (text line)
  JobSkipped reason ->
    let line =
          "⚠ "
            <> T.unpack (packageKeyText key)
            <> if T.null reason
              then ""
              else "  " <> T.unpack reason
     in maybeColor color ColorBrightYellow (text line)
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
withStepProgress = withStepProgressIO defaultPanelIO

-- | Step-progress host with injectable panel IO (for tests).
withStepProgressIO ::
  PanelIO ->
  ProgressConfig ->
  Int ->
  (StepHandle -> IO a) ->
  IO a
withStepProgressIO pio cfg total action0 =
  withStepProgressRaw pio cfg total $ \sh ->
    instrumentStepHandle (pcMetrics cfg) sh action0

withStepProgressRaw ::
  PanelIO ->
  ProgressConfig ->
  Int ->
  (StepHandle -> IO a) ->
  IO a
withStepProgressRaw pio cfg total action
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
      drawLock <- newMVar ()
      pausedRef <- newIORef False
      lineCountRef <- newIORef 0
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
          ctrl =
            PanelController
              { panelPause = pausePanel pio drawLock pausedRef lineCountRef h,
                panelResume = resumePanel drawLock pausedRef
              }
      writeIORef (pcPanelCtrl cfg) (Just ctrl)
      withAsync
        (stepPanelLoop pio h color stateRef stopVar drawLock pausedRef lineCountRef)
        $ \panel ->
          action handle `finally` do
            reapPanel panel stopVar
            writeIORef (pcPanelCtrl cfg) Nothing
            flushLogHold (pcLogHold cfg) (pcLogger cfg)

stepPanelLoop ::
  PanelIO ->
  Handle ->
  ColorMode ->
  IORef StepState ->
  MVar () ->
  MVar () ->
  IORef Bool ->
  IORef Int ->
  IO ()
stepPanelLoop pio h color stateRef stopVar drawLock pausedRef lineCountRef = do
  let cleanup =
        withDrawLock drawLock $ do
          pioClearLines pio h =<< readIORef lineCountRef
          writeIORef lineCountRef 0
      tickLoop = do
        stopped <- tryTakeMVar stopVar
        withDrawLock drawLock $ do
          paused <- readIORef pausedRef
          unless paused $ do
            s0 <- readIORef stateRef
            let s = s0 {ssTick = ssTick s0 + 1}
            writeIORef stateRef s
            let frame = renderStep color s
            prev <- readIORef lineCountRef
            store <- pioDrawFrame pio h prev frame
            writeIORef lineCountRef store
        case stopped of
          Just () -> pure ()
          Nothing -> do
            pioDelay pio 80_000
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
-- Panel pause + stderr frame drawing
------------------------------------------------------------------------

pausePanel :: PanelIO -> MVar () -> IORef Bool -> IORef Int -> Handle -> IO ()
pausePanel pio drawLock pausedRef lineCountRef h =
  withDrawLock drawLock $ do
    pioClearLines pio h =<< readIORef lineCountRef
    writeIORef lineCountRef 0
    writeIORef pausedRef True

resumePanel :: MVar () -> IORef Bool -> IO ()
resumePanel drawLock pausedRef =
  withDrawLock drawLock $
    writeIORef pausedRef False

-- | Pure plan for one multi-line panel redraw.
--
-- Invariant after emit: cursor sits just below the current content band, and
-- 'dpStore' equals the logical content line count (tight dynamic height).
data DrawPlan = DrawPlan
  { -- | Cursor-up distance to the panel origin before rewriting.
    dpMoveUp :: Int,
    -- | Logical content lines for this frame.
    dpContentLines :: [String],
    -- | Blank clear-to-EOL lines needed when the previous band was taller.
    dpClearExtra :: Int,
    -- | Cursor-up after clear-extra so the cursor ends just below content.
    dpMoveBack :: Int,
    -- | Owned height to store for the next redraw or 'clearLines'.
    dpStore :: Int
  }
  deriving (Eq, Show)

-- | Plan a redraw from the previous owned height and the new frame string.
planDraw :: Int -> String -> DrawPlan
planDraw prevLineCount frame =
  let contentLines = lines frame
      n = length contentLines
      clearExtra = max 0 (prevLineCount - n)
   in DrawPlan
        { dpMoveUp = prevLineCount,
          dpContentLines = contentLines,
          dpClearExtra = clearExtra,
          dpMoveBack = clearExtra,
          dpStore = n
        }

-- | Emit ANSI for one frame from 'planDraw'; returns the store count.
drawFrame :: Handle -> Int -> String -> IO Int
drawFrame h prevLineCount frame = do
  let DrawPlan {..} = planDraw prevLineCount frame
      moveUp =
        if dpMoveUp > 0
          then "\ESC[" <> show dpMoveUp <> "A\r"
          else ""
      body =
        concatMap (<> "\ESC[K\n") dpContentLines
          <> concat (replicate dpClearExtra "\ESC[K\n")
      moveBack =
        if dpMoveBack > 0
          then "\ESC[" <> show dpMoveBack <> "A\r"
          else ""
  hPutStr h (moveUp <> body <> moveBack)
  hFlush h
  pure dpStore

clearLines :: Handle -> Int -> IO ()
clearLines h n = when (n > 0) $ do
  let moveUp = "\ESC[" <> show n <> "A\r"
      clear = concat (replicate n "\ESC[K\n")
  hPutStr h (moveUp <> clear)
  hPutStr h ("\ESC[" <> show n <> "A\r")
  hFlush h

------------------------------------------------------------------------
-- Metrics spans derived from progress (design D3)
------------------------------------------------------------------------

-- | Open package span and its current step span.
data PackageSpans = PackageSpans
  { psPackage :: SpanId,
    psStep :: Maybe SpanId
  }

-- | Wrap a multi handle so every visible package transition is a span.
--
-- @start@ opens a @package@ span; @step@, @status@, and @wait@ close the
-- previous @step@ span and open the next; @success@, @skip@, and @fail@
-- close the open step and the package span with that outcome. Spans still
-- open when @action@ ends are closed (@fail@ when it threw).
instrumentMultiHandle ::
  Metrics ->
  Text ->
  MultiHandle ->
  (MultiHandle -> IO a) ->
  IO a
instrumentMultiHandle m label inner action
  | not (mEnabled m) = action inner {mhMetrics = m}
  | otherwise = do
      spansRef <- newIORef (Map.empty :: Map PackageKey PackageSpans)
      let pkgAttrs key = ["package" .= packageKeyText key]
          closeStep outcome ps =
            for_ (psStep ps) $ \sid -> mSpanEnd m sid outcome []
          finish key outcome attrs = do
            mPs <- atomicModifyIORef' spansRef $ \mp ->
              (Map.delete key mp, Map.lookup key mp)
            for_ mPs $ \ps -> do
              closeStep outcome ps
              mSpanEnd m (psPackage ps) outcome attrs
          nextStep key name extra = do
            mPs <- Map.lookup key <$> readIORef spansRef
            for_ mPs $ \ps -> do
              closeStep OutcomeOk ps
              sid <- mSpanStart m "step" (pkgAttrs key <> ["step" .= name] <> extra)
              atomicModifyIORef' spansRef $ \mp ->
                (Map.adjust (\p -> p {psStep = Just sid}) key mp, ())
          closeAll outcome = do
            open <- atomicModifyIORef' spansRef (Map.empty,)
            for_ open $ \ps -> do
              closeStep outcome ps
              mSpanEnd m (psPackage ps) outcome []
          handle =
            inner
              { mhStart = \key -> do
                  mhStart inner key
                  finish key OutcomeOk []
                  sid <- mSpanStart m "package" (pkgAttrs key <> ["panel" .= label])
                  atomicModifyIORef' spansRef $ \mp ->
                    (Map.insert key (PackageSpans sid Nothing) mp, ()),
                mhWait = \key reason -> do
                  mhWait inner key reason
                  nextStep key reason ["wait" .= True],
                mhStatus = \key name -> do
                  mhStatus inner key name
                  nextStep key name [],
                mhStep = \key name -> do
                  mhStep inner key name
                  nextStep key name [],
                mhSuccess = \key -> do
                  mhSuccess inner key
                  finish key OutcomeOk [],
                mhSkip = \key reason -> do
                  mhSkip inner key reason
                  finish key OutcomeSkip ["reason" .= reason],
                mhFail = \key reason -> do
                  mhFail inner key reason
                  finish key OutcomeFail ["reason" .= reason],
                mhMetrics = m
              }
      r <- action handle `onException` closeAll OutcomeFail
      closeAll OutcomeOk
      pure r

-- | Wrap a step bar: one @steps@ span for the bar and one @step@ child span
-- per 'shStep'.
instrumentStepHandle :: Metrics -> StepHandle -> (StepHandle -> IO a) -> IO a
instrumentStepHandle m inner action
  | not (mEnabled m) = action inner
  | otherwise = do
      current <- newIORef Nothing
      let closeCurrent outcome = do
            open <- atomicModifyIORef' current (Nothing,)
            for_ open $ \sid -> mSpanEnd m sid outcome []
          handle =
            StepHandle
              { shStep = \desc -> do
                  shStep inner desc
                  closeCurrent OutcomeOk
                  sid <- mSpanStart m "step" ["step" .= desc]
                  writeIORef current (Just sid)
              }
      withSpan m "steps" [] $ do
        r <- action handle `onException` closeCurrent OutcomeFail
        closeCurrent OutcomeOk
        pure r
