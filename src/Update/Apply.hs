{-# LANGUAGE OverloadedStrings #-}

-- | Product Apply surface used by the executable.
--
-- Per-package helpers and materialize budgets for unit tests live in
-- 'Update.Apply.TestSupport' (not advertised as product API).
module Update.Apply
  ( applyOverlay,
    applyOverlayFromPlan,
    WavePrepare,
    ImageEnsure,
    foldExitHardFail,
    EbuildRunner,
    productionEbuildRunner,
    mkEbuildRunner,
    ApplyEnv (..),
    fetchModelsDevApiJson,
    -- | Exported for 'Update.Apply.TestSupport' and direct unit tests.
    applyPackagePhase1,
    -- | Exported for multi-progress terminal-handle unit tests.
    applyPackagePhase1Tracked,
    -- | Plan phase + pure builders (tests / spine).
    module Update.Apply.Plan,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig,
    withMultiProgress,
  )
import Control.Concurrent (newQSem, signalQSem, waitQSem)
import Control.Concurrent.Async (mapConcurrently_, wait, withAsync)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Exception (bracket_)
import Control.Monad (replicateM_, unless, when)
import Data.Foldable (for_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Update.Apply.Env
  ( ApplyEnv (..),
    EbuildRunner,
    mkEbuildRunner,
    productionEbuildRunner,
  )
import Update.Apply.GitMv (applyGitMv, applyGitMvWithRemote)
import Update.Apply.Materialize
  ( applyDepsAndAssets,
    applyDepsAndAssetsFromPlan,
    fetchModelsDevApiJson,
  )
import Update.Apply.Plan
import Update.Check (PackageEntry (..))
import Update.Git (GitOps (..))
import Update.Hardcoded (lookupPolicy)
import Update.Materialize (waitingOnMaterializeImage)
import Update.OverlayWaves
  ( AdmitSets (..),
    OverlayPlanKind (..),
    classifyAdmit,
    overlayCeilingProviderForKey,
    overlayProviderCascadeMessage,
  )
import Update.TempWorkspace (cleanupRunSuccess)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateTechnique (..),
    outcomeIsHardFail,
    packageKeyText,
  )

foldExitHardFail :: [ApplyOutcome] -> Bool
foldExitHardFail = any outcomeIsHardFail

-- | Legacy entry: plan+mutate per package (used by older tests).
applyOverlay ::
  ProgressConfig ->
  ApplyEnv ->
  FilePath ->
  [PackageEntry] ->
  Maybe [PackageKey] ->
  IO [ApplyOutcome]
applyOverlay pcfg env overlayRoot entries mFilter = do
  isGit <- goIsWorkTree (aeGitOps env) overlayRoot
  if not isGit
    then
      pure
        [ ApplyHardFail
            (PackageKey "")
            "overlay path is not a git work tree"
            False
            False
        ]
    else do
      let selected = case mFilter of
            Nothing -> entries
            Just keys -> [e | e <- entries, peKey e `elem` keys]
      nested <-
        withMultiProgress pcfg "Updating packages" (length selected) $ \mh ->
          let env' = env {aeMulti = mh}
           in mapConcurrentlyN
                (aeJobs env')
                (applyPackagePhase1Tracked env' overlayRoot)
                selected
      let outcomes = concat nested
      unless (any outcomeIsHardFail outcomes) $
        cleanupRunSuccess (aeTempRun env)
      pure outcomes

-- | After a provider signed commit (or apply skip), re-plan withheld consumers.
type WavePrepare =
  PackageKey ->
  [PackageKey] ->
  MultiHandle ->
  IO [PackagePlanResult]

-- | t0 image ensure: runs outside the package job limiter.
type ImageEnsure = MultiHandle -> IO (Either Text ())

planKindOf :: PackagePlanResult -> OverlayPlanKind
planKindOf = \case
  PlanSoftSkip {} -> OverlayPlanSkip
  PlanHardFail {} -> OverlayPlanFail
  PlanNeedsWork {} -> OverlayPlanWork

-- | Mutate phase consuming plan results. Overlay wait-edge consumers are
-- withheld until their in-run provider reaches a non-hard-fail terminal
-- overlay outcome; they are not mutated on the start-of-run plan.
applyOverlayFromPlan ::
  ProgressConfig ->
  ApplyEnv ->
  FilePath ->
  [PackageEntry] ->
  [PackagePlanResult] ->
  WavePrepare ->
  -- | Admitted full-path keys that wait on image ensure (not a job slot).
  [PackageKey] ->
  ImageEnsure ->
  IO [ApplyOutcome]
applyOverlayFromPlan pcfg env overlayRoot entries planResults prepare fullPathKeys imageEnsure = do
  isGit <- goIsWorkTree (aeGitOps env) overlayRoot
  if not isGit
    then
      pure
        [ ApplyHardFail
            (PackageKey "")
            "overlay path is not a git work tree"
            False
            False
        ]
    else do
      let kinds = [(planResultKey r, planKindOf r) | r <- planResults]
          admit = classifyAdmit overlayCeilingProviderForKey kinds
          withheldSet = Map.fromList (asWithheld admit)
          terminalKeys = asTerminal admit
          carried =
            mapMaybe
              ( \r ->
                  if planResultKey r `elem` terminalKeys
                    then planResultToOutcome r
                    else Nothing
              )
              planResults
          byEntry = Map.fromList [(peKey e, e) | e <- entries]
          planByKey = Map.fromList [(planResultKey r, r) | r <- planResults]
          admittedWork =
            [ (e, work)
            | k <- asReady admit,
              Just (PlanNeedsWork _ work) <- [Map.lookup k planByKey],
              Just e <- [Map.lookup k byEntry]
            ]
          withheldPairs = asWithheld admit
          panelTotal = length admittedWork + length withheldPairs
          (readyWork, ensureWork) =
            partitionEnsure fullPathKeys admittedWork
      nested <-
        if panelTotal <= 0
          then pure []
          else withMultiProgress pcfg "Updating packages" panelTotal $ \mh -> do
            for_ withheldPairs $ \(consumer, provider) ->
              mhWait mh consumer ("waiting on " <> packageKeyText provider)
            for_ ensureWork $ \(e, _) ->
              mhWait mh (peKey e) waitingOnMaterializeImage
            let env' = env {aeMulti = mh}
            runAdmitPool
              env'
              overlayRoot
              readyWork
              ensureWork
              imageEnsure
              withheldSet
              byEntry
              prepare
      let outcomes = carried <> nested
      unless (any outcomeIsHardFail outcomes) $
        cleanupRunSuccess (aeTempRun env)
      pure outcomes

partitionEnsure ::
  [PackageKey] ->
  [(PackageEntry, PlannedWork)] ->
  ( [(PackageEntry, PlannedWork)],
    [(PackageEntry, PlannedWork)]
  )
partitionEnsure fullKeys items =
  let isFull e = peKey e `elem` fullKeys
   in ( [it | it@(e, _) <- items, not (isFull e)],
        [it | it@(e, _) <- items, isFull e]
      )

runAdmitPool ::
  ApplyEnv ->
  FilePath ->
  [(PackageEntry, PlannedWork)] ->
  [(PackageEntry, PlannedWork)] ->
  ImageEnsure ->
  Map PackageKey PackageKey ->
  Map PackageKey PackageEntry ->
  WavePrepare ->
  IO [ApplyOutcome]
runAdmitPool env overlayRoot readyWork ensureWork imageEnsure withheld0 byEntry prepare = do
  let jobs = max 1 (aeJobs env)
      mh = aeMulti env
      panelCount = length readyWork + length ensureWork + Map.size withheld0
  if panelCount == 0
    then pure []
    else do
      sem <- newQSem jobs
      chan <- newChan
      remaining <- newIORef panelCount
      outcomesRef <- newIORef ([] :: [ApplyOutcome])
      withheldRef <- newIORef withheld0
      for_ readyWork $ \item -> writeChan chan (Just item)
      let finishOne = do
            n <- atomicModifyIORef' remaining (\x -> let x' = x - 1 in (x', x'))
            when (n == 0) $
              replicateM_ jobs (writeChan chan Nothing)
          recordOutcomes os =
            atomicModifyIORef' outcomesRef (\acc -> (acc <> os, ()))
          cascade provider consumers = do
            let msg = overlayProviderCascadeMessage provider
            for_ consumers $ \c -> do
              mhFail mh c msg
              recordOutcomes [ApplyHardFail c msg False False]
              finishOne
          admitResults provider consumers results = do
            let byPlan = Map.fromList [(planResultKey r, r) | r <- results]
            for_ consumers $ \c ->
              case Map.lookup c byPlan of
                Just (PlanNeedsWork _ work)
                  | Just e <- Map.lookup c byEntry ->
                      writeChan chan (Just (e, work))
                Just (PlanSoftSkip _ reason) -> do
                  mhSkip mh c (shortApplyReason reason)
                  recordOutcomes [ApplySoftSkip c reason]
                  finishOne
                Just (PlanHardFail _ msg) -> do
                  mhFail mh c (shortApplyReason msg)
                  recordOutcomes [ApplyHardFail c msg False False]
                  finishOne
                _ -> cascade provider [c]
          handleDone key outs = do
            recordOutcomes outs
            waiting <-
              Map.keys . Map.filter (== key) <$> readIORef withheldRef
            if null waiting
              then finishOne
              else do
                atomicModifyIORef'
                  withheldRef
                  (\m -> (foldl' (flip Map.delete) m waiting, ()))
                finishOne
                if any outcomeIsHardFail outs
                  then cascade key waiting
                  else do
                    results <- prepare key waiting mh
                    admitResults key waiting results
          worker = do
            item <- readChan chan
            case item of
              Nothing -> pure ()
              Just (entry, work) -> do
                outs <-
                  bracket_
                    (waitQSem sem)
                    (signalQSem sem)
                    (applyNeedsWorkTracked env overlayRoot entry work)
                handleDone (peKey entry) outs
                worker
          runEnsure =
            if null ensureWork
              then pure ()
              else do
                result <- imageEnsure mh
                case result of
                  Left err ->
                    for_ ensureWork $ \(e, _) -> do
                      let k = peKey e
                      mhFail mh k (shortApplyReason err)
                      recordOutcomes [ApplyHardFail k err False False]
                      finishOne
                  Right () ->
                    for_ ensureWork $ \item -> writeChan chan (Just item)
      withAsync runEnsure $ \ea -> do
        mapConcurrently_ (const worker) [1 .. jobs]
        wait ea
      readIORef outcomesRef

shortApplyReason :: Text -> Text
shortApplyReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

applyNeedsWorkTracked ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  PlannedWork ->
  IO [ApplyOutcome]
applyNeedsWorkTracked env overlayRoot entry work = do
  let key = peKey entry
      mh = aeMulti env
  mhStart mh key
  outcomes <- applyNeedsWork env overlayRoot entry work
  case outcomes of
    [] -> mhSuccess mh key
    _ ->
      if any outcomeIsHardFail outcomes
        then
          let msg = case [m | ApplyHardFail _ m _ _ <- outcomes] of
                (m : _) -> m
                [] -> "hard fail"
           in mhFail mh key (shortReason msg)
        else
          if all isSoft outcomes
            then
              let reason = case [r | ApplySoftSkip _ r <- outcomes] of
                    (r : _) -> r
                    [] -> "skipped"
               in mhSkip mh key (shortReason reason)
            else mhSuccess mh key
  pure outcomes
  where
    isSoft ApplySoftSkip {} = True
    isSoft _ = False

applyNeedsWork ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  PlannedWork ->
  IO [ApplyOutcome]
applyNeedsWork env overlayRoot entry = \case
  PlannedGitMv remote ->
    case lookupPolicy (peKey entry) of
      Just policy ->
        (: [])
          <$> applyGitMvWithRemote
            env
            overlayRoot
            entry
            (policySource policy)
            remote
      Nothing ->
        pure [ApplySoftSkip (peKey entry) "no hardcoded policy for package"]
  PlannedDeps eco src plan localPVs contentFix ->
    applyDepsAndAssetsFromPlan
      env
      overlayRoot
      entry
      src
      eco
      plan
      localPVs
      contentFix
      0

applyPackagePhase1Tracked ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  IO [ApplyOutcome]
applyPackagePhase1Tracked env overlayRoot entry = do
  let key = peKey entry
      mh = aeMulti env
  mhStart mh key
  outcomes <- applyPackagePhase1 env overlayRoot entry
  case outcomes of
    [] -> mhSuccess mh key
    _ ->
      if any outcomeIsHardFail outcomes
        then
          let msg = case [m | ApplyHardFail _ m _ _ <- outcomes] of
                (m : _) -> m
                [] -> "hard fail"
           in mhFail mh key (shortReason msg)
        else
          if all isSoft outcomes
            then
              let reason = case [r | ApplySoftSkip _ r <- outcomes] of
                    (r : _) -> r
                    [] -> "skipped"
               in mhSkip mh key (shortReason reason)
            else mhSuccess mh key
  pure outcomes
  where
    isSoft ApplySoftSkip {} = True
    isSoft _ = False

shortReason :: Text -> Text
shortReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

applyPackagePhase1 ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  IO [ApplyOutcome]
applyPackagePhase1 env overlayRoot entry =
  case lookupPolicy (peKey entry) of
    Nothing ->
      pure [ApplySoftSkip (peKey entry) "no hardcoded policy for package"]
    Just policy ->
      case policyTechnique policy of
        Unsupported reason ->
          pure
            [ ApplySoftSkip
                (peKey entry)
                ("unsupported update technique: " <> reason)
            ]
        GitMvAndManifest ->
          (: []) <$> applyGitMv env overlayRoot entry (policySource policy)
        DepsAndAssets eco ->
          applyDepsAndAssets env overlayRoot entry (policySource policy) eco
