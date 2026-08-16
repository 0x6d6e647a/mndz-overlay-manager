{-# LANGUAGE OverloadedStrings #-}

-- | Testable @update@ spine: plan → conditional preflight → classify → disk gate → mutate.
module Update.Spine
  ( UpdateSpineDeps (..),
    UpdateSpineResult (..),
    runUpdatePhases,
  )
where

import CLI.Progress
  ( ProgressConfig,
    StepHandle (..),
    noopMultiHandle,
    withStepProgress,
  )
import Control.Concurrent.MVar (newMVar)
import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Overlay.Types (Ebuild)
import Update.Apply
  ( ApplyEnv (..),
    applyOverlayFromPlan,
    fetchModelsDevApiJson,
    productionEbuildRunner,
  )
import Update.Apply.Plan
  ( ClassifyPackageResult (..),
    PackagePlanResult (..),
    classifyNeedsWorkPackages,
    needsWorkDepsAssets,
    planPackages,
    unitPlansFromClassifyResults,
  )
import Update.Assets.Release (ReleaseOps (..))
import Update.Bun.Cache (mkBunCacheOps)
import Update.Cargo.Crates (mkCargoOps)
import Update.Check
  ( PackageEntry (..),
    groupByPackage,
  )
import Update.CheckCache
  ( CheckCacheHandle,
    cacheSummaryLine,
    flushCheckCache,
  )
import Update.Deps.Plan (DepsPlanOps, toGoPlanOps)
import Update.DiskSpace
  ( DiskGateOk (..),
    DiskSpaceProbe,
    resolveTempRoot,
    runDiskSpaceGate,
  )
import Update.Distfiles (lookupPortageDistDir)
import Update.Git (GitOps)
import Update.Go.Vendor (mkVendorOps)
import Update.Md5Cache (productionEgencacheRunner)
import Update.Npm.Cache (mkNpmCacheOps)
import Update.Preflight
  ( AssetsPreflight (..),
    assetsPreflightFromPlan,
    buildGitMvUnitPlans,
    preflightUpdateTools,
    validateAssetsPath,
  )
import Update.Process.Docker (productionMaterializeRunner)
import Update.Sbcl.Deps (mkSbclDepsOps)
import Update.SshAgent
  ( SshAgentOps,
    ensureSshAgent,
    teardownSshSession,
  )
import Update.TempWorkspace (RunRoot (..), openRunRoot)
import Update.Types
  ( ApplyOutcome (..),
    Fetcher,
    PackageKey (..),
  )

-- | Injectable dependencies for the update spine (tests override probes/ops).
data UpdateSpineDeps = UpdateSpineDeps
  { usdJobs :: Int,
    usdProgress :: ProgressConfig,
    usdFetcher :: Fetcher,
    usdDepsPlanOps :: DepsPlanOps,
    usdReleaseOps :: ReleaseOps,
    usdDiskProbe :: DiskSpaceProbe,
    usdGitOps :: GitOps,
    usdCheckCache :: CheckCacheHandle,
    usdAssetsOwner :: Text,
    usdAssetsRepo :: Text,
    usdGitHubToken :: Maybe Text,
    usdAssetsPathCfg :: Maybe FilePath,
    usdDistDir :: FilePath,
    usdOverlayRoot :: FilePath,
    usdSshOps :: SshAgentOps
  }

data UpdateSpineResult = UpdateSpineResult
  { usrOutcomes :: [ApplyOutcome],
    usrWarnings :: [Text],
    usrCacheSummary :: Maybe Text
  }
  deriving (Eq, Show)

-- | Production spine after spine tools / layout / distfiles already succeeded.
--
-- Order: plan → (token/assets/xz if needs-work DepsAndAssets) → classify →
-- language tools → disk gate → mutate. Always mutates after successful gate.
runUpdatePhases ::
  UpdateSpineDeps ->
  [PackageEntry] ->
  [Ebuild] ->
  [PackageEntry] ->
  IO (Either Text UpdateSpineResult)
runUpdatePhases deps entries allEbuilds selected = do
  let jobs = usdJobs deps
      pcfg = usdProgress deps
      cache = usdCheckCache deps
      overlayRoot = usdOverlayRoot deps
      distDir = usdDistDir deps
      byPkg = groupByPackage allEbuilds
  -- PLAN
  planResults <-
    planPackages
      pcfg
      (usdFetcher deps)
      (usdDepsPlanOps deps)
      cache
      jobs
      selected
      byPkg
  let needDeps = any needsWorkDepsAssets planResults
  -- Conditional assets/token/xz before classify (token needed for probe)
  eTokenAssets <-
    if needDeps
      then do
        toolsAssets <-
          preflightUpdateTools
            AssetsPreflight
              { apNeedAssets = True,
                apNeedGo = False,
                apNeedNpm = False,
                apNeedBun = False,
                apNeedCargo = False,
                apNeedDocker = False
              }
        case toolsAssets of
          Left err -> pure (Left err)
          Right () -> do
            case usdGitHubToken deps of
              Nothing ->
                pure $
                  Left
                    "GitHub token required for assets publish (set github-token in config or GITHUB_TOKEN/GH_TOKEN)"
              Just _ -> do
                eRoot <- validateAssetsPath (usdAssetsPathCfg deps)
                pure $ case eRoot of
                  Left err -> Left err
                  Right p -> Right (Just p)
      else pure (Right Nothing)
  case eTokenAssets of
    Left err -> pure (Left err)
    Right mAssetsRoot -> do
      let releaseOps = usdReleaseOps deps
      -- CLASSIFY
      classifyResults <-
        classifyNeedsWorkPackages
          releaseOps
          (usdAssetsOwner deps)
          (usdAssetsRepo deps)
          overlayRoot
          planResults
      let planResults' = mergeClassifyHardFails planResults classifyResults
          languagePf = assetsPreflightFromPlan planResults' classifyResults
          -- Language/cargo tools only (assets already checked when needDeps).
          langOnly =
            languagePf
              { apNeedAssets = False
              }
      eLang <- preflightUpdateTools langOnly
      case eLang of
        Left err -> pure (Left err)
        Right () -> do
          -- Disk units from needs-work classified + GitMv
          gitMvUnits <- buildGitMvUnitPlans overlayRoot distDir planResults'
          let units = unitPlansFromClassifyResults classifyResults gitMvUnits
          diskGate <-
            withStepProgress pcfg 1 $ \step -> do
              shStep step "Checking free disk space"
              tempRoot <- resolveTempRoot
              mPortage <- lookupPortageDistDir
              runDiskSpaceGate
                (usdDiskProbe deps)
                jobs
                tempRoot
                distDir
                mPortage
                units
          case diskGate of
            Left err -> pure (Left err)
            Right (DiskGateOk warns) -> do
              let runMutate = do
                    assetsLock <- newMVar ()
                    overlayLock <- newMVar ()
                    tempRun <- openRunRoot
                    matRunner <- productionMaterializeRunner (rrPath tempRun)
                    let env =
                          ApplyEnv
                            { aeFetcher = usdFetcher deps,
                              aeGitOps = usdGitOps deps,
                              aeEbuildRunner = productionEbuildRunner distDir,
                              aeEgencacheRunner = productionEgencacheRunner,
                              aeVendorOps = mkVendorOps matRunner,
                              aeNpmCacheOps = mkNpmCacheOps matRunner,
                              aeBunCacheOps = mkBunCacheOps matRunner,
                              aeCargoOps = mkCargoOps matRunner,
                              aeSbclDepsOps = mkSbclDepsOps matRunner,
                              aeReleaseOps = releaseOps,
                              aeFetchModelsDev = fetchModelsDevApiJson,
                              aeAssetsRoot = mAssetsRoot,
                              aeGitHubToken = usdGitHubToken deps,
                              aeAssetsOwner = usdAssetsOwner deps,
                              aeAssetsRepo = usdAssetsRepo deps,
                              aeAssetsLock = assetsLock,
                              aeOverlayLock = overlayLock,
                              aeJobs = jobs,
                              aeMulti = noopMultiHandle,
                              aePlanOps = toGoPlanOps (usdDepsPlanOps deps),
                              aeDepsPlanOps = usdDepsPlanOps deps,
                              aeTempRun = tempRun,
                              aeCheckCache = cache
                            }
                    applyOverlayFromPlan pcfg env overlayRoot entries planResults'
              outcomes <-
                if needDeps
                  then
                    bracket
                      (ensureSshAgent (usdSshOps deps))
                      ( \case
                          Left _ -> pure ()
                          Right sess -> teardownSshSession (usdSshOps deps) sess
                      )
                      ( \case
                          Left err ->
                            pure
                              [ ApplyHardFail
                                  (PackageKey "")
                                  ("SSH agent setup failed: " <> err)
                                  False
                                  False
                              ]
                          Right _sess -> runMutate
                      )
                  else runMutate
              flushCheckCache cache
              mSummary <- cacheSummaryLine cache
              pure $
                Right
                  UpdateSpineResult
                    { usrOutcomes = outcomes,
                      usrWarnings = warns,
                      usrCacheSummary = mSummary
                    }

-- | Promote classify hard-fails into plan results so mutate skips them.
mergeClassifyHardFails ::
  [PackagePlanResult] ->
  [ClassifyPackageResult] ->
  [PackagePlanResult]
mergeClassifyHardFails plans classify =
  let failMap =
        Map.fromList
          [ (k, msg)
          | ClassifyHardFail k msg <- classify
          ]
   in map
        ( \p ->
            case Map.lookup (planKey p) failMap of
              Just msg -> PlanHardFail (planKey p) msg
              Nothing -> p
        )
        plans
  where
    planKey = \case
      PlanSoftSkip k _ -> k
      PlanHardFail k _ -> k
      PlanNeedsWork k _ -> k
