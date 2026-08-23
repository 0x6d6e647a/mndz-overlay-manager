{-# LANGUAGE OverloadedStrings #-}

-- | Testable @update@ spine: plan → conditional preflight → classify → disk gate → mutate.
module Update.Spine
  ( UpdateSpineDeps (..),
    UpdateSpineResult (..),
    runUpdatePhases,
  )
where

import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig,
    StepHandle (..),
    noopMultiHandle,
    withStepProgress,
  )
import Control.Concurrent.MVar (newMVar)
import Control.Exception (bracket)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Overlay.Types (Ebuild)
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    applyOverlayFromPlan,
    fetchModelsDevApiJson,
  )
import Update.Apply.Plan
  ( ClassifyPackageResult (..),
    PackagePlanResult (..),
    PlanEnv (..),
    classifyNeedsWorkPackages,
    needsWorkDepsAssets,
    planPackage,
    planPackages,
    planResultKey,
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
import Update.Deps.Plan (DepsPlanOps, invalidateBunCeilingsCache, toGoPlanOps)
import Update.DiskSpace
  ( DiskGateOk (..),
    DiskSpaceProbe,
    resolveTempRoot,
    runDiskSpaceGate,
  )
import Update.Distfiles (lookupPortageDistDir)
import Update.Git (GitOps)
import Update.Go.Vendor (mkVendorOps)
import Update.Hardcoded (lookupPolicy)
import Update.Materialize
  ( EnsureOutcome (..),
    NeededFloors,
    ensuringMaterializeImageStatus,
    floorsIsEmpty,
    fullPathKeysFromClassify,
    neededFloorsFromClassified,
    readOverlayBunFloor,
  )
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (mkNpmCacheOps)
import Update.OverlayWaves
  ( AdmitSets (..),
    OverlayPlanKind (..),
    classifyAdmit,
    overlayCeilingProviderForKey,
  )
import Update.Preflight
  ( AssetsPreflight (..),
    assetsPreflightFromPlan,
    buildGitMvUnitPlans,
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
    PackagePolicy (..),
    techniqueNeedsAssets,
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
    usdSshOps :: SshAgentOps,
    usdEbuildRunner :: EbuildRunner,
    usdEgencacheRunner :: EgencacheRunner,
    usdPreflightTools :: AssetsPreflight -> IO (Either Text ()),
    -- | Ensure the materialize image for these floors (fake in tests).
    usdEnsureImage :: NeededFloors -> IO (Either Text EnsureOutcome),
    -- | After mutate: rmi previous default-tag id if unused, then prune -f.
    usdPruneMaterialize :: IO ()
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
  let kinds = [(planResultKey r, planKind r) | r <- planResults]
      admit = classifyAdmit overlayCeilingProviderForKey kinds
      admittedKeys = asReady admit
      withheldKeys = map fst (asWithheld admit)
      admittedPlans =
        [r | r <- planResults, planResultKey r `elem` admittedKeys]
      needDepsAdmitted = any needsWorkDepsAssets admittedPlans
      withheldNeedsAssets =
        any
          ( \k ->
              case lookupPolicy k of
                Just pol -> techniqueNeedsAssets (policyTechnique pol)
                Nothing -> False
          )
          withheldKeys
      needDeps = needDepsAdmitted || withheldNeedsAssets
  -- Conditional assets/token before classify (token needed for probe)
  eTokenAssets <-
    if needDeps
      then do
        toolsAssets <-
          usdPreflightTools
            deps
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
      -- CLASSIFY admitted packages only (withheld re-enter after provider commit)
      classifyResults <-
        classifyNeedsWorkPackages
          releaseOps
          (usdAssetsOwner deps)
          (usdAssetsRepo deps)
          overlayRoot
          admittedPlans
      let planResults' = mergeClassifyHardFails planResults classifyResults
          admittedAfter =
            [r | r <- planResults', planResultKey r `elem` admittedKeys]
      -- Docker-on-PATH for admitted full-path is checked inside ensure, not as
      -- a spine-wide gate, so GitMv/reuse can overlap a missing/building image.
      gitMvUnits <- buildGitMvUnitPlans overlayRoot distDir admittedAfter
      let units = unitPlansFromClassifyResults classifyResults gitMvUnits
          t0FullKeys = fullPathKeysFromClassify classifyResults
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
          let runEnsure classifyForFloors plansForFloors mh = do
                bunFloor <- readOverlayBunFloor overlayRoot
                let floors =
                      neededFloorsFromClassified
                        classifyForFloors
                        plansForFloors
                        bunFloor
                if floorsIsEmpty floors
                  then pure (Right ())
                  else do
                    for_ (fullPathKeysFromClassify classifyForFloors) $ \k ->
                      mhStatus mh k ensuringMaterializeImageStatus
                    usdEnsureImage deps floors >>= \case
                      Left err -> pure (Left err)
                      Right _ -> pure (Right ())
              prepare _provider consumers mh = do
                invalidateBunCeilingsCache (usdDepsPlanOps deps)
                let consumerEntries =
                      [e | e <- selected, peKey e `elem` consumers]
                    planEnv =
                      PlanEnv
                        { peFetcher = usdFetcher deps,
                          peDepsPlanOps = usdDepsPlanOps deps,
                          peCheckCache = cache,
                          peJobs = jobs,
                          peMulti = mh,
                          peSelectedKeys = map peKey selected
                        }
                -- Keep waiting presentation; do not mhStart (that is apply).
                planned <- mapM (planPackage planEnv byPkg) consumerEntries
                let needWork = [r | r@PlanNeedsWork {} <- planned]
                classifyR <-
                  classifyNeedsWorkPackages
                    releaseOps
                    (usdAssetsOwner deps)
                    (usdAssetsRepo deps)
                    overlayRoot
                    needWork
                let planned' = mergeClassifyHardFails planned classifyR
                    rePf =
                      (assetsPreflightFromPlan planned' classifyR)
                        { apNeedAssets = False
                        }
                eReLang <- usdPreflightTools deps rePf
                case eReLang of
                  Left err ->
                    pure (failNeedsWork err planned')
                  Right () -> do
                    gitMvU <-
                      buildGitMvUnitPlans overlayRoot distDir planned'
                    let newUnits =
                          unitPlansFromClassifyResults classifyR gitMvU
                    eEns <- runEnsure classifyR planned' mh
                    case eEns of
                      Left err ->
                        pure (failNeedsWork err planned')
                      Right ()
                        | null newUnits ->
                            pure planned'
                        | otherwise -> do
                            tempRoot <- resolveTempRoot
                            mPortage <- lookupPortageDistDir
                            disk <-
                              runDiskSpaceGate
                                (usdDiskProbe deps)
                                jobs
                                tempRoot
                                distDir
                                mPortage
                                newUnits
                            case disk of
                              Left err ->
                                pure (failNeedsWork err planned')
                              Right (DiskGateOk _) ->
                                pure planned'
              runMutate = do
                assetsLock <- newMVar ()
                overlayLock <- newMVar ()
                tempRun <- openRunRoot
                matRunner <- productionMaterializeRunner (rrPath tempRun)
                let env =
                      ApplyEnv
                        { aeFetcher = usdFetcher deps,
                          aeGitOps = usdGitOps deps,
                          aeEbuildRunner = usdEbuildRunner deps,
                          aeEgencacheRunner = usdEgencacheRunner deps,
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
                    overlapReady =
                      [ r
                      | r@(PlanNeedsWork k _) <- admittedAfter,
                        k `notElem` t0FullKeys
                      ]
                    t0Ensure = runEnsure classifyResults planResults'
                if null t0FullKeys
                  then
                    applyOverlayFromPlan
                      pcfg
                      env
                      overlayRoot
                      entries
                      planResults'
                      prepare
                      []
                      (\_ -> pure (Right ()))
                  else
                    if not (null overlapReady)
                      then
                        applyOverlayFromPlan
                          pcfg
                          env
                          overlayRoot
                          entries
                          planResults'
                          prepare
                          t0FullKeys
                          t0Ensure
                      else do
                        bunFloor <- readOverlayBunFloor overlayRoot
                        let floors =
                              neededFloorsFromClassified
                                classifyResults
                                planResults'
                                bunFloor
                        eEns <-
                          if floorsIsEmpty floors
                            then pure (Right EnsureSkipped)
                            else withStepProgress pcfg 1 $ \step -> do
                              shStep step "Ensuring materialize image"
                              usdEnsureImage deps floors
                        case eEns of
                          Right _ ->
                            applyOverlayFromPlan
                              pcfg
                              env
                              overlayRoot
                              entries
                              planResults'
                              prepare
                              []
                              (\_ -> pure (Right ()))
                          Left err ->
                            applyOverlayFromPlan
                              pcfg
                              env
                              overlayRoot
                              entries
                              planResults'
                              prepare
                              t0FullKeys
                              (\_ -> pure (Left err))
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
          usdPruneMaterialize deps
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

planKind :: PackagePlanResult -> OverlayPlanKind
planKind = \case
  PlanSoftSkip {} -> OverlayPlanSkip
  PlanHardFail {} -> OverlayPlanFail
  PlanNeedsWork {} -> OverlayPlanWork

failNeedsWork :: Text -> [PackagePlanResult] -> [PackagePlanResult]
failNeedsWork err =
  map
    ( \case
        PlanNeedsWork k _ -> PlanHardFail k err
        other -> other
    )
