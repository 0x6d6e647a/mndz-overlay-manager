{-# LANGUAGE OverloadedStrings #-}

module Update.Check
  ( groupNewest,
    groupByPackage,
    PackageEntry (..),
    checkOverlay,
    checkOverlayWith,
    checkOverlayWithPlan,
    checkOverlayWithDepsPlan,
    checkPackage,
    checkPackageDeps,
    checkPackageGo,
    productionFetcher,
    productionFetcherWithToken,
    statusFromCompare,
    renderPVNoRev,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress (MultiHandle (..))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, renderPVNoRev, samePV)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))
import Update.Assets.Layout (distfileKindForEcosystem, distfileTarballName)
import Update.Cargo.Msrv (probeRustVersionFromCargoTomls)
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithProgress,
    productionDepsPlanOps,
  )
import Update.EbuildEdit
  ( bunBdependAtom,
    ebuildNeedsCargoContentFix,
    ebuildNeedsContentFix,
    ebuildNeedsContentFixAtom,
    manifestHasVendorDist,
    nodejsBdependAtom,
  )
import Update.GitHub (fetchGitHubWith)
import Update.Go.Lanes
  ( GapLine (..),
    GoLanePlan (..),
    PlannedEbuild (..),
    buildGapLines,
    missingTargets,
    planNeedsWork,
  )
import Update.Go.ModFetch (GoModKey (..), parseGoReqFromMod)
import Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    localNonLivePVs,
  )
import Update.Go.Vendor (versionTag)
import Update.Hardcoded (lookupPolicy)
import Update.Http (fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.Resolve (resolveSource)
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

-- | Run update checks concurrently with a jobs limit (no progress UI).
checkOverlay :: Int -> Fetcher -> [Ebuild] -> IO [UpdateReport]
checkOverlay jobs = checkOverlayWith jobs noopMulti
  where
    noopMulti =
      MultiHandle
        { mhStart = \_ -> pure (),
          mhStatus = \_ _ -> pure (),
          mhSteps = \_ _ -> pure (),
          mhStep = \_ _ -> pure (),
          mhSuccess = \_ -> pure (),
          mhFail = \_ _ -> pure ()
        }

-- | Concurrent checks with multi-progress callbacks.
checkOverlayWith ::
  Int ->
  MultiHandle ->
  Fetcher ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWith jobs mh fetch ebuilds = do
  depsOps <- productionDepsPlanOps Nothing jobs Nothing
  checkOverlayWithDepsPlan jobs mh fetch depsOps ebuilds

-- | Like 'checkOverlayWith' with injectable Go plan ops (token-aware list/mod).
checkOverlayWithPlan ::
  Int ->
  MultiHandle ->
  Fetcher ->
  PlanOps ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWithPlan jobs mh fetch planOps ebuilds = do
  -- Wrap PlanOps into a minimal DepsPlanOps for Go-only paths.
  depsOps <- productionDepsPlanOps Nothing jobs Nothing
  let depsOps' =
        depsOps
          { dpoPortageq = poPortageq planOps,
            dpoListVersions = poListVersions planOps,
            dpoFetchGoMod = poFetchGoMod planOps,
            dpoWorkBudget = poWorkBudget planOps,
            dpoGoCeilingsCache = poCeilingsCache planOps
          }
  checkOverlayWithDepsPlan jobs mh fetch depsOps' ebuilds

checkOverlayWithDepsPlan ::
  Int ->
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWithDepsPlan jobs mh fetch depsOps ebuilds = do
  let entries = sortOn (packageKeyText . peKey) (groupNewest ebuilds)
      byPkg = groupByPackage ebuilds
  mapConcurrentlyN jobs (checkOne mh fetch depsOps byPkg) entries

checkOne ::
  MultiHandle ->
  Fetcher ->
  DepsPlanOps ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO UpdateReport
checkOne mh fetch depsOps byPkg entry = do
  let key = peKey entry
  mhStart mh key
  let locals = Map.findWithDefault [] key byPkg
  report <- case lookupPolicy key of
    Just (PackagePolicy src (DepsAndAssets eco)) ->
      checkPackageDeps mh depsOps entry locals src eco
    _ -> do
      mhStatus mh key "fetching"
      checkPackage fetch entry
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
checkPackage :: Fetcher -> PackageEntry -> IO UpdateReport
checkPackage fetch entry = do
  let key = peKey entry
      local = peLocal entry
  case resolveSource key of
    Nothing ->
      pure UpdateReport {reportKey = key, reportStatus = Unconfigured}
    Just src -> do
      result <- fetch src
      pure $ case result of
        Left err ->
          UpdateReport {reportKey = key, reportStatus = FetchError err}
        Right remote ->
          UpdateReport
            { reportKey = key,
              reportStatus = statusFromCompare local remote
            }

-- | Runtime-lane outdated check for DepsAndAssets packages.
checkPackageDeps ::
  MultiHandle ->
  DepsPlanOps ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  EcosystemSpec ->
  IO UpdateReport
checkPackageDeps mh depsOps entry locals src eco = do
  let key = peKey entry
      progress = depsPlanProgress mh key eco
      localPVs = localNonLivePVs locals
  planResult <-
    planDepsPackageWithProgress depsOps progress eco src localPVs
  case planResult of
    Left err ->
      pure UpdateReport {reportKey = key, reportStatus = FetchError err}
    Right plan -> do
      contentFix <- contentFixPVs depsOps eco src locals plan
      let missing = missingTargets localPVs plan
          needsWork = missing <> contentFix
          gaps =
            if planNeedsWork localPVs contentFix plan
              then buildGapLines localPVs needsWork plan
              else []
          contentFixSet = contentFix
          isContentOnly toPV =
            any (samePV toPV) contentFixSet
              && not (any (samePV toPV) missing)
      pure $
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
                          olAssetsReusable = isContentOnly (glTo g)
                        }
                    | g <- gaps
                    ]
          }

-- | Go-only entry (tests).
checkPackageGo ::
  MultiHandle ->
  PlanOps ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  Maybe FilePath ->
  IO UpdateReport
checkPackageGo mh planOps entry locals src mSub = do
  depsOps <- productionDepsPlanOps Nothing 2 Nothing
  let depsOps' =
        depsOps
          { dpoPortageq = poPortageq planOps,
            dpoListVersions = poListVersions planOps,
            dpoFetchGoMod = poFetchGoMod planOps,
            dpoWorkBudget = poWorkBudget planOps,
            dpoGoCeilingsCache = poCeilingsCache planOps
          }
  checkPackageDeps mh depsOps' entry locals src (Go mSub)

depsPlanProgress :: MultiHandle -> PackageKey -> EcosystemSpec -> PlanProgress
depsPlanProgress mh key eco =
  let ceilLabel = case eco of
        Go _ -> "discovering go ceilings"
        NpmEco -> "discovering nodejs ceilings"
        Bun -> "discovering bun-bin ceilings"
        Cargo {} -> "discovering rust ceilings"
      probeLabel = case eco of
        Go _ -> "probing go.mod"
        NpmEco -> "probing engines.node"
        Bun -> "probing engines.bun"
        Cargo {} -> "probing rust-version"
   in PlanProgress
        { ppOnCeilingsStart = do
            mhSteps mh key 3
            mhStatus mh key ceilLabel,
          ppOnCeilingsDone = mhStep mh key ceilLabel,
          ppOnListStart = mhStatus mh key "listing versions",
          ppOnListDone = \_n -> mhStep mh key "listing versions",
          ppOnProbeDone = mhStep mh key probeLabel
        }

contentFixPVs ::
  DepsPlanOps ->
  EcosystemSpec ->
  UpdateSource ->
  [Ebuild] ->
  GoLanePlan ->
  IO [EbuildVersion]
contentFixPVs depsOps eco src locals plan = do
  let planned = glpEbuilds plan
  concat <$> mapM (checkOneEbuild locals) planned
  where
    kind = distfileKindForEcosystem eco
    checkOneEbuild es pe = do
      let matches =
            [ e
            | e <- es,
              samePV
                (parseEbuildVersion (ebuildVersion e))
                (pePV pe)
            ]
      case matches of
        [] -> pure []
        (e : _) -> do
          exists <- doesFileExist (ebuildPath e)
          if not exists
            then pure [pePV pe]
            else do
              content <- TIO.readFile (ebuildPath e)
              let pkgDir = takeDirectory (ebuildPath e)
                  pn = ebuildPackage e
                  pvNoRev = renderPVNoRev (pePV pe)
                  tarball = distfileTarballName kind pn pvNoRev
                  manPath = pkgDir </> "Manifest"
              manMissing <- do
                manExists <- doesFileExist manPath
                if not manExists
                  then pure True
                  else do
                    manText <- TIO.readFile manPath
                    pure (not (manifestHasVendorDist manText tarball))
              bad <- case eco of
                Go mSub -> do
                  mGoVer <- fetchGoModForPV depsOps src mSub pvNoRev
                  pure $
                    ebuildNeedsContentFix (peKeywords pe) content mGoVer
                      || manMissing
                NpmEco -> do
                  mAtom <- fetchNpmAtom depsOps src pvNoRev
                  pure $
                    ebuildNeedsContentFixAtom (peKeywords pe) content mAtom
                      || manMissing
                Bun -> do
                  mAtom <- fetchBunAtom depsOps src pvNoRev
                  pure $
                    ebuildNeedsContentFixAtom (peKeywords pe) content mAtom
                      || manMissing
                Cargo mLock mPkg -> do
                  mMsrv <- fetchCargoMsrv depsOps src mLock mPkg pvNoRev
                  pure $
                    ebuildNeedsCargoContentFix (peKeywords pe) content mMsrv
                      || manMissing
              pure [pePV pe | bad]

fetchGoModForPV ::
  DepsPlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  Text ->
  IO (Maybe Text)
fetchGoModForPV depsOps src mSub pvNoRev =
  case src of
    GitHub owner repo prefix -> do
      let tag = versionTag prefix pvNoRev
          key =
            GoModKey
              { gmkOwner = owner,
                gmkRepo = repo,
                gmkTag = tag,
                gmkSubdir = mSub
              }
      eres <- dpoFetchGoMod depsOps key
      pure $ case eres of
        Right body -> parseGoReqFromMod body
        Left _ -> Nothing
    _ -> pure Nothing

fetchNpmAtom :: DepsPlanOps -> UpdateSource -> Text -> IO (Maybe Text)
fetchNpmAtom depsOps src pvNoRev =
  case src of
    Npm npmPkg -> do
      eres <- dpoFetchNpmEngines depsOps npmPkg pvNoRev
      pure $ case eres of
        Right ver -> Just (nodejsBdependAtom ver)
        Left _ -> Nothing
    _ -> pure Nothing

fetchBunAtom :: DepsPlanOps -> UpdateSource -> Text -> IO (Maybe Text)
fetchBunAtom depsOps src pvNoRev =
  case src of
    GitHub owner repo prefix -> do
      eres <- dpoFetchBunEngines depsOps owner repo prefix pvNoRev
      pure $ case eres of
        Right ver -> Just (bunBdependAtom ver)
        Left _ -> Nothing
    _ -> pure Nothing

fetchCargoMsrv ::
  DepsPlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  Maybe FilePath ->
  Text ->
  IO (Maybe Text)
fetchCargoMsrv depsOps src mLock mPkg pvNoRev =
  case src of
    GitHub owner repo prefix ->
      probeRustVersionFromCargoTomls mPkg mLock $ \mSub ->
        dpoFetchCargoToml depsOps owner repo prefix pvNoRev mSub
    _ -> pure Nothing

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
productionFetcher :: IO Fetcher
productionFetcher = productionFetcherWithToken Nothing

-- | Like 'productionFetcher' with an optional resolved GitHub token.
productionFetcherWithToken :: Maybe T.Text -> IO Fetcher
productionFetcherWithToken mToken = do
  mgr <- newManager tlsManagerSettings
  pure $ \src -> case src of
    Http {} -> fetchHttpWith mgr src
    GitHub {} -> fetchGitHubWith mgr mToken src
    Npm {} -> fetchNpmWith mgr src
