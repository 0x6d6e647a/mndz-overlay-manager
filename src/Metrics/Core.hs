{-# LANGUAGE OverloadedStrings #-}

-- | Run metrics recorder interface (design D1).
--
-- One 'Metrics' value per run travels in 'CLI.Progress.ProgressConfig'.
-- 'noopMetrics' is used when recording is off and by tests; every operation
-- does nothing. The recording instance lives in "Metrics.Recorder".
module Metrics.Core
  ( Metrics (..),
    SpanId (..),
    Outcome (..),
    Attrs,
    noopMetrics,
    outcomeText,
    withSpan,
    withSpanResult,
    captureSpanContext,
    redactArgs,
    setCount,
    openLifecycleSpan,
    trySync,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, mask, throwIO, try)
import Data.Aeson (Value (..), (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)

-- | Span id, unique within a run and increasing in start order.
newtype SpanId = SpanId Int
  deriving (Eq, Ord, Show)

-- | How a span ended.
data Outcome
  = OutcomeOk
  | OutcomeSkip
  | OutcomeFail
  deriving (Eq, Show)

-- | Span or event attributes, in emit order.
type Attrs = [Pair]

outcomeText :: Outcome -> Text
outcomeText = \case
  OutcomeOk -> "ok"
  OutcomeSkip -> "skip"
  OutcomeFail -> "fail"

-- | Recorder operations for one run.
data Metrics = Metrics
  { -- | True when this run writes @run.jsonl@.
    mEnabled :: Bool,
    -- | Open a span. Its parent is the calling thread's current span.
    mSpanStart :: Text -> Attrs -> IO SpanId,
    -- | Open a span under the calling thread's current span without making
    -- it the parent of later spans (long-lived process lifecycles).
    mSpanStartDetached :: Text -> Attrs -> IO SpanId,
    -- | Close a span opened by 'mSpanStart' (any thread).
    mSpanEnd :: SpanId -> Outcome -> Attrs -> IO (),
    -- | The calling thread's innermost open span.
    mCurrentSpan :: IO (Maybe SpanId),
    -- | Nearest enclosing open span's @package@ attribute (across forks).
    mCurrentPackage :: IO (Maybe Text),
    -- | Close the open command phase (if any) and open @phase.\<name\>@ on
    -- the calling thread. Phases are sequential children of the command span.
    mEnterPhase :: Text -> IO (),
    -- | Run an action on the calling thread with @parent@ as the base of its
    -- span stack (fork points: the child inherits the caller's span).
    mWithParent :: forall a. Maybe SpanId -> IO a -> IO a,
    -- | Add to a numeric footer counter.
    mBump :: Text -> Integer -> IO (),
    -- | Set a footer counter to a value (last write wins).
    mSetCounter :: Text -> Value -> IO (),
    -- | Write a non-span event line (@sample@, @container@).
    mEvent :: Text -> Attrs -> IO (),
    -- | Per-process GNU time files (@\<run-dir\>/time@) when recording.
    mTimeDir :: Maybe FilePath,
    -- | Register a secret value to redact from recorded arguments.
    mAddSecret :: Text -> IO (),
    -- | Current redaction (replace every known secret with @\<redacted\>@).
    mRedactor :: IO (Text -> Text),
    -- | Register a materialize container cgroup path for process sampling.
    mRegisterCgroup :: Text -> IO ()
  }

-- | Recording off: every operation is a no-op.
noopMetrics :: Metrics
noopMetrics =
  Metrics
    { mEnabled = False,
      mSpanStart = \_ _ -> pure (SpanId 0),
      mSpanStartDetached = \_ _ -> pure (SpanId 0),
      mSpanEnd = \_ _ _ -> pure (),
      mCurrentSpan = pure Nothing,
      mCurrentPackage = pure Nothing,
      mEnterPhase = \_ -> pure (),
      mWithParent = \_ act -> act,
      mBump = \_ _ -> pure (),
      mSetCounter = \_ _ -> pure (),
      mEvent = \_ _ -> pure (),
      mTimeDir = Nothing,
      mAddSecret = \_ -> pure (),
      mRedactor = pure id,
      mRegisterCgroup = \_ -> pure ()
    }

-- | Span around an action. Outcome @ok@ on return, @fail@ on an exception
-- (rethrown).
withSpan :: Metrics -> Text -> Attrs -> IO a -> IO a
withSpan m name attrs = withSpanResult m name attrs (const (OutcomeOk, []))

-- | Span whose outcome and end attributes come from the result.
withSpanResult ::
  Metrics ->
  Text ->
  Attrs ->
  (a -> (Outcome, Attrs)) ->
  IO a ->
  IO a
withSpanResult m name attrs classify action
  | not (mEnabled m) = action
  | otherwise = mask $ \restore -> do
      sid <- mSpanStart m name attrs
      r <- try @SomeException (restore action)
      case r of
        Left e -> do
          mSpanEnd m sid OutcomeFail []
          throwIO e
        Right a -> do
          let (outcome, endAttrs) = classify a
          mSpanEnd m sid outcome endAttrs
          pure a

-- | Catch synchronous exceptions only. Asynchronous ones (Ctrl-C's
-- 'Control.Exception.UserInterrupt', 'Control.Concurrent.Async.cancel')
-- are rethrown so best-effort recording never swallows them.
trySync :: IO a -> IO (Either SomeException a)
trySync act = do
  r <- try act
  case r of
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    _ -> pure r

-- | Capture the calling thread's span so a forked child can inherit it.
--
-- Use at fork points: @inherit <- captureSpanContext m@, then run each child
-- body as @inherit body@ on the child thread.
captureSpanContext :: Metrics -> IO (IO a -> IO a)
captureSpanContext m = do
  parent <- mCurrentSpan m
  pure (mWithParent m parent)

-- | @lifecycle@ span for a long-lived process (never GNU-time wrapped):
-- opened now, detached from the thread's span stack, and closed by the
-- returned action when the process stops.
openLifecycleSpan :: Metrics -> Text -> IO (Outcome -> IO ())
openLifecycleSpan m process
  | not (mEnabled m) = pure (\_ -> pure ())
  | otherwise = do
      sid <- mSpanStartDetached m "lifecycle" ["process" .= process]
      pure (\outcome -> mSpanEnd m sid outcome [])

-- | Set an integer footer counter.
setCount :: Metrics -> Text -> Int -> IO ()
setCount m key n = mSetCounter m key (Number (fromIntegral n))

-- | Redact known secrets from an argument list.
redactArgs :: Metrics -> [Text] -> IO [Text]
redactArgs m args = do
  redact <- mRedactor m
  pure (map redact args)
