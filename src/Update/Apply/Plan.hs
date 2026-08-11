{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Plan phase for @update@: needs-work determination, reuse/full classify,
-- and pure disk-unit builders for the free-space gate.
module Update.Apply.Plan
  ( -- * Plan results
    PackagePlanResult (..),
    PlannedWork (..),
    planResultKey,
    planResultToOutcome,
    needsWorkDepsAssets,
    needsWorkCargo,

    -- * Plan phase
    PlanEnv (..),
    planPackages,
    planPackage,

    -- * Classify
    ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    classifyNeedsWorkPackages,
    classifyPackageUnits,

    -- * Pure disk units
    PvDiskEstimate (..),
    estimateReuseTempNeed,
    estimateFullTempNeed,
    buildUnitPlanFromPvEstimates,
    buildUnitPlansFromClassified,
    unitPlansFromClassifyResults,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress
  ( MultiHandle (..),
    ProgressConfig,
    withMultiProgress,
  )
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Types (Ebuild (..))
import Overlay.Version
  ( EbuildVersion,
    renderPVNoRev,
  )
import System.FilePath ((</>))
import Update.Assets.Layout
  ( distfileKindForEcosystem,
    distfileTarballName,
    modelsDistfileName,
    releaseTag,
  )
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseOps (..),
    findAssetByName,
  )
import Update.Check
  ( PackageEntry (..),
    checkPackage,
    contentFixPVs,
  )
import Update.CheckCache
  ( CheckCacheHandle,
    computeFingerprint,
    lookupDeps,
    recordFetch,
    recordHit,
    storeDeps,
  )
import Update.Deps.Plan
  ( DepsPlanOps,
    planDepsPackageWithProgress,
  )
import Update.DiskSpace
  ( MaterializeClass (..),
    UnitDiskPlan (..),
    estimateNeedBytes,
    lookupManifestBaselineForClass,
    materializeClassFull,
    readManifestMaybe,
  )
import Update.Go.Lanes
  ( RuntimeLanePlan (..),
    missingTargets,
    planErrorMessage,
    planNeedsWork,
  )
import Update.Go.Plan (PlanProgress (..), localNonLivePVs)
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    Fetcher,
    OutdatedLine (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    UpdateTechnique (..),
    ecosystemIsCargo,
    splitPackageKey,
  )

------------------------------------------------------------------------
-- Plan result types
------------------------------------------------------------------------

-- | Per-package outcome of the update plan phase (no mutation).
data PackagePlanResult
  = PlanSoftSkip PackageKey Text
  | PlanHardFail PackageKey Text
  | PlanNeedsWork PackageKey PlannedWork
  deriving (Eq, Show)

-- | Work that mutate will perform for a needs-work package.
data PlannedWork
  = PlannedGitMv
      { pgRemote :: EbuildVersion
      }
  | PlannedDeps
      { pdEco :: EcosystemSpec,
        pdSource :: UpdateSource,
        pdPlan :: RuntimeLanePlan,
        pdLocalPVs :: [EbuildVersion],
        pdContentFix :: [EbuildVersion]
      }
  deriving (Eq, Show)

planResultKey :: PackagePlanResult -> PackageKey
planResultKey = \case
  PlanSoftSkip k _ -> k
  PlanHardFail k _ -> k
  PlanNeedsWork k _ -> k

-- | Carry plan soft-skip / hard-fail into apply outcomes (no re-plan).
planResultToOutcome :: PackagePlanResult -> Maybe ApplyOutcome
planResultToOutcome = \case
  PlanSoftSkip k r -> Just (ApplySoftSkip k r)
  PlanHardFail k m -> Just (ApplyHardFail k m False False)
  PlanNeedsWork {} -> Nothing

needsWorkDepsAssets :: PackagePlanResult -> Bool
needsWorkDepsAssets = \case
  PlanNeedsWork _ PlannedDeps {} -> True
  _ -> False

needsWorkCargo :: PackagePlanResult -> Bool
needsWorkCargo = \case
  PlanNeedsWork _ (PlannedDeps eco _ _ _ _) -> ecosystemIsCargo eco
  _ -> False

------------------------------------------------------------------------
-- Plan environment + concurrent plan
------------------------------------------------------------------------

data PlanEnv = PlanEnv
  { peFetcher :: Fetcher,
    peDepsPlanOps :: DepsPlanOps,
    peCheckCache :: CheckCacheHandle,
    peJobs :: Int,
    peMulti :: MultiHandle
  }

-- | Concurrent plan over selected packages with multi-progress.
planPackages ::
  ProgressConfig ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  Int ->
  [PackageEntry] ->
  Map.Map PackageKey [Ebuild] ->
  IO [PackagePlanResult]
planPackages pcfg fetch depsOps cache jobs selected byPkg =
  withMultiProgress pcfg "Planning packages" (length selected) $ \mh ->
    let env =
          PlanEnv
            { peFetcher = fetch,
              peDepsPlanOps = depsOps,
              peCheckCache = cache,
              peJobs = jobs,
              peMulti = mh
            }
     in mapConcurrentlyN jobs (planPackageTracked env byPkg) selected

planPackageTracked ::
  PlanEnv ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO PackagePlanResult
planPackageTracked env byPkg entry = do
  let key = peKey entry
      mh = peMulti env
  mhStart mh key
  result <- planPackage env byPkg entry
  case result of
    PlanSoftSkip _ reason -> mhSkip mh key (shortReason reason)
    PlanHardFail _ msg -> mhFail mh key (shortReason msg)
    PlanNeedsWork _ _ -> mhSuccess mh key
  pure result

planPackage ::
  PlanEnv ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO PackagePlanResult
planPackage env byPkg entry =
  case lookupPolicy (peKey entry) of
    Nothing ->
      pure $ PlanSoftSkip (peKey entry) "no hardcoded policy for package"
    Just policy ->
      case policyTechnique policy of
        Unsupported reason ->
          pure $
            PlanSoftSkip
              (peKey entry)
              ("unsupported update technique: " <> reason)
        GitMvAndManifest ->
          planGitMv env entry (Map.findWithDefault [] (peKey entry) byPkg)
        DepsAndAssets eco ->
          planDeps
            env
            entry
            (Map.findWithDefault [] (peKey entry) byPkg)
            (policySource policy)
            eco

planGitMv :: PlanEnv -> PackageEntry -> [Ebuild] -> IO PackagePlanResult
planGitMv env entry locals = do
  let key = peKey entry
      mh = peMulti env
  mhStatus mh key "fetching"
  report <- checkPackage (peFetcher env) (peCheckCache env) entry locals
  pure $ case reportStatus report of
    FetchError err -> PlanHardFail key ("fetch failed: " <> err)
    Unconfigured -> PlanSoftSkip key "no hardcoded policy for package"
    Ok _ -> PlanSoftSkip key "already at latest upstream version"
    Ahead _ _ -> PlanSoftSkip key "already at latest upstream version"
    Outdated lines_ ->
      case lines_ of
        (ol : _) -> PlanNeedsWork key (PlannedGitMv (olTo ol))
        [] -> PlanSoftSkip key "already at latest upstream version"

planDeps ::
  PlanEnv ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  EcosystemSpec ->
  IO PackagePlanResult
planDeps env entry locals src eco = do
  let key = peKey entry
      mh = peMulti env
      cache = peCheckCache env
      depsOps = peDepsPlanOps env
      progress = planProgress mh key eco
      localPVs = localNonLivePVs locals
  fp <- computeFingerprint src locals
  mCached <- lookupDeps cache key fp
  planResult <- case mCached of
    Just plan -> do
      recordHit cache
      pure (Right plan)
    Nothing -> do
      recordFetch cache
      planDepsPackageWithProgress depsOps progress eco src localPVs
  case planResult of
    Left err ->
      pure $
        PlanHardFail
          key
          ("runtime-lane plan failed: " <> planErrorMessage err)
    Right plan -> do
      case mCached of
        Nothing -> storeDeps cache key fp plan
        Just _ -> pure ()
      contentFix <- contentFixPVs depsOps eco src locals plan
      if not (planNeedsWork localPVs contentFix plan)
        then pure $ PlanSoftSkip key "already matches runtime-lane plan"
        else
          pure $
            PlanNeedsWork
              key
              PlannedDeps
                { pdEco = eco,
                  pdSource = src,
                  pdPlan = plan,
                  pdLocalPVs = localPVs,
                  pdContentFix = contentFix
                }

planProgress :: MultiHandle -> PackageKey -> EcosystemSpec -> PlanProgress
planProgress mh key eco =
  let ceilLabel = case eco of
        Go _ -> "discovering go ceilings"
        NpmEco -> "discovering nodejs ceilings"
        Bun -> "discovering bun-bin ceilings"
        Cargo {} -> "discovering rust ceilings"
        Sbcl -> "discovering sbcl ceilings"
      probeLabel = case eco of
        Go _ -> "probing go.mod"
        NpmEco -> "probing engines.node"
        Bun -> "probing engines.bun"
        Cargo {} -> "probing rust-version"
        Sbcl -> "probing sbcl.version"
   in PlanProgress
        { ppOnCeilingsStart = do
            mhSteps mh key 3
            mhStatus mh key ceilLabel,
          ppOnCeilingsDone = mhStep mh key ceilLabel,
          ppOnListStart = mhStatus mh key "listing versions",
          ppOnListDone = \_n -> mhStep mh key "listing versions",
          ppOnProbeDone = mhStep mh key probeLabel
        }

shortReason :: Text -> Text
shortReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

------------------------------------------------------------------------
-- Classify reuse vs full
------------------------------------------------------------------------

-- | One heavy PV unit after release probe classification.
data ClassifiedPvUnit = ClassifiedPvUnit
  { cpuKey :: PackageKey,
    cpuPN :: Text,
    cpuPV :: EbuildVersion,
    cpuEco :: EcosystemSpec,
    cpuClass :: MaterializeClass,
    -- | Baseline compressed size for temp estimate (reuse size or full Manifest/floor).
    cpuTempBaseline :: Maybe Integer
  }
  deriving (Eq, Show)

data ClassifyPackageResult
  = ClassifyOk PackageKey [ClassifiedPvUnit]
  | -- | Probe/API error — hard-fail package; exclude from gate units.
    ClassifyHardFail PackageKey Text
  deriving (Eq, Show)

classifyNeedsWorkPackages ::
  ReleaseOps ->
  Text ->
  Text ->
  FilePath ->
  [PackagePlanResult] ->
  IO [ClassifyPackageResult]
classifyNeedsWorkPackages releaseOps owner repo overlayRoot results =
  mapM (classifyOne releaseOps owner repo overlayRoot) needs
  where
    needs = [r | r@PlanNeedsWork {} <- results]

classifyOne ::
  ReleaseOps ->
  Text ->
  Text ->
  FilePath ->
  PackagePlanResult ->
  IO ClassifyPackageResult
classifyOne releaseOps owner repo overlayRoot = \case
  PlanNeedsWork key (PlannedGitMv {}) ->
    -- GitMv is not release-classified; pure dist estimate is applied later.
    pure (ClassifyOk key [])
  PlanNeedsWork key work@PlannedDeps {} ->
    case splitPackageKey key of
      Just (_cat, pn) ->
        classifyPackageUnits
          releaseOps
          owner
          repo
          overlayRoot
          key
          pn
          work
      Nothing ->
        pure $
          ClassifyHardFail key "invalid package key"
  other -> pure (ClassifyOk (planResultKey other) [])

classifyPackageUnits ::
  ReleaseOps ->
  Text ->
  Text ->
  FilePath ->
  PackageKey ->
  Text ->
  PlannedWork ->
  IO ClassifyPackageResult
classifyPackageUnits releaseOps owner repo overlayRoot key pn work =
  case work of
    PlannedGitMv {} -> pure (ClassifyOk key [])
    PlannedDeps eco _src plan localPVs contentFix -> do
      let needPVs = missingTargets localPVs plan <> contentFix
          pkgDir = case splitPackageKey key of
            Just (cat, p) -> overlayRoot </> T.unpack cat </> T.unpack p
            Nothing -> overlayRoot
      if null needPVs
        then pure (ClassifyOk key []) -- prune-only: no heavy unit
        else do
          mMan <- readManifestMaybe pkgDir
          classified <- mapM (classifyPv releaseOps owner repo eco key pn mMan) needPVs
          pure $ case sequence classified of
            Left err -> ClassifyHardFail key err
            Right units -> ClassifyOk key units

classifyPv ::
  ReleaseOps ->
  Text ->
  Text ->
  EcosystemSpec ->
  PackageKey ->
  Text ->
  Maybe Text ->
  EbuildVersion ->
  IO (Either Text ClassifiedPvUnit)
classifyPv releaseOps owner repo eco key pn mMan pv = do
  let pvNoRev = renderPVNoRev pv
      assetNames = map T.pack (requiredAssetBasenames key eco pn pvNoRev)
      tag = releaseTag pn pvNoRev
      fullCls = materializeClassFull eco
  eres <- roGetReleaseByTag releaseOps owner repo tag
  pure $ case eres of
    Left err -> Left ("release asset lookup failed: " <> err)
    Right Nothing ->
      Right $ fullUnit key pn pv eco fullCls mMan
    Right (Just info) ->
      let assets = mapMaybe (findAssetByName info) assetNames
       in if length assets /= length assetNames
            then Right $ fullUnit key pn pv eco fullCls mMan
            else
              let mSize = case assets of
                    (a : _) -> raSize a
                    [] -> Nothing
               in case mSize of
                    Just n
                      | n > 0 ->
                          Right
                            ClassifiedPvUnit
                              { cpuKey = key,
                                cpuPN = pn,
                                cpuPV = pv,
                                cpuEco = eco,
                                cpuClass = ReusePath,
                                cpuTempBaseline = Just n
                              }
                    _ ->
                      let mBase =
                            mMan >>= (`lookupManifestBaselineForClass` ReusePath)
                       in Right
                            ClassifiedPvUnit
                              { cpuKey = key,
                                cpuPN = pn,
                                cpuPV = pv,
                                cpuEco = eco,
                                cpuClass = ReusePath,
                                cpuTempBaseline = mBase
                              }

fullUnit ::
  PackageKey ->
  Text ->
  EbuildVersion ->
  EcosystemSpec ->
  MaterializeClass ->
  Maybe Text ->
  ClassifiedPvUnit
fullUnit key pn pv eco fullCls mMan =
  let mBase = mMan >>= (`lookupManifestBaselineForClass` fullCls)
   in ClassifiedPvUnit
        { cpuKey = key,
          cpuPN = pn,
          cpuPV = pv,
          cpuEco = eco,
          cpuClass = fullCls,
          cpuTempBaseline = mBase
        }

requiredAssetBasenames :: PackageKey -> EcosystemSpec -> Text -> Text -> [FilePath]
requiredAssetBasenames key eco pn pvNoRev =
  let primary = distfileTarballName (distfileKindForEcosystem eco) pn pvNoRev
      extras =
        case key of
          PackageKey "dev-util/opencode" -> [modelsDistfileName pn pvNoRev]
          _ -> []
   in primary : extras

------------------------------------------------------------------------
-- Pure disk unit builders
------------------------------------------------------------------------

-- | Per-PV estimated needs before package-level max collapse.
data PvDiskEstimate = PvDiskEstimate
  { pveClass :: MaterializeClass,
    pveTempNeed :: Integer,
    pveDistNeed :: Integer
  }
  deriving (Eq, Show)

estimateReuseTempNeed :: Maybe Integer -> Integer
estimateReuseTempNeed = estimateNeedBytes ReusePath

estimateFullTempNeed :: EcosystemSpec -> Maybe Integer -> Integer
estimateFullTempNeed eco = estimateNeedBytes (materializeClassFull eco)

-- | Collapse sequential multi-PV estimates into one concurrent unit (max needs).
buildUnitPlanFromPvEstimates ::
  PackageKey ->
  [PvDiskEstimate] ->
  Maybe UnitDiskPlan
buildUnitPlanFromPvEstimates _ [] = Nothing
buildUnitPlanFromPvEstimates key estimates@(e0 : _) =
  let tempNeed = maximum (map pveTempNeed estimates)
      distNeed = maximum (map pveDistNeed estimates)
      cls =
        case [pveClass e | e <- estimates, pveTempNeed e == tempNeed] of
          (c : _) -> c
          [] -> pveClass e0
   in if tempNeed <= 0 && distNeed <= 0
        then Nothing
        else
          Just
            UnitDiskPlan
              { udpKey = key,
                udpClass = cls,
                udpTempNeed = tempNeed,
                udpDistNeed = distNeed
              }

-- | Pure: classified PV units → package-level @[UnitDiskPlan]@ (max-PV, omit empty).
buildUnitPlansFromClassified :: [ClassifiedPvUnit] -> [UnitDiskPlan]
buildUnitPlansFromClassified units =
  let byKey = foldl' insert [] units
   in mapMaybe (\(k, us) -> buildUnitPlanFromPvEstimates k (map toEst us)) byKey
  where
    insert acc u =
      case lookup (cpuKey u) acc of
        Nothing -> (cpuKey u, [u]) : acc
        Just us ->
          (cpuKey u, u : us) : filter ((/= cpuKey u) . fst) acc
    toEst u =
      PvDiskEstimate
        { pveClass = cpuClass u,
          pveTempNeed = estimateNeedBytes (cpuClass u) (cpuTempBaseline u),
          pveDistNeed = 0
        }

-- | Combine classify results + GitMv dist plans into gate units.
unitPlansFromClassifyResults ::
  [ClassifyPackageResult] ->
  [UnitDiskPlan] ->
  [UnitDiskPlan]
unitPlansFromClassifyResults classifyResults gitMvUnits =
  let fromClassified =
        buildUnitPlansFromClassified
          [ u
          | ClassifyOk _ us <- classifyResults,
            u <- us
          ]
   in fromClassified <> gitMvUnits
