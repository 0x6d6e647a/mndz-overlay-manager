{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    noopPlanProgress,
    productionPlanOps,
    planGoPackage,
    planGoPackageWithProgress,
    localNonLivePVs,
    isLivePackageVersion,
  )
where

import CLI.Jobs (WorkBudget, newWorkBudget, withWorkSlot)
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), parseEbuildVersion)
import Update.GitHub (listGitHubVersionsWith)
import Update.Go.Lanes
  ( GoLanePlan,
    VersionCandidate (..),
    planFromTargets,
    selectAllLaneTargets,
  )
import Update.Go.ModFetch
  ( GoModFetcher,
    GoModKey (..),
    parseGoReqFromMod,
    productionGoModFetcher,
    withGoModCache,
  )
import Update.Go.Tree
  ( GoCeilings,
    PortageqRunner,
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
    poCeilingsCache :: MVar (Maybe GoCeilings)
  }

-- | Optional progress hooks for long Go planning pipelines.
data PlanProgress = PlanProgress
  { ppOnCeilingsStart :: IO (),
    ppOnCeilingsDone :: IO (),
    ppOnListStart :: IO (),
    -- | Called after version list succeeds with the version count so callers
    -- can set step total to @2 + n@ (ceilings + list + one probe each).
    ppOnListDone :: Int -> IO (),
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
--
-- @jobs@ is the resolved package job limit; work budget capacity is @2 * jobs@.
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
discoverCeilingsCached :: PlanOps -> IO (Either Text GoCeilings)
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
          -- Prefer first successful insert if racing.
          final <- readMVar (poCeilingsCache ops)
          pure $ case final of
            Just c' -> Right c'
            Nothing -> Right c

-- | Full plan without progress hooks.
planGoPackage ::
  PlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  IO (Either Text GoLanePlan)
planGoPackage ops = planGoPackageWithProgress ops noopPlanProgress

-- | Full plan: ceilings → version list → go_req probe → lane targets.
planGoPackageWithProgress ::
  PlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  IO (Either Text GoLanePlan)
planGoPackageWithProgress ops progress src mSub =
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
              candidates <-
                buildVersionCandidatesWithProgress
                  ops
                  progress
                  owner
                  repo
                  prefix
                  mSub
                  versions
              let targets = selectAllLaneTargets ceilings candidates
              pure (Right (planFromTargets targets))
    _ -> pure (Left "Go tree-lane planning requires a GitHub update source")

buildVersionCandidatesWithProgress ::
  PlanOps ->
  PlanProgress ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [EbuildVersion] ->
  IO [VersionCandidate]
buildVersionCandidatesWithProgress ops progress owner repo prefix mSub =
  mapConcurrently probe
  where
    probe pv = do
      vc <- withWorkSlot (poWorkBudget ops) (one pv)
      ppOnProbeDone progress
      pure vc
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
    renderPVNoRev (Numeric comps _) =
      T.intercalate "." (map (T.pack . show) comps)
    renderPVNoRev (Raw t) = t
