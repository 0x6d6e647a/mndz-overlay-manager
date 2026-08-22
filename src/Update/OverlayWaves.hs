{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Technique-implied overlay wait-edges and pure admit / plan-delta helpers.
--
-- Overlay ceiling providers are derived from 'UpdateTechnique' (Bun →
-- @dev-lang/bun-bin@). This module does not parse ebuild DEPEND/RDEPEND/BDEPEND
-- and does not keep a per-package edge map.
module Update.OverlayWaves
  ( bunBinPackageKey,
    overlayCeilingProvider,
    overlayCeilingProviderForKey,
    OverlayPlanKind (..),
    AdmitSets (..),
    classifyAdmit,
    replaceNewestNonLivePv,
    hypotheticalCeilings,
    planDeltaHolds,
    overlayRefuseMessage,
    overlayFailClosedMessage,
    overlayProviderCascadeMessage,
    computeOverlayProviderFingerprint,
    fetchOverlayProviderLatest,
    blockedOnLabel,
  )
where

import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, comparePV)
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import Update.CheckCache
  ( CacheFingerprint,
    CheckCacheHandle,
    computeFingerprintFromDir,
    lookupLatest,
    recordFetch,
    recordHit,
    storeLatest,
  )
import Update.Hardcoded (lookupPolicy)
import Update.Runtime.Ceilings
  ( RuntimeCeilings,
    RuntimeEbuildMeta (..),
    bunBinRuntimeAtom,
    computeCeilings,
  )
import Update.Types
  ( EcosystemSpec (..),
    Fetcher,
    PackageKey (..),
    PackagePolicy (..),
    UpdateTechnique (..),
    packageKeyText,
    splitPackageKey,
  )

-- | Overlay package that supplies Bun runtime-lane ceilings.
bunBinPackageKey :: PackageKey
bunBinPackageKey = PackageKey "dev-lang/bun-bin"

-- | Overlay wait-edge provider for a technique, if any.
overlayCeilingProvider :: UpdateTechnique -> Maybe PackageKey
overlayCeilingProvider (DepsAndAssets Bun) = Just bunBinPackageKey
overlayCeilingProvider _ = Nothing

-- | Provider for a configured package key (hardcoded policy technique).
overlayCeilingProviderForKey :: PackageKey -> Maybe PackageKey
overlayCeilingProviderForKey key =
  overlayCeilingProvider . policyTechnique =<< lookupPolicy key

-- | Coarse plan kind for admit classification (avoids importing plan types).
data OverlayPlanKind
  = OverlayPlanSkip
  | OverlayPlanFail
  | OverlayPlanWork
  deriving (Eq, Show)

-- | Admit-when-ready partition of a selection.
--
-- 'asReady' is the only set that may occupy a package job slot. Withheld
-- consumers wait outside the limiter.
data AdmitSets = AdmitSets
  { asReady :: [PackageKey],
    -- | Consumer and the in-run provider it waits on.
    asWithheld :: [(PackageKey, PackageKey)],
    asTerminal :: [PackageKey]
  }
  deriving (Eq, Show)

-- | Partition plan results: withhold consumers of an in-run needs-work provider.
classifyAdmit ::
  (PackageKey -> Maybe PackageKey) ->
  [(PackageKey, OverlayPlanKind)] ->
  AdmitSets
classifyAdmit providerOf rows =
  let selection = Set.fromList (map fst rows)
      needing =
        Set.fromList
          [k | (k, OverlayPlanWork) <- rows]
      awaitedProviders =
        Set.fromList
          [ p
          | (k, _) <- rows,
            Just p <- [providerOf k],
            p `Set.member` selection,
            p `Set.member` needing
          ]
      decided = map (decide awaitedProviders) rows
   in AdmitSets
        { asReady = [k | (k, Ready) <- decided],
          asWithheld = [(k, p) | (k, Withheld p) <- decided],
          asTerminal = [k | (k, Terminal) <- decided]
        }
  where
    decide awaited (key, kind) =
      let unmet =
            case providerOf key of
              Just p
                | p `Set.member` awaited ->
                    Just p
              _ -> Nothing
       in case (unmet, kind) of
            -- Hard-fail is already terminal (refuse / plan error).
            (_, OverlayPlanFail) -> (key, Terminal)
            (Just p, _) -> (key, Withheld p)
            (Nothing, OverlayPlanWork) -> (key, Ready)
            (Nothing, _) -> (key, Terminal)

data Slot
  = Ready
  | Withheld PackageKey
  | Terminal

-- | Replace the newest non-live PV; KEYWORDS on that meta are unchanged.
replaceNewestNonLivePv :: [RuntimeEbuildMeta] -> EbuildVersion -> [RuntimeEbuildMeta]
replaceNewestNonLivePv metas remote =
  case pickNewest metas of
    Nothing -> metas
    Just newest ->
      map
        ( \m ->
            if remPV m == remPV newest
              then m {remPV = remote}
              else m
        )
        metas

pickNewest :: [RuntimeEbuildMeta] -> Maybe RuntimeEbuildMeta
pickNewest [] = Nothing
pickNewest (x : xs) = Just (foldl' newerMeta x xs)
  where
    newerMeta a b =
      case comparePV (remPV a) (remPV b) of
        Just LT -> b
        _ -> a

-- | Ceilings as if the newest overlay provider ebuild were at @remote@.
hypotheticalCeilings :: [RuntimeEbuildMeta] -> EbuildVersion -> RuntimeCeilings
hypotheticalCeilings metas remote =
  computeCeilings bunBinRuntimeAtom (replaceNewestNonLivePv metas remote)

-- | Sorted unique planned PVs (structural 'Eq').
uniquePvSet :: [EbuildVersion] -> [EbuildVersion]
uniquePvSet = sort

-- | Plan-delta: unique planned PVs or needs-work determination differs.
planDeltaHolds ::
  [EbuildVersion] ->
  Bool ->
  [EbuildVersion] ->
  Bool ->
  Bool
planDeltaHolds onDiskPvs onDiskNeed hypoPvs hypoNeed =
  uniquePvSet onDiskPvs /= uniquePvSet hypoPvs || onDiskNeed /= hypoNeed

overlayRefuseMessage :: PackageKey -> Text
overlayRefuseMessage provider =
  "overlay ceiling provider "
    <> packageKeyText provider
    <> " is not selected and would change this package's plan; "
    <> "run `update "
    <> packageKeyText provider
    <> "` or untargeted `update`"

overlayFailClosedMessage :: PackageKey -> Text
overlayFailClosedMessage provider =
  "could not check overlay ceiling provider "
    <> packageKeyText provider
    <> " upstream latest; refusing on-disk plan"

overlayProviderCascadeMessage :: PackageKey -> Text
overlayProviderCascadeMessage provider =
  "overlay ceiling provider "
    <> packageKeyText provider
    <> " hard-failed; not applying under a dirty overlay"

-- | Fingerprint of the overlay ceiling-provider tree, when the technique has one.
computeOverlayProviderFingerprint ::
  FilePath ->
  UpdateTechnique ->
  IO (Maybe CacheFingerprint)
computeOverlayProviderFingerprint overlayRoot tech =
  case overlayCeilingProvider tech of
    Nothing -> pure Nothing
    Just providerKey ->
      case (splitPackageKey providerKey, lookupPolicy providerKey) of
        (Just (cat, pn), Just policy) -> do
          let dir = overlayRoot </> T.unpack cat </> T.unpack pn
          exists <- doesDirectoryExist dir
          if not exists
            then pure Nothing
            else
              Just
                <$> computeFingerprintFromDir (policySource policy) dir pn
        _ -> pure Nothing

-- | Operator-facing blocked-on fragment for @outdated@ lines.
blockedOnLabel :: PackageKey -> Text
blockedOnLabel provider =
  "blocked on " <> packageKeyText provider

-- | GitMv latest for an overlay ceiling provider (check-cache latest allowed).
fetchOverlayProviderLatest ::
  Fetcher ->
  CheckCacheHandle ->
  FilePath ->
  PackageKey ->
  IO (Either Text EbuildVersion)
fetchOverlayProviderLatest fetch cache overlayRoot providerKey =
  case (splitPackageKey providerKey, lookupPolicy providerKey) of
    (Just (cat, pn), Just policy) -> do
      let dir = overlayRoot </> T.unpack cat </> T.unpack pn
      exists <- doesDirectoryExist dir
      if not exists
        then
          pure $
            Left
              ( "overlay ceiling provider "
                  <> packageKeyText providerKey
                  <> " directory not found"
              )
        else do
          fp <- computeFingerprintFromDir (policySource policy) dir pn
          mCached <- lookupLatest cache providerKey fp
          case mCached of
            Just remote -> do
              recordHit cache
              pure (Right remote)
            Nothing -> do
              recordFetch cache
              result <- fetch (policySource policy)
              case result of
                Left err -> pure (Left err)
                Right remote -> do
                  storeLatest cache providerKey fp remote
                  pure (Right remote)
    _ ->
      pure $
        Left
          ( "overlay ceiling provider "
              <> packageKeyText providerKey
              <> " has no configured update source"
          )
