{-# LANGUAGE OverloadedStrings #-}

-- | Run metrics startup gate (design D11): decide whether this invocation
-- records, check GNU time, and create the run directory before config load.
module Metrics.Startup
  ( MetricsStartupOps (..),
    MetricsStart (..),
    productionMetricsStartupOps,
    metricsGate,
    metricsCommandName,
    commandName,
    stateHomeFrom,
    metricsRunDir,
    gnuTimePath,
  )
where

import CLI.Parser (Command (..))
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | Host GNU time used to wrap subprocesses.
gnuTimePath :: FilePath
gnuTimePath = "/usr/bin/time"

-- | Injectable startup effects (tests use fakes).
data MetricsStartupOps = MetricsStartupOps
  { -- | Output of @/usr/bin/time --version@, or why it could not run.
    msoTimeVersion :: IO (Either Text Text),
    -- | Environment lookup for @XDG_STATE_HOME@ and @HOME@.
    msoLookupEnv :: String -> IO (Maybe String),
    -- | Create the run directory (and its @time/@) and prove it is writable.
    msoCreateRunDir :: FilePath -> IO (Either Text ())
  }

-- | Gate result for an invocation.
data MetricsStart
  = -- | This invocation does not record.
    MetricsOff
  | -- | Record into this run directory; GNU time reported this version.
    MetricsOn
      { msRunDir :: FilePath,
        msTimeVersion :: Text
      }
  deriving (Eq, Show)

productionMetricsStartupOps :: MetricsStartupOps
productionMetricsStartupOps =
  MetricsStartupOps
    { msoTimeVersion = do
        r <- try @IOException (readProcessWithExitCode gnuTimePath ["--version"] "")
        pure $ case r of
          Left e -> Left (T.pack (show e))
          Right (ExitSuccess, out, err) -> Right (T.pack (out <> err))
          Right (ExitFailure n, _, err) ->
            Left ("exit " <> T.pack (show n) <> ": " <> T.strip (T.pack err)),
      msoLookupEnv = lookupEnv,
      msoCreateRunDir = \dir -> do
        r <- try @IOException $ do
          createDirectoryIfMissing True (dir </> "time")
          let probe = dir </> ".write-probe"
          writeFile probe ""
          removeFile probe
        pure (either (Left . T.pack . show) Right r)
    }

-- | Subcommand name as typed.
commandName :: Command -> Text
commandName = \case
  List -> "list"
  Outdated {} -> "outdated"
  Update {} -> "update"
  Gencache {} -> "gencache"
  Eclean -> "eclean"
  GitHubToken {} -> "github-token"

-- | Work commands record runs; @list@ and @github-token@ never do.
metricsCommandName :: Command -> Maybe Text
metricsCommandName cmd = case cmd of
  Outdated {} -> Just (commandName cmd)
  Update {} -> Just (commandName cmd)
  Gencache {} -> Just (commandName cmd)
  Eclean -> Just (commandName cmd)
  List -> Nothing
  GitHubToken {} -> Nothing

-- | @XDG_STATE_HOME@ when set and non-empty, else @$HOME/.local/state@.
stateHomeFrom :: Maybe String -> Maybe String -> Maybe FilePath
stateHomeFrom xdg home = case xdg of
  Just s | not (null s) -> Just s
  _ -> case home of
    Just h | not (null h) -> Just (h </> ".local" </> "state")
    _ -> Nothing

-- | @\<state\>/mndz/overlay-manager/metrics/\<run-id\>-\<command\>@
metricsRunDir :: FilePath -> String -> Text -> FilePath
metricsRunDir stateHome runId cmd =
  stateHome
    </> "mndz"
    </> "overlay-manager"
    </> "metrics"
    </> (runId <> "-" <> T.unpack cmd)

-- | Decide whether this invocation records, logging warnings via @warn@.
--
-- 'Left' is an error naming the tool or path and @--no-metrics@; the caller
-- exits 1. With @--no-metrics@ no startup effect runs.
metricsGate ::
  MetricsStartupOps ->
  (Text -> IO ()) ->
  Bool ->
  Command ->
  String ->
  IO (Either Text MetricsStart)
metricsGate ops warn noMetrics cmd runId =
  case metricsCommandName cmd of
    Nothing -> do
      when noMetrics $
        warn
          ( "metrics are not collected for "
              <> commandName cmd
              <> "; --no-metrics has no effect"
          )
      pure (Right MetricsOff)
    Just name
      | noMetrics -> do
          warn "metrics disabled by --no-metrics"
          pure (Right MetricsOff)
      | otherwise -> do
          tv <- msoTimeVersion ops
          case tv of
            Left err ->
              pure . Left $
                "run metrics need GNU time at "
                  <> T.pack gnuTimePath
                  <> " ("
                  <> T.strip err
                  <> "); install sys-process/time or pass --no-metrics"
            Right out
              | not ("GNU Time" `T.isInfixOf` out) ->
                  pure . Left $
                    T.pack gnuTimePath
                      <> " is not GNU Time; run metrics need GNU time \
                         \(install sys-process/time) or pass --no-metrics"
              | otherwise -> do
                  xdg <- msoLookupEnv ops "XDG_STATE_HOME"
                  home <- msoLookupEnv ops "HOME"
                  case stateHomeFrom xdg home of
                    Nothing ->
                      pure . Left $
                        "run metrics need XDG_STATE_HOME or HOME to locate the \
                        \metrics directory; set one or pass --no-metrics"
                    Just stateHome -> do
                      let dir = metricsRunDir stateHome runId name
                      created <- msoCreateRunDir ops dir
                      pure $ case created of
                        Left err ->
                          Left $
                            "cannot create run metrics directory "
                              <> T.pack dir
                              <> " ("
                              <> err
                              <> "); fix permissions or pass --no-metrics"
                        Right () ->
                          Right
                            MetricsOn
                              { msRunDir = dir,
                                msTimeVersion = firstLine out
                              }
  where
    firstLine = T.strip . T.takeWhile (/= '\n')
