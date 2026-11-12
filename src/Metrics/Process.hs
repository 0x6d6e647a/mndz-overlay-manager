{-# LANGUAGE OverloadedStrings #-}

-- | Subprocess measurement with GNU time (design D5, D6).
--
-- 'timedRunner' wraps a 'CommandRunner': each 'Timed' request runs as
-- @/usr/bin/time -o \<file\> --quiet -f \<fmt\> -- cmd args…@ inside a @proc@
-- span, and the time file is read into the span and deleted.
--
-- GNU time does not forward SIGTERM, so cancelling the wrapped request would
-- leave the command running. Each wrapped request therefore carries a unique
-- 'requestMarkerVar' in its environment, and an interrupted request terminates
-- every process still carrying its marker.
module Metrics.Process
  ( timedRunner,
    requestMarkerVar,
    timeFormat,
    timeWrapArgs,
    timeFileName,
    ingestTimeFile,
    procStartAttrs,
    procEndAttrs,
    wallClockProc,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, mask, throwIO, try)
import Control.Monad (filterM, forM_, unless, void, when)
import Data.Aeson (Value (..), decodeStrict, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isAlphaNum)
import Data.Either (fromRight)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Metrics.Core (Attrs, Metrics (..), Outcome (..), SpanId (..), trySync)
import Metrics.Startup (gnuTimePath)
import System.Directory
  ( doesFileExist,
    findExecutable,
    findExecutablesInDirectories,
    listDirectory,
    removeFile,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, splitSearchPath, takeFileName, (</>))
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Posix.Types (CPid (..))
import Text.Read (readMaybe)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )

-- | GNU time @-f@ format writing one JSON object (see design D5 for omitted
-- fields). @%P@ stays a string: it prints @?@ when elapsed time is zero.
timeFormat :: String
timeFormat =
  "{\"wall_s\":%e,\"user_s\":%U,\"sys_s\":%S,\"cpu_pct\":\"%P\",\"max_rss_kb\":%M,\
  \\"major_faults\":%F,\"minor_faults\":%R,\"swaps\":%W,\"invol_ctx\":%c,\
  \\"vol_ctx\":%w,\"fs_in\":%I,\"fs_out\":%O,\"exit\":%x}"

-- | @/usr/bin/time -o file --quiet -f fmt -- argv…@
timeWrapArgs :: FilePath -> [String] -> (FilePath, [String])
timeWrapArgs file argv =
  (gnuTimePath, ["-o", file, "--quiet", "-f", timeFormat, "--"] <> argv)

-- | @\<span-id\>-\<slug\>\<suffix\>.json@; the slug names the package (when
-- known) and the command basename.
timeFileName :: SpanId -> Maybe Text -> String -> String -> FilePath
timeFileName (SpanId sid) pkg cmd suffix =
  show sid <> "-" <> slug <> suffix <> ".json"
  where
    slug =
      map safe $
        maybe "" (\p -> T.unpack (T.replace "/" "_" p) <> "-") pkg
          <> takeFileName cmd
    safe c
      | isAlphaNum c || c `elem` ("._-" :: String) = c
      | otherwise = '_'

-- | Read a time file into span attributes. A parsed file is deleted and
-- yields @time@; otherwise the file is kept and @time_parse_error@ is set.
ingestTimeFile :: FilePath -> IO Attrs
ingestTimeFile path = do
  r <- trySync (BS.readFile path)
  case r of
    Left e -> pure ["time_parse_error" .= ("unreadable: " <> T.pack (show e))]
    Right bytes -> case decodeStrict bytes of
      Just o@(Object _) -> do
        _ <- trySync (removeFile path)
        pure ["time" .= o]
      _ ->
        pure
          [ "time_parse_error"
              .= ( if BS.null bytes
                     then "empty time file" :: Text
                     else "malformed time file"
                 )
          ]

-- | Start attributes of a @proc@ span: basename, redacted args, cwd, package.
procStartAttrs :: Metrics -> FilePath -> [String] -> Maybe FilePath -> IO Attrs
procStartAttrs m cmd args cwd = do
  redact <- mRedactor m
  pkg <- mCurrentPackage m
  pure $
    [ "cmd" .= T.pack (takeFileName cmd),
      "args" .= map (redact . T.pack) args
    ]
      <> maybe [] (\d -> ["cwd" .= d]) cwd
      <> maybe [] (\p -> ["package" .= p]) pkg

-- | End attributes from a captured result.
procEndAttrs :: ProcessResult -> Attrs
procEndAttrs res =
  [ "exit" .= exitInt (prExitCode res),
    "stdout_bytes" .= utf8Len (prStdout res),
    "stderr_bytes" .= utf8Len (prStderr res)
  ]
  where
    utf8Len = BS.length . TE.encodeUtf8 . T.pack

exitInt :: ExitCode -> Int
exitInt = \case
  ExitSuccess -> 0
  ExitFailure n -> n

outcomeOf :: ExitCode -> Outcome
outcomeOf = \case
  ExitSuccess -> OutcomeOk
  ExitFailure _ -> OutcomeFail

-- | Decorate a runner with GNU time measurement when recording.
--
-- 'Lifecycle' and 'Untimed' requests pass through. A command that cannot
-- be resolved runs unwrapped so its failure is the same as without metrics.
timedRunner :: Metrics -> CommandRunner -> CommandRunner
timedRunner m inner req =
  case (mEnabled m, mTimeDir m, prMeasure req) of
    (True, Just dir, Timed) -> measured dir "" []
    (True, Just dir, TimedInteractive) -> measured dir "" ["interactive" .= True]
    (True, Just dir, TimedContainerExec) -> measured dir ".outer" []
    _ -> inner req
  where
    (cmd, args) = case prMode req of
      ExecCmd c as -> (c, as)
      ShellCmd s -> ("/bin/sh", ["-c", s])
    measured dir suffix extra = do
      startAttrs <- (<> extra) <$> procStartAttrs m cmd args (prCwd req)
      found <- resolvable req
      mask $ \restore -> do
        sid <- mSpanStart m "proc" startAttrs
        pkg <- mCurrentPackage m
        let file = dir </> timeFileName sid pkg cmd suffix
            (timeCmd, timeArgs) = timeWrapArgs file (cmd : args)
            marker = takeFileName file
        baseEnv <- maybe getEnvironment pure (prEnv req)
        let wrapped =
              req
                { prMode = ExecCmd timeCmd timeArgs,
                  prEnv = Just ((requestMarkerVar, marker) : baseEnv)
                }
        r <-
          try @SomeException . restore $
            if found then inner wrapped else inner req
        case r of
          Left e -> do
            -- Cancelling the request kills GNU time but not its command.
            when found (reapMarked marker)
            mSpanEnd m sid OutcomeFail ["error" .= T.pack (show e)]
            throwIO e
          Right res -> do
            timeAttrs <-
              if found
                then ingestTimeFile file
                else pure ["unwrapped" .= ("command not found" :: Text)]
            mSpanEnd m sid (outcomeOf (prExitCode res)) (procEndAttrs res <> timeAttrs)
            pure res

-- | Environment variable naming the wrapped request a process belongs to.
requestMarkerVar :: String
requestMarkerVar = "MNDZ_TIMED_REQUEST"

procRoot :: FilePath
procRoot = "/proc"

-- | Terminate every other process whose environment carries @marker@:
-- @SIGTERM@, then @SIGKILL@ for those still alive after a short grace period.
-- Best effort: a process that clears its environment is not found.
reapMarked :: String -> IO ()
reapMarked marker = do
  self <- getProcessID
  pids <- markedProcesses procRoot marker
  let targets = filter (/= self) pids
  forM_ targets (signalQuietly sigTERM)
  unless (null targets) $ do
    survivors <- waitGone (20 :: Int) targets
    forM_ survivors (signalQuietly sigKILL)
  where
    waitGone 0 ps = alive ps
    waitGone n ps = do
      left <- alive ps
      if null left
        then pure []
        else threadDelay 50000 *> waitGone (n - 1) left
    alive = filterM (\p -> (p `elem`) <$> markedProcesses procRoot marker)
    signalQuietly sig p = void (trySync (signalProcess sig p))

-- | Processes (by pid) whose initial environment has the request marker.
markedProcesses :: FilePath -> String -> IO [CPid]
markedProcesses root marker = do
  entries <- fromRight [] <$> trySync (listDirectory root)
  let needle = TE.encodeUtf8 (T.pack (requestMarkerVar <> "=" <> marker))
  fmap concat . mapM (check needle) $ mapMaybe readMaybe entries
  where
    check needle pid = do
      r <- trySync (BS.readFile (root </> show (pid :: Int) </> "environ"))
      pure $ case r of
        Right bytes | needle `elem` BS8.split '\0' bytes -> [CPid (fromIntegral pid)]
        _ -> []

-- | Whether GNU time could exec the request's command.
resolvable :: ProcessRequest -> IO Bool
resolvable req = case prMode req of
  ShellCmd _ -> pure True
  ExecCmd c _
    | '/' `elem` c ->
        doesFileExist (if isAbsolute c then c else fromMaybe "." (prCwd req) </> c)
    | otherwise -> case prEnv req >>= lookup "PATH" of
        Just path -> not . null <$> findExecutablesInDirectories (splitSearchPath path) c
        Nothing -> isJust <$> findExecutable c

-- | Wall-clock @proc@ span (no @time@ object) around a subprocess the shared
-- runner does not start. @extra@ adds attributes such as @interactive@.
wallClockProc ::
  Metrics ->
  FilePath ->
  [String] ->
  Maybe FilePath ->
  Attrs ->
  (a -> Maybe ExitCode) ->
  IO a ->
  IO a
wallClockProc m cmd args cwd extra exitOf action
  | not (mEnabled m) = action
  | otherwise = do
      startAttrs <- procStartAttrs m cmd args cwd
      mask $ \restore -> do
        sid <- mSpanStart m "proc" (startAttrs <> extra)
        r <- try @SomeException (restore action)
        case r of
          Left e -> do
            mSpanEnd m sid OutcomeFail ["error" .= T.pack (show e)]
            throwIO e
          Right a -> do
            let (outcome, endAttrs) = case exitOf a of
                  Just code -> (outcomeOf code, ["exit" .= exitInt code])
                  Nothing -> (OutcomeOk, [])
            mSpanEnd m sid outcome endAttrs
            pure a
