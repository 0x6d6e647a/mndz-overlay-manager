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
    productionFetcherWithToken,
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
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, renderPVNoRev, samePV)
import System.Directory (doesFileExist)
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
import Update.Cargo.Msrv (parseRustMinVerFromEbuild)
import Update.CheckCache
  ( CheckCacheHandle,
    cachedCargoPlanUsable,
    computeFingerprint,
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
    planDepsPackageWithProgressFor,
  )
import Update.EbuildSelection
  ( InventoryFile (..),
    inventoryFromEbuild,
    selectCanonicalSamePV,
    selectHighestNonLive,
  )
import Update.GitHub (fetchGitHubWith)
import Update.Go.Lanes
  ( GapLine (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    buildGapLines,
    missingTargets,
    planErrorMessage,
    planNeedsWork,
  )
import Update.Go.Plan
  ( PlanProgress (..),
    localNonLivePVs,
  )
import Update.Hardcoded (lookupLaneArches, lookupPolicy)
import Update.Http (fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.OverlayWaves
  ( blockedOnLabel,
    computeOverlayProviderFingerprint,
    fetchOverlayProviderLatest,
    hypotheticalCeilings,
    overlayCeilingProvider,
    overlayFailClosedMessage,
    planDeltaHolds,
  )
import Update.Resolve (resolveSource)
import Update.Runtime.Ceilings (discoverBunBinMetas)
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
  mapConcurrentlyN jobs (checkOne mh fetch depsOps cache byPkg) entries

checkOne ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO UpdateReport
checkOne mh fetch depsOps cache byPkg entry = do
  let key = peKey entry
  mhStart mh key
  let locals = Map.findWithDefault [] key byPkg
  report <- case lookupPolicy key of
    Just (PackagePolicy src (DepsAndAssets eco) _) ->
      checkPackageDeps mh fetch depsOps cache entry locals src eco
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
      pure UpdateReport {reportKey = key, reportStatus = Unconfigured}
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
      fp <- computeFingerprint src ebuilds
      mCached <- lookupLatest cache key fp
      case mCached of
        Just remote -> do
          recordHit cache
          pure
            UpdateReport
              { reportKey = key,
                reportStatus = statusFromCompare local remote
              }
        Nothing -> do
          recordFetch cache
          result <- fetch src
          case result of
            Left err ->
              pure UpdateReport {reportKey = key, reportStatus = FetchError err}
            Right remote -> do
              storeLatest cache key fp remote
              pure
                UpdateReport
                  { reportKey = key,
                    reportStatus = statusFromCompare local remote
                  }

-- | Runtime-lane outdated check for DepsAndAssets packages.
checkPackageDeps ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  CheckCacheHandle ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  EcosystemSpec ->
  IO UpdateReport
checkPackageDeps mh fetch depsOps cache entry locals src eco = do
  let key = peKey entry
      progress = depsPlanProgress mh key eco
      localPVs = localNonLivePVs locals
      tech = DepsAndAssets eco
  fp <- computeFingerprint src locals
  mProvFp <-
    case dpoOverlayRoot depsOps of
      Just overlayRoot -> computeOverlayProviderFingerprint overlayRoot tech
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
          reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan
    _ -> do
      recordFetch cache
      planResult <-
        planDepsPackageWithProgressFor
          depsOps
          progress
          eco
          src
          localPVs
          (lookupLaneArches key)
      case planResult of
        Left err ->
          pure
            UpdateReport
              { reportKey = key,
                reportStatus = FetchError (planErrorMessage err)
              }
        Right plan -> do
          storeDeps cache key fp mProvFp plan
          reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan

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
  IO UpdateReport
reportFromDepsPlan mh fetch depsOps cache eco src entry locals localPVs plan = do
  let key = peKey entry
      pn = pePN entry
  assessed <- assessOverlayContent eco key pn locals plan
  case assessed of
    Left err ->
      pure
        UpdateReport
          { reportKey = key,
            reportStatus = FetchError err
          }
    Right (ca, _, _) -> do
      let missing = missingTargets localPVs plan
          contentFix =
            [ pv
            | pv <- caNeedsWorkPVs ca,
              not (any (samePV pv) missing)
            ]
          forceFull = caForceFullPVs ca
          onDiskNeed = planNeedsWork localPVs contentFix plan
          needsWork = missing <> contentFix
          gaps =
            if onDiskNeed
              then buildGapLines localPVs needsWork plan
              else []
          isContentOnly toPV =
            any (samePV toPV) contentFix
              && not (any (samePV toPV) missing)
          -- Marker is conservative until release lookup is plumbed: never
          -- claim reusable for forced-full PVs.
          mayReuse toPV =
            isContentOnly toPV && not (any (samePV toPV) forceFull)
          baseReport =
            UpdateReport
              { reportKey = key,
                reportStatus =
                  if null gaps
                    then case localPVs of
                      (v : _) -> Ok v
                      [] -> Ok (peLocal entry)
                    else
                      Outdated
                        [ OutdatedLine
                            { olFrom = glFrom g,
                              olTo = glTo g,
                              olLabel = Just (glLabel g),
                              olAssetsReusable = mayReuse (glTo g)
                            }
                        | g <- gaps
                        ]
              }
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
        baseReport

-- | Overlay wait-edge consumers: plan-delta blocked-on, fail-closed on fetch.
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
  UpdateReport ->
  IO UpdateReport
applyOverlayBlockIndication mh fetch depsOps cache eco src entry locals localPVs onDiskPlan onDiskNeed base =
  case overlayCeilingProvider (DepsAndAssets eco) of
    Nothing -> pure base
    Just provider ->
      case dpoOverlayRoot depsOps of
        Nothing ->
          pure
            base
              { reportStatus = FetchError (overlayFailClosedMessage provider)
              }
        Just overlayRoot -> do
          eRemote <-
            fetchOverlayProviderLatest fetch cache overlayRoot provider
          case eRemote of
            Left _ ->
              pure
                base
                  { reportStatus = FetchError (overlayFailClosedMessage provider)
                  }
            Right remote -> do
              eMetas <- discoverBunBinMetas overlayRoot
              case eMetas of
                Left _ ->
                  pure
                    base
                      { reportStatus = FetchError (overlayFailClosedMessage provider)
                      }
                Right metas -> do
                  let hypoCeil = hypotheticalCeilings metas remote
                  hypoResult <-
                    planDepsPackageWithCeilingsFor
                      depsOps
                      (depsPlanProgress mh (peKey entry) eco)
                      eco
                      src
                      localPVs
                      hypoCeil
                      (lookupLaneArches (peKey entry))
                  case hypoResult of
                    Left _ ->
                      pure
                        base
                          { reportStatus = FetchError (overlayFailClosedMessage provider)
                          }
                    Right hypoPlan -> do
                      hypoFix <- contentFixPVs depsOps eco src locals hypoPlan
                      let hypoNeed = planNeedsWork localPVs hypoFix hypoPlan
                      if not
                        ( planDeltaHolds
                            (glpUniquePVs onDiskPlan)
                            onDiskNeed
                            (glpUniquePVs hypoPlan)
                            hypoNeed
                        )
                        then pure base
                        else
                          pure $
                            annotateBlockedOn provider hypoPlan localPVs base

annotateBlockedOn ::
  PackageKey ->
  RuntimeLanePlan ->
  [EbuildVersion] ->
  UpdateReport ->
  UpdateReport
annotateBlockedOn provider hypoPlan localPVs base =
  let note = blockedOnLabel provider
   in case reportStatus base of
        Outdated lines_ ->
          base
            { reportStatus =
                Outdated
                  [ ol
                      { olLabel =
                          Just $
                            maybe note (\lab -> lab <> " " <> note) (olLabel ol)
                      }
                  | ol <- lines_
                  ]
            }
        Ok local ->
          let target =
                case glpUniquePVs hypoPlan of
                  (pv : rest) -> foldl' newerPv pv rest
                  [] -> local
           in base
                { reportStatus =
                    Outdated
                      [ OutdatedLine
                          { olFrom = case localPVs of
                              (v : _) -> v
                              [] -> local,
                            olTo = target,
                            olLabel = Just note,
                            olAssetsReusable = False
                          }
                      ]
                }
        other -> base {reportStatus = other}
  where
    newerPv a b =
      case comparePV a b of
        Just LT -> b
        _ -> a

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
  DepsPlanOps ->
  EcosystemSpec ->
  UpdateSource ->
  [Ebuild] ->
  RuntimeLanePlan ->
  IO [EbuildVersion]
contentFixPVs _depsOps eco _src locals plan = do
  let pn =
        case locals of
          (e : _) -> ebuildPackage e
          [] -> ""
      key =
        case locals of
          (e : _) -> mkPackageKey (ebuildCategory e) (ebuildPackage e)
          [] -> PackageKey ""
  assessed <- assessOverlayContent eco key pn locals plan
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
assessOverlayContent eco key pn locals plan = do
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
              then Just <$> TIO.readFile manPath
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
              ca = assessPlannedFacts key eco pn facts
          pure (Right (ca, samePaths, invPath <$> mFallback))
  where
    templateFloor Nothing = pure Nothing
    templateFloor (Just f) = do
      exists <- doesFileExist (invPath f)
      if not exists
        then pure Nothing
        else parseRustMinVerFromEbuild <$> TIO.readFile (invPath f)
    mkFacts mMan mFallbackFloor (pe, mSame) = do
      mContent <- case mSame of
        Nothing -> pure Nothing
        Just f -> do
          exists <- doesFileExist (invPath f)
          if exists then Just <$> TIO.readFile (invPath f) else pure Nothing
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
            ppfTemplateFloor = mTemplate
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
productionFetcherWithToken :: Maybe T.Text -> IO Fetcher
productionFetcherWithToken mToken = do
  mgr <- newManager tlsManagerSettings
  pure $ \src -> case src of
    Http {} -> fetchHttpWith mgr src
    GitHub {} -> fetchGitHubWith mgr mToken src
    Npm {} -> fetchNpmWith mgr src
