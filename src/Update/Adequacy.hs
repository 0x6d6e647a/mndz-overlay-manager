{-# LANGUAGE OverloadedStrings #-}

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
import Overlay.Version (EbuildVersion, renderPVNoRev, samePV)
import Update.Assets.Layout
  ( distfileKindForEcosystem,
    distfileTarballName,
    modelsDistfileName,
  )
import Update.Cargo.Msrv
  ( maxMaybeRustVersions,
    parseRustMinVerFromEbuild,
    rustMinVerTooLow,
  )
import Update.EbuildEdit
  ( bunBdependAtomFor,
    ebuildNeedsCargoBodyFix,
    ebuildNeedsContentFix,
    ebuildNeedsContentFixAtom,
    nodejsBdependAtom,
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
    ppfTemplateFloor :: Maybe Text
  }
  deriving (Eq, Show)

-- | Required release/Manifest basenames (primary + companions).
requiredAssetBasenames :: PackageKey -> EcosystemSpec -> Text -> Text -> [FilePath]
requiredAssetBasenames key eco pn pvNoRev =
  let primary = distfileTarballName (distfileKindForEcosystem eco) pn pvNoRev
      extras =
        case key of
          PackageKey "dev-util/opencode" -> [modelsDistfileName pn pvNoRev]
          _ -> []
   in primary : extras

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
  ContentAssessment
assessPlannedFacts key eco pn facts =
  ContentAssessment
    { caNeedsWorkPVs = [ppfPV f | f <- facts, outcome f /= Adequate],
      caForceFullPVs = [ppfPV f | f <- facts, outcome f == NeedsFull]
    }
  where
    outcome = assessPresentFacts key eco pn

assessPresentFacts ::
  PackageKey ->
  EcosystemSpec ->
  Text ->
  PlannedPvFacts ->
  PresentPvOutcome
assessPresentFacts key eco pn facts =
  case ppfPresentContent facts of
    Nothing -> assessMissing eco facts
    Just content -> assessPresent key eco pn facts content

assessMissing :: EcosystemSpec -> PlannedPvFacts -> PresentPvOutcome
assessMissing eco facts =
  case eco of
    Cargo {} ->
      case cargoReuseWriteFloor (ppfTagFloor facts) (ppfTemplateFloor facts) of
        Nothing -> NeedsFull
        Just _ -> NeedsRewrite
    _ -> NeedsRewrite

assessPresent ::
  PackageKey ->
  EcosystemSpec ->
  Text ->
  PlannedPvFacts ->
  Text ->
  PresentPvOutcome
assessPresent key eco pn facts content =
  let manBad = manifestNeedsWork key eco pn facts
      bodyBad = ebuildBodyNeedsWork key eco facts content
   in case eco of
        Cargo {} ->
          case cargoFloorOutcome (ppfTagFloor facts) content of
            NeedsFull -> NeedsFull
            NeedsRewrite -> NeedsRewrite
            Adequate
              | manBad || bodyBad -> NeedsRewrite
              | otherwise -> Adequate
        _ ->
          if manBad || bodyBad then NeedsRewrite else Adequate

cargoFloorOutcome :: Maybe Text -> Text -> PresentPvOutcome
cargoFloorOutcome mTag content =
  let mWritten = parseRustMinVerFromEbuild content
   in case (mTag, mWritten) of
        (Nothing, Nothing) -> NeedsFull
        (_, Nothing) -> NeedsRewrite
        (Nothing, Just _) -> Adequate
        (Just tag, Just written) ->
          if rustMinVerTooLow written tag then NeedsRewrite else Adequate

ebuildBodyNeedsWork :: PackageKey -> EcosystemSpec -> PlannedPvFacts -> Text -> Bool
ebuildBodyNeedsWork key eco facts content =
  let kws = ppfKeywords facts
   in case eco of
        Go _ ->
          ebuildNeedsContentFix kws content (ppfRuntimeReq facts)
        NpmEco ->
          ebuildNeedsContentFixAtom kws content (nodejsBdependAtom <$> ppfRuntimeReq facts)
        Bun ->
          ebuildNeedsContentFixAtom kws content (bunBdependAtomFor key <$> ppfRuntimeReq facts)
        Sbcl ->
          ebuildNeedsContentFixAtom kws content (sbclBdependAtom <$> ppfRuntimeReq facts)
        Cargo {} ->
          ebuildNeedsCargoBodyFix (cargoSource eco) kws content

manifestNeedsWork :: PackageKey -> EcosystemSpec -> Text -> PlannedPvFacts -> Bool
manifestNeedsWork key eco pn facts =
  let pvNoRev = renderPVNoRev (ppfPV facts)
      required = requiredAssetBasenames key eco pn pvNoRev
   in case ppfManifest facts of
        Nothing -> True
        Just man -> not (all (manifestHasExactDist man) required)
