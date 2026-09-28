{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Update.Check
  ( groupNewest,
    groupByPackage,
    PackageEntry (..),
    checkOverlayWithDepsPlan,
    checkPackage,
    checkPackageDeps,
    contentFixPVs,
    assessOverlayContent,
    productionFetcherWithLatch,
    needsLiveGitHubApi,
    finishOutdatedReports,
    statusFromCompare,
    renderPVNoRev,
    selectCanonicalSamePV,
    selectHighestNonLive,
    InventoryFile (..),
    inventoryFromEbuild,
    ContentAssessment (..),
    PresentPvOutcome (..),
    requiredAssetBasenames,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress (MultiHandle (..))
import Data.List (sortBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, renderPVNoRev, samePV)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Update.Adequacy
  ( ContentAssessment (..),
    PlannedPvFacts (..),
    PresentPvOutcome (..),
    assessPlannedFacts,
    lookupDirectTagFloor,
    plannedRuntimeReq,
    requiredAssetBasenames,
  )
import Update.AtomClosure (keepPVsForProvider)
import Update.Cargo.Msrv (parseRustMinVerFromEbuild)
import Update.CheckCache
  ( CheckCacheHandle,
    cachedCargoPlanUsable,
    computeFingerprint,
    computeFingerprintFromDir,
    lookupDeps,
    lookupLatest,
    recordFetch,
    recordHit,
    storeDeps,
    storeLatest,
  )
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithCeilingsFor,
    planDepsPackageWithProgressDonor,
    readNpmDonorBody,
  )
import Update.EbuildEdit (defaultAssetsHost)
import Update.EbuildSelection
  ( InventoryFile (..),
    inventoryFromEbuild,
    selectCanonicalSamePV,
    selectHighestNonLive,
  )
import Update.GitHub
  ( GitHubLatch,
    fetchGitHubWithLatch,
    formatGitHubHttpError,
    gitHubAbortLog,
    githubLatchAbortedMessage,
    peekGitHubLatch,
  )
import Update.Go.Lanes
  ( GapLine (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    buildGapLines,
    extrasToDelete,
    missingTargets,
    planErrorMessage,
    planNeedsWork,
  )
import Update.Go.Plan
  ( PlanProgress (..),
    localNonLivePVs,
  )
import Update.Hardcoded (lookupLaneArches, lookupPolicy)
import Update.Http (fetchHttpJsonWith, fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.OverlayTree (InTree, readEbuild, withNewTreeLock)
import Update.OverlayWaves
  ( OverlayCeilingPlan (..),
    computeOverlayProviderFingerprint,
    fetchOverlayProviderLatest,
    newestNonLivePv,
    overlayCeilingPlan,
    overlayCeilingProvider,
    overlayFailClosedMessage,
    overlayRefuseMessage,
    planDeltaHolds,
  )
import Update.Resolve (resolveSource)
import Update.Runtime.Ceilings
  ( RuntimeCeilings,
    RuntimeEbuildMeta,
    discoverBunBinMetas,
  )
import Update.Types
  ( EcosystemSpec (..),
    Fetcher,
    OutdatedLine (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    UpdateTechnique (..),
    mkPackageKey,
    packageKeyText,
    splitPackageKey,
  )

-- | One package's newest local ebuild used for checks / apply entry.
data PackageEntry = PackageEntry
  { peKey :: PackageKey,
    pePN :: Text,
    peLocal :: EbuildVersion,
    pePath :: FilePath
  }
  deriving (Eq, Show)

-- | Group ebuilds by category/package; keep newest PV (revision as tiebreak).
groupNewest :: [Ebuild] -> [PackageEntry]
groupNewest ebuilds =
  Map.elems $ foldl' insert Map.empty ebuilds
  where
    insert acc e =
      let key = mkPackageKey (ebuildCategory e) (ebuildPackage e)
          local = parseEbuildVersion (ebuildVersion e)
          entry =
            PackageEntry
              { peKey = key,
                pePN = ebuildPackage e,
                peLocal = local,
                pePath = ebuildPath e
              }
       in Map.insertWith preferNewer key entry acc

    preferNewer new old =
      case compareForNewest (peLocal new) (peLocal old) of
        GT -> new
        LT -> old
        EQ ->
          case (peLocal new, peLocal old) of
            (Numeric _ (Just r1), Numeric _ (Just r2))
              | r1 > r2 -> new
              | otherwise -> old
            (Numeric _ (Just _), Numeric _ Nothing) -> new
            _ -> old

-- | All ebuilds grouped by package key.
groupByPackage :: [Ebuild] -> Map.Map PackageKey [Ebuild]
groupByPackage =
  foldl' insert Map.empty
  where
    insert acc e =
      let key = mkPackageKey (ebuildCategory e) (ebuildPackage e)
       in Map.insertWith (<>) key [e] acc

compareForNewest :: EbuildVersion -> EbuildVersion -> Ordering
compareForNewest a b =
  case comparePV a b of
    Just o -> o
    Nothing -> compare (show a) (show b)

checkOverlayWithDepsPlan ::
  Int ->
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWithDepsPlan jobs mh fetch depsOps cache ebuilds = do
  let entries = sortOn (packageKeyText . peKey) (groupNewest ebuilds)
      byPkg = groupByPackage ebuilds
      checkSet = Set.fromList (map peKey entries)
  mapConcurrentlyN jobs (checkOne mh fetch depsOps cache byPkg checkSet) entries

checkOne ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  Map.Map PackageKey [Ebuild] ->
  Set.Set PackageKey ->
  PackageEntry ->
  IO UpdateReport
checkOne mh fetch depsOps cache byPkg checkSet entry = do
  let key = peKey entry
  mhStart mh key
  let locals = Map.findWithDefault [] key byPkg
  report <- case lookupPolicy key of
    Just (PackagePolicy src (DepsAndAssets eco) _) ->
      checkPackageDeps mh fetch depsOps cache entry locals src eco checkSet
    _ -> do
      mhStatus mh key "fetching"
      checkPackage fetch cache entry locals
  case reportStatus report of
    Outdated _ -> mhSuccess mh key
    Ok _ -> mhSuccess mh key
    Ahead _ _ -> mhFail mh key "ahead of upstream"
    Unconfigured -> mhFail mh key "unconfigured"
    FetchError err -> mhFail mh key (shortReason err)
  pure report

shortReason :: Text -> Text
shortReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

-- | Resolve, fetch, and compare one package (latest-only path).
checkPackage ::
  Fetcher ->
  CheckCacheHandle ->
  PackageEntry ->
  [Ebuild] ->
  IO UpdateReport
checkPackage fetch cache entry locals = do
  let key = peKey entry
      local = peLocal entry
  case resolveSource key of
    Nothing ->
      pure (mkReport key Unconfigured)
    Just src -> do
      let ebuilds =
            if null locals
              then
                [ Ebuild
                    { ebuildCategory = "",
                      ebuildPackage = pePN entry,
                      ebuildVersion = renderPVNoRev (peLocal entry),
                      ebuildPath = pePath entry
                    }
                ]
              else locals
      fp <- withNewTreeLock $ \tree -> computeFingerprint tree src ebuilds
      mCached <- lookupLatest cache key fp
      case mCached of
        Just remote -> do
          recordHit cache
          pure (mkReport key (statusFromCompare local remote))
        Nothing -> do
          recordFetch cache
          result <- fetch src
          case result of
            Left err ->
              pure (mkReport key (FetchError err))
            Right remote -> do
              storeLatest cache key fp remote
              pure (mkReport key (statusFromCompare local remote))

-- | Runtime-lane outdated check for DepsAndAssets packages.
-- @checkSet@ is this @outdated@ invocation's package keys. A ceiling
-- provider omitted from the set is the left-out refuse case.
checkPackageDeps ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  EcosystemSpec ->
  Set.Set PackageKey ->
  IO UpdateReport
checkPackageDeps mh fetch depsOps cache entry locals src eco checkSet = do
  let key = peKey entry
      progress = depsPlanProgress mh key eco
      localPVs = localNonLivePVs locals
      tech = DepsAndAssets eco
  fp <- withNewTreeLock $ \tree -> computeFingerprint tree src locals
  mProvFp <-
    case dpoOverlayRoot depsOps of
      Just overlayRoot ->
        withNewTreeLock $ \tree ->
          computeOverlayProviderFingerprint tree overlayRoot tech
      Nothing -> pure Nothing
  mCached <-
    case (overlayCeilingProvider tech, mProvFp) of
      (Just _, Nothing) -> pure Nothing
      (Just _, Just pfp) -> lookupDeps cache key fp (Just pfp)
      (Nothing, _) -> lookupDeps cache key fp Nothing
  case mCached of
    Just plan
      | cachedCargoPlanUsable eco src plan -> do
          recordHit cache
          reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan checkSet
    _ -> do
      recordFetch cache
      eDonor <- npmDonorBody eco locals
      case eDonor of
        Left err ->
          pure (mkReport key (FetchError err))
        Right mDonor -> do
          planResult <-
            planDepsPackageWithProgressDonor
              depsOps
              progress
              eco
              src
              localPVs
              (lookupLaneArches key)
              mDonor
          case planResult of
            Left err ->
              pure (mkReport key (FetchError (planErrorMessage err)))
            Right plan -> do
              storeDeps cache key fp mProvFp plan
              reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan checkSet

-- | Donor ebuild body for npm planning. Other ecosystems skip the read.
npmDonorBody :: EcosystemSpec -> [Ebuild] -> IO (Either Text (Maybe Text))
npmDonorBody eco locals =
  case eco of
    NpmEco ->
      withNewTreeLock $ \tree ->
        readNpmDonorBody locals (readEbuild tree)
    _ -> pure (Right Nothing)

reportFromDepsPlan ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  [Ebuild] ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  Set.Set PackageKey ->
  IO UpdateReport
reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan checkSet = do
  displayed <- displayForPlan eco entry locals localPVs plan
  case displayed of
    Left err ->
      pure (mkReport (peKey entry) (FetchError err))
    Right (gaps, onDiskNeed) -> do
      let base = reportFromGaps (peKey entry) localPVs (peLocal entry) gaps
      applyOverlayBlockIndication
        mh
        fetch
        depsOps
        cache
        eco
        src
        entry
        locals
        localPVs
        plan
        onDiskNeed
        checkSet
        base

-- | Lane gaps for one plan, without re-entering overlay plan-delta.
displayForPlan ::
  EcosystemSpec ->
  PackageEntry ->
  [Ebuild] ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  IO (Either Text ([OutdatedLine], Bool))
displayForPlan eco entry locals localPVs plan = do
  let key = peKey entry
      pn = pePN entry
  assessed <-
    withNewTreeLock $ \tree ->
      assessOverlayContent tree eco key pn locals plan
  pure $ case assessed of
    Left err -> Left err
    Right (ca, _, _) ->
      let missing = missingTargets localPVs plan
          contentFix =
            [ pv
            | pv <- caNeedsWorkPVs ca,
              not (any (samePV pv) missing)
            ]
          forceFull = caForceFullPVs ca
          need = planNeedsWork localPVs contentFix plan
          needsWork = missing <> contentFix
          gapLines =
            if need
              then buildGapLines localPVs needsWork plan
              else []
          isContentOnly toPV =
            any (samePV toPV) contentFix
              && not (any (samePV toPV) missing)
          -- Marker is conservative until release lookup is plumbed: never
          -- claim reusable for forced-full PVs.
          mayReuse toPV =
            isContentOnly toPV && not (any (samePV toPV) forceFull)
          lines_ =
            [ OutdatedLine
                { olFrom = glFrom g,
                  olTo = glTo g,
                  olLabel = Just (glLabel g),
                  olAssetsReusable = mayReuse (glTo g)
                }
            | g <- gapLines
            ]
       in Right (lines_, need)

-- | Overlay wait-edge consumers: hypothetical preview or refuse, else on-disk.
applyOverlayBlockIndication ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  [Ebuild] ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  Bool ->
  Set.Set PackageKey ->
  UpdateReport ->
  IO UpdateReport
applyOverlayBlockIndication mh fetch depsOps cache eco src entry locals localPVs onDiskPlan onDiskNeed checkSet base =
  case overlayCeilingProvider (DepsAndAssets eco) of
    Nothing ->
      attachDisplayed depsOps localPVs onDiskPlan Nothing base
    Just provider ->
      case dpoOverlayRoot depsOps of
        Nothing ->
          pure (failClosed (peKey entry) provider)
        Just overlayRoot -> do
          eRemote <-
            fetchOverlayProviderLatest withNewTreeLock fetch cache overlayRoot provider
          case eRemote of
            Left _ ->
              pure (failClosed (peKey entry) provider)
            Right remote -> do
              eMetas <-
                withNewTreeLock $ \tree -> discoverBunBinMetas tree overlayRoot
              case eMetas of
                Left _ ->
                  pure (failClosed (peKey entry) provider)
                Right metas ->
                  case overlayCeilingPlan metas remote of
                    CeilingsUnchanged ->
                      attachDisplayed depsOps localPVs onDiskPlan Nothing base
                    CeilingsChanged hypoCeil
                      | provider `Set.member` checkSet
                          && not (providerIsGitMvOutdated remote metas) ->
                          attachDisplayed depsOps localPVs onDiskPlan Nothing base
                      | otherwise ->
                          previewHypothetical
                            mh
                            depsOps
                            eco
                            src
                            entry
                            locals
                            localPVs
                            onDiskPlan
                            onDiskNeed
                            checkSet
                            provider
                            hypoCeil
                            base

-- | Fetched remote latest is strictly greater than the newest non-live on-disk PV.
providerIsGitMvOutdated :: EbuildVersion -> [RuntimeEbuildMeta] -> Bool
providerIsGitMvOutdated remote metas =
  case newestNonLivePv metas of
    Just local -> comparePV local remote == Just LT
    Nothing -> False

previewHypothetical ::
  MultiHandle ->
  DepsPlanOps ->
  EcosystemSpec ->
  UpdateSource ->
  PackageEntry ->
  [Ebuild] ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  Bool ->
  Set.Set PackageKey ->
  PackageKey ->
  RuntimeCeilings ->
  UpdateReport ->
  IO UpdateReport
previewHypothetical mh depsOps eco src entry locals localPVs onDiskPlan onDiskNeed checkSet provider hypoCeil base = do
  let key = peKey entry
  hypoResult <-
    planDepsPackageWithCeilingsFor
      depsOps
      (depsPlanProgress mh key eco)
      eco
      src
      localPVs
      hypoCeil
      (lookupLaneArches key)
  case hypoResult of
    Left _ -> pure (failClosed key provider)
    Right hypoPlan -> do
      displayed <- displayForPlan eco entry locals localPVs hypoPlan
      case displayed of
        Left _ -> pure (failClosed key provider)
        Right (gaps, hypoNeed) ->
          if not
            ( planDeltaHolds
                (glpUniquePVs onDiskPlan)
                onDiskNeed
                (glpUniquePVs hypoPlan)
                hypoNeed
            )
            then attachDisplayed depsOps localPVs onDiskPlan Nothing base
            else
              let mNote =
                    if provider `Set.member` checkSet
                      then Nothing
                      else Just (overlayRefuseMessage provider)
                  hypoBase = reportFromGaps key localPVs (peLocal entry) gaps
               in attachDisplayed depsOps localPVs hypoPlan mNote hypoBase

-- | Gap lines, or Ok when this plan has nothing to print yet.
reportFromGaps ::
  PackageKey ->
  [EbuildVersion] ->
  EbuildVersion ->
  [OutdatedLine] ->
  UpdateReport
reportFromGaps key localPVs fallback gaps =
  mkReport key $
    if null gaps
      then Ok $ case localPVs of
        (v : _) -> v
        [] -> fallback
      else Outdated gaps

attachDisplayed ::
  DepsPlanOps ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  Maybe Text ->
  UpdateReport ->
  IO UpdateReport
attachDisplayed depsOps localPVs plan mNote base = do
  outcome <- removalOutcome depsOps (reportKey base) localPVs plan
  pure (applyRemovalOutcome base outcome mNote)

-- | Removal lines for @extrasToDelete@, skipping the keep read when empty.
removalOutcome ::
  DepsPlanOps ->
  PackageKey ->
  [EbuildVersion] ->
  RuntimeLanePlan ->
  IO (Either Text [OutdatedLine])
removalOutcome depsOps key localPVs plan =
  let extras = extrasToDelete localPVs plan
   in if null extras
        then pure (Right [])
        else do
          eKeep <- case dpoOverlayRoot depsOps of
            Nothing ->
              pure
                ( Left
                    "could not read ebuild keep-set: overlay root is not configured"
                )
            Just overlayRoot ->
              withNewTreeLock $ \tree ->
                keepPVsForProvider Nothing tree overlayRoot key (glpUniquePVs plan)
          pure $ case eKeep of
            Left err -> Left err
            Right keep ->
              Right (map OutdatedRemoval (removalPVs extras keep))

removalPVs :: [EbuildVersion] -> [EbuildVersion] -> [EbuildVersion]
removalPVs extras keep =
  collapseAscending [v | v <- extras, not (any (samePV v) keep)]

collapseAscending :: [EbuildVersion] -> [EbuildVersion]
collapseAscending vs = go (sortBy pvOrd vs)
  where
    go [] = []
    go (v : rest) = stripRevision v : go (dropWhile (samePV v) rest)

stripRevision :: EbuildVersion -> EbuildVersion
stripRevision (Numeric comps _) = Numeric comps Nothing
stripRevision raw = raw

pvOrd :: EbuildVersion -> EbuildVersion -> Ordering
pvOrd a b =
  case comparePV a b of
    Just o -> o
    Nothing -> compare (show a) (show b)

applyRemovalOutcome ::
  UpdateReport ->
  Either Text [OutdatedLine] ->
  Maybe Text ->
  UpdateReport
applyRemovalOutcome base outcome mNote =
  let key = reportKey base
      gaps = case reportStatus base of
        Outdated ls -> ls
        _ -> []
      (removals, mWarn) = case outcome of
        Right rs -> (rs, Nothing)
        Left err -> ([], Just err)
      notes = case mNote of
        Nothing -> []
        Just t -> [OutdatedNote t]
      lines_ = gaps ++ removals ++ notes
   in case (lines_, mWarn) of
        ([], Just err) ->
          UpdateReport
            { reportKey = key,
              reportStatus = FetchError err,
              reportWarning = Nothing
            }
        ([], Nothing) -> base
        (ls, w) ->
          UpdateReport
            { reportKey = key,
              reportStatus = Outdated ls,
              reportWarning = w
            }

failClosed :: PackageKey -> PackageKey -> UpdateReport
failClosed key provider =
  mkReport key (FetchError (overlayFailClosedMessage provider))

mkReport :: PackageKey -> UpdateStatus -> UpdateReport
mkReport key status =
  UpdateReport
    { reportKey = key,
      reportStatus = status,
      reportWarning = Nothing
    }

depsPlanProgress :: MultiHandle -> PackageKey -> EcosystemSpec -> PlanProgress
depsPlanProgress mh key eco =
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

-- | Present-PV content-fix list (legacy wrapper). Missing PVs are excluded.
contentFixPVs ::
  InTree ->
  DepsPlanOps ->
  EcosystemSpec ->
  UpdateSource ->
  [Ebuild] ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixPVs tree _depsOps eco _src locals plan = do
  let pn =
        case locals of
          (e : _) -> ebuildPackage e
          [] -> ""
      key =
        case locals of
          (e : _) -> mkPackageKey (ebuildCategory e) (ebuildPackage e)
          [] -> PackageKey ""
  assessed <- assessOverlayContent tree eco key pn locals plan
  pure $ case assessed of
    Left _ -> []
    Right (ca, _, _) ->
      let missing = missingTargets (localNonLivePVs locals) plan
       in [ pv
          | pv <- caNeedsWorkPVs ca,
            not (any (samePV pv) missing)
          ]

-- | Shared overlay content assessment: canonical same-PV selection, planned
-- requirement snapshots, no upstream fetch.
assessOverlayContent ::
  InTree ->
  EcosystemSpec ->
  PackageKey ->
  Text ->
  [Ebuild] ->
  RuntimeLanePlan ->
  IO
    ( Either
        Text
        ( ContentAssessment,
          [(EbuildVersion, FilePath)],
          Maybe FilePath
        )
    )
assessOverlayContent tree eco key pn locals plan = do
  let inv = map inventoryFromEbuild locals
  case selectHighestNonLive inv of
    Left err -> pure (Left err)
    Right mFallback ->
      case mapM (\pe -> selectCanonicalSamePV (pePV pe) inv) (glpEbuilds plan) of
        Left err -> pure (Left err)
        Right sameSels -> do
          let pkgDir =
                case locals of
                  (e : _) -> takeDirectory (ebuildPath e)
                  [] -> "."
              manPath = pkgDir </> "Manifest"
          manExists <- doesFileExist manPath
          mMan <-
            if manExists
              then Just <$> TIO.readFile manPath -- allow-non-ebuild: Manifest
              else pure Nothing
          mFallbackFloor <- templateFloor mFallback
          facts <-
            mapM
              (mkFacts mMan mFallbackFloor)
              (zip (glpEbuilds plan) sameSels)
          let samePaths =
                [ (pePV pe, invPath f)
                | (pe, Just f) <- zip (glpEbuilds plan) sameSels
                ]
          case assessPlannedFacts key eco pn facts of
            Left err -> pure (Left err)
            Right ca ->
              pure (Right (ca, samePaths, invPath <$> mFallback))
  where
    templateFloor Nothing = pure Nothing
    templateFloor (Just f) = do
      exists <- doesFileExist (invPath f)
      if not exists
        then pure Nothing
        else parseRustMinVerFromEbuild <$> readEbuild tree (invPath f)
    mkFacts mMan mFallbackFloor (pe, mSame) = do
      mContent <- case mSame of
        Nothing -> pure Nothing
        Just f -> do
          exists <- doesFileExist (invPath f)
          if exists then Just <$> readEbuild tree (invPath f) else pure Nothing
      let mTag =
            case eco of
              Cargo {} -> fromMaybe Nothing (lookupDirectTagFloor plan (pePV pe))
              _ -> Nothing
          mTemplate = maybe mFallbackFloor parseRustMinVerFromEbuild mContent
      pure
        PlannedPvFacts
          { ppfPV = pePV pe,
            ppfKeywords = peKeywords pe,
            ppfPresentContent = mContent,
            ppfManifest = mMan,
            ppfTagFloor = mTag,
            ppfRuntimeReq = plannedRuntimeReq plan (pePV pe),
            ppfTemplateFloor = mTemplate,
            ppfAssetsHost = defaultAssetsHost
          }

statusFromCompare :: EbuildVersion -> EbuildVersion -> UpdateStatus
statusFromCompare local remote =
  case comparePV local remote of
    Just LT ->
      Outdated
        [ OutdatedLine
            { olFrom = local,
              olTo = remote,
              olLabel = Nothing,
              olAssetsReusable = False
            }
        ]
    Just EQ -> Ok local
    Just GT -> Ahead local remote
    Nothing ->
      FetchError
        ( "incomparable versions: local="
            <> T.pack (show local)
            <> " remote="
            <> T.pack (show remote)
        )

-- | Production fetcher dispatching to Http / GitHub / npm clients.
productionFetcherWithLatch :: GitHubLatch -> Maybe T.Text -> IO Fetcher
productionFetcherWithLatch latch mToken = do
  mgr <- newManager tlsManagerSettings
  pure $ \src -> case src of
    Http {} -> fetchHttpWith mgr src
    HttpJson {} -> fetchHttpJsonWith mgr src
    GitHub {} -> fetchGitHubWithLatch latch mgr mToken src
    Npm {} -> fetchNpmWith mgr src

-- | True when selected GitHub sources will live-call @api.github.com@.
needsLiveGitHubApi ::
  CheckCacheHandle ->
  FilePath ->
  [PackageEntry] ->
  Map.Map PackageKey [Ebuild] ->
  IO Bool
needsLiveGitHubApi cache overlayRoot entries byPkg =
  go entries
  where
    go [] = pure False
    go (e : es) = do
      live <- packageNeedsLiveGitHub cache overlayRoot byPkg e
      if live then pure True else go es

packageNeedsLiveGitHub ::
  CheckCacheHandle ->
  FilePath ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO Bool
packageNeedsLiveGitHub cache overlayRoot byPkg entry =
  case lookupPolicy (peKey entry) of
    Nothing -> pure False
    Just policy ->
      case policySource policy of
        GitHub {} ->
          let locals = Map.findWithDefault [] (peKey entry) byPkg
           in case policyTechnique policy of
                GitMvAndManifest -> gitMvNeedsLive cache entry locals (policySource policy)
                DepsAndAssets eco ->
                  depsNeedsLive cache overlayRoot entry locals (policySource policy) eco
                Unsupported _ -> pure False
        _ -> pure False

gitMvNeedsLive ::
  CheckCacheHandle ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  IO Bool
gitMvNeedsLive cache entry locals src = do
  let ebuilds = if null locals then syntheticLocals entry else locals
  fp <- withNewTreeLock $ \tree -> computeFingerprint tree src ebuilds
  mCached <- lookupLatest cache (peKey entry) fp
  pure (isNothing mCached)

depsNeedsLive ::
  CheckCacheHandle ->
  FilePath ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  EcosystemSpec ->
  IO Bool
depsNeedsLive cache overlayRoot entry locals src eco = do
  let tech = DepsAndAssets eco
      localPVs = localNonLivePVs locals
  fp <- withNewTreeLock $ \tree -> computeFingerprint tree src locals
  mProvFp <-
    withNewTreeLock $ \tree ->
      computeOverlayProviderFingerprint tree overlayRoot tech
  mCached <-
    case (overlayCeilingProvider tech, mProvFp) of
      (Just _, Nothing) -> pure Nothing
      (Just _, Just pfp) -> lookupDeps cache (peKey entry) fp (Just pfp)
      (Nothing, _) -> lookupDeps cache (peKey entry) fp Nothing
  planLive <- case mCached of
    Just plan
      | cachedCargoPlanUsable eco src plan -> do
          assessed <-
            withNewTreeLock $ \tree ->
              assessOverlayContent tree eco (peKey entry) (pePN entry) locals plan
          pure $ case assessed of
            Left _ -> True
            Right (ca, _, _) ->
              let missing = missingTargets localPVs plan
                  contentFix =
                    [ pv
                    | pv <- caNeedsWorkPVs ca,
                      not (any (samePV pv) missing)
                    ]
               in planNeedsWork localPVs contentFix plan
    _ -> pure True
  providerLive <-
    case overlayCeilingProvider tech of
      Nothing -> pure False
      Just provider -> providerLatestMiss cache overlayRoot provider
  pure (planLive || providerLive)

providerLatestMiss :: CheckCacheHandle -> FilePath -> PackageKey -> IO Bool
providerLatestMiss cache overlayRoot providerKey =
  case (splitPackageKey providerKey, lookupPolicy providerKey) of
    (Just (cat, pn), Just policy) -> do
      let dir = overlayRoot </> T.unpack cat </> T.unpack pn
      exists <- doesDirectoryExist dir
      if not exists
        then pure False
        else do
          fp <-
            withNewTreeLock $ \tree ->
              computeFingerprintFromDir tree (policySource policy) dir pn
          mCached <- lookupLatest cache providerKey fp
          pure (isNothing mCached)
    _ -> pure False

syntheticLocals :: PackageEntry -> [Ebuild]
syntheticLocals entry =
  [ Ebuild
      { ebuildCategory = "",
        ebuildPackage = pePN entry,
        ebuildVersion = renderPVNoRev (peLocal entry),
        ebuildPath = pePath entry
      }
  ]

-- | Drop latch-class fetch errors; return command abort text when tripped.
finishOutdatedReports ::
  GitHubLatch ->
  [UpdateReport] ->
  IO ([UpdateReport], Maybe Text)
finishOutdatedReports latch reports = do
  mErr <- peekGitHubLatch latch
  case mErr of
    Nothing -> pure (reports, Nothing)
    Just err ->
      let formatted = formatGitHubHttpError err
          keep =
            [ r
            | r <- reports,
              case reportStatus r of
                FetchError t ->
                  t /= githubLatchAbortedMessage && t /= formatted
                _ -> True
            ]
       in pure (keep, Just (gitHubAbortLog err))
