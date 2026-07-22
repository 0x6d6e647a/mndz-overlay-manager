{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Lanes
  ( LaneId (..),
    allLaneIds,
    laneLabel,
    laneArch,
    laneTier,
    laneCeilingLane,
    LaneTarget (..),
    PlannedEbuild (..),
    GoLanePlan (..),
    GapLine (..),
    VersionCandidate (..),
    selectLaneTarget,
    selectAllLaneTargets,
    collapsePlannedEbuilds,
    assembleKeywords,
    planFromTargets,
    planNeedsWork,
    extrasToDelete,
    missingTargets,
    buildGapLines,
    goReqMeetsCeiling,
    maxVersionUnder,
  )
where

import Data.List (nub, sortBy)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import Update.Go.Tree
  ( GoArch (..),
    GoCeilingLane (..),
    GoCeilings (..),
    KeywordTier (..),
    ceilingFor,
  )
import Update.Go.Version (compareGoVersions)

-- | Logical lane id matching the four tree ceilings.
data LaneId
  = LaneAmd64Plain
  | LaneAmd64Tilde
  | LaneArm64Plain
  | LaneArm64Tilde
  deriving (Eq, Ord, Show, Enum, Bounded)

allLaneIds :: [LaneId]
allLaneIds = [minBound .. maxBound]

laneLabel :: LaneId -> Text
laneLabel = \case
  LaneAmd64Plain -> "(dev-lang/go amd64)"
  LaneAmd64Tilde -> "(dev-lang/go ~amd64)"
  LaneArm64Plain -> "(dev-lang/go arm64)"
  LaneArm64Tilde -> "(dev-lang/go ~arm64)"

laneArch :: LaneId -> GoArch
laneArch = \case
  LaneAmd64Plain -> Amd64
  LaneAmd64Tilde -> Amd64
  LaneArm64Plain -> Arm64
  LaneArm64Tilde -> Arm64

laneTier :: LaneId -> KeywordTier
laneTier = \case
  LaneAmd64Plain -> Plain
  LaneAmd64Tilde -> Tilde
  LaneArm64Plain -> Plain
  LaneArm64Tilde -> Tilde

laneCeilingLane :: LaneId -> GoCeilingLane
laneCeilingLane lid = GoCeilingLane (laneArch lid) (laneTier lid)

-- | Per-lane selection result.
data LaneTarget = LaneTarget
  { ltLane :: LaneId,
    ltCeiling :: Maybe EbuildVersion,
    ltPackagePV :: Maybe EbuildVersion,
    ltGoReq :: Maybe Text
  }
  deriving (Eq, Show)

-- | Unique ebuild PV with assembled KEYWORDS membership.
data PlannedEbuild = PlannedEbuild
  { pePV :: EbuildVersion,
    peKeywords :: [Text],
    peLanes :: [LaneId]
  }
  deriving (Eq, Show)

-- | Full plan for one GoVendorAndAssets package.
data GoLanePlan = GoLanePlan
  { glpLanes :: [LaneTarget],
    glpEbuilds :: [PlannedEbuild],
    glpUniquePVs :: [EbuildVersion]
  }
  deriving (Eq, Show)

-- | One outdated/success report line.
data GapLine = GapLine
  { glFrom :: EbuildVersion,
    glTo :: EbuildVersion,
    glLabel :: Text
  }
  deriving (Eq, Show)

-- | Upstream version with optional go_req (Nothing = unparseable / skip).
data VersionCandidate = VersionCandidate
  { vcPV :: EbuildVersion,
    vcGoReq :: Maybe Text
  }
  deriving (Eq, Show)

-- | Whether package go_req is ≤ Go ceiling (same rules as host gate).
goReqMeetsCeiling :: Text -> EbuildVersion -> Maybe Bool
goReqMeetsCeiling goReq ceilingPV =
  let ceilingTok = renderGoCeiling ceilingPV
   in case compareGoVersions goReq ceilingTok of
        Just GT -> Just False
        Just _ -> Just True
        Nothing -> Nothing

renderGoCeiling :: EbuildVersion -> Text
renderGoCeiling (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)
renderGoCeiling (Raw t) = t

-- | Max package PV among candidates with parseable go_req ≤ ceiling.
maxVersionUnder :: EbuildVersion -> [VersionCandidate] -> Maybe (EbuildVersion, Text)
maxVersionUnder goCeiling candidates =
  let eligible =
        [ (vcPV c, req)
        | c <- candidates,
          Just req <- [vcGoReq c],
          goReqMeetsCeiling req goCeiling == Just True
        ]
   in case eligible of
        [] -> Nothing
        (x : xs) -> Just (foldl' maxPair x xs)
  where
    maxPair (pa, ra) (pb, rb) =
      case comparePV pa pb of
        Just LT -> (pb, rb)
        _ -> (pa, ra)

-- | Select target for one lane.
selectLaneTarget :: GoCeilings -> [VersionCandidate] -> LaneId -> LaneTarget
selectLaneTarget ceilings candidates lid =
  let mCeiling = ceilingFor ceilings (laneCeilingLane lid)
      mPick = case mCeiling of
        Nothing -> Nothing
        Just c -> maxVersionUnder c candidates
   in LaneTarget
        { ltLane = lid,
          ltCeiling = mCeiling,
          ltPackagePV = fst <$> mPick,
          ltGoReq = snd <$> mPick
        }

selectAllLaneTargets :: GoCeilings -> [VersionCandidate] -> [LaneTarget]
selectAllLaneTargets ceilings candidates =
  map (selectLaneTarget ceilings candidates) allLaneIds

-- | KEYWORDS tokens from lane membership (plain → bare arch; tilde-only → @~arch@).
--
-- Per arch (@amd64@ then @arm64@): if any plain lane targets the PV, emit bare
-- @arch@; else if any tilde lane targets it, emit @~arch@; else omit. Never both
-- bare and tilde for the same arch (bare covers plain and tilde consumers).
assembleKeywords :: [LaneId] -> [Text]
assembleKeywords lanes =
  [ token
  | arch <- [Amd64, Arm64],
    Just token <- [tokenForArch arch]
  ]
  where
    tokenForArch arch
      | any (\l -> laneArch l == arch && laneTier l == Plain) lanes =
          Just (bareToken arch)
      | any (\l -> laneArch l == arch && laneTier l == Tilde) lanes =
          Just (tildeToken arch)
      | otherwise = Nothing
    bareToken = \case
      Amd64 -> "amd64"
      Arm64 -> "arm64"
    tildeToken = \case
      Amd64 -> "~amd64"
      Arm64 -> "~arm64"

-- | Collapse lane targets to unique planned ebuilds with KEYWORDS.
collapsePlannedEbuilds :: [LaneTarget] -> [PlannedEbuild]
collapsePlannedEbuilds targets =
  let withPV =
        [ (ltPackagePV t, ltLane t)
        | t <- targets,
          Just _ <- [ltPackagePV t]
        ]
      pvs = nub [pv | (Just pv, _) <- withPV]
   in map (buildEbuild withPV) pvs
  where
    buildEbuild withPV pv =
      let lanes = [lid | (Just p, lid) <- withPV, samePV p pv]
       in PlannedEbuild
            { pePV = pv,
              peKeywords = assembleKeywords lanes,
              peLanes = lanes
            }
    samePV a b =
      case comparePV a b of
        Just EQ -> True
        _ -> a == b

planFromTargets :: [LaneTarget] -> GoLanePlan
planFromTargets targets =
  let ebuilds = collapsePlannedEbuilds targets
   in GoLanePlan
        { glpLanes = targets,
          glpEbuilds = ebuilds,
          glpUniquePVs = map pePV ebuilds
        }

-- | True when local set differs from planned unique PVs or content needs work.
planNeedsWork ::
  -- | Local non-live numeric PVs present
  [EbuildVersion] ->
  -- | PVs that exist but need content fix (SRC_URI / BDEPEND / KEYWORDS)
  [EbuildVersion] ->
  GoLanePlan ->
  Bool
planNeedsWork localPVs contentFixPVs plan =
  not (null (missingTargets localPVs plan))
    || not (null (extrasToDelete localPVs plan))
    || not (null contentFixPVs)

missingTargets :: [EbuildVersion] -> GoLanePlan -> [EbuildVersion]
missingTargets localPVs plan =
  [ pv
  | pv <- glpUniquePVs plan,
    not (any (samePV pv) localPVs)
  ]
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

-- | Local non-live PVs not in the planned set (candidates for prune).
extrasToDelete :: [EbuildVersion] -> GoLanePlan -> [EbuildVersion]
extrasToDelete localPVs plan =
  [ loc
  | loc <- localPVs,
    not (any (samePV loc) (glpUniquePVs plan))
  ]
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False

-- | Build outdated/success gap lines from local PVs and plan.
--
-- Unsatisfied lanes emit one line each. @from@ selection:
--   * content fix (target already local): from = target
--   * single local: that local (split)
--   * multiple locals: cycle through locals not in the new set (converge),
--     falling back to all locals then newest.
buildGapLines ::
  [EbuildVersion] ->
  -- | Target PVs still needing work (missing or content fix)
  [EbuildVersion] ->
  GoLanePlan ->
  [GapLine]
buildGapLines localPVs needsWorkPVs plan =
  let unsatisfied =
        [ t
        | t <- glpLanes plan,
          Just pv <- [ltPackagePV t],
          any (samePV pv) needsWorkPVs
        ]
      newSet = glpUniquePVs plan
      removed =
        [ loc
        | loc <- localPVs,
          not (any (samePV loc) newSet)
        ]
      fromPool =
        if null removed
          then localPVs
          else removed
      sortedPool = sortPVs fromPool
   in zipWith (mkLine sortedPool) [0 ..] unsatisfied
  where
    samePV a b = case comparePV a b of Just EQ -> True; _ -> False
    mkLine pool idx t =
      let toPV = case ltPackagePV t of
            Just p -> p
            Nothing -> parseEbuildVersion "0"
          fromPV =
            if any (samePV toPV) localPVs
              then toPV
              else case pool of
                [] -> toPV
                _ -> pool !! (idx `mod` length pool)
       in GapLine
            { glFrom = stripRev fromPV,
              glTo = stripRev toPV,
              glLabel = laneLabel (ltLane t)
            }
    stripRev (Numeric comps _) = Numeric comps Nothing
    stripRev r = r
    sortPVs =
      sortBy
        ( \a b ->
            case comparePV a b of
              Just o -> o
              Nothing -> compare (show a) (show b)
        )
