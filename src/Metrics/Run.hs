{-# LANGUAGE OverloadedStrings #-}

-- | One recorded run: open @run.jsonl@, write the header, run the command
-- under the @command@ root span, and write the footer on every exit path
-- (design D11).
module Metrics.Run
  ( RunSetup (..),
    withRunMetrics,
    invocationFor,
  )
where

import Build.Info (buildInfo, exeSha256)
import CLI.Parser (Command (..))
import Control.Exception (IOException, SomeException, bracket, mask, onException, throwIO, try)
import Control.Monad (void)
import Data.Aeson ((.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.LocalTime (getZonedTime)
import GHC.Conc (getNumCapabilities)
import Metrics.Core (Metrics (..), Outcome (..), noopMetrics, withSpan)
import Metrics.Recorder
  ( HeaderInputs (..),
    Invocation (..),
    Recorder,
    closeRecorderPhase,
    finishRecorder,
    openRecorder,
    readHostFacts,
    recMetrics,
    writeRunHeader,
  )
import Metrics.Startup (gnuTimePath)
import Metrics.Writer (handleSink, newWriter)
import System.Directory (makeAbsolute)
import System.FilePath ((</>))
import System.IO (IOMode (AppendMode), openBinaryFile)

-- | Everything 'withRunMetrics' needs beyond the command body.
data RunSetup = RunSetup
  { rsRunDir :: FilePath,
    rsRunId :: String,
    rsCommand :: Text,
    rsTimeVersion :: Text,
    rsInvocation :: Invocation,
    -- | Log a warning (write failures; at most one per run).
    rsWarn :: Text -> IO (),
    -- | Started after the header with the run's recorder; the returned action
    -- stops it and is run before the footer.
    rsStartSampler :: Recorder -> IO (IO ())
  }

-- | Record one run around @body@. The body's result or exception is passed
-- through unchanged.
withRunMetrics :: RunSetup -> (Metrics -> IO a) -> IO a
withRunMetrics rs0 body = do
  -- Absolute so GNU time @-o@ paths and container bind mounts resolve anywhere.
  runDir <- makeAbsolute (rsRunDir rs0)
  let rs = rs0 {rsRunDir = runDir}
  -- Masked until the body: an interrupt during setup is delivered once the
  -- header is written, inside the 'try', so the footer is never skipped.
  mask $ \restore -> do
    opened <- try @IOException (openBinaryFile (rsRunDir rs </> "run.jsonl") AppendMode)
    case opened of
      Left e -> do
        rsWarn rs ("metrics recording stopped: " <> T.pack (show e))
        restore (body noopMetrics)
      Right h -> do
        writer <- newWriter (rsWarn rs) (handleSink h)
        rec <- openRecorder writer (rsRunDir rs </> "time")
        startedAt <- getZonedTime
        exeHash <- exeSha256
        host <- readHostFacts "/proc"
        caps <- getNumCapabilities
        writeRunHeader
          rec
          HeaderInputs
            { hiRunId = T.pack (rsRunId rs),
              hiCommand = rsCommand rs,
              hiStartedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Ez" startedAt),
              hiBuild = buildInfo,
              hiExeSha256 = exeHash,
              hiHost = host,
              hiInvocation = rsInvocation rs,
              hiTimePath = T.pack gnuTimePath,
              hiTimeVersion = rsTimeVersion rs,
              hiCapabilities = caps
            }
        let m = recMetrics rec
        result <-
          try @SomeException . restore $
            bracket (rsStartSampler rs rec) id $ \_ ->
              withSpan m "command" ["command" .= rsCommand rs] $ do
                r <- body m `onException` closeRecorderPhase rec OutcomeFail
                closeRecorderPhase rec OutcomeOk
                pure r
        finishRecorder rec (void result)
        either throwIO pure result

-- | Header invocation for a parsed command and resolved @--jobs@.
invocationFor :: Int -> Command -> Invocation
invocationFor jobs cmd =
  case cmd of
    Outdated refresh targets excludes -> inv (Just refresh) targets excludes
    Update refresh targets excludes -> inv (Just refresh) targets excludes
    Gencache targets _ excludes -> inv Nothing targets excludes
    Eclean -> inv Nothing [] []
    List -> inv Nothing [] []
    GitHubToken _ -> inv Nothing [] []
  where
    inv refresh targets excludes =
      Invocation
        { invJobs = jobs,
          invRefresh = refresh,
          invTargets = map T.pack targets,
          invExcludes = map T.pack excludes
        }
