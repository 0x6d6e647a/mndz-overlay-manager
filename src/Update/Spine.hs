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
import Control.Monad (void)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Overlay.Types (Ebuild)
import Overlay.Version (renderPV)
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    MutateEnsure (..),
    applyOverlayFromPlan,
    fetchModelsDevApiJson,
  )
import Update.Apply.Plan
  ( ClassifyPackageResult (..),
    PackagePlanResult (..),
    PlannedWork (..),
    classifyNeedsWorkPackages,
    needsWorkDepsAssets,
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
import Update.Deps.Plan (DepsPlanOps, toGoPlanOps)
import Update.DiskSpace
  ( DiskGateOk (..),
    DiskSpaceProbe,
    resolveTempRoot,
    runDiskSpaceGate,
  )
import Update.Distfiles (lookupPortageDistDir)
import Update.Git (GitOps (..))
import Update.Go.Vendor (mkVendorOps)
import Update.Hardcoded (lookupPolicy)
import Update.Materialize
  ( EnsureOutcome (..),
    NeededFloors (..),
    ensuringMaterializeImageStatus,
    floorsIsEmpty,
    fullPathKeysFromClassify,
    neededFloorsFromClassified,
    readOverlayBunFloor,
    readOverlayQlotFloor,
  )
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (mkNpmCacheOps)
import Update.OverlayWaves
  ( AdmitSets (..),
    OverlayPlanKind (..),
    bunBinPackageKey,
    classifyAdmit,
    dirtyPreflightStepLabel,
    overlayCeilingProviderForKey,
    overlayDirtyPreflightMessage,
    overlayPackageRelDir,
    qlotPackageKey,
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
  eDirty <-
    runDirtyPreflight
      pcfg
      (usdGitOps deps)
      overlayRoot
      (nubOrd (map peKey selected ++ [bunBinPackageKey]))
  case eDirty of
    Left err -> pure (Left err)
    Right () -> do
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
              withheldNeedsWork =
                [ r
                | r@PlanNeedsWork {} <- planResults,
                  planResultKey r `elem` withheldKeys
                ]
          -- CLASSIFY admitted and withheld hypo-planned consumers (t0 floors)
          classifyResults <-
            classifyNeedsWorkPackages
              releaseOps
              (usdAssetsOwner deps)
              (usdAssetsRepo deps)
              overlayRoot
              (admittedPlans ++ withheldNeedsWork)
          let planResults' = mergeClassifyHardFails planResults classifyResults
              admittedAfter =
                [r | r <- planResults', planResultKey r `elem` admittedKeys]
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
              t0EnsureOutcome <- newIORef (Nothing :: Maybe (Either Text ()))
              bunFloor <- bunFloorForEnsure overlayRoot planResults'
              qlotFloor <- qlotFloorForEnsure overlayRoot planResults'
              let t0Floors =
                    neededFloorsFromClassified
                      classifyResults
                      planResults'
                      bunFloor
                      qlotFloor
                  bunNeedsGitMv =
                    any
                      ( \case
                          PlanNeedsWork k PlannedGitMv {} ->
                            k == bunBinPackageKey
                          _ -> False
                      )
                      planResults'
                  qlotNeedsGitMv =
                    any
                      ( \case
                          PlanNeedsWork k PlannedGitMv {} ->
                            k == qlotPackageKey
                          _ -> False
                      )
                      planResults'
                  willEnsure = not (null t0FullKeys)
                  delayCommit =
                    if willEnsure && bunNeedsGitMv
                      then Just bunBinPackageKey
                      else Nothing
                  gateEnsure =
                    [ k
                    | (True, k) <-
                        [ ( willEnsure && bunNeedsGitMv && isJust (nfBun t0Floors),
                            bunBinPackageKey
                          ),
                          ( willEnsure && qlotNeedsGitMv && isJust (nfSbcl t0Floors),
                            qlotPackageKey
                          )
                        ]
                    ]
                  recordEnsure outcome = do
                    writeIORef t0EnsureOutcome (Just outcome)
                    pure outcome
                  runEnsure classifyForFloors plansForFloors mh = do
                    bunFl <- bunFloorForEnsure overlayRoot plansForFloors
                    qlotFl <- qlotFloorForEnsure overlayRoot plansForFloors
                    let floors =
                          neededFloorsFromClassified
                            classifyForFloors
                            plansForFloors
                            bunFl
                            qlotFl
                    if floorsIsEmpty floors
                      then recordEnsure (Right ())
                      else do
                        for_ (fullPathKeysFromClassify classifyForFloors) $ \k ->
                          mhStatus mh k ensuringMaterializeImageStatus
                        usdEnsureImage deps floors >>= \case
                          Left err -> recordEnsure (Left err)
                          Right _ -> recordEnsure (Right ())
                  diskAfterClassify classifyR planned' = do
                    gitMvU <-
                      buildGitMvUnitPlans overlayRoot distDir planned'
                    let newUnits =
                          unitPlansFromClassifyResults classifyR gitMvU
                    if null newUnits
                      then pure (Right planned')
                      else do
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
                        pure $ case disk of
                          Left err -> Left err
                          Right (DiskGateOk _) -> Right planned'
                  prepare _provider consumers mh = do
                    -- Admit withheld consumers on the t0 hypo plan (no disk re-plan).
                    let planned =
                          [ r
                          | r <- planResults',
                            planResultKey r `elem` consumers
                          ]
                        needWork = [r | r@PlanNeedsWork {} <- planned]
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
                        mEns <- readIORef t0EnsureOutcome
                        case mEns of
                          Just (Left err) ->
                            pure (failNeedsWork err planned')
                          Just (Right ()) ->
                            diskAfterClassify classifyR planned' >>= \case
                              Left err ->
                                pure (failNeedsWork err planned')
                              Right ok -> pure ok
                          Nothing -> do
                            eEns <- runEnsure classifyR planned' mh
                            case eEns of
                              Left err ->
                                pure (failNeedsWork err planned')
                              Right () ->
                                diskAfterClassify classifyR planned' >>= \case
                                  Left err ->
                                    pure (failNeedsWork err planned')
                                  Right ok -> pure ok
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
                        emptyMutate =
                          MutateEnsure
                            { meFullPathKeys = [],
                              meImageEnsure = \_ -> pure (Right ()),
                              meDelayCommit = Nothing,
                              meGateEnsureOnFiles = [],
                              meRunEnsure = False
                            }
                    if null t0FullKeys
                      then
                        applyOverlayFromPlan
                          pcfg
                          env
                          overlayRoot
                          entries
                          planResults'
                          prepare
                          emptyMutate
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
                              MutateEnsure
                                { meFullPathKeys = t0FullKeys,
                                  meImageEnsure = t0Ensure,
                                  meDelayCommit = delayCommit,
                                  meGateEnsureOnFiles = gateEnsure,
                                  meRunEnsure = True
                                }
                          else do
                            eEns <-
                              if floorsIsEmpty t0Floors
                                then recordEnsure (Right ()) >> pure (Right EnsureSkipped)
                                else withStepProgress pcfg 1 $ \step -> do
                                  shStep step "Ensuring materialize image"
                                  usdEnsureImage deps t0Floors >>= \case
                                    Left err -> do
                                      void (recordEnsure (Left err))
                                      pure (Left err)
                                    Right out -> do
                                      void (recordEnsure (Right ()))
                                      pure (Right out)
                            case eEns of
                              Right _ ->
                                applyOverlayFromPlan
                                  pcfg
                                  env
                                  overlayRoot
                                  entries
                                  planResults'
                                  prepare
                                  emptyMutate
                              Left err ->
                                applyOverlayFromPlan
                                  pcfg
                                  env
                                  overlayRoot
                                  entries
                                  planResults'
                                  prepare
                                  MutateEnsure
                                    { meFullPathKeys = t0FullKeys,
                                      meImageEnsure = \_ -> pure (Left err),
                                      meDelayCommit = Nothing,
                                      meGateEnsureOnFiles = [],
                                      meRunEnsure = True
                                    }
              eDirtyQlot <-
                if isJust (nfSbcl t0Floors)
                  then
                    runDirtyPreflight
                      pcfg
                      (usdGitOps deps)
                      overlayRoot
                      [qlotPackageKey]
                  else pure (Right ())
              case eDirtyQlot of
                Left err -> pure (Left err)
                Right () -> do
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

-- | Spine-level overlay dirty check on selected package dirs plus bun-bin.
runDirtyPreflight ::
  ProgressConfig ->
  GitOps ->
  FilePath ->
  [PackageKey] ->
  IO (Either Text ())
runDirtyPreflight pcfg gitOps overlayRoot keys =
  withStepProgress pcfg 1 $ \step -> do
    shStep step dirtyPreflightStepLabel
    go keys
  where
    go [] = pure (Right ())
    go (k : ks) =
      case overlayPackageRelDir k of
        Nothing -> go ks
        Just rel -> do
          r <- goPathsDirty gitOps overlayRoot [rel]
          case r of
            Left err -> pure (Left err)
            Right True ->
              pure (Left (overlayDirtyPreflightMessage k rel))
            Right False -> go ks

-- | Overlay bun floor for ensure: planned bun-bin remote when selected GitMv.
bunFloorForEnsure :: FilePath -> [PackagePlanResult] -> IO (Maybe Text)
bunFloorForEnsure overlayRoot =
  overlayGitMvFloorForEnsure bunBinPackageKey (readOverlayBunFloor overlayRoot)

-- | Overlay qlot floor for ensure: planned qlot remote when selected GitMv.
qlotFloorForEnsure :: FilePath -> [PackagePlanResult] -> IO (Maybe Text)
qlotFloorForEnsure overlayRoot =
  overlayGitMvFloorForEnsure qlotPackageKey (readOverlayQlotFloor overlayRoot)

overlayGitMvFloorForEnsure ::
  PackageKey ->
  IO (Maybe Text) ->
  [PackagePlanResult] ->
  IO (Maybe Text)
overlayGitMvFloorForEnsure key scanOverlay plans =
  case [ renderPV remote
       | PlanNeedsWork k (PlannedGitMv remote) <- plans,
         k == key
       ] of
    (pv : _) -> pure (Just pv)
    [] -> scanOverlay
