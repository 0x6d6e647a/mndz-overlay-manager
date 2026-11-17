{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Orchestration of a @smoke@ command after planning: leftover sweep, smoke
-- image, tree snapshot (then the tree lock is released), sandbox probe,
-- compile cache preparation, the runs one at a time, result lines, and the
-- summary. Every effect is a field
-- of 'SmokeOps', so the pipeline runs over fakes in tests.
module Smoke.Run
  ( -- * Selection
    missingDefinitions,

    -- * Pipeline
    SmokeOps (..),
    SmokeSummary (..),
    runSmoke,
    resultLine,
    summaryLines,

    -- * Logs
    smokeLogsRoot,
    pruneRunLogs,
    keptRunLogs,

    -- * Worktree state
    uncommittedPackages,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (filterM, forM, forM_, join)
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Smoke.Check (SmokeDef)
import Smoke.CompileCache (CacheUse, reportLine, reportWarning)
import Smoke.Container (RunOutcome (..), RunResult (..), renderFailStage, runLogDir)
import Smoke.Plan (PlannedItem (..), SmokeRun (..), itemAtom)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    getModificationTime,
    listDirectory,
    removeDirectoryRecursive,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Types (PackageKey, packageKeyText)

-- | Selected keys with no definition, in order.
missingDefinitions :: (PackageKey -> Maybe SmokeDef) -> [PackageKey] -> [PackageKey]
missingDefinitions lookupDef keys = [k | k <- keys, Nothing <- [lookupDef k]]

data SmokeOps = SmokeOps
  { -- | Remove leftover containers and snapshots of dead commands.
    soSweep :: IO (),
    soEnsureImage :: IO (Either Text ()),
    -- | Snapshot the tree, run the continuation with it, and remove it.
    soWithSnapshot :: forall a. IO a -> IO (Either Text a),
    -- | Release the shared tree lock (called once the snapshot exists).
    soReleaseTree :: IO (),
    soProbe :: IO (Either Text ()),
    -- | Clean, reset, and prepare the compile cache; decides whether the
    -- runs use it (never fails the command).
    soPrepareCache :: IO CacheUse,
    -- | One run in a fresh container, logs under the given directory.
    soRun :: CacheUse -> SmokeRun -> SmokeDef -> FilePath -> IO RunOutcome,
    -- | Write one result line to stdout.
    soEmit :: Text -> IO (),
    -- | Report a failed run with its log path.
    soLogFailure :: Text -> IO (),
    soLogWarning :: Text -> IO (),
    soLogInfo :: Text -> IO (),
    -- | Progress: item index (1-based), total, and the item's atom.
    soProgress :: Int -> Int -> Text -> IO ()
  }

data SmokeSummary = SmokeSummary
  { ssPassed :: Int,
    ssFailed :: Int,
    ssSkipped :: Int
  }
  deriving (Eq, Show)

-- | The pipeline from the sweep to the last run. 'Left' is a hard failure
-- before the first run. @logsDir@ is this command's log directory.
runSmoke ::
  SmokeOps ->
  (PackageKey -> SmokeDef) ->
  FilePath ->
  [PlannedItem] ->
  IO (Either Text SmokeSummary)
runSmoke ops defFor logsDir items = do
  soSweep ops
  image <- soEnsureImage ops
  case image of
    Left err -> pure (Left err)
    Right () -> do
      result <- soWithSnapshot ops $ do
        soReleaseTree ops
        probe <- soProbe ops
        case probe of
          Left err -> pure (Left err)
          Right () -> Right <$> runAll
      pure (join result)
  where
    total = length items
    runAll = do
      createDirectoryIfMissing True logsDir
      cache <- soPrepareCache ops
      results <- forM (zip [1 ..] items) $ \(i, item) -> do
        soProgress ops i total (itemAtom item)
        outcome <- case item of
          PlannedSkip _ reason -> pure (Skipped reason)
          PlannedFail _ reason -> pure (Failed "plan" reason Nothing)
          PlannedRun run -> do
            r <- soRun ops cache run (defFor (srKey run)) (runLogDir logsDir run)
            forM_ (roCache r) $ \report -> do
              soLogInfo ops (itemAtom item <> ": " <> reportLine report)
              forM_ (reportWarning report) (soLogWarning ops)
            pure $ case roResult r of
              RunPass -> Passed
              RunFail stage why file -> Failed (renderFailStage stage) why (Just file)
        soEmit ops (resultLine item outcome)
        case outcome of
          Failed _ why mFile ->
            soLogFailure ops $
              itemAtom item
                <> ": "
                <> why
                <> maybe "" (\f -> " (log: " <> T.pack f <> ")") mFile
          _ -> pure ()
        pure outcome
      pure
        SmokeSummary
          { ssPassed = length [() | Passed <- results],
            ssFailed = length [() | Failed {} <- results],
            ssSkipped = length [() | Skipped _ <- results]
          }

data ItemOutcome
  = Passed
  | Skipped Text
  | -- | Stage, reason, log file.
    Failed Text Text (Maybe FilePath)

-- | @\<atom\> [(\<lane\>)]: pass@, @: skip: \<reason\>@, or @: fail: \<stage\>@.
resultLine :: PlannedItem -> ItemOutcome -> Text
resultLine item outcome =
  itemAtom item <> ": " <> case outcome of
    Passed -> "pass"
    Skipped reason -> "skip: " <> reason
    Failed stage _ _ -> "fail: " <> stage

-- | Summary log lines: counts and the log directory, then each package
-- tested with uncommitted changes.
summaryLines :: SmokeSummary -> FilePath -> [PackageKey] -> [Text]
summaryLines s logsDir dirty =
  ( "smoke: "
      <> tshow (ssPassed s)
      <> " passed, "
      <> tshow (ssFailed s)
      <> " failed, "
      <> tshow (ssSkipped s)
      <> " skipped; logs in "
      <> T.pack logsDir
  )
    : [packageKeyText k <> " was tested with uncommitted changes" | k <- dirty]

-- | @\<smoke cache\>/logs@.
smokeLogsRoot :: FilePath -> FilePath
smokeLogsRoot cacheDir = cacheDir </> "logs"

-- | Number of earlier commands' log directories kept.
keptRunLogs :: Int
keptRunLogs = 10

-- | Keep the 'keptRunLogs' most recent run directories under @root@ and
-- delete older ones. Best effort.
pruneRunLogs :: FilePath -> IO ()
pruneRunLogs root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure ()
    else do
      names <- listDirectory root
      dirs <- filterM (doesDirectoryExist . (root </>)) names
      dated <- forM dirs $ \d -> (,d) <$> getModificationTime (root </> d)
      let old = drop keptRunLogs (map snd (sortOn (Down . fst) dated))
      forM_ old $ \d -> try @SomeException (removeDirectoryRecursive (root </> d))

-- | Selected packages whose package directory has modified, staged, or
-- untracked files.
uncommittedPackages :: CommandRunner -> FilePath -> [PackageKey] -> IO [PackageKey]
uncommittedPackages run overlay =
  filterM dirty
  where
    dirty key = do
      res <-
        run
          ProcessRequest
            { prMode =
                ExecCmd
                  "git"
                  ["-C", overlay, "status", "--porcelain", "--untracked-files=all", "--", T.unpack (packageKeyText key)],
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = "",
              prMeasure = Timed
            }
      pure (prExitCode res == ExitSuccess && not (all null (lines (prStdout res))))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
