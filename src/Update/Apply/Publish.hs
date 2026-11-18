{-# LANGUAGE OverloadedStrings #-}

-- | The end of every apply unit once its overlay files, Manifest, and
-- md5-cache are written: smoke gate, then (full path) assets publish and
-- verification, then the signed overlay commit and its push. A unit that
-- stops after the gate started is held: its work is saved and its overlay
-- paths are rolled back.
module Update.Apply.Publish
  ( UnitTail (..),
    AfterGateStop (..),
    UnitCtx (..),
    GatedUnit,
    finishUnit,
    gateUnitStep,
    publishAndCommitStep,
    noPublish,
    holdForStop,
    mkHold,
    smokeTestingStatus,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar (MVar, withMVar)
import Data.Either (fromRight)
import Data.IORef (atomicModifyIORef', readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Update.Apply.Commit (CommitOutcome (..), commitAndPushOverlay)
import Update.Apply.Env (ApplyEnv (..), HoldRequest (..), PublishControl (..))
import Update.Apply.Errors (ApplyUnitError (..), applyUnitErrorMessage)
import Update.Assets.Verify (assetsDownloadPrefix)
import Update.Gate (GateFailure (..), GateHandle (..), GateRequest (..), GateResult (..))
import Update.Git (gitRevParseHead)
import Update.Held
  ( AssetRecord (..),
    GateRunRecord,
    HeldInput (..),
    HeldMeta (..),
    HeldReason (..),
    heldEntryPath,
    holdUnit,
  )
import Update.OverlayTree (TreeLock, withOverlayTree)
import Update.OverlayWaves (committingOverlayStatus)
import Update.Process (CommandRunner)
import Update.Types (ApplyOutcome (..), PackageKey, SuccessLine)

-- | What a unit does around its gate beyond committing.
data UnitTail = UnitTail
  { -- | Policy technique, as recorded in a held entry.
    utTechnique :: Text,
    -- | @full@ or @reuse@ for a DepsAndAssets unit.
    utPath :: Maybe Text,
    -- | Built distfiles staged for the gate and kept in a held entry.
    utStaged :: [FilePath],
    utRelease :: Maybe Text,
    utAssetNames :: [Text],
    -- | Whether the unit's assets were already published before its gate
    -- (reuse path).
    utPublishedBefore :: Bool,
    -- | After a passed gate: publish and verify. Full path only.
    utAfterGate :: IO (Either AfterGateStop ()),
    -- | A progress step completed (@regenerating manifest@, @smoke testing@).
    utStepDone :: Text -> IO ()
  }

-- | Why the publish step after a passed gate stopped the unit.
data AfterGateStop
  = -- | Sidecars, assets commit, push, or release failed.
    StopPublishFailed Text
  | -- | A published asset did not verify: the URL and the mismatch.
    StopVerifyFailed Text Text
  | -- | Publishing halted before this unit published.
    StopHalted Text
  deriving (Eq, Show)

-- | A tail with nothing to publish after the gate.
noPublish :: Text -> Maybe Text -> UnitTail
noPublish technique path =
  UnitTail
    { utTechnique = technique,
      utPath = path,
      utStaged = [],
      utRelease = Nothing,
      utAssetNames = [],
      utPublishedBefore = False,
      utAfterGate = pure (Right ()),
      utStepDone = \_ -> pure ()
    }

smokeTestingStatus :: Text
smokeTestingStatus = "smoke testing"

-- | One unit at the end of its pipeline.
data UnitCtx = UnitCtx
  { ucKey :: PackageKey,
    ucPv :: Text,
    -- | Overlay-relative paths the commit stages and a held entry captures.
    ucPaths :: [FilePath],
    ucMessage :: Text,
    ucLines :: [SuccessLine],
    ucTail :: UnitTail
  }

-- | A unit whose gate passed.
data GatedUnit = GatedUnit
  { guRuns :: [GateRunRecord],
    guLogs :: [FilePath]
  }

-- | Gate, publish and verify, commit, push.
finishUnit :: ApplyEnv -> FilePath -> UnitCtx -> IO ApplyOutcome
finishUnit env overlayRoot ctx =
  gateUnitStep env ctx >>= either pure (publishAndCommitStep env overlayRoot ctx)

-- | Record the unit as in flight: an interrupt from now until it finishes
-- holds it.
registerInFlight :: ApplyEnv -> UnitCtx -> IO ()
registerInFlight env ctx =
  atomicModifyIORef' (aeInFlight env) $ \m ->
    (Map.insert (ucKey ctx) (holdForStop env ctx HeldInterrupted "update was interrupted") m, ())

finishedInFlight :: ApplyEnv -> UnitCtx -> IO ()
finishedInFlight env ctx = atomicModifyIORef' (aeInFlight env) (\m -> (Map.delete (ucKey ctx) m, ()))

-- | The gate. A failure holds the unit ('Left' is its outcome).
gateUnitStep :: ApplyEnv -> UnitCtx -> IO (Either ApplyOutcome GatedUnit)
gateUnitStep env ctx = do
  let key = ucKey ctx
      unitTail = ucTail ctx
  mhStatus (aeMulti env) key smokeTestingStatus
  registerInFlight env ctx
  gate <-
    ghGate
      (aeGate env)
      GateRequest
        { grKey = key,
          grPv = ucPv ctx,
          grStaged = utStaged unitTail,
          grAssetsPrefix = assetsDownloadPrefix (aeAssetsOwner env) (aeAssetsRepo env),
          grStatus = mhStatus (aeMulti env) key
        }
  case gate of
    GateFailed failure ->
      fmap Left . (<* finishedInFlight env ctx) $
        holdUnitAs
          env
          ctx
          (gfReason failure)
          (gfRuns failure)
          (gfLogDirs failure)
          (utPublishedBefore unitTail)
          (gateFailureText failure)
    GatePassed runs logs -> do
      utStepDone unitTail smokeTestingStatus
      pure (Right (GatedUnit runs logs))

-- | After a passed gate: stop when publishing halted, publish and verify,
-- then commit and push.
publishAndCommitStep :: ApplyEnv -> FilePath -> UnitCtx -> GatedUnit -> IO ApplyOutcome
publishAndCommitStep env overlayRoot ctx gated =
  -- Not on an exception: an interrupted unit stays registered for the sweep.
  publishAndCommit env overlayRoot ctx gated <* finishedInFlight env ctx

publishAndCommit :: ApplyEnv -> FilePath -> UnitCtx -> GatedUnit -> IO ApplyOutcome
publishAndCommit env overlayRoot ctx gated = do
  let key = ucKey ctx
      unitTail = ucTail ctx
      before = utPublishedBefore unitTail
      hold reason = holdUnitAs env ctx reason (guRuns gated) (guLogs gated)
  halted <- readIORef (pcHalted (aePublish env))
  case halted of
    Just cause -> hold HeldHalted before (applyUnitErrorMessage (ApplyPublishingHalted cause))
    Nothing -> do
      after <- utAfterGate unitTail
      let published = before || (not (null (utAssetNames unitTail)) && either (const False) (const True) after)
      case after of
        Left (StopPublishFailed err) ->
          pure (ApplyHardFail key ("assets publish failed: " <> err) True False)
        Left (StopVerifyFailed url why) ->
          hold HeldVerify True (applyUnitErrorMessage (ApplyVerifyFailed url why))
        Left (StopHalted cause) ->
          hold HeldHalted before (applyUnitErrorMessage (ApplyPublishingHalted cause))
        Right () -> do
          mhStatus (aeMulti env) key committingOverlayStatus
          committed <- commitAndPushOverlay env overlayRoot key (ucPaths ctx) (ucMessage ctx)
          case committed of
            Committed -> pure (ApplySuccess key (ucLines ctx) (ucPaths ctx))
            CommitHalted cause ->
              hold HeldHalted published (applyUnitErrorMessage (ApplyPublishingHalted cause))
            CommitFailed err -> pure (ApplyHardFail key err True published)
            PushFailed err ->
              pure (ApplyHardFail key (applyUnitErrorMessage (ApplyOverlayPushFailed overlayRoot err)) False False)

gateFailureText :: GateFailure -> Text
gateFailureText failure = case gfReason failure of
  HeldGate -> applyUnitErrorMessage (ApplyGateFailed (gfMessage failure))
  _ -> gfMessage failure

-- | Hold the unit for a reason found outside its gate (an interrupt).
holdForStop :: ApplyEnv -> UnitCtx -> HeldReason -> Text -> IO ApplyOutcome
holdForStop env ctx reason =
  holdUnitAs env ctx reason [] [] (utPublishedBefore (ucTail ctx))

-- | Capture and roll back; the hard-fail names the held entry, or says the
-- work was left in place when the capture failed. Held units never get the
-- half-applied warning.
holdUnitAs ::
  ApplyEnv ->
  UnitCtx ->
  HeldReason ->
  [GateRunRecord] ->
  [FilePath] ->
  Bool ->
  Text ->
  IO ApplyOutcome
holdUnitAs env ctx reason runs logs published detail = do
  let unitTail = ucTail ctx
      key = ucKey ctx
  held <-
    aeHold
      env
      HoldRequest
        { hrKey = key,
          hrPv = ucPv ctx,
          hrTechnique = utTechnique unitTail,
          hrPath = utPath unitTail,
          hrRuns = runs,
          hrReason = reason,
          hrDetail = detail,
          hrRelease = utRelease unitTail,
          hrAssets = [AssetRecord n published | n <- utAssetNames unitTail],
          hrPaths = ucPaths ctx,
          hrDistfiles = utStaged unitTail,
          hrLogDirs = logs
        }
  pure $ case held of
    Right entry -> ApplyHardFail key (detail <> "; held in " <> T.pack entry) False published
    Left err -> ApplyHardFail key (detail <> "; " <> err) False published

-- | Production hold: under the overlay critical section and the ebuild
-- exclusion (rollback removes and restores ebuilds), record the base
-- @HEAD@, capture the entry under @heldRoot@, and roll the unit back.
mkHold ::
  CommandRunner ->
  MVar () ->
  TreeLock ->
  FilePath ->
  FilePath ->
  Text ->
  HoldRequest ->
  IO (Either Text FilePath)
mkHold run overlayLock treeLock overlayRoot heldRoot runId req =
  withMVar overlayLock $ \() -> withOverlayTree treeLock $ \_ -> do
    base <- gitRevParseHead run overlayRoot
    now <- getCurrentTime
    let meta =
          HeldMeta
            { hmPackage = hrKey req,
              hmPv = hrPv req,
              hmTechnique = hrTechnique req,
              hmPath = hrPath req,
              hmRuns = hrRuns req,
              hmReason = hrReason req,
              hmDetail = hrDetail req,
              hmBaseHead = fromRight "unknown" base,
              hmRelease = hrRelease req,
              hmAssets = hrAssets req,
              hmPaths = hrPaths req,
              hmRunId = runId,
              hmTime = now
            }
    holdUnit
      run
      HeldInput
        { hiOverlay = overlayRoot,
          hiEntry = heldEntryPath heldRoot runId (hrKey req) (hrPv req),
          hiMeta = meta,
          hiDistfiles = hrDistfiles req,
          hiLogDirs = hrLogDirs req
        }
