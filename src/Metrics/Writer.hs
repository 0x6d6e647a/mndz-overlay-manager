{-# LANGUAGE OverloadedStrings #-}

-- | Single-writer JSON Lines sink for @run.jsonl@ (design D4).
--
-- Callers encode each event on their own thread and push the line to a
-- 'Chan'. One writer thread appends and flushes. On the first
-- 'IOException' the writer degrades: later lines are dropped and one
-- warning is logged. A failure to record never reaches the caller.
module Metrics.Writer
  ( LineSink (..),
    Writer,
    handleSink,
    newWriter,
    writeLine,
    encodeLine,
    closeWriter,
    writerDegraded,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, evaluate, finally, try)
import Control.Monad (unless, void)
import Data.Aeson.Encoding (encodingToLazyByteString, pairs)
import Data.Aeson.Types (Pair, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (Handle, hClose, hFlush)

-- | Where encoded lines go (a file handle in production, a fake in tests).
data LineSink = LineSink
  { sinkWrite :: BS.ByteString -> IO (),
    sinkClose :: IO ()
  }

-- | Append-and-flush sink over an open handle.
handleSink :: Handle -> LineSink
handleSink h =
  LineSink
    { sinkWrite = \line -> BS.hPut h line >> hFlush h,
      sinkClose = hClose h
    }

data Writer = Writer
  { wChan :: Chan (Maybe BS.ByteString),
    wDegraded :: IORef Bool,
    wDone :: MVar ()
  }

-- | Start the writer thread. @warn@ is called once, on the first write failure.
newWriter :: (Text -> IO ()) -> LineSink -> IO Writer
newWriter warn sink = do
  chan <- newChan
  degraded <- newIORef False
  done <- newEmptyMVar
  let loop = do
        next <- readChan chan
        case next of
          Nothing -> pure ()
          Just line -> do
            isDegraded <- readIORef degraded
            unless isDegraded $ do
              r <- try @IOException (sinkWrite sink line)
              case r of
                Right () -> pure ()
                Left e -> do
                  wasDegraded <- atomicModifyIORef' degraded (True,)
                  unless wasDegraded $
                    warn ("metrics recording stopped: " <> T.pack (show e))
            loop
      closeSink = void (try @IOException (sinkClose sink))
  _ <- forkIO ((loop `finally` closeSink) `finally` putMVar done ())
  pure Writer {wChan = chan, wDegraded = degraded, wDone = done}

-- | Encode one event object as a JSON line (keys in the given order).
encodeLine :: [Pair] -> BS.ByteString
encodeLine kvs =
  BL.toStrict (encodingToLazyByteString (pairs (foldMap (uncurry (.=)) kvs)))
    <> BS8.singleton '\n'

-- | Encode on the calling thread, then queue for the writer.
writeLine :: Writer -> [Pair] -> IO ()
writeLine w kvs = do
  isDegraded <- readIORef (wDegraded w)
  unless isDegraded $ do
    line <- evaluate (encodeLine kvs)
    writeChan (wChan w) (Just line)

-- | Drain queued lines, stop the writer thread, and close the sink.
closeWriter :: Writer -> IO ()
closeWriter w = do
  writeChan (wChan w) Nothing
  takeMVar (wDone w)

-- | True once a write has failed.
writerDegraded :: Writer -> IO Bool
writerDegraded = readIORef . wDegraded
