{-# LANGUAGE OverloadedStrings #-}

module Update.Deps.Plan
  ( DepsPlanOps (..),
    BunProbe (..),
    minimumBunProbe,
    productionDepsPlanOps,
    planDepsPackageWithProgress,
    planDepsPackageWithProgressFor,
    planDepsPackageWithCeilingsFor,
    toGoPlanOps,
  )
where

import CLI.Jobs (WorkBudget, newWorkBudget, withWorkSlot)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, catch)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion (..), comparePV, renderPVNoRev, samePV)
import System.FilePath ((</>))
import Update.Bun.Cache
  ( BunProbe (..),
    minimumBunProbe,
    parseBunProbeFromPackageJson,
  )
import Update.Cargo.Msrv
  ( CargoTomlFetch (..),
    TagFloorResult (..),
    applyRustToolchainFloor,
    cargoFloorPolicyKey,
    probePolicyTagFloor,
  )
import Update.GitHub (listGitHubVersionsWith)
import Update.Go.Lanes
  ( CargoFloorCoverage (..),
    CargoPathProvenance (..),
    CargoTagFloorSnapshot (..),
    LaneTarget (..),
    PlanError (..),
    RuntimeLanePlan (..),
    VersionCandidate (..),
    filterCandidateVersions,
    planFromTargetsWithAtomFor,
    restrictCeilings,
    selectAllLaneTargets,
    withCargoTagFloors,
  )
import Update.Go.ModFetch
  ( GoModFetcher,
    GoModKey (..),
    parseGoReqFromMod,
    productionGoModFetcher,
    withGoModCache,
  )
import Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
  )
import Update.Go.Vendor (versionTag)
import Update.Npm.Cache (fetchNpmEnginesNode, listNpmVersions)
import Update.Runtime.Ceilings
  ( PortageqRunner,
    RuntimeCeilings (..),
    discoverBunBinCeilings,
    discoverGoCeilingsWith,
    discoverNodejsCeilingsWith,
    discoverRustUnionCeilingsWith,
    discoverSbclCeilingsWith,
    productionPortageqRunner,
  )
import Update.Sbcl.Deps (parseSbclVersionFloor)
import Update.Types (EcosystemSpec (..), UpdateSource (..))

-- | Injectable ops for multi-ecosystem deps planning.
data DepsPlanOps = DepsPlanOps
  { dpoPortageq :: PortageqRunner,
    dpoListVersions :: UpdateSource -> IO (Either Text [EbuildVersion]),
    dpoFetchGoMod :: GoModFetcher,
    dpoFetchNpmEngines :: Text -> Text -> IO (Either Text Text),
    dpoFetchBunEngines :: Text -> Text -> Text -> Text -> IO (Either Text BunProbe),
    -- | Fetch package Cargo.toml body at tag for rust-version probe.
    dpoFetchCargoToml :: Text -> Text -> Text -> Text -> Maybe FilePath -> IO CargoTomlFetch,
    -- | Fetch rust-toolchain.toml at tag (lock subdir then repository root).
    dpoFetchRustToolchain :: Text -> Text -> Text -> Text -> Maybe FilePath -> IO CargoTomlFetch,
    -- | Fetch @sbcl.version@ body at tag for SBCL floor probe.
    dpoFetchSbclVersion :: Text -> Text -> Text -> Text -> IO (Either Text Text),
    dpoWorkBudget :: WorkBudget,
    dpoGoCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoNodeCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoBunCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoRustCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoSbclCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoOverlayRoot :: Maybe FilePath,
    dpoManager :: Manager
  }

-- | View as Go PlanOps (shared go.mod / portageq / list for GitHub).
toGoPlanOps :: DepsPlanOps -> PlanOps
toGoPlanOps d =
  PlanOps
    { poPortageq = dpoPortageq d,
      poListVersions = dpoListVersions d,
      poFetchGoMod = dpoFetchGoMod d,
      poWorkBudget = dpoWorkBudget d,
      poCeilingsCache = dpoGoCeilingsCache d
    }

productionDepsPlanOps :: Maybe Text -> Int -> Maybe FilePath -> IO DepsPlanOps
productionDepsPlanOps mToken jobs mOverlay = do
  mgr <- newManager tlsManagerSettings
  baseMod <- productionGoModFetcher mToken
  cachedMod <- withGoModCache baseMod
  budget <- newWorkBudget jobs
  goCache <- newMVar Nothing
  nodeCache <- newMVar Nothing
  bunCache <- newMVar Nothing
  rustCache <- newMVar Nothing
  sbclCache <- newMVar Nothing
  pure
    DepsPlanOps
      { dpoPortageq = productionPortageqRunner,
        dpoListVersions = \src -> case src of
          GitHub {} -> listGitHubVersionsWith mgr mToken src
          Npm pkg -> listNpmVersions mgr pkg
          _ -> pure (Left "unsupported update source for deps planning"),
        dpoFetchGoMod = cachedMod,
        dpoFetchNpmEngines = fetchNpmEnginesNode mgr,
        dpoFetchBunEngines = fetchBunEnginesAtTag mgr mToken,
        dpoFetchCargoToml = fetchCargoTomlAtTag mgr mToken,
        dpoFetchRustToolchain = fetchRustToolchainAtTag mgr mToken,
        dpoFetchSbclVersion = fetchSbclVersionAtTag mgr mToken,
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoSbclCeilingsCache = sbclCache,
        dpoOverlayRoot = mOverlay,
        dpoManager = mgr
      }

planDepsPackageWithProgress ::
  DepsPlanOps ->
  PlanProgress ->
  EcosystemSpec ->
  UpdateSource ->
  [EbuildVersion] ->
  IO (Either PlanError RuntimeLanePlan)
planDepsPackageWithProgress ops progress eco src locals =
  planDepsPackageWithProgressFor ops progress eco src locals []

-- | Like 'planDepsPackageWithProgress' with a policy runtime-lane arch allowlist.
planDepsPackageWithProgressFor ::
  DepsPlanOps ->
  PlanProgress ->
  EcosystemSpec ->
  UpdateSource ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planDepsPackageWithProgressFor ops progress eco src locals allowlist =
  case eco of
    Go mSub -> planGo ops progress src mSub locals allowlist
    NpmEco -> planNpm ops progress src locals allowlist
    Bun -> planBun ops progress src locals Nothing allowlist
    Cargo mLock mPkg _src -> planCargo ops progress src mLock mPkg locals allowlist
    Sbcl -> planSbcl ops progress src locals allowlist

-- | Plan against caller-supplied ceilings (hypothetical overlay bun-bin)
-- with a policy runtime-lane arch allowlist.
-- Does not read or write the process-lifetime bun ceiling cache.
planDepsPackageWithCeilingsFor ::
  DepsPlanOps ->
  PlanProgress ->
  EcosystemSpec ->
  UpdateSource ->
  [EbuildVersion] ->
  RuntimeCeilings ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planDepsPackageWithCeilingsFor ops progress eco src locals ceilings allowlist =
  case eco of
    Bun -> planBun ops progress src locals (Just ceilings) allowlist
    Go mSub -> planGo ops progress src mSub locals allowlist
    NpmEco -> planNpm ops progress src locals allowlist
    Cargo mLock mPkg _src -> planCargo ops progress src mLock mPkg locals allowlist
    Sbcl -> planSbcl ops progress src locals allowlist

------------------------------------------------------------------------
-- Go
------------------------------------------------------------------------

planGo ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planGo ops progress src mSub locals allowlist =
  case src of
    GitHub owner repo prefix ->
      planWith
        ops
        progress
        src
        locals
        allowlist
        (discoverCeilingsCached (dpoGoCeilingsCache ops) (discoverGoCeilingsWith (dpoPortageq ops)))
        ( \pv -> do
            let tag = versionTag prefix (renderPVNoRev pv)
                key =
                  GoModKey
                    { gmkOwner = owner,
                      gmkRepo = repo,
                      gmkTag = tag,
                      gmkSubdir = mSub
                    }
            body <- dpoFetchGoMod ops key
            pure $ case body of
              Left _ -> Right Nothing
              Right txt -> Right (parseGoReqFromMod txt)
        )
    _ -> pure (Left (PlanFailed "DepsAndAssets Go requires a GitHub update source"))

------------------------------------------------------------------------
-- Npm
------------------------------------------------------------------------

planNpm ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planNpm ops progress src locals allowlist =
  case src of
    Npm npmPkg ->
      planWith
        ops
        progress
        src
        locals
        allowlist
        ( discoverCeilingsCached
            (dpoNodeCeilingsCache ops)
            (discoverNodejsCeilingsWith (dpoPortageq ops))
        )
        ( \pv -> do
            eres <- dpoFetchNpmEngines ops npmPkg (renderPVNoRev pv)
            pure $ case eres of
              Left err -> Left (PlanProbeFailed err)
              Right ver -> Right (Just ver)
        )
    _ -> pure (Left (PlanFailed "DepsAndAssets Npm requires an Npm update source"))

------------------------------------------------------------------------
-- Bun
------------------------------------------------------------------------

planBun ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  -- | Override ceilings (hypothetical plan-delta). @Nothing@ discovers from overlay.
  Maybe RuntimeCeilings ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planBun ops progress src locals mCeilings allowlist =
  case src of
    GitHub owner repo prefix ->
      case mCeilings of
        Just ceilings ->
          planWith
            ops
            progress
            src
            locals
            allowlist
            (pure (Right ceilings))
            (bunProbe ops owner repo prefix)
        Nothing ->
          case dpoOverlayRoot ops of
            Nothing ->
              pure
                ( Left
                    ( PlanFailed
                        "overlay path required for bun-bin runtime ceilings"
                    )
                )
            Just overlayRoot ->
              planWith
                ops
                progress
                src
                locals
                allowlist
                ( discoverCeilingsCached
                    (dpoBunCeilingsCache ops)
                    (discoverBunBinCeilings overlayRoot)
                )
                (bunProbe ops owner repo prefix)
    _ -> pure (Left (PlanFailed "DepsAndAssets Bun requires a GitHub update source"))

bunProbe ::
  DepsPlanOps ->
  Text ->
  Text ->
  Text ->
  EbuildVersion ->
  IO (Either PlanError (Maybe Text))
bunProbe ops owner repo prefix pv = do
  eres <-
    dpoFetchBunEngines
      ops
      owner
      repo
      prefix
      (renderPVNoRev pv)
  pure $ case eres of
    Left err -> Left (PlanProbeFailed err)
    Right probe -> Right (Just (bunProbeMinimum probe))

------------------------------------------------------------------------
-- Cargo
------------------------------------------------------------------------

planCargo ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  Maybe FilePath ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planCargo ops progress src mLockSub mPkgSub locals allowlist =
  case src of
    GitHub owner repo prefix -> do
      snapsVar <- newMVar []
      memoVar <- newMVar Map.empty
      result <-
        planWith
          ops
          progress
          src
          locals
          allowlist
          ( discoverCeilingsCached
              (dpoRustCeilingsCache ops)
              (discoverRustUnionCeilingsWith (dpoPortageq ops))
          )
          ( \pv -> do
              let pvText = renderPVNoRev pv
                  fetchMemo = memoFetchCargo memoVar ops owner repo prefix pvText
              probed <-
                probePolicyTagFloor mPkgSub mLockSub Nothing fetchMemo
              case probed of
                TagFloorFailed err -> pure (Left (PlanProbeFailed err))
                TagFloorIncomplete _ _ ->
                  -- Incomplete is not a parseable requirement; skip, do not persist.
                  pure (Right Nothing)
                TagFloorComplete mFloor prov -> do
                  applied <-
                    applyRustToolchainFloor
                      mLockSub
                      (memoFetchToolchain memoVar ops owner repo prefix pvText)
                      mFloor
                  case applied of
                    Left err -> pure (Left (PlanProbeFailed err))
                    Right mFloor' -> do
                      let snap =
                            CargoTagFloorSnapshot
                              { ctfsPV = stripRev pv,
                                ctfsFloor = mFloor',
                                ctfsCoverage = Just CargoCoverageComplete,
                                ctfsReasons = [],
                                ctfsProvenance =
                                  [ CargoPathProvenance p f
                                  | (p, f) <- prov
                                  ]
                              }
                      modifyMVar_ snapsVar $ \xs -> pure (snap : xs)
                      pure (Right (Just (fromMaybe "0.0.0" mFloor')))
          )
      case result of
        Left err -> pure (Left err)
        Right plan -> do
          snaps <- readMVar snapsVar
          let selected = mapMaybe (`lookupSnap` snaps) (glpUniquePVs plan)
              policy = cargoFloorPolicyKey prefix mPkgSub mLockSub
          pure (Right (withCargoTagFloors selected policy plan))
    _ -> pure (Left (PlanFailed "DepsAndAssets Cargo requires a GitHub update source"))

memoFetchCargo ::
  MVar (Map.Map (Text, Maybe FilePath) CargoTomlFetch) ->
  DepsPlanOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO CargoTomlFetch
memoFetchCargo memoVar ops owner repo prefix pvText mSub = do
  let tag = versionTag prefix pvText
      key = (tag, mSub)
  modifyMVar memoVar $ \m ->
    case Map.lookup key m of
      Just v -> pure (m, v)
      Nothing -> do
        v <- dpoFetchCargoToml ops owner repo prefix pvText mSub
        pure (Map.insert key v m, v)

memoFetchToolchain ::
  MVar (Map.Map (Text, Maybe FilePath) CargoTomlFetch) ->
  DepsPlanOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO CargoTomlFetch
memoFetchToolchain memoVar ops owner repo prefix pvText mSub = do
  let tag = versionTag prefix pvText
      key = (tag <> "#rust-toolchain", mSub)
  modifyMVar memoVar $ \m ->
    case Map.lookup key m of
      Just v -> pure (m, v)
      Nothing -> do
        v <- dpoFetchRustToolchain ops owner repo prefix pvText mSub
        pure (Map.insert key v m, v)

lookupSnap :: EbuildVersion -> [CargoTagFloorSnapshot] -> Maybe CargoTagFloorSnapshot
lookupSnap pv snaps =
  case [s | s <- snaps, samePV (ctfsPV s) pv || ctfsPV s == pv] of
    (s : _) -> Just s
    [] -> Nothing

------------------------------------------------------------------------
-- Sbcl
------------------------------------------------------------------------

planSbcl ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either PlanError RuntimeLanePlan)
planSbcl ops progress src locals allowlist =
  case src of
    GitHub owner repo prefix ->
      planWith
        ops
        progress
        src
        locals
        allowlist
        ( discoverCeilingsCached
            (dpoSbclCeilingsCache ops)
            (discoverSbclCeilingsWith (dpoPortageq ops))
        )
        ( \pv -> do
            eres <-
              dpoFetchSbclVersion
                ops
                owner
                repo
                prefix
                (renderPVNoRev pv)
            pure $ case eres of
              Left _ -> Right Nothing
              Right body -> Right (parseSbclVersionFloor body)
        )
    _ -> pure (Left (PlanFailed "DepsAndAssets Sbcl requires a GitHub update source"))

------------------------------------------------------------------------
-- Shared spine
------------------------------------------------------------------------

planWith ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  [Text] ->
  IO (Either Text RuntimeCeilings) ->
  (EbuildVersion -> IO (Either PlanError (Maybe Text))) ->
  IO (Either PlanError RuntimeLanePlan)
planWith ops progress src locals allowlist discoverCeilings fetchReq = do
  ppOnCeilingsStart progress
  ceilingsResult <- discoverCeilings
  case ceilingsResult of
    Left err -> pure (Left (PlanCeilingFailed err))
    Right ceilings -> do
      ppOnCeilingsDone progress
      ppOnListStart progress
      versResult <-
        withWorkSlot (dpoWorkBudget ops) $
          dpoListVersions ops src
      case versResult of
        Left err -> pure (Left (PlanListVersionsFailed err))
        Right versions -> do
          ppOnListDone progress (length versions)
          case filterCandidateVersions locals versions of
            Left err -> pure (Left err)
            Right candidatePVs -> do
              let ordered = sortNewestFirst candidatePVs
                  restricted = restrictCeilings allowlist ceilings
              candResult <-
                buildCandidates
                  ops
                  progress
                  restricted
                  ordered
                  fetchReq
              case candResult of
                Left err -> pure (Left err)
                Right candidates -> do
                  let targets = selectAllLaneTargets restricted candidates
                      plan =
                        planFromTargetsWithAtomFor
                          allowlist
                          (rcAtom ceilings)
                          targets
                  if null (glpUniquePVs plan)
                    then pure (Left PlanZeroPlannedPVs)
                    else pure (Right plan)

discoverCeilingsCached ::
  MVar (Maybe RuntimeCeilings) ->
  IO (Either Text RuntimeCeilings) ->
  IO (Either Text RuntimeCeilings)
discoverCeilingsCached cacheVar discover = do
  cached <- readMVar cacheVar
  case cached of
    Just c -> pure (Right c)
    Nothing -> do
      result <- discover
      case result of
        Left err -> pure (Left err)
        Right c -> do
          modifyMVar_ cacheVar $ \m ->
            pure $ case m of
              Just existing -> Just existing
              Nothing -> Just c
          final <- readMVar cacheVar
          pure $ case final of
            Just c' -> Right c'
            Nothing -> Right c

buildCandidates ::
  DepsPlanOps ->
  PlanProgress ->
  RuntimeCeilings ->
  [EbuildVersion] ->
  (EbuildVersion -> IO (Either PlanError (Maybe Text))) ->
  IO (Either PlanError [VersionCandidate])
buildCandidates ops progress ceilings versions fetchReq = do
  result <- walk [] versions
  ppOnProbeDone progress
  pure result
  where
    walk acc [] = pure (Right (reverse acc))
    walk acc (pv : rest)
      | allCeilingedLanesFilled ceilings acc = pure (Right (reverse acc))
      | otherwise = do
          oneResult <- withWorkSlot (dpoWorkBudget ops) (fetchReq pv)
          case oneResult of
            Left err -> pure (Left err)
            Right mReq ->
              walk
                ( VersionCandidate
                    { vcPV = stripRev pv,
                      vcGoReq = mReq
                    }
                    : acc
                )
                rest

allCeilingedLanesFilled :: RuntimeCeilings -> [VersionCandidate] -> Bool
allCeilingedLanesFilled ceilings candidates =
  all laneOk (selectAllLaneTargets ceilings candidates)
  where
    laneOk t = case ltCeiling t of
      Nothing -> True
      Just _ -> isJust (ltPackagePV t)

sortNewestFirst :: [EbuildVersion] -> [EbuildVersion]
sortNewestFirst =
  sortBy
    ( \a b ->
        case comparePV a b of
          Just LT -> GT
          Just GT -> LT
          Just EQ -> EQ
          Nothing -> compare (show b) (show a)
    )

stripRev :: EbuildVersion -> EbuildVersion
stripRev (Numeric comps _) = Numeric comps Nothing
stripRev r = r

fetchBunEnginesAtTag ::
  Manager ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  IO (Either Text BunProbe)
fetchBunEnginesAtTag mgr mToken owner repo prefix pv = do
  let tag = versionTag prefix pv
      url =
        "https://raw.githubusercontent.com/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/"
          <> T.unpack tag
          <> "/package.json"
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/json")
              ]
                <> case mToken of
                  Just t -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]
                  Nothing -> []
          }
  eres <-
    (Right <$> httpLbs req mgr)
      `catch` \(e :: SomeException) -> pure (Left (T.pack (show e)))
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then
              let txt = TE.decodeUtf8 (BL.toStrict (responseBody resp))
               in case parseBunProbeFromPackageJson txt of
                    Just p -> Right p
                    Nothing ->
                      Left
                        ( "missing or unparseable engines.bun / packageManager bun@ for "
                            <> owner
                            <> "/"
                            <> repo
                            <> "@"
                            <> tag
                        )
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

fetchCargoTomlAtTag ::
  Manager ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO CargoTomlFetch
fetchCargoTomlAtTag mgr mToken owner repo prefix pv mSub = do
  let tag = versionTag prefix pv
      subPath = case mSub of
        Nothing -> "Cargo.toml"
        Just sub -> sub </> "Cargo.toml"
      url =
        "https://raw.githubusercontent.com/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/"
          <> T.unpack tag
          <> "/"
          <> subPath
  fetchCargoTomlUrl mgr mToken url

fetchRustToolchainAtTag ::
  Manager ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO CargoTomlFetch
fetchRustToolchainAtTag mgr mToken owner repo prefix pv mSub = do
  let tag = versionTag prefix pv
      subPath = case mSub of
        Nothing -> "rust-toolchain.toml"
        Just sub -> sub </> "rust-toolchain.toml"
      url =
        "https://raw.githubusercontent.com/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/"
          <> T.unpack tag
          <> "/"
          <> subPath
  fetchCargoTomlUrl mgr mToken url

fetchCargoTomlUrl :: Manager -> Maybe Text -> String -> IO CargoTomlFetch
fetchCargoTomlUrl mgr mToken url = do
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "text/plain")
              ]
                <> case mToken of
                  Just t -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]
                  Nothing -> []
          }
  eres <-
    (Right <$> httpLbs req mgr)
      `catch` \(e :: SomeException) -> pure (Left (T.pack (show e)))
  pure $ case eres of
    Left err -> CargoTomlError err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then CargoTomlBody (TE.decodeUtf8 (BL.toStrict (responseBody resp)))
            else
              if code == 404
                then CargoTomlMissing
                else CargoTomlError ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

fetchSbclVersionAtTag ::
  Manager ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  IO (Either Text Text)
fetchSbclVersionAtTag mgr mToken owner repo prefix pv = do
  let tag = versionTag prefix pv
      url =
        "https://raw.githubusercontent.com/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/"
          <> T.unpack tag
          <> "/sbcl.version"
  fetchRawGithubFile mgr mToken url

fetchRawGithubFile ::
  Manager ->
  Maybe Text ->
  String ->
  IO (Either Text Text)
fetchRawGithubFile mgr mToken url = do
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "text/plain")
              ]
                <> case mToken of
                  Just t -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]
                  Nothing -> []
          }
  eres <-
    (Right <$> httpLbs req mgr)
      `catch` \(e :: SomeException) -> pure (Left (T.pack (show e)))
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then Right (TE.decodeUtf8 (BL.toStrict (responseBody resp)))
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)
