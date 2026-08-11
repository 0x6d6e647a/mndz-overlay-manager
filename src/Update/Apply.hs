{-# LANGUAGE OverloadedStrings #-}

-- | Product Apply surface used by the executable.
--
-- Per-package helpers and materialize budgets for unit tests live in
-- 'Update.Apply.TestSupport' (not advertised as product API).
module Update.Apply
  ( applyOverlay,
    applyOverlayFromPlan,
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
import Control.Monad (unless)
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
import Update.TempWorkspace (cleanupRunSuccess)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateTechnique (..),
    outcomeIsHardFail,
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

-- | Mutate phase consuming plan results: skip plan hard-fails / soft-skips;
-- only re-enter needs-work packages with carried plan data.
applyOverlayFromPlan ::
  ProgressConfig ->
  ApplyEnv ->
  FilePath ->
  [PackageEntry] ->
  [PackagePlanResult] ->
  IO [ApplyOutcome]
applyOverlayFromPlan pcfg env overlayRoot entries planResults = do
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
      let carried = mapMaybe planResultToOutcome planResults
          needs =
            [ (e, work)
            | PlanNeedsWork key work <- planResults,
              e <- entries,
              peKey e == key
            ]
      -- Soft-skips for packages not in planResults should not occur;
      -- plan covers the full selected set.
      nested <-
        if null needs
          then pure []
          else withMultiProgress pcfg "Updating packages" (length needs) $ \mh ->
            let env' = env {aeMulti = mh}
             in mapConcurrentlyN
                  (aeJobs env')
                  (uncurry (applyNeedsWorkTracked env' overlayRoot))
                  needs
      let outcomes = carried <> concat nested
      unless (any outcomeIsHardFail outcomes) $
        cleanupRunSuccess (aeTempRun env)
      pure outcomes

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
