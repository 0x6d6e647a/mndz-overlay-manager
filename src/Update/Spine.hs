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
import Control.Monad (unless, void)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Overlay.Types (Ebuild)
import Overlay.Version (renderPV)
import System.Exit (ExitCode (..))
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    MutateEnsure (..),
    applyOverlayFromPlan,
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
import Update.GitHub (GitHubLatch, gitHubAbortLog, parseGitHubOrigin, peekGitHubLatch)
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
    readOverlayNodeGypFloor,
    readOverlayQlotFloor,
  )
import Update.Md5Cache (EgencacheRunner)
import Update.Npm.Cache (mkNpmCacheOps)
import Update.OverlayTree
  ( InTree,
    TreeLock,
    newTreeLock,
    withNewTreeLock,
    withOverlayTree,
  )
import Update.OverlayWaves
  ( AdmitSets (..),
    OverlayPlanKind (..),
    bunBinPackageKey,
    classifyAdmit,
    dirtyPreflightStepLabel,
    nodeGypPackageKey,
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
import Update.Process (CommandRunner, ProcessResult (..))
import Update.Process.Docker (resolveMaterializeDockerCfg)
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
    -- | Decrypt the config envelope when a token is required and env is empty.
    usdUnlockConfigToken :: IO (Either Text Text),
    -- | Build release ops for a resolved live token.
    usdMkReleaseOps :: Text -> IO ReleaseOps,
    -- | @git remote get-url origin@ in the assets worktree.
    usdGitOriginUrl :: FilePath -> IO (Either Text Text),
    usdAssetsPathCfg :: Maybe FilePath,
    usdDistDir :: FilePath,
    usdOverlayRoot :: FilePath,
    usdSshOps :: SshAgentOps,
    usdEbuildRunner :: EbuildRunner,
    usdEgencacheRunner :: EgencacheRunner,
    usdPreflightTools :: AssetsPreflight -> IO (Either Text ()),
    -- | Ensure the materialize image for these floors (fake in tests).
    usdEnsureImage :: TreeLock -> NeededFloors -> IO (Either Text EnsureOutcome),
    -- | After mutate: rmi previous default-tag id if unused, then prune -f.
    usdPruneMaterialize :: IO (),
    -- | Best-effort leftover materialize-session sweep (no-op in tests).
    usdSweepMaterialize :: IO (),
    -- | Inner @docker@ CLI for per-unit sessions. @Nothing@ keeps placeholder
    -- ops (tests). Production is @Just productionCommandRunner@.
    usdMaterializeDockerRunner :: Maybe CommandRunner,
    usdGitHubLatch :: GitHubLatch,
    -- | Git Operations Statuspage check before assets @git push@ (no-op when unused).
    usdGitOperationsHealth :: IO (Either Text ()),
    -- | Before workers and the image build, when a selected unit may sign.
    -- Arguments: run root, whether this run may publish assets, overlay root,
    -- assets worktree.
    usdPrepareSigning ::
      FilePath ->
      Bool ->
      FilePath ->
      Maybe FilePath ->
      IO (Either Text ()),
    -- | Kill the session agent before a successful run root is removed.
    usdReleaseSigning :: IO ()
  }

data UpdateSpineResult = UpdateSpineResult
  { usrOutcomes :: [ApplyOutcome],
    usrWarnings :: [Text],
    usrCacheSummary :: Maybe Text
  }
  deriving (Eq, Show)

-- | Token + origin parse when DepsAndAssets work needs GitHub. Fails before mutate.
resolveAssetsGitHub ::
  UpdateSpineDeps ->
  IO
    ( Either
        Text
        ( Maybe FilePath,
          Text,
          Text,
          Maybe Text,
          ReleaseOps
        )
    )
resolveAssetsGitHub deps = do
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
      eTok <-
        case usdGitHubToken deps of
          Just t -> pure (Right t)
          Nothing -> usdUnlockConfigToken deps
      case eTok of
        Left err -> pure (Left err)
        Right token -> do
          eRoot <- validateAssetsPath (usdAssetsPathCfg deps)
          case eRoot of
            Left err -> pure (Left err)
            Right root -> do
              eUrl <- usdGitOriginUrl deps root
              case eUrl of
                Left err -> pure (Left err)
                Right url ->
                  case parseGitHubOrigin url of
                    Left err -> pure (Left err)
                    Right (owner, repo) -> do
                      ops <- usdMkReleaseOps deps token
                      pure (Right (Just root, owner, repo, Just token, ops))

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
      withNewTreeLock
      selected
      byPkg
  mPlanAbort <- peekGitHubLatch (usdGitHubLatch deps)
  case mPlanAbort of
    Just err -> pure (Left (gitHubAbortLog err))
    Nothing -> runAfterPlan deps entries allEbuilds selected planResults cache overlayRoot distDir byPkg jobs pcfg

runAfterPlan ::
  UpdateSpineDeps ->
  [PackageEntry] ->
  [Ebuild] ->
  [PackageEntry] ->
  [PackagePlanResult] ->
  CheckCacheHandle ->
  FilePath ->
  FilePath ->
  Map.Map PackageKey [Ebuild] ->
  Int ->
  ProgressConfig ->
  IO (Either Text UpdateSpineResult)
runAfterPlan deps entries _allEbuilds selected planResults cache overlayRoot distDir _byPkg jobs pcfg = do
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
          then resolveAssetsGitHub deps
          else
            pure $
              Right
                ( Nothing,
                  usdAssetsOwner deps,
                  usdAssetsRepo deps,
                  usdGitHubToken deps,
                  usdReleaseOps deps
                )
      case eTokenAssets of
        Left err -> pure (Left err)
        Right (mAssetsRoot, assetsOwner, assetsRepo, resolvedToken, releaseOps) -> do
          let withheldNeedsWork =
                [ r
                | r@PlanNeedsWork {} <- planResults,
                  planResultKey r `elem` withheldKeys
                ]
          -- CLASSIFY admitted and withheld hypo-planned consumers (t0 floors)
          classifyResults <-
            classifyNeedsWorkPackages
              releaseOps
              assetsOwner
              assetsRepo
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
              ePrefloors <-
                withNewTreeLock $ \tree -> do
                  eBun <- bunFloorForEnsure tree overlayRoot planResults'
                  eQlot <- qlotFloorForEnsure tree overlayRoot planResults'
                  eNode <- nodeGypFloorForEnsure tree overlayRoot
                  pure ((,,) <$> eBun <*> eQlot <*> eNode)
              case ePrefloors of
                Left err -> pure (Left err)
                Right (bunFloor, qlotFloor, nodeGypFloor) -> do
                  treeLock <- newTreeLock
                  let t0Floors =
                        neededFloorsFromClassified
                          classifyResults
                          planResults'
                          bunFloor
                          qlotFloor
                          nodeGypFloor
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
                      nodeGypNeedsWork =
                        any
                          ( \case
                              PlanNeedsWork k _ ->
                                k == nodeGypPackageKey
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
                              ),
                              ( willEnsure && nodeGypNeedsWork && isJust (nfNodeGyp t0Floors),
                                nodeGypPackageKey
                              )
                            ]
                        ]
                      recordEnsure outcome = do
                        writeIORef t0EnsureOutcome (Just outcome)
                        pure outcome
                      runEnsure classifyForFloors plansForFloors mh = do
                        eLive <-
                          withOverlayTree treeLock $ \tree -> do
                            eBun <- bunFloorForEnsure tree overlayRoot plansForFloors
                            eQlot <- qlotFloorForEnsure tree overlayRoot plansForFloors
                            eNode <- nodeGypFloorForEnsure tree overlayRoot
                            pure ((,,) <$> eBun <*> eQlot <*> eNode)
                        case eLive of
                          Left err -> recordEnsure (Left err)
                          Right (bunFl, qlotFl, nodeGypFl) -> do
                            let floors =
                                  neededFloorsFromClassified
                                    classifyForFloors
                                    plansForFloors
                                    bunFl
                                    qlotFl
                                    nodeGypFl
                            if floorsIsEmpty floors
                              then recordEnsure (Right ())
                              else do
                                for_ (fullPathKeysFromClassify classifyForFloors) $ \k ->
                                  mhStatus mh k ensuringMaterializeImageStatus
                                usdEnsureImage deps treeLock floors >>= \case
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
                            assetsOwner
                            assetsRepo
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
                      maySign =
                        any
                          ( \case
                              PlanNeedsWork _ _ -> True
                              _ -> False
                          )
                          planResults'
                      mayPublishAssets =
                        any
                          ( \case
                              PlanNeedsWork _ PlannedDeps {} -> True
                              _ -> False
                          )
                          planResults'
                      runMutate = do
                        assetsLock <- newMVar ()
                        overlayLock <- newMVar ()
                        tempRun <- openRunRoot
                        eSign <-
                          if maySign
                            then
                              usdPrepareSigning
                                deps
                                (rrPath tempRun)
                                mayPublishAssets
                                overlayRoot
                                mAssetsRoot
                            else pure (Right ())
                        case eSign of
                          Left err ->
                            pure
                              [ ApplyHardFail
                                  (PackageKey "")
                                  err
                                  False
                                  False
                              ]
                          Right () ->
                            mutateSigned assetsLock overlayLock tempRun
                      mutateSigned assetsLock overlayLock tempRun = do
                        unless (null t0FullKeys) $
                          usdSweepMaterialize deps
                        mMatDocker <-
                          case usdMaterializeDockerRunner deps of
                            Nothing -> pure Nothing
                            Just inner
                              | null t0FullKeys -> pure Nothing
                              | otherwise -> do
                                  cfg <- resolveMaterializeDockerCfg (rrRunId tempRun)
                                  pure (Just (cfg, inner))
                        let closedRun _ =
                              pure
                                ProcessResult
                                  { prExitCode = ExitFailure 127,
                                    prStdout = "",
                                    prStderr = "internal: materialize session not opened"
                                  }
                            env =
                              ApplyEnv
                                { aeFetcher = usdFetcher deps,
                                  aeGitOps = usdGitOps deps,
                                  aeEbuildRunner = usdEbuildRunner deps,
                                  aeEgencacheRunner = usdEgencacheRunner deps,
                                  aeVendorOps = mkVendorOps closedRun,
                                  aeNpmCacheOps = mkNpmCacheOps closedRun,
                                  aeBunCacheOps = mkBunCacheOps closedRun,
                                  aeCargoOps = mkCargoOps closedRun,
                                  aeSbclDepsOps = mkSbclDepsOps closedRun,
                                  aeReleaseOps = releaseOps,
                                  aeAssetsRoot = mAssetsRoot,
                                  aeGitHubToken = resolvedToken,
                                  aeAssetsOwner = assetsOwner,
                                  aeAssetsRepo = assetsRepo,
                                  aeAssetsLock = assetsLock,
                                  aeOverlayLock = overlayLock,
                                  aeTreeLock = treeLock,
                                  aeJobs = jobs,
                                  aeMulti = noopMultiHandle,
                                  aePlanOps = toGoPlanOps (usdDepsPlanOps deps),
                                  aeDepsPlanOps = usdDepsPlanOps deps,
                                  aeTempRun = tempRun,
                                  aeCheckCache = cache,
                                  aeMaterializeDocker = mMatDocker,
                                  aeAtomClosure = Nothing,
                                  aeGitOperationsHealth = usdGitOperationsHealth deps,
                                  aeReleaseSigningSession = usdReleaseSigning deps
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
                                      preLock <- newTreeLock
                                      usdEnsureImage deps preLock t0Floors >>= \case
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
                      eDirtyNodeGyp <-
                        if isJust (nfNodeGyp t0Floors)
                          then
                            runDirtyPreflight
                              pcfg
                              (usdGitOps deps)
                              overlayRoot
                              [nodeGypPackageKey]
                          else pure (Right ())
                      case eDirtyNodeGyp of
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
bunFloorForEnsure ::
  InTree ->
  FilePath ->
  [PackagePlanResult] ->
  IO (Either Text (Maybe Text))
bunFloorForEnsure tree overlayRoot =
  overlayGitMvFloorForEnsure bunBinPackageKey (readOverlayBunFloor tree overlayRoot)

-- | Overlay qlot floor for ensure: planned qlot remote when selected GitMv.
qlotFloorForEnsure ::
  InTree ->
  FilePath ->
  [PackagePlanResult] ->
  IO (Either Text (Maybe Text))
qlotFloorForEnsure tree overlayRoot =
  overlayGitMvFloorForEnsure qlotPackageKey (readOverlayQlotFloor tree overlayRoot)

-- | Overlay node-gyp floor for ensure: newest non-live overlay PV (scan after
-- file work when that work precedes docker).
nodeGypFloorForEnsure :: InTree -> FilePath -> IO (Either Text (Maybe Text))
nodeGypFloorForEnsure = readOverlayNodeGypFloor

overlayGitMvFloorForEnsure ::
  PackageKey ->
  IO (Either Text (Maybe Text)) ->
  [PackagePlanResult] ->
  IO (Either Text (Maybe Text))
overlayGitMvFloorForEnsure key scanOverlay plans =
  case [ renderPV remote
       | PlanNeedsWork k (PlannedGitMv remote) <- plans,
         k == key
       ] of
    (pv : _) -> pure (Right (Just pv))
    [] -> scanOverlay
