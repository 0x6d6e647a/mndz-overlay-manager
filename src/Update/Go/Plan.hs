{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Plan
  ( PlanOps (..),
    productionPlanOps,
    buildVersionCandidates,
    planGoPackage,
    localNonLivePVs,
    isLivePackageVersion,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), parseEbuildVersion)
import Update.GitHub (listGitHubVersionsWith)
import Update.Go.Lanes
  ( GoLanePlan,
    VersionCandidate (..),
    planFromTargets,
    selectAllLaneTargets,
  )
import Update.Go.ModFetch
  ( GoModFetcher,
    GoModKey (..),
    parseGoReqFromMod,
    productionGoModFetcher,
    withGoModCache,
  )
import Update.Go.Tree
  ( PortageqRunner,
    discoverGoCeilingsWith,
    productionPortageqRunner,
  )
import Update.Go.Vendor (versionTag)
import Update.Types (UpdateSource (..))

-- | Injectable dependencies for Go tree-lane planning.
data PlanOps = PlanOps
  { poPortageq :: PortageqRunner,
    poListVersions :: UpdateSource -> IO (Either Text [EbuildVersion]),
    poFetchGoMod :: GoModFetcher
  }

productionPlanOps :: Maybe Text -> IO PlanOps
productionPlanOps mToken = do
  mgr <- newManager tlsManagerSettings
  baseMod <- productionGoModFetcher mToken
  cachedMod <- withGoModCache baseMod
  pure
    PlanOps
      { poPortageq = productionPortageqRunner,
        poListVersions = listGitHubVersionsWith mgr mToken,
        poFetchGoMod = cachedMod
      }

isLivePackageVersion :: EbuildVersion -> Bool
isLivePackageVersion (Numeric [9999] _) = True
isLivePackageVersion (Raw t) = T.strip t == "9999"
isLivePackageVersion _ = False

-- | Non-live numeric (or raw non-9999) PVs from package ebuilds.
localNonLivePVs :: [Ebuild] -> [EbuildVersion]
localNonLivePVs es =
  [ parseEbuildVersion (ebuildVersion e)
  | e <- es,
    let v = parseEbuildVersion (ebuildVersion e),
    not (isLivePackageVersion v)
  ]

-- | Resolve go_req for each listed version (skips unparseable).
buildVersionCandidates ::
  PlanOps ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [EbuildVersion] ->
  IO [VersionCandidate]
buildVersionCandidates ops owner repo prefix mSub =
  mapM one
  where
    one pv = do
      let tag = versionTag prefix (renderPVNoRev pv)
          key =
            GoModKey
              { gmkOwner = owner,
                gmkRepo = repo,
                gmkTag = tag,
                gmkSubdir = mSub
              }
      body <- poFetchGoMod ops key
      pure $
        VersionCandidate
          { vcPV = stripRev pv,
            vcGoReq = case body of
              Left _ -> Nothing
              Right txt -> parseGoReqFromMod txt
          }
    stripRev (Numeric comps _) = Numeric comps Nothing
    stripRev r = r
    renderPVNoRev (Numeric comps _) =
      T.intercalate "." (map (T.pack . show) comps)
    renderPVNoRev (Raw t) = t

-- | Full plan: ceilings → version list → go_req probe → lane targets.
planGoPackage ::
  PlanOps ->
  UpdateSource ->
  Maybe FilePath ->
  IO (Either Text GoLanePlan)
planGoPackage ops src mSub =
  case src of
    GitHub owner repo prefix -> do
      ceilingsResult <- discoverGoCeilingsWith (poPortageq ops)
      case ceilingsResult of
        Left err -> pure (Left err)
        Right ceilings -> do
          versResult <- poListVersions ops src
          case versResult of
            Left err -> pure (Left ("list versions failed: " <> err))
            Right versions -> do
              candidates <-
                buildVersionCandidates ops owner repo prefix mSub versions
              let targets = selectAllLaneTargets ceilings candidates
              pure (Right (planFromTargets targets))
    _ -> pure (Left "Go tree-lane planning requires a GitHub update source")
