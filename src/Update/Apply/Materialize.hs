{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | DepsAndAssets materialize: plan, distfile, reuse/full publish, step budgets.
module Update.Apply.Materialize
  ( applyDepsAndAssets,
    applyDepsAndAssetsFromPlan,
    contentFixNeeded,
    goPublishAndOverlay,
    markSuccessLinesReused,
    materializePlan,
    orderNeedPlannedUnits,
    fullPathMaterializeSteps,
    reusePathMaterializeSteps,
    materializeStepTotalUpper,
    reviseMaterializeStepTotal,
    fetchModelsDevApiJson,
    harvestVsLaneCeiling,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Applicative ((<|>))
import Control.Concurrent.MVar (withMVar)
import Control.Exception (SomeException, catch)
import Control.Monad (void, when)
import Data.ByteString.Lazy qualified as LBS
import Data.Containers.ListUtils (nubOrd)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (statusCode)
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Types (Ebuild (..))
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    renderPV,
    renderPVNoRev,
    samePV,
  )
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
    removeFile,
  )
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Adequacy
  ( cargoReuseWriteFloor,
    lookupDirectTagFloor,
    requiredAssetBasenames,
  )
import Update.Apply.Commit (egencacheAndSignedCommit, pruneCommitMessage)
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitErrorMessage,
    applyUnitHardFail,
  )
import Update.Apply.GitMv (requirePackageMd5Cache)
import Update.Apply.OverlayWrite (CodexV8Overlay (..), findTemplate, overlayAfterAssets)
import Update.Assets.Hash (FileDigests (..), hashFile, writeSidecars)
import Update.Assets.Layout
  ( SidecarPaths (..),
    commitMessage,
    modelsDistfileName,
    releaseName,
    releaseTag,
    rustyV8CommitMessage,
    rustyV8DirName,
    rustyV8ReleaseName,
    rustyV8ReleaseTag,
    rustyV8SidecarPaths,
    rustyV8SnapshotBasename,
    sidecarPaths,
  )
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseMeta (..),
    ReleaseOps (..),
    findAssetByName,
    lookupNamedAssets,
  )
import Update.AtomClosure (keepPVsForProvider)
import Update.Bun.Cache (BunCacheProgress (..), BunProbe (..), buildBunDepsTarball, bunPackagingModeFor, isBunCompilePinPackage, mkBunCacheOps)
import Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    buildCargoCratesTarball,
    harvestRustyV8Snapshot,
    mkCargoOps,
    parseV8DepsGcsLinux,
    parseV8RegistryPin,
  )
import Update.Cargo.Msrv
  ( parseRustMinVerFromEbuild,
    rustMinVerTooLow,
  )
import Update.Cargo.V8Deps
  ( V8GcsLinuxDists (..),
    extractV8DepsFromSnapshot,
  )
import Update.Check
  ( ContentAssessment (..),
    PackageEntry (..),
    assessOverlayContent,
  )
import Update.CheckCache
  ( cachedCargoPlanUsable,
    computeFingerprintFromDir,
    lookupDeps,
    recordFetch,
    recordHit,
    storeDeps,
  )
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithProgressFor,
  )
import Update.DiskSpace
  ( checkTempNeedAtAdmit,
    estimateNeedBytes,
    getFreeBytes,
    materializeClassFull,
    resolveTempRoot,
  )
import Update.EbuildEdit
  ( bunAtomVersion,
    bunBdependAtomFor,
    cargoProvenanceMismatch,
    goBdependAtom,
    nodejsBdependAtom,
    parseQuotedAssignment,
    sbclBdependAtom,
    writeVersionForPlannedPV,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Go.Lanes
  ( GapLine (..),
    LaneTarget (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    buildGapLines,
    missingTargets,
    planErrorMessage,
    planFromTargets,
    planNeedsWork,
  )
import Update.Go.ModFetch (GoModKey (..), parseGoReqFromMod)
import Update.Go.Plan
  ( PlanProgress (..),
    isLivePackageVersion,
  )
import Update.Go.Vendor
  ( VendorProgress (..),
    VendorResult (..),
    buildVendorTarball,
    mkVendorOps,
    versionTag,
  )
import Update.Hardcoded (lookupLaneArches)
import Update.Npm.Cache
  ( NpmCacheProgress (..),
    buildNpmDepsTarball,
    mkNpmCacheOps,
  )
import Update.OverlayWaves
  ( bunBinPackageKey,
    computeOverlayProviderFingerprint,
    newestNonLivePv,
    overlayCeilingProvider,
    overlayProviderPvMismatchMessage,
  )
import Update.Process.Docker
  ( MaterializeUnitRef (..),
    withUnitMaterializeSession,
  )
import Update.Runtime.Ceilings (discoverBunBinMetas)
import Update.Sbcl.Deps
  ( SbclDepsProgress (..),
    buildSbclDepsTarball,
    mkSbclDepsOps,
    parseSbclVersionFloor,
  )
import Update.TempWorkspace
  ( UnitDirs (..),
    UnitKind (..),
    deleteUnit,
    ensureUnit,
    retainUnitError,
  )
import Update.Types
  ( ApplyOutcome (..),
    CargoSource (..),
    EcosystemSpec (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource (..),
    UpdateTechnique (..),
    packageKeyText,
    splitPackageKey,
  )

applyDepsAndAssets ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  IO [ApplyOutcome]
applyDepsAndAssets env overlayRoot entry src eco = do
  let key = peKey entry
      mh = aeMulti env
      pkgDir = takeDirectory (pePath entry)
      cache = aeCheckCache env
      pn = pePN entry
  planDoneRef <- newIORef (0 :: Int)
  let progress = depsApplyPlanProgress mh key eco planDoneRef
  localPVs <- listLocalNonLivePVs pkgDir pn
  fp <- computeFingerprintFromDir src pkgDir pn
  mProvFp <- computeOverlayProviderFingerprint overlayRoot (DepsAndAssets eco)
  mCached <-
    case (overlayCeilingProvider (DepsAndAssets eco), mProvFp) of
      (Just _, Nothing) -> pure Nothing
      (Just _, Just pfp) -> lookupDeps cache key fp (Just pfp)
      (Nothing, _) -> lookupDeps cache key fp Nothing
  planResult <- case mCached of
    Just plan
      | cachedCargoPlanUsable eco src plan -> do
          recordHit cache
          pure (Right plan)
    _ -> do
      recordFetch cache
      planDepsPackageWithProgressFor
        (aeDepsPlanOps env)
        progress
        eco
        src
        localPVs
        (lookupLaneArches key)
  case planResult of
    Left err ->
      pure
        [ ApplyHardFail
            key
            ("runtime-lane plan failed: " <> planErrorMessage err)
            False
            False
        ]
    Right plan -> do
      -- Persist successful live plans; cache hits leave the existing entry.
      case mCached of
        Nothing -> storeDeps cache key fp mProvFp plan
        Just _ -> pure ()
      locals <- listLocalEbuilds key pn pkgDir
      assessed <- assessOverlayContent eco key pn locals plan
      case assessed of
        Left err ->
          pure [ApplyHardFail key err False False]
        Right (ca, _, _) -> do
          let missing = missingTargets localPVs plan
              contentFix =
                [ pv
                | pv <- caNeedsWorkPVs ca,
                  not (any (samePV pv) missing)
                ]
              forceFull = caForceFullPVs ca
          if not (planNeedsWork localPVs contentFix plan)
            then pure [ApplySoftSkip key "already matches runtime-lane plan"]
            else
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
                Nothing
                =<< readIORef planDoneRef

-- | Mutate using a plan-phase result (skip re-plan / re-content-fix).
applyDepsAndAssetsFromPlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  -- | Hypothetical provider + assumed remote PV, when the working plan used hypo ceilings.
  Maybe (PackageKey, EbuildVersion) ->
  Int ->
  IO [ApplyOutcome]
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
  planDone = do
    let key = peKey entry
        pkgDir = takeDirectory (pePath entry)
        pn = pePN entry
    coherence <- cargoProvenanceGate eco entry
    case coherence of
      Just msg -> pure [ApplyHardFail key msg False False]
      Nothing ->
        if not (planNeedsWork localPVs contentFix plan)
          then pure [ApplySoftSkip key "already matches runtime-lane plan"]
          else do
            asserted <- assertHypoProviderPv overlayRoot key mHypo
            case asserted of
              Left msg ->
                pure [ApplyHardFail key msg False False]
              Right () -> do
                cacheGate <- requirePackageMd5Cache overlayRoot key pkgDir
                case cacheGate of
                  Left unitErr -> pure [applyUnitHardFail key unitErr False False]
                  Right () -> do
                    outcomes <-
                      materializeDepsPlan
                        env
                        overlayRoot
                        entry
                        src
                        eco
                        plan
                        localPVs
                        contentFix
                        forceFull
                        planDone
                    when (any isApplySuccess outcomes) $ do
                      fp' <- computeFingerprintFromDir src pkgDir pn
                      mProvFp' <-
                        computeOverlayProviderFingerprint overlayRoot (DepsAndAssets eco)
                      storeDeps (aeCheckCache env) key fp' mProvFp' plan
                    pure outcomes
    where
      isApplySuccess ApplySuccess {} = True
      isApplySuccess _ = False

-- | Provenance coherence gate (apply-time, before any mutation): every present
-- non-live ebuild of the package must agree with the policy Cargo provenance
-- on the primary source-line form; a mismatch names expected vs observed.
cargoProvenanceGate :: EcosystemSpec -> PackageEntry -> IO (Maybe Text)
cargoProvenanceGate eco entry = case eco of
  Cargo {cargoSource = cargoSrc} -> do
    let pkgDir = takeDirectory (pePath entry)
    locals <- listLocalEbuilds (peKey entry) (pePN entry) pkgDir
    let nonLive =
          [ eb
          | eb <- locals,
            not (isLivePackageVersion (parseEbuildVersion (ebuildVersion eb)))
          ]
    errs <- mapM (checkOne cargoSrc) nonLive
    pure (listToMaybe (catMaybes errs))
  _ -> pure Nothing
  where
    checkOne cargoSrc eb = do
      exists <- doesFileExist (ebuildPath eb)
      if not exists
        then pure Nothing
        else do
          content <- TIO.readFile (ebuildPath eb)
          pure
            ( cargoProvenanceMismatch
                cargoSrc
                (T.pack (takeFileName (ebuildPath eb)))
                content
            )

-- | Overlay write of a hypo-planned consumer requires the provider PV to match.
assertHypoProviderPv ::
  FilePath ->
  PackageKey ->
  Maybe (PackageKey, EbuildVersion) ->
  IO (Either Text ())
assertHypoProviderPv _overlayRoot _key Nothing = pure (Right ())
assertHypoProviderPv overlayRoot key (Just (provider, plannedPv)) = do
  eMetas <-
    if provider == bunBinPackageKey
      then discoverBunBinMetas overlayRoot
      else pure (Left "no overlay provider metas")
  let overlayPv = case eMetas of
        Right metas -> newestNonLivePv metas
        Left _ -> Nothing
  pure $ case overlayPv of
    Just got
      | comparePV got plannedPv == Just EQ -> Right ()
      | otherwise ->
          Left (overlayProviderPvMismatchMessage key provider plannedPv got)
    Nothing ->
      Left
        ( packageKeyText key
            <> ": overlay ceiling provider "
            <> packageKeyText provider
            <> " has no newest non-live ebuild (plan assumed "
            <> renderPV plannedPv
            <> "); the provider bump did not land as planned and this package was not mutated. Restore or finish "
            <> packageKeyText provider
            <> " relative to git HEAD, then retry"
        )

-- | Planning progress during update apply (same 3-step model as outdated).
depsApplyPlanProgress ::
  MultiHandle -> PackageKey -> EcosystemSpec -> IORef Int -> PlanProgress
depsApplyPlanProgress mh key eco doneRef =
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
          ppOnCeilingsDone = do
            atomicModifyIORef' doneRef (\n -> (n + 1, ()))
            mhStep mh key ceilLabel,
          ppOnListStart = mhStatus mh key "listing versions",
          ppOnListDone = \_n -> do
            atomicModifyIORef' doneRef (\d -> (d + 1, ()))
            mhStep mh key "listing versions",
          ppOnProbeDone = do
            atomicModifyIORef' doneRef (\n -> (n + 1, ()))
            mhStep mh key probeLabel
        }

listLocalNonLivePVs :: FilePath -> Text -> IO [EbuildVersion]
listLocalNonLivePVs pkgDir pn = do
  names <- listDirectory pkgDir
  let vers =
        [ parseEbuildVersion (T.pack verStr)
        | name <- names,
          Just (pkg, verStr) <- [parseEbuildFileName name],
          T.pack pkg == pn,
          let v = parseEbuildVersion (T.pack verStr),
          not (isLivePackageVersion v)
        ]
  pure vers

-- | Present planned PVs whose ebuild content, BDEPEND, or Manifest needs fix.
contentFixFromAssessment ::
  EcosystemSpec ->
  PackageKey ->
  Text ->
  FilePath ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixFromAssessment eco key pn pkgDir plan = do
  locals <- listLocalEbuilds key pn pkgDir
  assessed <- assessOverlayContent eco key pn locals plan
  pure $ case assessed of
    Left _ -> []
    Right (ca, _, _) ->
      let missing = missingTargets (map (parseEbuildVersion . ebuildVersion) locals) plan
       in [ pv
          | pv <- caNeedsWorkPVs ca,
            not (any (samePV pv) missing)
          ]

listLocalEbuilds :: PackageKey -> Text -> FilePath -> IO [Ebuild]
listLocalEbuilds key pn pkgDir = do
  names <- listDirectory pkgDir
  let cat = case splitPackageKey key of
        Just (c, _) -> c
        Nothing -> ""
  pure
    [ Ebuild cat pn (T.pack verStr) (pkgDir </> n)
    | n <- names,
      Just (pkg, verStr) <- [parseEbuildFileName n],
      T.pack pkg == pn
    ]

-- | Present planned PVs whose ebuild content, BDEPEND, or Manifest needs fix.
contentFixNeededEnv ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  FilePath ->
  Text ->
  PackageKey ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixNeededEnv _env eco _src pkgDir pn key =
  contentFixFromAssessment eco key pn pkgDir

-- | Full required BDEPEND atom for a planned PV, when obtainable.
fetchRequiredBdependAtom ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageKey ->
  Text ->
  IO (Maybe Text)
fetchRequiredBdependAtom env eco src key pvNoRev =
  case (eco, src) of
    (Go mSub, GitHub owner repo prefix) -> do
      mGo <- fetchGoModVersion env owner repo prefix pvNoRev mSub
      pure (goBdependAtom <$> mGo)
    (NpmEco, Npm npmPkg) -> do
      eres <- dpoFetchNpmEngines (aeDepsPlanOps env) npmPkg pvNoRev
      pure $ case eres of
        Right ver -> Just (nodejsBdependAtom ver)
        Left _ -> Nothing
    (Bun, GitHub owner repo prefix) -> do
      eres <-
        dpoFetchBunEngines (aeDepsPlanOps env) owner repo prefix pvNoRev
      pure $ case eres of
        Right probe ->
          let mVer =
                if isBunCompilePinPackage key
                  then bunProbeExactPin probe <|> Just (bunProbeMinimum probe)
                  else Just (bunProbeMinimum probe)
           in bunBdependAtomFor key <$> mVer
        Left _ -> Nothing
    (Sbcl, GitHub owner repo prefix) -> do
      eres <-
        dpoFetchSbclVersion (aeDepsPlanOps env) owner repo prefix pvNoRev
      pure $ case eres of
        Right body -> sbclBdependAtom <$> parseSbclVersionFloor body
        Left _ -> Nothing
    (Cargo {}, _) -> pure Nothing
    _ -> pure Nothing

-- | Legacy Go-only content fix (tests).
contentFixNeeded ::
  ApplyEnv ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  FilePath ->
  Text ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixNeeded env owner repo prefix mSub pkgDir pn =
  contentFixNeededEnv
    env
    (Go mSub)
    (GitHub owner repo prefix)
    pkgDir
    pn
    (PackageKey (T.pack "legacy/" <> pn))

materializeDepsPlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  Int ->
  IO [ApplyOutcome]
materializeDepsPlan env overlayRoot entry src eco plan localPVs contentFix forceFull planDone = do
  let key = peKey entry
      mh = aeMulti env
      needPVs =
        nubOrd
          ( missingTargets localPVs plan
              <> contentFix
          )
      planned = [pe | pe <- glpEbuilds plan, any (samePV (pePV pe)) needPVs]
      -- Missing PVs before pure content-fix; ascending PV within each group.
      sortedPlanned = orderNeedPlannedUnits localPVs planned
      nPVs = length sortedPlanned
  when (nPVs > 0) $
    mhSteps mh key (materializeStepTotalUpper planDone nPVs)
  stepsDoneRef <- newIORef planDone
  results <- materializeUntilFail stepsDoneRef sortedPlanned
  let failures = [o | o@ApplyHardFail {} <- results]
      successes = [o | o@ApplySuccess {} <- results]
  if not (null failures)
    then pure (successes <> failures)
    else do
      pruneResult <- pruneExtras env overlayRoot entry plan
      case pruneResult of
        Left err ->
          pure
            ( successes
                <> [ApplyHardFail key err True False]
            )
        Right extraPaths
          | null extraPaths ->
              pure $
                if null successes
                  then [ApplySoftSkip key "already matches runtime-lane plan"]
                  else successes
          | otherwise -> do
              committed <-
                egencacheAndSignedCommit
                  env
                  overlayRoot
                  key
                  extraPaths
                  (pruneCommitMessage key)
              pure $ case committed of
                Left err ->
                  successes <> [ApplyHardFail key err True False]
                Right paths
                  | null successes ->
                      let lines_ = gapSuccessLines localPVs needPVs plan
                       in [ApplySuccess key lines_ paths]
                  | otherwise -> successes
  where
    materializeUntilFail _ [] = pure []
    materializeUntilFail stepsDoneRef remaining@(pe : rest) = do
      r <-
        materializeOneDeps
          env
          overlayRoot
          entry
          src
          eco
          localPVs
          plan
          forceFull
          pe
          stepsDoneRef
          (length remaining)
      case r of
        ApplyHardFail {} -> pure [r]
        _ -> do
          more <- materializeUntilFail stepsDoneRef rest
          pure (r : more)

-- | Order planned units that need work: **missing** PVs first (no local
-- non-live same-PV ebuild), then pure **content-fix** PVs; ascending numeric
-- PV within each group. A missing PV is classified as missing even if also
-- content-related.
orderNeedPlannedUnits ::
  [EbuildVersion] ->
  [PlannedEbuild] ->
  [PlannedEbuild]
orderNeedPlannedUnits localPVs =
  sortOn
    ( \pe ->
        let missing = not (any (samePV (pePV pe)) localPVs)
            pvKey = case pePV pe of
              Numeric comps _ -> comps
              Raw _ -> []
         in (if missing then (0 :: Int) else 1, pvKey)
    )

-- | Legacy Go-only entry used by tests.
materializePlan ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  Int ->
  IO [ApplyOutcome]
materializePlan env overlayRoot entry owner repo prefix mSub plan localPVs contentFix =
  materializeDepsPlan
    env
    overlayRoot
    entry
    (GitHub owner repo prefix)
    (Go mSub)
    plan
    localPVs
    contentFix
    []

gapSuccessLines :: [EbuildVersion] -> [EbuildVersion] -> RuntimeLanePlan -> [SuccessLine]
gapSuccessLines localPVs needs plan =
  [ SuccessLine
      { slFrom = glFrom g,
        slTo = glTo g,
        slLabel = Just (glLabel g),
        slAssetsReused = False
      }
  | g <- buildGapLines localPVs needs plan
  ]

-- | Mark success lines as completed via the release-asset reuse path.
markSuccessLinesReused :: [SuccessLine] -> [SuccessLine]
markSuccessLinesReused = map (\sl -> sl {slAssetsReused = True})

materializeOneDeps ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  PlannedEbuild ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
materializeOneDeps env overlayRoot entry src eco localPVs plan forceFull pe stepsDoneRef remainingPVs = do
  let targetVer = case pePV pe of
        Numeric comps _ -> Numeric comps Nothing
        Raw t -> Raw t
      writeVer = writeVersionForPlannedPV targetVer localPVs
      forced = any (samePV targetVer) forceFull
      lines_ =
        filter
          (\sl -> samePV (slTo sl) targetVer)
          (gapSuccessLines localPVs [targetVer] plan)
  depsPublishAndOverlay
    env
    overlayRoot
    entry
    src
    eco
    plan
    forced
    (peKeywords pe)
    lines_
    writeVer
    stepsDoneRef
    remainingPVs

pruneExtras ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  RuntimeLanePlan ->
  IO (Either Text [FilePath])
pruneExtras env overlayRoot entry plan = do
  let pkgDir = takeDirectory (pePath entry)
      pn = pePN entry
      key = peKey entry
  names <- listDirectory pkgDir
  keepResult <-
    keepPVsForProvider
      (aeAtomClosure env)
      overlayRoot
      key
      (glpUniquePVs plan)
  case keepResult of
    Left err -> pure (Left err)
    Right keep -> do
      let extras =
            [ pkgDir </> n
            | n <- names,
              Just (pkg, verStr) <- [parseEbuildFileName n],
              T.pack pkg == pn,
              let v = parseEbuildVersion (T.pack verStr),
              not (isLivePackageVersion v),
              not (any (samePV v) keep)
            ]
      if null extras
        then pure (Right [])
        else do
          mapM_ removeFile extras
          rels <- mapM (relativeOverlayPath overlayRoot) extras
          -- Manifest after deletions.
          manResult <-
            case [n | n <- names, ".ebuild" `T.isSuffixOf` T.pack n, n `notElem` map takeFileName extras] of
              (keepName : _) -> aeEbuildRunner env pkgDir keepName
              [] -> pure (Right ())
          case manResult of
            Left err -> pure (Left err)
            Right () -> do
              manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
              pure (Right (rels <> [manRel]))

-- | Full materialize path: 7 discrete multi-progress steps.
fullPathMaterializeSteps :: Int
fullPathMaterializeSteps = 7

-- | Reuse materialize path: 3 discrete multi-progress steps.
reusePathMaterializeSteps :: Int
reusePathMaterializeSteps = 3

-- | Upper-bound package step total after planning: @planDone + nPVs × 7@.
materializeStepTotalUpper :: Int -> Int -> Int
materializeStepTotalUpper planDone nPVs =
  planDone + nPVs * fullPathMaterializeSteps

-- | After path selection: @stepsDone + thisPath + remainingUnstarted × 7@.
reviseMaterializeStepTotal :: Int -> Int -> Int -> Int
reviseMaterializeStepTotal stepsDone thisPathSteps remainingUnstartedPVs =
  stepsDone + thisPathSteps + remainingUnstartedPVs * fullPathMaterializeSteps

markMaterializeStep :: IORef Int -> MultiHandle -> PackageKey -> Text -> IO ()
markMaterializeStep stepsDoneRef mh key name = do
  atomicModifyIORef' stepsDoneRef (\n -> (n + 1, ()))
  mhStep mh key name

goVendorProgress :: IORef Int -> MultiHandle -> PackageKey -> VendorProgress
goVendorProgress stepsDoneRef mh key =
  VendorProgress
    { vpOnCloneStart = mhStatus mh key "cloning upstream",
      vpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      vpOnDownloadStart = mhStatus mh key "go mod download",
      vpOnDownloadDone = markMaterializeStep stepsDoneRef mh key "go mod download",
      vpOnCompressStart = mhStatus mh key "compressing tarball",
      vpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

depsPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  Bool ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
depsPublishAndOverlay env overlayRoot entry src eco plan forced keywords lines_ targetVer stepsDoneRef remainingPVs = do
  let key = peKey entry
      pn = pePN entry
      pvNoRev = renderPVNoRev targetVer
      assetNames = requiredAssetBasenames key eco pn pvNoRev
      tag = releaseTag pn pvNoRev
      mh = aeMulti env
      remainingAfter = max 0 (remainingPVs - 1)
  case (aeAssetsRoot env, aeGitHubToken env) of
    (Nothing, _) ->
      pure $ applyUnitHardFail key ApplyMissingAssetsPath False False
    (_, Nothing) ->
      pure $ applyUnitHardFail key ApplyMissingGitHubToken False False
    (Just assetsRoot, Just _token) ->
      case splitPackageKey key of
        Nothing ->
          pure $
            applyUnitHardFail key (ApplyInvalidPackageKey Nothing) False False
        Just (category, _) -> do
          mhStatus mh key "probing release asset"
          looked <-
            lookupNamedAssets
              (aeReleaseOps env)
              (aeAssetsOwner env)
              (aeAssetsRepo env)
              tag
              (map T.pack assetNames)
          tagExists <-
            roGetReleaseByTag
              (aeReleaseOps env)
              (aeAssetsOwner env)
              (aeAssetsRepo env)
              tag
          let conflictMsg =
                "existing release "
                  <> aeAssetsOwner env
                  <> "/"
                  <> aeAssetsRepo env
                  <> " "
                  <> tag
                  <> " cannot be reused or fully published; remove or repair that \
                     \release externally before retrying"
          case (looked, tagExists, forced) of
            (Left err, _, _) ->
              pure $
                ApplyHardFail
                  key
                  ("release asset lookup failed: " <> err)
                  False
                  False
            (_, Left err, _) ->
              pure $
                ApplyHardFail
                  key
                  ("release asset lookup failed: " <> err)
                  False
                  False
            (Right (Just downloadUrls), Right (Just _), False) -> do
              done <- readIORef stepsDoneRef
              mhSteps
                mh
                key
                ( reviseMaterializeStepTotal
                    done
                    reusePathMaterializeSteps
                    remainingAfter
                )
              reuseDepsReleaseAsset
                env
                overlayRoot
                entry
                src
                eco
                plan
                keywords
                lines_
                targetVer
                assetsRoot
                category
                pn
                pvNoRev
                (zip assetNames downloadUrls)
                stepsDoneRef
            (Right Nothing, Right Nothing, _) -> do
              done <- readIORef stepsDoneRef
              mhSteps
                mh
                key
                ( reviseMaterializeStepTotal
                    done
                    fullPathMaterializeSteps
                    remainingAfter
                )
              fullDepsPublishAndOverlay
                env
                overlayRoot
                entry
                src
                eco
                plan
                keywords
                lines_
                targetVer
                assetsRoot
                category
                pn
                pvNoRev
                assetNames
                mh
                key
                stepsDoneRef
            _ ->
              pure $
                ApplyHardFail key conflictMsg False False

goPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  IORef Int ->
  Int ->
  IO ApplyOutcome
goPublishAndOverlay env overlayRoot entry owner repo prefix mSub =
  depsPublishAndOverlay
    env
    overlayRoot
    entry
    (GitHub owner repo prefix)
    (Go mSub)
    (planFromTargets [])
    False

fullDepsPublishAndOverlay ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  FilePath ->
  Text ->
  Text ->
  Text ->
  [FilePath] ->
  MultiHandle ->
  PackageKey ->
  IORef Int ->
  IO ApplyOutcome
fullDepsPublishAndOverlay
  env
  overlayRoot
  entry
  src
  eco
  plan
  keywords
  lines_
  targetVer
  assetsRoot
  category
  pn
  pvNoRev
  assetNames
  mh
  key
  stepsDoneRef = do
    tempRoot <- resolveTempRoot
    let admitNeed = estimateNeedBytes (materializeClassFull eco) Nothing
    admitOk <- checkTempNeedAtAdmit getFreeBytes tempRoot admitNeed
    case admitOk of
      Left err -> pure $ ApplyHardFail key err False False
      Right () -> do
        unit <-
          ensureUnit (aeTempRun env) category pn pvNoRev UnitFull
        built <-
          withFullPathMaterializeSession env unit category pn pvNoRev $ \env' ->
            materializeDistfiles
              env'
              eco
              src
              entry
              key
              plan
              pn
              pvNoRev
              (udWork unit)
              (udOut unit)
              assetNames
              stepsDoneRef
              mh
        case built of
          Left err ->
            pure $
              ApplyHardFail key (retainUnitError unit err) False False
          Right (paths, mReqVer, mEbuildBody) -> do
            rusty <-
              prepareCodexRustyV8
                env
                overlayRoot
                entry
                eco
                pn
                pvNoRev
                assetsRoot
                (udWork unit)
                (udOut unit)
                mEbuildBody
            case rusty of
              Left err ->
                pure $
                  ApplyHardFail key (retainUnitError unit err) False False
              Right (mHarvestPath, mCodexV8) -> do
                let cratesMsg = commitMessage category pn (renderPV targetVer)
                    cratesRel =
                      [ T.unpack category </> T.unpack pn </> takeFileName p <> ext
                      | p <- paths,
                        ext <- [".sha256", ".sha512", ".b3"]
                      ]
                    cratesMeta sha =
                      ReleaseMeta
                        { rmOwner = aeAssetsOwner env,
                          rmRepo = aeAssetsRepo env,
                          rmTag = releaseTag pn pvNoRev,
                          rmName = releaseName category pn pvNoRev,
                          rmBody = cratesMsg,
                          rmTargetCommitish = sha
                        }
                pubResult <-
                  publishAssetCycle
                    env
                    key
                    assetsRoot
                    paths
                    (sidecarPaths assetsRoot category pn)
                    cratesRel
                    cratesMsg
                    cratesMeta
                    stepsDoneRef
                    mh
                case pubResult of
                  Left err ->
                    pure $
                      ApplyHardFail
                        key
                        (retainUnitError unit ("assets publish failed: " <> err))
                        False
                        False
                  Right distDigests -> do
                    rustyPub <-
                      case (mHarvestPath, mCodexV8) of
                        (Nothing, _) -> pure (Right ())
                        (Just harvestPath, Just ov) ->
                          let ver = cvoVer ov
                              base = takeFileName harvestPath
                              rel =
                                [ rustyV8DirName </> base <> ext
                                | ext <- [".sha256", ".sha512", ".b3"]
                                ]
                              msg = rustyV8CommitMessage ver
                              meta sha =
                                ReleaseMeta
                                  { rmOwner = aeAssetsOwner env,
                                    rmRepo = aeAssetsRepo env,
                                    rmTag = rustyV8ReleaseTag ver,
                                    rmName = rustyV8ReleaseName ver,
                                    rmBody = msg,
                                    rmTargetCommitish = sha
                                  }
                           in void
                                <$> publishAssetCycle
                                  env
                                  key
                                  assetsRoot
                                  [harvestPath]
                                  (rustyV8SidecarPaths assetsRoot)
                                  rel
                                  msg
                                  meta
                                  stepsDoneRef
                                  mh
                        (Just _, Nothing) ->
                          pure (Left "internal: harvested rusty_v8 without pin")
                    case rustyPub of
                      Left err ->
                        pure $
                          ApplyHardFail
                            key
                            (retainUnitError unit ("assets publish failed: " <> err))
                            False
                            False
                      Right () -> do
                        mhStatus mh key "regenerating manifest"
                        outcome <-
                          overlayAfterAssets
                            env
                            overlayRoot
                            entry
                            eco
                            keywords
                            lines_
                            targetVer
                            distDigests
                            mReqVer
                            mEbuildBody
                            mCodexV8
                        case outcome of
                          ApplySuccess {} -> do
                            markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                            deleteUnit unit
                            pure outcome
                          ApplySoftSkip {} -> do
                            deleteUnit unit
                            pure outcome
                          ApplyHardFail k failMsg half assetsPub ->
                            pure $
                              ApplyHardFail
                                k
                                (retainUnitError unit failMsg)
                                half
                                assetsPub

-- | Build all required distfiles (primary + companions); paths in asset order.
materializeDistfiles ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  PackageKey ->
  RuntimeLanePlan ->
  Text ->
  Text ->
  -- | Unit @work/@.
  FilePath ->
  -- | Unit @out/@.
  FilePath ->
  [FilePath] ->
  IORef Int ->
  MultiHandle ->
  IO (Either Text ([FilePath], Maybe Text, Maybe Text))
materializeDistfiles env eco src entry key plan pn pvNoRev workDir outDir assetNames stepsDoneRef mh =
  case assetNames of
    [] -> pure (Left "no required assets for materialize")
    (primaryName : companionNames) -> do
      primary <-
        materializePrimaryDistfile
          env
          eco
          src
          entry
          key
          plan
          pvNoRev
          workDir
          outDir
          primaryName
          stepsDoneRef
          mh
      case primary of
        Left err -> pure (Left err)
        Right (p, mReqVer, mEbuildBody) -> do
          companions <-
            materializeCompanionAssets env key pn pvNoRev outDir companionNames
          pure $ case companions of
            Left err -> Left err
            Right extras -> Right (p : extras, mReqVer, mEbuildBody)

-- | Build primary vendor/deps/crates tarball.
materializePrimaryDistfile ::
  ApplyEnv ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  PackageKey ->
  RuntimeLanePlan ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  IORef Int ->
  MultiHandle ->
  IO (Either Text (FilePath, Maybe Text, Maybe Text))
materializePrimaryDistfile env eco src entry key plan pvNoRev workDir outDir tarballName stepsDoneRef mh =
  case (eco, src) of
    (Go mSub, GitHub owner repo prefix) -> do
      built <-
        buildVendorTarball
          (aeVendorOps env)
          (goVendorProgress stepsDoneRef mh key)
          owner
          repo
          prefix
          pvNoRev
          mSub
          workDir
          outDir
          tarballName
      pure $ case built of
        Left err -> Left err
        Right VendorResult {vrTarballPath = p, vrGoModVersion = mGo} ->
          Right (p, mGo, Nothing)
    (NpmEco, Npm npmPkg) -> do
      -- Require engines for host gate: fetch first
      eng <- dpoFetchNpmEngines (aeDepsPlanOps env) npmPkg pvNoRev
      case eng of
        Left err -> pure (Left err)
        Right nodeReq -> do
          let progress = npmCacheProgress stepsDoneRef mh key
          built <-
            buildNpmDepsTarball
              (aeNpmCacheOps env)
              progress
              npmPkg
              pvNoRev
              nodeReq
              workDir
              outDir
              tarballName
          pure $ case built of
            Left err -> Left err
            Right p -> Right (p, Just nodeReq, Nothing)
    (Bun, GitHub owner repo prefix) -> do
      eng <-
        dpoFetchBunEngines (aeDepsPlanOps env) owner repo prefix pvNoRev
      case eng of
        Left err -> pure (Left err)
        Right probe -> do
          let progress = bunCacheProgress stepsDoneRef mh key
              packMode = bunPackagingModeFor key
              bunMin = bunProbeMinimum probe
          built <-
            buildBunDepsTarball
              (aeBunCacheOps env)
              progress
              packMode
              owner
              repo
              prefix
              pvNoRev
              bunMin
              workDir
              outDir
              tarballName
          pure $ case built of
            Left err -> Left err
            Right p -> Right (p, Just bunMin, Nothing)
    (Cargo mLock mPkg mCargoSrc, GitHub owner repo prefix) -> do
      let plannedPv = parseEbuildVersion pvNoRev
      donorPath <-
        findTemplate
          (takeDirectory (pePath entry))
          (pePN entry)
          plannedPv
          (pePath entry)
      donorExists <- doesFileExist donorPath
      if not donorExists
        then
          pure $
            Left $
              applyUnitErrorMessage $
                ApplyMissingDonorTemplate key (renderPV plannedPv) donorPath
        else do
          donorContent <- TIO.readFile donorPath
          let progress = cargoCratesProgress stepsDoneRef mh key mCargoSrc
              plannedPv' = parseEbuildVersion pvNoRev
              tagFloor = fromMaybe Nothing (lookupDirectTagFloor plan plannedPv')
              samePv =
                case parseEbuildFileName (takeFileName donorPath) of
                  Just (_, verStr) ->
                    samePV (parseEbuildVersion (T.pack verStr)) plannedPv'
                  Nothing -> False
          built <-
            buildCargoCratesTarball
              (aeCargoOps env)
              progress
              owner
              repo
              prefix
              pvNoRev
              mLock
              mPkg
              mCargoSrc
              donorContent
              tagFloor
              samePv
              (pePN entry)
              workDir
              outDir
              tarballName
          pure $ case built of
            Left err -> Left err
            Right
              CargoResult
                { crTarballPath = p,
                  crMsrv = msrv,
                  crEbuildBody = body,
                  crHarvestFloor = harvest
                } ->
                case harvestVsLaneCeiling plan plannedPv' tagFloor harvest of
                  Left err -> Left err
                  Right () -> Right (p, Just msrv, Just body)
    (Sbcl, GitHub owner repo prefix) -> do
      floorResult <-
        dpoFetchSbclVersion (aeDepsPlanOps env) owner repo prefix pvNoRev
      case floorResult of
        Left err -> pure (Left err)
        Right body ->
          case parseSbclVersionFloor body of
            Nothing ->
              pure
                ( Left
                    ( "unparseable sbcl.version for "
                        <> pePN entry
                        <> "-"
                        <> pvNoRev
                    )
                )
            Just floorVer -> do
              let progress = sbclDepsProgress stepsDoneRef mh key
              built <-
                buildSbclDepsTarball
                  (aeSbclDepsOps env)
                  progress
                  owner
                  repo
                  prefix
                  pvNoRev
                  workDir
                  outDir
                  tarballName
              pure $ case built of
                Left err -> Left err
                Right p -> Right (p, Just floorVer, Nothing)
    (Go _, _) -> pure (Left "DepsAndAssets Go requires a GitHub update source")
    (NpmEco, _) -> pure (Left "DepsAndAssets Npm requires an Npm update source")
    (Bun, _) -> pure (Left "DepsAndAssets Bun requires a GitHub update source")
    (Cargo {}, _) -> pure (Left "DepsAndAssets Cargo requires a GitHub update source")
    (Sbcl, _) -> pure (Left "DepsAndAssets Sbcl requires a GitHub update source")

-- | After pack, fail closed if harvest exceeds any selecting rust ceiling.
harvestVsLaneCeiling ::
  RuntimeLanePlan ->
  EbuildVersion ->
  Maybe Text ->
  Maybe Text ->
  Either Text ()
harvestVsLaneCeiling plan pv tagFloor harvest =
  case harvest of
    Nothing -> Right ()
    Just h ->
      case bindingCeilings of
        [] -> Right ()
        (c : _) ->
          Left
            ( "Cargo harvest rust-version "
                <> h
                <> " exceeds rust ceiling "
                <> renderPVNoRev c
                <> " for "
                <> renderPVNoRev pv
                <> " (tag floor "
                <> fromMaybe "absent" tagFloor
                <> ")"
            )
  where
    bindingCeilings =
      [ c
      | lt <- glpLanes plan,
        Just lpv <- [ltPackagePV lt],
        samePV lpv pv,
        Just c <- [ltCeiling lt],
        rustMinVerTooLow (renderPVNoRev c) hNeed
      ]
    hNeed = fromMaybe "0.0.0" harvest

-- | Companion distfiles (e.g. models JSON) required beyond the primary tarball.
materializeCompanionAssets ::
  ApplyEnv ->
  PackageKey ->
  Text ->
  Text ->
  FilePath ->
  [FilePath] ->
  IO (Either Text [FilePath])
materializeCompanionAssets _ _ _ _ _ [] = pure (Right [])
materializeCompanionAssets env key pn pvNoRev outDir names =
  case key of
    PackageKey "dev-util/opencode" ->
      goOpencode names
    _ ->
      pure $
        Left
          ( "unknown companion assets for "
              <> let PackageKey k = key in k
          )
  where
    goOpencode [] = pure (Right [])
    goOpencode (n : rest)
      | n == modelsDistfileName pn pvNoRev = do
          fetched <- aeFetchModelsDev env (outDir </> n)
          case fetched of
            Left err -> pure (Left err)
            Right p -> do
              more <- goOpencode rest
              pure $ case more of
                Left err -> Left err
                Right ps -> Right (p : ps)
      | otherwise =
          pure $
            Left ("unexpected companion distfile for opencode: " <> T.pack n)

-- | GET https://models.dev/api.json → write raw body to dest path.
fetchModelsDevApiJson :: FilePath -> IO (Either Text FilePath)
fetchModelsDevApiJson destPath = do
  mgr <- newManager tlsManagerSettings
  fetchModelsDevApiJsonWith mgr destPath

fetchModelsDevApiJsonWith :: Manager -> FilePath -> IO (Either Text FilePath)
fetchModelsDevApiJsonWith mgr destPath = do
  req0 <- parseRequest "https://models.dev/api.json"
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/json")
              ]
          }
  eres <-
    (Right <$> httpLbs req mgr)
      `catch` \(e :: SomeException) -> pure (Left (T.pack (show e)))
  case eres of
    Left err -> pure (Left ("models.dev fetch failed: " <> err))
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then do
              let body = responseBody resp
              if LBS.null body
                then pure (Left "models.dev returned empty body")
                else do
                  createDirectoryIfMissing True (takeDirectory destPath)
                  LBS.writeFile destPath body
                  pure (Right destPath)
            else
              pure $
                Left $
                  "models.dev HTTP "
                    <> T.pack (show code)
                    <> " fetching api.json"

npmCacheProgress :: IORef Int -> MultiHandle -> PackageKey -> NpmCacheProgress
npmCacheProgress stepsDoneRef mh key =
  NpmCacheProgress
    { ncpOnPackStart = mhStatus mh key "npm pack",
      ncpOnPackDone = markMaterializeStep stepsDoneRef mh key "npm pack",
      ncpOnInstallStart = mhStatus mh key "npm cache install",
      ncpOnInstallDone = markMaterializeStep stepsDoneRef mh key "npm cache install",
      ncpOnCompressStart = mhStatus mh key "compressing tarball",
      ncpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

bunCacheProgress :: IORef Int -> MultiHandle -> PackageKey -> BunCacheProgress
bunCacheProgress stepsDoneRef mh key =
  BunCacheProgress
    { bcpOnCloneStart = mhStatus mh key "cloning upstream",
      bcpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      bcpOnInstallStart = mhStatus mh key "bun install",
      bcpOnInstallDone = markMaterializeStep stepsDoneRef mh key "bun install",
      bcpOnCompressStart = mhStatus mh key "compressing tarball",
      bcpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

cargoCratesProgress :: IORef Int -> MultiHandle -> PackageKey -> CargoSource -> CargoProgress
cargoCratesProgress stepsDoneRef mh key cargoSrc =
  let cloneLabel = case cargoSrc of
        CargoGitTag -> "cloning upstream"
        CargoCratesIo -> "fetching published crate"
   in CargoProgress
        { cgpOnCloneStart = mhStatus mh key cloneLabel,
          cgpOnCloneDone = markMaterializeStep stepsDoneRef mh key cloneLabel,
          cgpOnPycargoStart = mhStatus mh key "pycargoebuild",
          cgpOnPycargoDone = markMaterializeStep stepsDoneRef mh key "pycargoebuild",
          cgpOnStageCrate = \k n ->
            mhStatus
              mh
              key
              ( "staging crates "
                  <> T.pack (show k)
                  <> "/"
                  <> T.pack (show n)
              ),
          cgpOnPackStart = mhStatus mh key "crates pack",
          cgpOnPackDone = markMaterializeStep stepsDoneRef mh key "crates pack"
        }

-- | Open a per-unit Docker session when configured; otherwise keep injected ops.
withFullPathMaterializeSession ::
  ApplyEnv ->
  UnitDirs ->
  Text ->
  Text ->
  Text ->
  (ApplyEnv -> IO (Either Text a)) ->
  IO (Either Text a)
withFullPathMaterializeSession env unit category pn pv action =
  case aeMaterializeDocker env of
    Nothing -> action env
    Just (cfg, dockerRun) ->
      withUnitMaterializeSession
        dockerRun
        cfg
        MaterializeUnitRef
          { murCategory = category,
            murPackage = pn,
            murPV = pv
          }
        unit
        ( \runner ->
            action
              ( env
                  { aeVendorOps = mkVendorOps runner,
                    aeNpmCacheOps = mkNpmCacheOps runner,
                    aeBunCacheOps = mkBunCacheOps runner,
                    aeCargoOps = mkCargoOps runner,
                    aeSbclDepsOps = mkSbclDepsOps runner
                  }
              )
        )

-- | Full-path SBCL materialize has more host steps than the generic 7-slot
-- budget (clone, qlot, fff, compress); only clone/compress mark the shared
-- materialize counters so totals stay aligned with other ecosystems.
sbclDepsProgress :: IORef Int -> MultiHandle -> PackageKey -> SbclDepsProgress
sbclDepsProgress stepsDoneRef mh key =
  SbclDepsProgress
    { sdpOnCloneStart = mhStatus mh key "cloning upstream",
      sdpOnCloneDone = markMaterializeStep stepsDoneRef mh key "cloning upstream",
      sdpOnQlotStart = mhStatus mh key "qlot install",
      sdpOnQlotDone = pure (),
      sdpOnFffStart = mhStatus mh key "vendoring fff",
      sdpOnFffDone = pure (),
      sdpOnCompressStart = mhStatus mh key "compressing tarball",
      sdpOnCompressDone = markMaterializeStep stepsDoneRef mh key "compressing tarball"
    }

reuseDepsReleaseAsset ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EcosystemSpec ->
  RuntimeLanePlan ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  FilePath ->
  Text ->
  Text ->
  Text ->
  -- | (basename, browser_download_url) for every required asset.
  [(FilePath, Text)] ->
  IORef Int ->
  IO ApplyOutcome
reuseDepsReleaseAsset
  env
  overlayRoot
  entry
  src
  eco
  plan
  keywords
  lines_
  targetVer
  assetsRoot
  category
  pn
  pvNoRev
  namedUrls
  stepsDoneRef = do
    let key = peKey entry
        mh = aeMulti env
        reusedLines = markSuccessLinesReused lines_
        verifyLabel = case eco of
          Go _ -> "verifying vendor asset"
          Cargo {} -> "verifying crates asset"
          _ -> "verifying deps asset"
    unit <-
      ensureUnit (aeTempRun env) category pn pvNoRev UnitReuse
    mhStatus mh key "reusing release assets"
    dlResult <- downloadNamedAssets (aeReleaseOps env) (udOut unit) namedUrls
    case dlResult of
      Left err ->
        pure $
          ApplyHardFail
            key
            ( retainUnitError
                unit
                ("download of existing release asset failed: " <> err)
            )
            False
            True
      Right localPaths -> do
        distDigests <- mapM (\p -> (takeFileName p,) <$> hashFile p) localPaths
        markMaterializeStep stepsDoneRef mh key "reusing release assets"
        mhStatus mh key verifyLabel
        sideCheck <- checkAllSidecars assetsRoot category pn distDigests
        case sideCheck of
          Left err ->
            pure $
              ApplyHardFail key (retainUnitError unit err) False True
          Right () -> do
            reqResult <- case eco of
              Go mSub ->
                fmap Right $ case src of
                  GitHub owner repo prefix ->
                    fetchGoModVersion env owner repo prefix pvNoRev mSub
                  _ -> pure Nothing
              Cargo {} -> do
                donorPath <-
                  findTemplate
                    (takeDirectory (pePath entry))
                    (pePN entry)
                    targetVer
                    (pePath entry)
                donorExists <- doesFileExist donorPath
                if not donorExists
                  then
                    pure $
                      Left $
                        applyUnitHardFail
                          key
                          ( ApplyMissingDonorTemplate
                              key
                              (renderPV targetVer)
                              donorPath
                          )
                          False
                          True
                  else do
                    donorContent <- TIO.readFile donorPath
                    let mTag = fromMaybe Nothing (lookupDirectTagFloor plan targetVer)
                        mTemplate = parseRustMinVerFromEbuild donorContent
                    pure (Right (cargoReuseWriteFloor mTag mTemplate))
              Sbcl ->
                case src of
                  GitHub owner repo prefix -> do
                    eres <-
                      dpoFetchSbclVersion
                        (aeDepsPlanOps env)
                        owner
                        repo
                        prefix
                        pvNoRev
                    pure $
                      Right $
                        case eres of
                          Right body -> parseSbclVersionFloor body
                          Left _ -> Nothing
                  _ -> pure (Right Nothing)
              _ -> do
                mAtom <- fetchRequiredBdependAtom env eco src key pvNoRev
                pure $
                  Right $
                    case mAtom of
                      Just atom
                        | "nodejs-" `T.isInfixOf` atom ->
                            Just
                              ( T.takeWhile
                                  (/= '[')
                                  ( T.drop
                                      (T.length (">=net-libs/nodejs-" :: Text))
                                      atom
                                  )
                              )
                        | "bun-bin-" `T.isInfixOf` atom -> bunAtomVersion atom
                        | otherwise -> Nothing
                      Nothing -> Nothing
            case reqResult of
              Left failOutcome -> do
                -- Donor-template hard-fail is structured; attach unit path.
                case failOutcome of
                  ApplyHardFail k failMsg half assetsPub ->
                    pure $
                      ApplyHardFail
                        k
                        (retainUnitError unit failMsg)
                        half
                        assetsPub
                  other -> pure other
              Right mReq -> do
                markMaterializeStep stepsDoneRef mh key verifyLabel
                mhStatus mh key "regenerating manifest"
                outcome <-
                  overlayAfterAssets
                    env
                    overlayRoot
                    entry
                    eco
                    keywords
                    reusedLines
                    targetVer
                    distDigests
                    mReq
                    Nothing
                    Nothing
                case outcome of
                  ApplySuccess k sls paths -> do
                    markMaterializeStep stepsDoneRef mh key "regenerating manifest"
                    deleteUnit unit
                    pure (ApplySuccess k sls paths)
                  ApplySoftSkip k reason -> do
                    deleteUnit unit
                    pure (ApplySoftSkip k reason)
                  ApplyHardFail k failMsg half assetsPub ->
                    pure $
                      ApplyHardFail
                        k
                        (retainUnitError unit failMsg)
                        half
                        assetsPub

downloadNamedAssets ::
  ReleaseOps ->
  FilePath ->
  [(FilePath, Text)] ->
  IO (Either Text [FilePath])
downloadNamedAssets _ _ [] = pure (Right [])
downloadNamedAssets ops tmpDir ((name, url) : rest) = do
  let dest = tmpDir </> name
  dl <- roDownloadAsset ops url dest
  case dl of
    Left err -> pure (Left err)
    Right () -> do
      more <- downloadNamedAssets ops tmpDir rest
      pure $ case more of
        Left err -> Left err
        Right ps -> Right (dest : ps)

checkAllSidecars ::
  FilePath ->
  Text ->
  Text ->
  [(FilePath, FileDigests)] ->
  IO (Either Text ())
checkAllSidecars _ _ _ [] = pure (Right ())
checkAllSidecars assetsRoot category pn ((name, digests) : rest) = do
  sideCheck <-
    checkSidecarSha512IfPresent
      assetsRoot
      category
      pn
      name
      (digestSHA512 digests)
  case sideCheck of
    Left err -> pure (Left err)
    Right () -> checkAllSidecars assetsRoot category pn rest

-- | Optional assets-repo sidecar SHA512 cross-check (only when file exists).
checkSidecarSha512IfPresent ::
  FilePath ->
  Text ->
  Text ->
  FilePath ->
  Text ->
  IO (Either Text ())
checkSidecarSha512IfPresent assetsRoot category pn tarballName expectedSha = do
  let sp = sidecarPaths assetsRoot category pn tarballName
      path = spSha512 sp
  exists <- doesFileExist path
  if not exists
    then pure (Right ())
    else do
      text <- TIO.readFile path
      case T.words (T.strip text) of
        (hex : _)
          | T.toLower hex == T.toLower expectedSha -> pure (Right ())
          | otherwise ->
              pure $
                Left
                  ( "assets-repo sidecar SHA512 disagrees with GitHub release asset for "
                      <> T.pack tarballName
                      <> " (assets repo and release are out of sync)"
                  )
        _ ->
          pure $
            Left
              ( "could not parse assets-repo SHA512 sidecar for "
                  <> T.pack tarballName
              )

-- | go.mod @go@ directive for BDEPEND without a vendor clone (reuse path).
fetchGoModVersion ::
  ApplyEnv ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO (Maybe Text)
fetchGoModVersion env owner repo prefix pvNoRev mSub = do
  let tag = versionTag prefix pvNoRev
      key =
        GoModKey
          { gmkOwner = owner,
            gmkRepo = repo,
            gmkTag = tag,
            gmkSubdir = mSub
          }
  eres <- dpoFetchGoMod (aeDepsPlanOps env) key
  pure $ case eres of
    Right body -> parseGoReqFromMod body
    Left _ -> Nothing

------------------------------------------------------------------------
-- Pin-keyed rusty-v8 harvest / publish (Codex only)
------------------------------------------------------------------------

isCodexKey :: PackageKey -> Bool
isCodexKey (PackageKey "dev-util/codex") = True
isCodexKey _ = False

cargoLockPath :: EcosystemSpec -> Text -> Text -> FilePath -> FilePath
cargoLockPath eco pn pv workDir =
  let srcDir = workDir </> "src"
      root = case eco of
        Cargo mLock _ CargoGitTag -> maybe srcDir (srcDir </>) mLock
        Cargo _ _ CargoCratesIo -> srcDir </> (T.unpack pn <> "-" <> T.unpack pv)
        _ -> srcDir
   in root </> "Cargo.lock"

-- | After crates exist: reuse or harvest rusty_v8 for Codex. Other packages skip.
prepareCodexRustyV8 ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  EcosystemSpec ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  Maybe Text ->
  IO (Either Text (Maybe FilePath, Maybe CodexV8Overlay))
prepareCodexRustyV8 env _overlayRoot entry eco pn pv assetsRoot workDir outDir _mEbuildBody
  | not (isCodexKey (peKey entry)) = pure (Right (Nothing, Nothing))
  | otherwise = do
      let lockPath = cargoLockPath eco pn pv workDir
      hasLock <- doesFileExist lockPath
      if not hasLock
        then
          pure $
            Left
              ( "Cargo.lock not found for rusty_v8 harvest at "
                  <> T.pack lockPath
              )
        else do
          lockBody <- TIO.readFile lockPath
          case parseV8RegistryPin lockBody of
            Nothing -> pure (Right (Nothing, Nothing))
            Just ver -> do
              donorPath <-
                findTemplate
                  (takeDirectory (pePath entry))
                  pn
                  (parseEbuildVersion pv)
                  (pePath entry)
              donorExists <- doesFileExist donorPath
              donorContent <-
                if donorExists
                  then TIO.readFile donorPath
                  else pure ""
              resolveCodexRustyV8
                env
                assetsRoot
                workDir
                outDir
                ver
                donorContent

resolveCodexRustyV8 ::
  ApplyEnv ->
  FilePath ->
  FilePath ->
  FilePath ->
  Text ->
  Text ->
  IO (Either Text (Maybe FilePath, Maybe CodexV8Overlay))
resolveCodexRustyV8 env assetsRoot workDir outDir ver donorContent = do
  let base = rustyV8SnapshotBasename ver
      tag = rustyV8ReleaseTag ver
      sp = rustyV8SidecarPaths assetsRoot base
      ops = aeReleaseOps env
      owner = aeAssetsOwner env
      repo = aeAssetsRepo env
      donorPin = parseQuotedAssignment "RUSTY_V8_VER" donorContent
      samePin = donorPin == Just ver
  tagRes <- roGetReleaseByTag ops owner repo tag
  case tagRes of
    Left err -> pure (Left ("rusty-v8 release lookup failed: " <> err))
    Right mInfo -> do
      sidesOk <- rustyV8SidecarsPresent sp
      case (mInfo, sidesOk) of
        (Just info, True)
          | Just asset <- findAssetByName info (T.pack base) -> do
              let dest = outDir </> base
              dl <- roDownloadAsset ops (raBrowserDownloadUrl asset) dest
              case dl of
                Left err ->
                  pure (Left ("rusty-v8 asset download failed: " <> err))
                Right () -> do
                  digests <- hashFile dest
                  match <- sidecarsMatchDigests sp digests
                  case match of
                    Left err -> pure (Left err)
                    Right () -> do
                      gcs <-
                        if samePin
                          then pure (Right Nothing)
                          else fmap Just <$> gcsFromSnapshotOrTree dest workDir
                      pure $ case gcs of
                        Left err -> Left err
                        Right mGcs ->
                          Right
                            ( Nothing,
                              Just (codexOverlay ver mGcs)
                            )
          | otherwise ->
              pure $
                Left
                  ( "existing rusty-v8 release "
                      <> tag
                      <> " is missing "
                      <> T.pack base
                      <> "; remove or repair that release externally before retrying"
                  )
        (Just _, False) ->
          pure $
            Left
              ( "existing rusty-v8 release "
                  <> tag
                  <> " does not match assets-worktree checksums; remove or repair \
                     \that release externally before retrying"
              )
        (Nothing, _) -> do
          harvested <-
            harvestRustyV8Snapshot
              (coCloneRecursiveSubmodules (aeCargoOps env))
              (coPackTree (aeCargoOps env))
              Nothing
              ver
              workDir
              outDir
          case harvested of
            Left err -> pure (Left err)
            Right path -> do
              gcs <-
                if samePin
                  then pure (Right Nothing)
                  else fmap Just <$> gcsFromCloneTree workDir
              pure $ case gcs of
                Left err -> Left err
                Right mGcs ->
                  Right
                    ( Just path,
                      Just (codexOverlay ver mGcs)
                    )

codexOverlay :: Text -> Maybe V8GcsLinuxDists -> CodexV8Overlay
codexOverlay ver mGcs =
  CodexV8Overlay
    { cvoVer = ver,
      cvoClangDist = v8ClangDist <$> mGcs,
      cvoRustTcDist = v8RustTcDist <$> mGcs
    }

rustyV8SidecarsPresent :: SidecarPaths -> IO Bool
rustyV8SidecarsPresent sp = do
  a <- doesFileExist (spSha256 sp)
  b <- doesFileExist (spSha512 sp)
  c <- doesFileExist (spB3 sp)
  pure (a && b && c)

sidecarsMatchDigests :: SidecarPaths -> FileDigests -> IO (Either Text ())
sidecarsMatchDigests sp digests = do
  sha256 <- sidecarHex (spSha256 sp)
  sha512 <- sidecarHex (spSha512 sp)
  b3 <- sidecarHex (spB3 sp)
  pure $
    case (sha256, sha512, b3) of
      (Right h256, Right h512, Right hb3)
        | h256 == T.toLower (digestSHA256 digests)
            && h512 == T.toLower (digestSHA512 digests)
            && hb3 == T.toLower (digestBLAKE3 digests) ->
            Right ()
        | otherwise ->
            Left
              "rusty-v8 snapshot bytes do not match assets-worktree checksum sidecars"
      (Left err, _, _) -> Left err
      (_, Left err, _) -> Left err
      (_, _, Left err) -> Left err

sidecarHex :: FilePath -> IO (Either Text Text)
sidecarHex path = do
  text <- TIO.readFile path
  pure $
    case T.words (T.strip text) of
      (hex : _) -> Right (T.toLower hex)
      _ -> Left ("could not parse rusty-v8 sidecar " <> T.pack path)

gcsFromCloneTree :: FilePath -> IO (Either Text V8GcsLinuxDists)
gcsFromCloneTree workDir = do
  let depsPath = workDir </> "rusty_v8" </> "v8" </> "DEPS"
  exists <- doesFileExist depsPath
  if not exists
    then pure (Left ("v8/DEPS missing after rusty_v8 clone at " <> T.pack depsPath))
    else parseV8DepsGcsLinux <$> TIO.readFile depsPath

gcsFromSnapshotOrTree :: FilePath -> FilePath -> IO (Either Text V8GcsLinuxDists)
gcsFromSnapshotOrTree tarball workDir = do
  let depsPath = workDir </> "rusty_v8" </> "v8" </> "DEPS"
  exists <- doesFileExist depsPath
  if exists
    then parseV8DepsGcsLinux <$> TIO.readFile depsPath
    else do
      extracted <- extractV8DepsFromSnapshot tarball
      pure $ case extracted of
        Left err -> Left err
        Right body -> parseV8DepsGcsLinux body

publishAssetCycle ::
  ApplyEnv ->
  PackageKey ->
  FilePath ->
  [FilePath] ->
  (FilePath -> SidecarPaths) ->
  [FilePath] ->
  Text ->
  (Text -> ReleaseMeta) ->
  IORef Int ->
  MultiHandle ->
  IO (Either Text [(FilePath, FileDigests)])
publishAssetCycle env key assetsRoot paths sidecarFn relSidecars msg mkMeta stepsDoneRef mh = do
  mhStatus mh key "committing assets"
  distDigests <- mapM (\p -> (takeFileName p,) <$> hashFile p) paths
  mapM_
    ( \(p, digests) -> do
        let sp = sidecarFn (takeFileName p)
        createDirectoryIfMissing True (takeDirectory (spSha256 sp))
        writeSidecars p digests (spSha256 sp) (spSha512 sp) (spB3 sp)
    )
    distDigests
  withMVar (aeAssetsLock env) $ \() -> do
    committed <- goAddAndCommit (aeGitOps env) assetsRoot relSidecars msg
    case committed of
      Left err -> pure (Left err)
      Right () -> do
        sha <- goRevParseHead (aeGitOps env) assetsRoot
        case sha of
          Left err -> pure (Left err)
          Right commitSha -> do
            markMaterializeStep stepsDoneRef mh key "committing assets"
            mhStatus mh key "pushing assets"
            pushed <- goPush (aeGitOps env) assetsRoot
            case pushed of
              Left err -> pure (Left err)
              Right () -> do
                markMaterializeStep stepsDoneRef mh key "pushing assets"
                mhStatus mh key "uploading release asset"
                uploaded <-
                  roCreateReleaseWithAssets
                    (aeReleaseOps env)
                    (mkMeta commitSha)
                    paths
                case uploaded of
                  Left err -> pure (Left err)
                  Right () -> do
                    markMaterializeStep stepsDoneRef mh key "uploading release asset"
                    pure (Right distDigests)
