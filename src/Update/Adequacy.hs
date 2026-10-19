-- | Shared content assessment over a planned requirement snapshot and one
-- canonical local ebuild. Performs no upstream fetch.
module Update.Adequacy
  ( ContentAssessment (..),
    PresentPvOutcome (..),
    PlannedPvFacts (..),
    assessPlannedFacts,
    assessPresentFacts,
    requiredAssetBasenames,
    cargoDecisionFloor,
    cargoReuseWriteFloor,
    lookupDirectTagFloor,
    plannedRuntimeReq,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, renderPVNoRev, samePV)
import Update.Assets.Layout
  ( distfileKindForEcosystem,
    distfileTarballName,
  )
import Update.Cargo.Msrv
  ( maxMaybeRustVersions,
    parseRustMinVerFromEbuild,
    rustMinVerTooLow,
  )
import Update.EbuildEdit
  ( AssetsHost (..),
    assetsOwnedTagCollisionFor,
    assetsSrcUriParameterizedFor,
    bunBdependAtomFor,
    ebuildNeedsCargoBodyFixFor,
    ebuildNeedsContentFixAtomFor,
    ebuildNeedsContentFixFor,
    keywordsMatch,
    nodejsBdependAtom,
    pythonCompatToken,
    sbclBdependAtom,
  )
import Update.Go.Lanes
  ( CargoTagFloorSnapshot (..),
    LaneTarget (..),
    RuntimeLanePlan (..),
  )
import Update.Manifest.Dist (manifestHasExactDist)
import Update.Types (EcosystemSpec (..), PackageKey (..))

-- | Shared assessment sets consumed by outdated, update planning, and apply.
data ContentAssessment = ContentAssessment
  { caNeedsWorkPVs :: [EbuildVersion],
    caForceFullPVs :: [EbuildVersion]
  }
  deriving (Eq, Show)

-- | Outcome for one present or missing planned PV.
data PresentPvOutcome
  = Adequate
  | NeedsRewrite
  | NeedsFull
  deriving (Eq, Show)

-- | Pure facts for one planned PV. Missing PV has 'ppfPresentContent' = Nothing.
data PlannedPvFacts = PlannedPvFacts
  { ppfPV :: EbuildVersion,
    ppfKeywords :: [Text],
    -- | Canonical same-PV ebuild body when the PV is present.
    ppfPresentContent :: Maybe Text,
    ppfManifest :: Maybe Text,
    -- | Planned direct tag floor (Cargo). 'Nothing' is explicit absence.
    ppfTagFloor :: Maybe Text,
    -- | Lane runtime requirement from the plan (go/npm/bun/sbcl).
    ppfRuntimeReq :: Maybe Text,
    -- | RUST_MIN_VER of the canonical selected template (same-PV or fallback).
    ppfTemplateFloor :: Maybe Text,
    -- | Assets GitHub host used for SRC_URI ownership (origin-derived).
    ppfAssetsHost :: AssetsHost,
    -- | Raw git tag for a Uv PV. 'Nothing' for every other ecosystem.
    ppfUvTag :: Maybe Text
  }
  deriving (Eq, Show)

-- | Required release/Manifest basenames (primary + companions).
-- Opencode is deps-only: models.json is not a required companion.
requiredAssetBasenames :: PackageKey -> EcosystemSpec -> Text -> Text -> [FilePath]
requiredAssetBasenames _key eco pn pvNoRev =
  [distfileTarballName (distfileKindForEcosystem eco) pn pvNoRev]

lookupDirectTagFloor :: RuntimeLanePlan -> EbuildVersion -> Maybe (Maybe Text)
lookupDirectTagFloor plan pv =
  case [ctfsFloor s | s <- glpDirectTagFloors plan, samePV (ctfsPV s) pv] of
    (f : _) -> Just f
    [] -> Nothing

plannedRuntimeReq :: RuntimeLanePlan -> EbuildVersion -> Maybe Text
plannedRuntimeReq plan pv =
  case [ltGoReq lt | lt <- glpLanes plan, ltPackagePV lt == Just pv] of
    (r : _) -> r
    [] -> Nothing

-- | Decision floor: numeric max of planned tag floor and canonical same-PV
-- written floor.
cargoDecisionFloor :: Maybe Text -> Maybe Text -> Maybe Text
cargoDecisionFloor tag donor = maxMaybeRustVersions [tag, donor]

-- | Reuse-write floor: numeric max of planned tag floor and selected template.
cargoReuseWriteFloor :: Maybe Text -> Maybe Text -> Maybe Text
cargoReuseWriteFloor = cargoDecisionFloor

assessPlannedFacts ::
  PackageKey ->
  EcosystemSpec ->
  Text ->
  [PlannedPvFacts] ->
  Either Text ContentAssessment
assessPlannedFacts key eco pn facts =
  case traverse (assessPresentFacts key eco pn) facts of
    Left err -> Left err
    Right outcomes ->
      Right
        ContentAssessment
          { caNeedsWorkPVs =
              [ppfPV f | (f, o) <- zip facts outcomes, o /= Adequate],
            caForceFullPVs =
              [ppfPV f | (f, o) <- zip facts outcomes, o == NeedsFull]
          }

assessPresentFacts ::
  PackageKey ->
  EcosystemSpec ->
  Text ->
  PlannedPvFacts ->
  Either Text PresentPvOutcome
assessPresentFacts key eco pn facts =
  case ppfPresentContent facts of
    Nothing -> Right (assessMissing eco facts)
    Just content ->
      case assetsOwnedTagCollisionFor (ppfAssetsHost facts) pn content of
        Just err -> Left err
        Nothing -> Right (assessPresent key eco pn facts content)

assessMissing :: EcosystemSpec -> PlannedPvFacts -> PresentPvOutcome
assessMissing eco facts =
  case eco of
    Cargo {} ->
      case cargoReuseWriteFloor (ppfTagFloor facts) (ppfTemplateFloor facts) of
        Nothing -> NeedsFull
        Just _ -> NeedsRewrite
    Go _ -> NeedsRewrite
    NpmEco -> NeedsRewrite
    Bun -> NeedsRewrite
    Sbcl -> NeedsRewrite
    Uv _ -> NeedsRewrite

assessPresent ::
  PackageKey ->
  EcosystemSpec ->
  Text ->
  PlannedPvFacts ->
  Text ->
  PresentPvOutcome
assessPresent key eco pn facts content =
  let manBad = manifestNeedsWork key eco pn facts
      bodyBad = ebuildBodyNeedsWork key eco pn facts content
      plain = if manBad || bodyBad then NeedsRewrite else Adequate
   in case eco of
        Cargo {} ->
          case cargoFloorOutcome (ppfTagFloor facts) content of
            NeedsFull -> NeedsFull
            NeedsRewrite -> NeedsRewrite
            Adequate
              | manBad || bodyBad -> NeedsRewrite
              | otherwise -> Adequate
        Go _ -> plain
        NpmEco -> plain
        Bun -> plain
        Sbcl -> plain
        Uv _ -> plain

cargoFloorOutcome :: Maybe Text -> Text -> PresentPvOutcome
cargoFloorOutcome mTag content =
  let mWritten = parseRustMinVerFromEbuild content
   in case (mTag, mWritten) of
        (Nothing, Nothing) -> NeedsFull
        (_, Nothing) -> NeedsRewrite
        (Nothing, Just _) -> Adequate
        (Just tag, Just written) ->
          if rustMinVerTooLow written tag then NeedsRewrite else Adequate

ebuildBodyNeedsWork :: PackageKey -> EcosystemSpec -> Text -> PlannedPvFacts -> Text -> Bool
ebuildBodyNeedsWork key eco pn facts content =
  let kws = ppfKeywords facts
      host = ppfAssetsHost facts
   in case eco of
        Go _ ->
          ebuildNeedsContentFixFor host pn kws content (ppfRuntimeReq facts)
        NpmEco ->
          ebuildNeedsContentFixAtomFor host pn kws content (nodejsBdependAtom <$> ppfRuntimeReq facts)
        Bun ->
          ebuildNeedsContentFixAtomFor host pn kws content (bunBdependAtomFor key <$> ppfRuntimeReq facts)
        Sbcl ->
          ebuildNeedsContentFixAtomFor host pn kws content (sbclBdependAtom <$> ppfRuntimeReq facts)
        Uv _ ->
          ebuildNeedsUvBody host pn kws content (ppfRuntimeReq facts) (ppfUvTag facts)
        Cargo {} ->
          ebuildNeedsCargoBodyFixFor host (cargoSource eco) pn kws content

ebuildNeedsUvBody ::
  AssetsHost ->
  Text ->
  [Text] ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Bool
ebuildNeedsUvBody host pn keywords content mSlot mTag =
  not (assetsSrcUriParameterizedFor host pn content)
    || not (keywordsMatch keywords content)
    || slotBad
    || tagBad
  where
    slotBad = case mSlot of
      Nothing -> True
      Just slot ->
        not ((T.pack "dev-lang/python:" <> slot) `T.isInfixOf` content)
          || case pythonCompatToken slot of
            Nothing -> True
            Just token -> not (token `T.isInfixOf` content)
    tagBad = case mTag of
      Nothing -> True
      Just tag ->
        not ((T.pack "archive/refs/tags/" <> tag <> T.pack ".tar.gz") `T.isInfixOf` content)

manifestNeedsWork :: PackageKey -> EcosystemSpec -> Text -> PlannedPvFacts -> Bool
manifestNeedsWork key eco pn facts =
  let pvNoRev = renderPVNoRev (ppfPV facts)
      required = requiredAssetBasenames key eco pn pvNoRev
   in case ppfManifest facts of
        Nothing -> True
        Just man -> not (all (manifestHasExactDist man) required)
