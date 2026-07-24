{-# LANGUAGE OverloadedStrings #-}

module Update.Deps.Plan
  ( DepsPlanOps (..),
    productionDepsPlanOps,
    planDepsPackageWithProgress,
    toGoPlanOps,
  )
where

import CLI.Jobs (WorkBudget, newWorkBudget, withWorkSlot)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, catch)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortBy)
import Data.Maybe (isJust)
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
import Overlay.Version (EbuildVersion (..), comparePV, renderPVNoRev)
import System.FilePath ((</>))
import Update.Bun.Cache (parseEnginesBunFromPackageJson)
import Update.Cargo.Msrv (parseRustVersionField)
import Update.GitHub (listGitHubVersionsWith)
import Update.Go.Lanes
  ( LaneTarget (..),
    RuntimeLanePlan (..),
    VersionCandidate (..),
    filterCandidateVersions,
    planFromTargetsWithAtom,
    selectAllLaneTargets,
    zeroPlannedPVsError,
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
    productionPortageqRunner,
  )
import Update.Types (EcosystemSpec (..), UpdateSource (..))

-- | Injectable ops for multi-ecosystem deps planning.
data DepsPlanOps = DepsPlanOps
  { dpoPortageq :: PortageqRunner,
    dpoListVersions :: UpdateSource -> IO (Either Text [EbuildVersion]),
    dpoFetchGoMod :: GoModFetcher,
    dpoFetchNpmEngines :: Text -> Text -> IO (Either Text Text),
    dpoFetchBunEngines :: Text -> Text -> Text -> Text -> IO (Either Text Text),
    -- | Fetch package Cargo.toml body at tag for rust-version probe.
    dpoFetchCargoToml :: Text -> Text -> Text -> Text -> Maybe FilePath -> IO (Either Text Text),
    dpoWorkBudget :: WorkBudget,
    dpoGoCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoNodeCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoBunCeilingsCache :: MVar (Maybe RuntimeCeilings),
    dpoRustCeilingsCache :: MVar (Maybe RuntimeCeilings),
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
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoOverlayRoot = mOverlay,
        dpoManager = mgr
      }

planDepsPackageWithProgress ::
  DepsPlanOps ->
  PlanProgress ->
  EcosystemSpec ->
  UpdateSource ->
  [EbuildVersion] ->
  IO (Either Text RuntimeLanePlan)
planDepsPackageWithProgress ops progress eco src locals =
  case eco of
    Go mSub -> planGo ops progress src mSub locals
    NpmEco -> planNpm ops progress src locals
    Bun -> planBun ops progress src locals
    Cargo mLock mPkg -> planCargo ops progress src mLock mPkg locals

------------------------------------------------------------------------
-- Go
------------------------------------------------------------------------

planGo ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  Maybe FilePath ->
  [EbuildVersion] ->
  IO (Either Text RuntimeLanePlan)
planGo ops progress src mSub locals =
  case src of
    GitHub owner repo prefix ->
      planWith
        ops
        progress
        src
        locals
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
    _ -> pure (Left "DepsAndAssets Go requires a GitHub update source")

------------------------------------------------------------------------
-- Npm
------------------------------------------------------------------------

planNpm ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  IO (Either Text RuntimeLanePlan)
planNpm ops progress src locals =
  case src of
    Npm npmPkg ->
      planWith
        ops
        progress
        src
        locals
        ( discoverCeilingsCached
            (dpoNodeCeilingsCache ops)
            (discoverNodejsCeilingsWith (dpoPortageq ops))
        )
        ( \pv -> do
            eres <- dpoFetchNpmEngines ops npmPkg (renderPVNoRev pv)
            pure $ case eres of
              Left err -> Left err
              Right ver -> Right (Just ver)
        )
    _ -> pure (Left "DepsAndAssets Npm requires an Npm update source")

------------------------------------------------------------------------
-- Bun
------------------------------------------------------------------------

planBun ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  IO (Either Text RuntimeLanePlan)
planBun ops progress src locals =
  case src of
    GitHub owner repo prefix ->
      case dpoOverlayRoot ops of
        Nothing ->
          pure (Left "overlay path required for bun-bin runtime ceilings")
        Just overlayRoot ->
          planWith
            ops
            progress
            src
            locals
            ( discoverCeilingsCached
                (dpoBunCeilingsCache ops)
                (discoverBunBinCeilings overlayRoot)
            )
            ( \pv -> do
                eres <-
                  dpoFetchBunEngines
                    ops
                    owner
                    repo
                    prefix
                    (renderPVNoRev pv)
                pure $ case eres of
                  Left err -> Left err
                  Right ver -> Right (Just ver)
            )
    _ -> pure (Left "DepsAndAssets Bun requires a GitHub update source")

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
  IO (Either Text RuntimeLanePlan)
planCargo ops progress src mLockSub mPkgSub locals =
  case src of
    GitHub owner repo prefix ->
      planWith
        ops
        progress
        src
        locals
        ( discoverCeilingsCached
            (dpoRustCeilingsCache ops)
            (discoverRustUnionCeilingsWith (dpoPortageq ops))
        )
        ( \pv -> do
            let pvText = renderPVNoRev pv
            -- Prefer package subdir Cargo.toml; fall back to lock-root / repo root.
            let tryPaths =
                  nubMaybe
                    [ mPkgSub,
                      mLockSub,
                      Nothing
                    ]
            probeRustVersion ops owner repo prefix pvText tryPaths
        )
    _ -> pure (Left "DepsAndAssets Cargo requires a GitHub update source")

-- | Probe rust-version from the first readable Cargo.toml among subdirs.
probeRustVersion ::
  DepsPlanOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  [Maybe FilePath] ->
  IO (Either Text (Maybe Text))
probeRustVersion ops owner repo prefix pv = go
  where
    go [] =
      -- No declared rust-version: still eligible under any ceiling; apply path
      -- recomputes max-deps + donor and hard-fails if still unknown.
      pure (Right (Just "0.0.0"))
    go (mSub : rest) = do
      eres <- dpoFetchCargoToml ops owner repo prefix pv mSub
      case eres of
        Left _ -> go rest
        Right body ->
          case parseRustVersionField body of
            Just ver -> pure (Right (Just ver))
            Nothing -> go rest

nubMaybe :: (Eq a) => [Maybe a] -> [Maybe a]
nubMaybe = go []
  where
    go acc [] = reverse acc
    go acc (x : xs)
      | x `elem` acc = go acc xs
      | otherwise = go (x : acc) xs

------------------------------------------------------------------------
-- Shared spine
------------------------------------------------------------------------

planWith ::
  DepsPlanOps ->
  PlanProgress ->
  UpdateSource ->
  [EbuildVersion] ->
  IO (Either Text RuntimeCeilings) ->
  (EbuildVersion -> IO (Either Text (Maybe Text))) ->
  IO (Either Text RuntimeLanePlan)
planWith ops progress src locals discoverCeilings fetchReq = do
  ppOnCeilingsStart progress
  ceilingsResult <- discoverCeilings
  case ceilingsResult of
    Left err -> pure (Left err)
    Right ceilings -> do
      ppOnCeilingsDone progress
      ppOnListStart progress
      versResult <-
        withWorkSlot (dpoWorkBudget ops) $
          dpoListVersions ops src
      case versResult of
        Left err -> pure (Left ("list versions failed: " <> err))
        Right versions -> do
          ppOnListDone progress (length versions)
          case filterCandidateVersions locals versions of
            Left err -> pure (Left err)
            Right candidatePVs -> do
              let ordered = sortNewestFirst candidatePVs
              candResult <-
                buildCandidates
                  ops
                  progress
                  ceilings
                  ordered
                  fetchReq
              case candResult of
                Left err -> pure (Left err)
                Right candidates -> do
                  let targets = selectAllLaneTargets ceilings candidates
                      plan =
                        planFromTargetsWithAtom
                          (rcAtom ceilings)
                          targets
                  if null (glpUniquePVs plan)
                    then pure (Left zeroPlannedPVsError)
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
  (EbuildVersion -> IO (Either Text (Maybe Text))) ->
  IO (Either Text [VersionCandidate])
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
  IO (Either Text Text)
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
               in case parseEnginesBunFromPackageJson txt of
                    Just v -> Right v
                    Nothing ->
                      Left
                        ( "missing or unparseable engines.bun for "
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
  IO (Either Text Text)
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
