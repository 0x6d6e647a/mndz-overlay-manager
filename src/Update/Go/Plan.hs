{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    noopPlanProgress,
    productionPlanOps,
    planGoPackage,
    planGoPackageWithProgress,
    planGoPackageWithLocals,
    planGoPackageWithLocalsProgress,
    localNonLivePVs,
    isLivePackageVersion,
  )
where

import CLI.Jobs (WorkBudget, newWorkBudget, withWorkSlot)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.List (sortBy)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, renderPVNoRev)
import Update.GitHub (listGitHubVersionsWith)
import Update.Go.Lanes
  ( GoLanePlan (..),
    LaneTarget (..),
    VersionCandidate (..),
    filterCandidateVersions,
    planFromTargetsWithAtom,
    selectAllLaneTargets,
    zeroPlannedPVsError,
  )
import Update.Go.ModFetch
  ( GoModFetcher,
    GoModKey (..),
    parseGoReqFromMod,
    productionGoModFetcher,
    withGoModCache,
  )
import Update.Go.Tree
  ( PortageqRunner,
    RuntimeCeilings (..),
    discoverGoCeilingsWith,
    productionPortageqRunner,
  )
import Update.Go.Vendor (versionTag)
import Update.Types (UpdateSource (..))

-- | Injectable dependencies for Go tree-lane planning.
data PlanOps = PlanOps
  { poPortageq :: PortageqRunner,
    poListVersions :: UpdateSource -> IO (Either Text [EbuildVersion]),
    poFetchGoMod :: GoModFetcher,
    poWorkBudget :: WorkBudget,
    -- | Process-wide successful ceiling cache for one command run.
    -- 'Nothing' = uncached; failures are not stored as success.
    poCeilingsCache :: MVar (Maybe RuntimeCeilings)
  }

-- | Optional progress hooks for long Go planning pipelines.
data PlanProgress = PlanProgress
  { ppOnCeilingsStart :: IO (),
    ppOnCeilingsDone :: IO (),
    ppOnListStart :: IO (),
    -- | Called after version list succeeds. The @Int@ is the listed version
    -- count (for tests/diagnostics); step total is no longer @2 + n@.
    ppOnListDone :: Int -> IO (),
    -- | Called once when the go.mod probe walk finishes (early exit or end).
    ppOnProbeDone :: IO ()
  }

noopPlanProgress :: PlanProgress
noopPlanProgress =
  PlanProgress
    { ppOnCeilingsStart = pure (),
      ppOnCeilingsDone = pure (),
      ppOnListStart = pure (),
      ppOnListDone = \_ -> pure (),
      ppOnProbeDone = pure ()
    }

-- | Production plan ops with go.mod cache, work budget, and ceiling cache.
productionPlanOps :: Maybe Text -> Int -> IO PlanOps
productionPlanOps mToken jobs = do
  mgr <- newManager tlsManagerSettings
  baseMod <- productionGoModFetcher mToken
  cachedMod <- withGoModCache baseMod
  budget <- newWorkBudget jobs
  ceilingsCache <- newMVar Nothing
  pure
    PlanOps
      { poPortageq = productionPortageqRunner,
        poListVersions = listGitHubVersionsWith mgr mToken,
        poFetchGoMod = cachedMod,
        poWorkBudget = budget,
        poCeilingsCache = ceilingsCache
      }

isLivePackageVersion :: EbuildVersion -> Bool
isLivePackageVersion (Numeric [9999] _) = True
isLivePackageVersion (Raw t) = T.strip t == "9999"
isLivePackageVersion _ = False

-- | Non-live numeric (or raw non-9999) PVs from package ebuilds.
localNonLivePVs :: [Ebuild] -> [EbuildVersion]
localNonLivePVs es =
  [ parseEbuildVersion (ebuildVersion e)
  | e <- es,
    let v = parseEbuildVersion (ebuildVersion e),
    not (isLivePackageVersion v)
  ]

-- | Discover ceilings with process cache; work slot only on real discovery.
discoverCeilingsCached :: PlanOps -> IO (Either Text RuntimeCeilings)
discoverCeilingsCached ops = do
  cached <- readMVar (poCeilingsCache ops)
  case cached of
    Just c -> pure (Right c)
    Nothing -> do
      result <-
        withWorkSlot (poWorkBudget ops) $
          discoverGoCeilingsWith (poPortageq ops)
      case result of
        Left err -> pure (Left err)
        Right c -> do
          modifyMVar_ (poCeilingsCache ops) $ \m ->
            pure $ case m of
              Just existing -> Just existing
              Nothing -> Just c
          final <- readMVar (poCeilingsCache ops)
          pure $ case final of
            Just c' -> Right c'
            Nothing -> Right c

-- | Full plan without progress hooks (no local-PV filter; all listed versions).
-- Prefer 'planGoPackageWithLocals' for production candidate-set rules.
planGoPackage ::
  PlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  IO (Either Text GoLanePlan)
planGoPackage ops = planGoPackageWithProgress ops noopPlanProgress

planGoPackageWithProgress ::
  PlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  IO (Either Text GoLanePlan)
planGoPackageWithProgress ops progress src mSub =
  -- Without local PVs, treat listed upstream as the full candidate set
  -- (tests that mock listVersions only). Production apply/check pass locals.
  planGoPackageWithLocalsProgress ops progress src mSub Nothing

-- | Plan with optional local non-live PVs for the candidate-set rule.
-- When @Just locals@ is empty, hard-fails (first import not supported).
-- When @Nothing@, does not apply the local∪newer filter (test/legacy path).
planGoPackageWithLocals ::
  PlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  Maybe [EbuildVersion] ->
  IO (Either Text GoLanePlan)
planGoPackageWithLocals ops =
  planGoPackageWithLocalsProgress ops noopPlanProgress

planGoPackageWithLocalsProgress ::
  PlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  Maybe [EbuildVersion] ->
  IO (Either Text GoLanePlan)
planGoPackageWithLocalsProgress ops progress src mSub mLocals =
  case src of
    GitHub owner repo prefix -> do
      ppOnCeilingsStart progress
      ceilingsResult <- discoverCeilingsCached ops
      case ceilingsResult of
        Left err -> pure (Left err)
        Right ceilings -> do
          ppOnCeilingsDone progress
          ppOnListStart progress
          versResult <-
            withWorkSlot (poWorkBudget ops) $
              poListVersions ops src
          case versResult of
            Left err -> pure (Left ("list versions failed: " <> err))
            Right versions -> do
              ppOnListDone progress (length versions)
              let candidateFilter = case mLocals of
                    Nothing -> Right versions
                    Just locals -> filterCandidateVersions locals versions
              case candidateFilter of
                Left err -> pure (Left err)
                Right candidatePVs -> do
                  -- Newest-first for early-exit probing.
                  let ordered = sortNewestFirst candidatePVs
                  candidates <-
                    buildVersionCandidatesWithProgress
                      ops
                      progress
                      ceilings
                      owner
                      repo
                      prefix
                      mSub
                      ordered
                  let targets = selectAllLaneTargets ceilings candidates
                      plan =
                        planFromTargetsWithAtom
                          (rcAtom ceilings)
                          targets
                  if null (glpUniquePVs plan)
                    then pure (Left zeroPlannedPVsError)
                    else pure (Right plan)
    _ -> pure (Left "DepsAndAssets Go planning requires a GitHub update source")

sortNewestFirst :: [EbuildVersion] -> [EbuildVersion]
sortNewestFirst =
  sortBy
    ( \a b ->
        case comparePV a b of
          Just LT -> GT
          Just GT -> LT
          Just EQ -> EQ
          Nothing -> compare (show b) (show a)
    )

-- | True when every lane that has a runtime ceiling already has a package target.
allCeilingedLanesFilled :: RuntimeCeilings -> [VersionCandidate] -> Bool
allCeilingedLanesFilled ceilings candidates =
  all laneOk (selectAllLaneTargets ceilings candidates)
  where
    laneOk t = case ltCeiling t of
      Nothing -> True
      Just _ -> isJust (ltPackagePV t)

-- | Newest-first sequential go.mod probes with early exit when all ceilinged
-- lanes have targets. Each probe is gated by the work budget.
buildVersionCandidatesWithProgress ::
  PlanOps ->
  PlanProgress ->
  RuntimeCeilings ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [EbuildVersion] ->
  IO [VersionCandidate]
buildVersionCandidatesWithProgress ops progress ceilings owner repo prefix mSub versions = do
  candidates <- walk [] versions
  ppOnProbeDone progress
  pure candidates
  where
    walk acc [] = pure (reverse acc)
    walk acc (pv : rest)
      | allCeilingedLanesFilled ceilings acc = pure (reverse acc)
      | otherwise = do
          vc <- withWorkSlot (poWorkBudget ops) (one pv)
          walk (vc : acc) rest
    one pv = do
      let tag = versionTag prefix (renderPVNoRev pv)
          key =
            GoModKey
              { gmkOwner = owner,
                gmkRepo = repo,
                gmkTag = tag,
                gmkSubdir = mSub
              }
      body <- poFetchGoMod ops key
      pure $
        VersionCandidate
          { vcPV = stripRev pv,
            vcGoReq = case body of
              Left _ -> Nothing
              Right txt -> parseGoReqFromMod txt
          }
    stripRev (Numeric comps _) = Numeric comps Nothing
    stripRev r = r

-- Silence unused export of atom constant if needed.
