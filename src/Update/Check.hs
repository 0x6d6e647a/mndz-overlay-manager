{-# LANGUAGE OverloadedStrings #-}

module Update.Check
  ( groupNewest,
    groupByPackage,
    PackageEntry (..),
    checkOverlay,
    checkOverlayWith,
    checkOverlayWithPlan,
    checkPackage,
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
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import System.Directory (doesFileExist)
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildHasDevLangGoBdepend,
    keywordsMatch,
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
import Update.Go.Plan
  ( PlanOps,
    PlanProgress (..),
    localNonLivePVs,
    planGoPackageWithProgress,
    productionPlanOps,
  )
import Update.Hardcoded (lookupPolicy)
import Update.Http (fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.Resolve (resolveSource)
import Update.Types
  ( Fetcher,
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
  planOps <- productionPlanOps Nothing jobs
  checkOverlayWithPlan jobs mh fetch planOps ebuilds

-- | Like 'checkOverlayWith' with injectable Go plan ops (token-aware list/mod).
checkOverlayWithPlan ::
  Int ->
  MultiHandle ->
  Fetcher ->
  PlanOps ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWithPlan jobs mh fetch planOps ebuilds = do
  let entries = sortOn (packageKeyText . peKey) (groupNewest ebuilds)
      byPkg = groupByPackage ebuilds
  mapConcurrentlyN jobs (checkOne mh fetch planOps byPkg) entries

checkOne ::
  MultiHandle ->
  Fetcher ->
  PlanOps ->
  Map.Map PackageKey [Ebuild] ->
  PackageEntry ->
  IO UpdateReport
checkOne mh fetch planOps byPkg entry = do
  let key = peKey entry
  mhStart mh key
  let locals = Map.findWithDefault [] key byPkg
  report <- case lookupPolicy key of
    Just (PackagePolicy src (GoVendorAndAssets mSub)) ->
      checkPackageGo mh planOps entry locals src mSub
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

-- | Go tree-lane outdated check with multi-step progress.
checkPackageGo ::
  MultiHandle ->
  PlanOps ->
  PackageEntry ->
  [Ebuild] ->
  UpdateSource ->
  Maybe FilePath ->
  IO UpdateReport
checkPackageGo mh planOps entry locals src mSub = do
  let key = peKey entry
      progress = goPlanProgress mh key
  planResult <- planGoPackageWithProgress planOps progress src mSub
  case planResult of
    Left err ->
      pure UpdateReport {reportKey = key, reportStatus = FetchError err}
    Right plan -> do
      let localPVs = localNonLivePVs locals
      contentFix <- contentFixPVs locals plan
      let needsWork =
            missingTargets localPVs plan
              <> contentFix
          gaps =
            if planNeedsWork localPVs contentFix plan
              then buildGapLines localPVs needsWork plan
              else []
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
                          olLabel = Just (glLabel g)
                        }
                    | g <- gaps
                    ]
          }

-- | Progress hooks: ceilings + list + one step per go.mod probe.
goPlanProgress :: MultiHandle -> PackageKey -> PlanProgress
goPlanProgress mh key =
  PlanProgress
    { ppOnCeilingsStart = do
        mhSteps mh key 2
        mhStatus mh key "discovering go ceilings",
      ppOnCeilingsDone = mhStep mh key "discovering go ceilings",
      ppOnListStart = mhStatus mh key "listing versions",
      ppOnListDone = \n -> do
        mhSteps mh key (2 + n)
        mhStep mh key "listing versions",
      ppOnProbeDone = mhStep mh key "probing go.mod"
    }

-- | Local PVs present in plan but needing content/KEYWORDS fix.
contentFixPVs :: [Ebuild] -> GoLanePlan -> IO [EbuildVersion]
contentFixPVs locals plan = do
  let planned = glpEbuilds plan
  concat <$> mapM (checkOneEbuild locals) planned
  where
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
              let bad =
                    not (assetsSrcUriParameterized content)
                      || not (ebuildHasDevLangGoBdepend content)
                      || not (keywordsMatch (peKeywords pe) content)
              pure [pePV pe | bad]
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

statusFromCompare :: EbuildVersion -> EbuildVersion -> UpdateStatus
statusFromCompare local remote =
  case comparePV local remote of
    Just LT ->
      Outdated
        [ OutdatedLine
            { olFrom = local,
              olTo = remote,
              olLabel = Nothing
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

renderPVNoRev :: EbuildVersion -> Text
renderPVNoRev (Raw t) = t
renderPVNoRev (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)

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
