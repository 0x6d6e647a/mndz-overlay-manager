{-# LANGUAGE OverloadedStrings #-}

-- | The smoke side of @update@'s gate: the command's smoke session, opened
-- concurrently with the first units, and one unit's gated runs against its
-- overlay snapshot.
module Update.Gate.Session
  ( -- * Session
    GateSessionCfg (..),
    withGateSession,
    gateWaitSpan,

    -- * One unit
    UnitGateCfg (..),
    runUnitGate,
  )
where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (void, when)
import Data.Aeson ((.=))
import Data.Map.Strict (Map)
import Data.Maybe (maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Metrics.Core (Metrics, Outcome (..), withSpan, withSpanResult)
import Smoke.Check (SmokeDef)
import Smoke.CompileCache (CacheUse)
import Smoke.Container (OverlayMount (..), RunOutcome, StagedFetch (..), runLogDir)
import Smoke.Plan
  ( HostCeilings,
    LaneRuntime,
    PackageInput (..),
    PlannedItem (..),
    SmokeRun,
    itemAtom,
    laneRuntimeFor,
    planPvRuns,
    readPackageInput,
    runLabel,
  )
import Smoke.Run (ItemOutcome (..), SmokeOps (..), runItem, withSmokeSession)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive)
import System.FilePath ((</>))
import Update.Gate
  ( GateConfig (..),
    GateFailure (..),
    GateHandle,
    GateRequest (..),
    GateResult (..),
    GateWait (..),
    newGateScheduler,
  )
import Update.Gate.Snapshot (buildUnitSnapshot)
import Update.Gate.Staging (buildStagingDir)
import Update.Held (GateRunRecord (..), HeldReason (..))
import Update.Process (CommandRunner)
import Update.Types (PackageKey, UpdateTechnique, packageKeyText)

------------------------------------------------------------------------
-- Session

data GateSessionCfg = GateSessionCfg
  { -- | Sweep, smoke image, tree snapshot, probe, and compile cache.
    gscSmokeOps :: SmokeOps,
    -- | One unit's gated runs in the open session.
    gscRunUnit :: CacheUse -> GateRequest -> IO GateResult,
    gscDependencies :: GateRequest -> IO [PackageKey],
    gscAroundWait :: forall a. PackageKey -> GateWait -> IO a -> IO a
  }

-- | Open the smoke session concurrently and run @k@ with the gate and a
-- start check: once the session has failed, @k@'s check returns the
-- reason, and units already at or reaching their gate fail it. The session
-- (and its snapshot) closes when @k@ returns.
withGateSession ::
  GateSessionCfg ->
  [PackageKey] ->
  (GateHandle -> IO (Maybe Text) -> IO a) ->
  IO a
withGateSession cfg selected k = do
  ready <- newEmptyMVar
  done <- newEmptyMVar
  let session = do
        r <-
          try @SomeException $
            withSmokeSession (gscSmokeOps cfg) $ \cache -> do
              putMVar ready (Right cache)
              takeMVar done
        case r of
          Left e -> void (tryPutMVar ready (Left (T.pack (displayException e))))
          Right (Left err) -> void (tryPutMVar ready (Left err))
          Right (Right ()) -> pure ()
  withAsync session $ \running -> do
    gate <-
      newGateScheduler
        GateConfig
          { gcSelected = Set.fromList selected,
            gcDependencies = gscDependencies cfg,
            gcReady = void <$> readMVar ready,
            gcRun = \req ->
              readMVar ready >>= \case
                Left err -> pure (GateFailed (GateFailure HeldGate err [] []))
                Right cache -> gscRunUnit cfg cache req,
            gcAroundWait = gscAroundWait cfg
          }
    let stop =
          tryReadMVar ready >>= \case
            Just (Left err) -> pure (Just ("smoke gate prerequisites failed: " <> err))
            _ -> pure Nothing
    result <- k gate stop
    _ <- tryPutMVar done ()
    _ <- try @SomeException (wait running)
    pure result

-- | A wait at a gate as a @slot.wait@ span: kind @smoke@ (capacity 1) for
-- the smoke lane, kind @gate-dependency@ naming the dependency.
gateWaitSpan :: Metrics -> PackageKey -> GateWait -> IO a -> IO a
gateWaitSpan m _ = \case
  WaitLane -> withSpan m "slot.wait" ["kind" .= ("smoke" :: Text), "capacity" .= (1 :: Int)]
  WaitDependency dep ->
    withSpan m "slot.wait" ["kind" .= ("gate-dependency" :: Text), "dependency" .= packageKeyText dep]

------------------------------------------------------------------------
-- One unit

data UnitGateCfg = UnitGateCfg
  { ugRunner :: CommandRunner,
    ugOverlay :: FilePath,
    -- | Per-command scratch directory for snapshots and staging.
    ugWorkDir :: FilePath,
    -- | Host @KEYWORDS@ token.
    ugArch :: Text,
    -- | Host ceilings of these runtimes, with lane ebuilds read from the
    -- given overlay root.
    ugCeilings :: FilePath -> [LaneRuntime] -> IO (Either Text (Map LaneRuntime HostCeilings)),
    ugTechnique :: PackageKey -> Maybe UpdateTechnique,
    ugDefinition :: PackageKey -> Maybe SmokeDef,
    -- | This command's smoke log directory.
    ugLogsDir :: FilePath,
    ugMetrics :: Metrics,
    -- | One run in a fresh container with the given overlay mount; the
    -- callback gets the run's atom and each stage.
    ugRun :: OverlayMount -> (Text -> Text -> IO ()) -> CacheUse -> SmokeRun -> SmokeDef -> FilePath -> IO RunOutcome
  }

-- | The unit's PV, run once per lane ceiling as @smoke@ would plan it,
-- against @HEAD@ plus the unit's own changes. The first failed or skipped
-- run fails the gate; nothing is retried.
runUnitGate :: UnitGateCfg -> SmokeOps -> CacheUse -> GateRequest -> IO GateResult
runUnitGate cfg ops cache req = do
  let key = grKey req
      dir = ugWorkDir cfg </> T.unpack (T.replace "/" "_" (packageKeyText key) <> "-" <> grPv req)
      overlayDir = dir </> "overlay"
      stagingDir = dir </> "staged"
      failWith msg = pure (GateFailed (GateFailure HeldGate msg [] []))
  stale <- doesDirectoryExist dir
  when stale (removeDirectoryRecursive dir)
  createDirectoryIfMissing True dir
  result <- case (ugTechnique cfg key, ugDefinition cfg key) of
    (Nothing, _) -> failWith ("no update policy for " <> packageKeyText key)
    (_, Nothing) -> failWith ("no smoke definition for " <> packageKeyText key)
    (Just technique, Just def) -> do
      snap <- buildUnitSnapshot (ugRunner cfg) (ugOverlay cfg) key overlayDir
      staged <- case grStaged req of
        [] -> pure (Right Nothing)
        files -> fmap (const (Just (StagedFetch stagingDir (grAssetsPrefix req)))) <$> buildStagingDir stagingDir files
      case (snap, staged) of
        (Left err, _) -> failWith err
        (_, Left err) -> failWith err
        (Right (), Right mStaged) -> do
          input <- readPackageInput overlayDir key technique
          case input of
            Left err -> failWith err
            Right pkg -> do
              ceilings <- ugCeilings cfg overlayDir (maybeToList (laneRuntimeFor (piTechnique pkg)))
              case ceilings of
                Left err -> failWith err
                Right cs -> case planPvRuns (ugArch cfg) cs pkg (grPv req) of
                  [] -> failWith ("no ebuild for " <> packageKeyText key <> "-" <> grPv req <> " in the gate snapshot")
                  items -> runItems (SnapshotMount overlayDir mStaged) def items []
  _ <- try @SomeException (removeDirectoryRecursive overlayDir)
  pure result
  where
    runItems _ _ [] done = pure (GatePassed (map fst done) [d | (_, Just d) <- done])
    runItems mount def (item : rest) done = do
      grStatus req ("smoke testing " <> itemAtom item)
      let progress atom stage = grStatus req ("smoke testing " <> atom <> ": " <> stage)
          ops' = ops {soRun = ugRun cfg mount progress}
          lane = case item of
            PlannedRun run -> runLabel run
            _ -> Nothing
          logDir = case item of
            PlannedRun run -> Just (runLogDir (ugLogsDir cfg) run)
            _ -> Nothing
      outcome <-
        withSpanResult
          (ugMetrics cfg)
          "gate.run"
          ( ["package" .= packageKeyText (grKey req), "pv" .= grPv req]
              <> ["lane" .= l | Just l <- [lane]]
          )
          ( \case
              Passed -> (OutcomeOk, ["stage" .= ("checks" :: Text), "gate_outcome" .= ("pass" :: Text)])
              Skipped reason -> (OutcomeFail, ["stage" .= ("plan" :: Text), "gate_outcome" .= ("skip: " <> reason)])
              Failed stage _ _ -> (OutcomeFail, ["stage" .= stage, "gate_outcome" .= ("fail: " <> stage)])
          )
          (runItem ops' (const def) (ugLogsDir cfg) cache item)
      case outcome of
        Passed -> runItems mount def rest (done <> [(GateRunRecord lane "pass", logDir)])
        Skipped reason ->
          failed (done <> [(GateRunRecord lane ("skip: " <> reason), logDir)]) (itemAtom item <> ": skip: " <> reason)
        Failed stage why mFile ->
          failed
            (done <> [(GateRunRecord lane ("fail: " <> stage), logDir)])
            ( itemAtom item
                <> ": fail: "
                <> stage
                <> " ("
                <> why
                <> ")"
                <> maybe "" (\f -> "; log: " <> T.pack f) mFile
            )
    failed runs msg =
      pure
        ( GateFailed
            GateFailure
              { gfReason = HeldGate,
                gfMessage = msg,
                gfRuns = map fst runs,
                gfLogDirs = [d | (_, Just d) <- runs]
              }
        )
