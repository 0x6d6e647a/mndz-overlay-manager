{-# LANGUAGE OverloadedStrings #-}

-- | Product Apply surface used by the executable.
--
-- Per-package helpers and materialize budgets for unit tests live in
-- 'Update.Apply.TestSupport' (not advertised as product API).
module Update.Apply
  ( applyOverlay,
    foldExitHardFail,
    EbuildRunner,
    productionEbuildRunner,
    ApplyEnv (..),
    -- | Exported for 'Update.Apply.TestSupport' and direct unit tests.
    applyPackagePhase1,
    -- | Exported for multi-progress terminal-handle unit tests.
    applyPackagePhase1Tracked,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig,
    withMultiProgress,
  )
import Data.Text (Text)
import Data.Text qualified as T
import Update.Apply.Env
  ( ApplyEnv (..),
    EbuildRunner,
    productionEbuildRunner,
  )
import Update.Apply.GitMv (applyGitMv)
import Update.Apply.Materialize (applyDepsAndAssets)
import Update.Check (PackageEntry (..))
import Update.Git (GitOps (..))
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateTechnique (..),
    outcomeIsHardFail,
  )

foldExitHardFail :: [ApplyOutcome] -> Bool
foldExitHardFail = any outcomeIsHardFail

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
      -- Concurrent per-package apply; each successful unit commits under
      -- aeOverlayLock (commit-on-unit-success). No deferred barrier phase.
      nested <-
        withMultiProgress pcfg "Updating packages" (length selected) $ \mh ->
          let env' = env {aeMulti = mh}
           in mapConcurrentlyN
                (aeJobs env')
                (applyPackagePhase1Tracked env' overlayRoot)
                selected
      pure (concat nested)

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
