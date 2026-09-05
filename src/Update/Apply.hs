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
    MutateEnsure (..),
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
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (bracket_)
import Control.Monad (replicateM_, unless, void, when)
import Data.Foldable (for_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Update.Apply.Env
  ( ApplyEnv (..),
    EbuildRunner,
    mkEbuildRunner,
    productionEbuildRunner,
  )
import Update.Apply.GitMv
  ( PendingGitMvCommit (..),
    applyGitMv,
    applyGitMvFilesWithRemote,
    applyGitMvWithRemote,
    commitPendingGitMv,
  )
import Update.Apply.Materialize
  ( applyDepsAndAssets,
    applyDepsAndAssetsFromPlan,
    fetchModelsDevApiJson,
  )
import Update.Apply.Plan
import Update.AtomClosure
  ( AtomClosureSession,
    AtomClosureTerminal (..),
    listNonLiveProviderPVs,
    mkAtomClosureSession,
    plannedRemainingFromWork,
    recordAtomClosureTerminal,
    wireAtomClosureSlots,
  )
import Update.Check (PackageEntry (..))
import Update.Git (GitOps (..))
import Update.Go.Lanes (RuntimeLanePlan (..))
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

terminalFromApplyOutcomes :: [ApplyOutcome] -> AtomClosureTerminal
terminalFromApplyOutcomes os
  | any outcomeIsHardFail os = TerminalOverlayFail
  | otherwise = TerminalOverlayOk

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

-- | Mutate-phase ensure / GitMv sequencing for bun-bin-before-docker.
data MutateEnsure = MutateEnsure
  { meFullPathKeys :: [PackageKey],
    meImageEnsure :: ImageEnsure,
    -- | GitMv key whose signed commit waits until ensure finishes.
    meDelayCommit :: Maybe PackageKey,
    -- | Overlay keys whose file work (GitMv or DepsAndAssets rewrite /
    -- Manifest) must finish before @docker build@.
    meGateEnsureOnFiles :: [PackageKey],
    -- | Run t0 ensure even when no admitted full-path package exists.
    meRunEnsure :: Bool
  }

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
  MutateEnsure ->
  IO [ApplyOutcome]
applyOverlayFromPlan pcfg env overlayRoot entries planResults prepare mutate = do
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
            partitionEnsure (meFullPathKeys mutate) admittedWork
      session <-
        mkApplyAtomClosureSession
          overlayRoot
          byEntry
          planByKey
          (map planResultKey planResults)
      let envSess = env {aeAtomClosure = Just session}
      nested <-
        if panelTotal <= 0 && not (meRunEnsure mutate)
          then pure []
          else withMultiProgress pcfg "Updating packages" (max 1 panelTotal) $ \mh -> do
            for_ withheldPairs $ \(consumer, provider) ->
              mhWait mh consumer ("waiting on " <> packageKeyText provider)
            for_ ensureWork $ \(e, _) ->
              mhWait mh (peKey e) waitingOnMaterializeImage
            let env' = envSess {aeMulti = mh}
            if panelTotal <= 0
              then do
                -- Ensure-only (no admitted/withheld rows): still run t0 ensure.
                void (meImageEnsure mutate mh)
                pure []
              else
                runAdmitPool
                  env'
                  overlayRoot
                  readyWork
                  ensureWork
                  mutate
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

mkApplyAtomClosureSession ::
  FilePath ->
  Map PackageKey PackageEntry ->
  Map PackageKey PackagePlanResult ->
  [PackageKey] ->
  IO AtomClosureSession
mkApplyAtomClosureSession overlayRoot byEntry planByKey selectedKeys = do
  remainingPairs <- mapM remainingOne selectedKeys
  let remaining = Map.fromList remainingPairs
      selected = Set.fromList selectedKeys
      prefilled =
        Map.fromList $
          mapMaybe prefill (Map.elems planByKey)
  mkAtomClosureSession remaining selected prefilled
  where
    prefill = \case
      PlanSoftSkip k _ -> Just (k, TerminalOverlayOk)
      PlanHardFail k _ -> Just (k, TerminalOverlayFail)
      PlanNeedsWork {} -> Nothing
    remainingOne k = do
      pvs <-
        case Map.lookup k planByKey of
          Just (PlanNeedsWork _ work)
            | Just e <- Map.lookup k byEntry ->
                plannedRemainingFromWork
                  overlayRoot
                  k
                  (peLocal e)
                  (workShape work)
          _ -> listNonLiveProviderPVs overlayRoot k
      pure (k, pvs)
    workShape = \case
      PlannedGitMv remote -> Right remote
      PlannedDeps _ _ plan _ _ _ _ -> Left (glpUniquePVs plan)

runAdmitPool ::
  ApplyEnv ->
  FilePath ->
  [(PackageEntry, PlannedWork)] ->
  [(PackageEntry, PlannedWork)] ->
  MutateEnsure ->
  Map PackageKey PackageKey ->
  Map PackageKey PackageEntry ->
  WavePrepare ->
  IO [ApplyOutcome]
runAdmitPool env overlayRoot readyWork ensureWork mutate withheld0 byEntry prepare = do
  let jobs = max 1 (aeJobs env)
      mh = aeMulti env
      panelCount = length readyWork + length ensureWork + Map.size withheld0
      -- Extra workers beyond --jobs so an overlay-write wait can yield its
      -- occupancy slot while another package still has a thread to run.
      nWorkers = max jobs panelCount
      delayKey = meDelayCommit mutate
      gateKeys = meGateEnsureOnFiles mutate
      isGitMvWork = \case
        PlannedGitMv {} -> True
        _ -> False
      delayInReady =
        maybe
          False
          (\k -> any (\(e, w) -> peKey e == k && isGitMvWork w) readyWork)
          delayKey
      isFileGateWork key work =
        key `elem` gateKeys && not (delayKey == Just key && isGitMvWork work)
      nGates =
        length
          [ k
          | k <- gateKeys,
            any (\(e, _) -> peKey e == k) readyWork
          ]
  if panelCount == 0
    then pure []
    else do
      sem <- newQSem jobs
      case aeAtomClosure env of
        Just session ->
          wireAtomClosureSlots session (signalQSem sem) (waitQSem sem)
        Nothing -> pure ()
      chan <- newChan
      remaining <- newIORef panelCount
      outcomesRef <- newIORef ([] :: [ApplyOutcome])
      withheldRef <- newIORef withheld0
      filesReady <- newEmptyMVar
      pendingVar <- newEmptyMVar
      remainingGates <- newIORef nGates
      when (nGates == 0) $
        void $
          tryPutMVar filesReady (Right ())
      for_ readyWork $ \item -> writeChan chan (Just item)
      let finishOne = do
            n <- atomicModifyIORef' remaining (\x -> let x' = x - 1 in (x', x'))
            when (n == 0) $
              replicateM_ nWorkers (writeChan chan Nothing)
          recordOutcomes os =
            atomicModifyIORef' outcomesRef (\acc -> (acc <> os, ()))
          cascade provider consumers = do
            let msg = overlayProviderCascadeMessage provider
            for_ consumers $ \c -> do
              mhFail mh c msg
              recordOutcomes [ApplyHardFail c msg False False]
              recordAtomClosureTerminal (aeAtomClosure env) c TerminalOverlayFail
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
                  recordAtomClosureTerminal (aeAtomClosure env) c TerminalOverlayOk
                  finishOne
                Just (PlanHardFail _ msg) -> do
                  mhFail mh c (shortApplyReason msg)
                  recordOutcomes [ApplyHardFail c msg False False]
                  recordAtomClosureTerminal (aeAtomClosure env) c TerminalOverlayFail
                  finishOne
                _ -> cascade provider [c]
          handleDone key outs = do
            recordOutcomes outs
            recordAtomClosureTerminal
              (aeAtomClosure env)
              key
              (terminalFromApplyOutcomes outs)
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
          failEnsureWork err = do
            for_ ensureWork $ \(e, _) -> do
              let k = peKey e
              mhFail mh k (shortApplyReason err)
              recordOutcomes [ApplyHardFail k err False False]
              recordAtomClosureTerminal (aeAtomClosure env) k TerminalOverlayFail
              finishOne
          delayedGitMv key work =
            delayKey == Just key && isGitMvWork work
          gatedFileWork = isFileGateWork
          signalFiles result = void $ tryPutMVar filesReady result
          signalGateDone result = case result of
            Left err -> signalFiles (Left err)
            Right () -> do
              n <- atomicModifyIORef' remainingGates (\x -> let x' = x - 1 in (x', x'))
              when (n == 0) $ signalFiles (Right ())
          worker = do
            item <- readChan chan
            case item of
              Nothing -> pure ()
              Just (entry, work)
                | delayedGitMv (peKey entry) work -> do
                    fileResult <-
                      bracket_
                        (waitQSem sem)
                        (signalQSem sem)
                        (runDelayedGitMvFiles env overlayRoot entry work)
                    case fileResult of
                      Left outcome -> do
                        presentApplyChrome mh (peKey entry) [outcome]
                        signalGateDone (Left (outcomeMessage outcome))
                        handleDone (peKey entry) [outcome]
                        worker
                      Right pending -> do
                        putMVar pendingVar pending
                        signalGateDone (Right ())
                        worker
                | gatedFileWork (peKey entry) work -> do
                    outs <-
                      bracket_
                        (waitQSem sem)
                        (signalQSem sem)
                        (applyNeedsWorkTracked env overlayRoot entry work)
                    signalGateDone $
                      case [m | ApplyHardFail _ m _ _ <- outs] of
                        (m : _) -> Left m
                        [] -> Right ()
                    handleDone (peKey entry) outs
                    worker
                | otherwise -> do
                    outs <-
                      bracket_
                        (waitQSem sem)
                        (signalQSem sem)
                        (applyNeedsWorkTracked env overlayRoot entry work)
                    handleDone (peKey entry) outs
                    worker
          gated = not (null gateKeys)
          runEnsure = do
            filesBefore <-
              if gated
                then takeMVar filesReady
                else pure (Right ())
            case filesBefore of
              Left err ->
                when (meRunEnsure mutate || not (null ensureWork)) $
                  failEnsureWork err
              Right () -> do
                result <-
                  if meRunEnsure mutate || not (null ensureWork)
                    then meImageEnsure mutate mh
                    else pure (Right ())
                filesAfter <-
                  if delayInReady && not gated
                    then takeMVar filesReady
                    else pure filesBefore
                case (meDelayCommit mutate, filesAfter) of
                  (Just bunKey, Right ())
                    | delayInReady -> do
                        pending <- takeMVar pendingVar
                        out <- commitPendingGitMv env overlayRoot pending
                        presentApplyChrome mh bunKey [out]
                        handleDone bunKey [out]
                  _ -> pure ()
                case result of
                  Left err -> failEnsureWork err
                  Right () ->
                    for_ ensureWork $ \item -> writeChan chan (Just item)
      withAsync runEnsure $ \ea -> do
        mapConcurrently_ (const worker) [1 .. nWorkers]
        wait ea
      readIORef outcomesRef

runDelayedGitMvFiles ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  PlannedWork ->
  IO (Either ApplyOutcome PendingGitMvCommit)
runDelayedGitMvFiles env overlayRoot entry work = do
  let key = peKey entry
      mh = aeMulti env
  mhStart mh key
  case work of
    PlannedGitMv remote ->
      case lookupPolicy key of
        Just policy ->
          applyGitMvFilesWithRemote
            env
            overlayRoot
            entry
            (policySource policy)
            remote
        Nothing ->
          pure $ Left $ ApplySoftSkip key "no hardcoded policy for package"
    _ ->
      pure $
        Left $
          ApplyHardFail key "internal: delayed commit is GitMv-only" False False

presentApplyChrome :: MultiHandle -> PackageKey -> [ApplyOutcome] -> IO ()
presentApplyChrome mh key outcomes =
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
  where
    isSoft ApplySoftSkip {} = True
    isSoft _ = False

outcomeMessage :: ApplyOutcome -> Text
outcomeMessage = \case
  ApplyHardFail _ m _ _ -> m
  ApplySoftSkip _ r -> r
  ApplySuccess {} -> "ok"

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
  PlannedDeps eco src plan localPVs contentFix forceFull mHypo ->
    applyDepsAndAssetsFromPlan
      env
      overlayRoot
      entry
      src
      eco
      plan
      localPVs
      contentFix
      forceFull
      mHypo
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
  recordAtomClosureTerminal
    (aeAtomClosure env)
    key
    (terminalFromApplyOutcomes outcomes)
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
