{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Logging.Bootstrap
  ( ColorMode (..),
    LogHold,
    mkLogger,
    mkLogHold,
    beginLogHold,
    flushLogHold,
    verbosityToSeverity,
    fmtMessageColored,
    showSeverityColored,
  )
where

import CLI.Parser (ColorMode (..), Verbosity)
import CLI.Parser qualified as V
import Colog
  ( LogAction (..),
    Message,
    Msg (..),
    Severity,
    cmap,
    filterBySeverity,
    logTextStderr,
    msgSeverity,
    showSourceLoc,
  )
import Colog qualified as C
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Console.ANSI
  ( Color (..),
    ColorIntensity (Vivid),
    ConsoleLayer (Foreground),
    SGR (..),
    setSGRCode,
  )

-- | Hold state for deferring log emission while activity panels are active.
data LogHold = LogHold
  { lhHolding :: IORef Bool,
    lhQueue :: MVar [Message]
  }

-- | Create an empty log-hold for optional queuing.
mkLogHold :: IO LogHold
mkLogHold = LogHold <$> newIORef False <*> newMVar []

-- | Start queuing messages instead of writing them.
beginLogHold :: LogHold -> IO ()
beginLogHold hold = writeIORef (lhHolding hold) True

-- | Stop holding and emit queued messages in order through the given action.
flushLogHold :: LogHold -> LogAction IO Message -> IO ()
flushLogHold hold (LogAction emit) = do
  writeIORef (lhHolding hold) False
  msgs <-
    modifyMVar (lhQueue hold) $ \q ->
      pure ([], reverse q)
  mapM_ emit msgs

-- | Map CLI verbosity to co-log minimum severity.
verbosityToSeverity :: Verbosity -> Severity
verbosityToSeverity = \case
  V.Error -> C.Error
  V.Warn -> C.Warning
  V.Info -> C.Info
  V.Debug -> C.Debug

-- | Custom severity tag colors: Info green, Warning yellow, Error red, Debug magenta.
showSeverityColored :: ColorMode -> Severity -> Text
showSeverityColored mode = \case
  C.Debug -> paint mode Magenta "[Debug]   "
  C.Info -> paint mode Green "[Info]    "
  C.Warning -> paint mode Yellow "[Warning] "
  C.Error -> paint mode Red "[Error]   "

paint :: ColorMode -> Color -> Text -> Text
paint ColorOff _ t = t
paint ColorOn c t =
  T.pack (setSGRCode [SetColor Foreground Vivid c])
    <> t
    <> T.pack (setSGRCode [Reset])

-- | Format a message with custom severity palette (and source location).
fmtMessageColored :: ColorMode -> Message -> Text
fmtMessageColored mode Msg {..} =
  showSeverityColored mode msgSeverity
    <> showSourceLoc msgStack
    <> msgText

-- | Build a filtered, colored logger with optional hold/queue support.
mkLogger :: Verbosity -> ColorMode -> LogHold -> LogAction IO Message
mkLogger verbosity color hold =
  filterBySeverity (verbosityToSeverity verbosity) msgSeverity $
    LogAction $ \msg -> do
      holding <- readIORef (lhHolding hold)
      if holding
        then modifyMVar_ (lhQueue hold) (\q -> pure (msg : q))
        else unLogAction sink msg
  where
    sink = cmap (fmtMessageColored color) logTextStderr
