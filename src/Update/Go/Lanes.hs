{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Update.Go.Lanes
  ( LaneId (..),
    pattern LaneAmd64Plain,
    pattern LaneAmd64Tilde,
    pattern LaneArm64Plain,
    pattern LaneArm64Tilde,
    allLaneIds,
    lanesFromCeilings,
    laneLabel,
    laneLabelWith,
    laneCeilingLane,
    LaneTarget (..),
    PlannedEbuild (..),
    GoLanePlan (..),
    LanePlan,
    GapLine (..),
    VersionCandidate (..),
    selectLaneTarget,
    selectAllLaneTargets,
    collapsePlannedEbuilds,
    assembleKeywords,
    planFromTargets,
    planFromTargetsWithAtom,
    planNeedsWork,
    extrasToDelete,
    missingTargets,
    buildGapLines,
    goReqMeetsCeiling,
    maxVersionUnder,
    filterCandidateVersions,
    zeroPlannedPVsError,
  )
where

import Data.List (nub, sort, sortBy)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, samePV)
import Update.Go.Tree
  ( Arch,
    CeilingLane (..),
    KeywordTier (..),
    RuntimeCeilings (..),
    allCeilingLanes,
    ceilingFor,
  )
import Update.Go.Version (compareGoVersions)

-- | Logical lane id: arch × plain/tilde.
data LaneId = LaneId
  { liArch :: Arch,
    liTier :: KeywordTier
  }
  deriving (Eq, Ord, Show)

-- | Pattern synonyms for dual-arch Go tests and fixtures.
pattern LaneAmd64Plain :: LaneId
pattern LaneAmd64Plain = LaneId "amd64" Plain

pattern LaneAmd64Tilde :: LaneId
pattern LaneAmd64Tilde = LaneId "amd64" Tilde

pattern LaneArm64Plain :: LaneId
pattern LaneArm64Plain = LaneId "arm64" Plain

pattern LaneArm64Tilde :: LaneId
pattern LaneArm64Tilde = LaneId "arm64" Tilde

-- | Default four dual-arch lanes (legacy helper; prefer 'lanesFromCeilings').
allLaneIds :: [LaneId]
allLaneIds =
  [ LaneAmd64Plain,
    LaneAmd64Tilde,
    LaneArm64Plain,
    LaneArm64Tilde
  ]

-- | Lanes derived from discovered ceilings (only arches/tiers with a ceiling).
-- When no ceilings are present, falls back to the four dual-arch lanes so empty
-- discovery still yields lane slots (selection will leave them empty).
lanesFromCeilings :: RuntimeCeilings -> [LaneId]
lanesFromCeilings ceilings =
  case allCeilingLanes ceilings of
    [] -> allLaneIds
    cls -> map (\(CeilingLane a t) -> LaneId a t) cls

laneLabel :: LaneId -> Text
laneLabel = laneLabelWith "dev-lang/go"

laneLabelWith :: Text -> LaneId -> Text
laneLabelWith atom (LaneId arch tier) =
  case tier of
    Plain -> "(" <> atom <> " " <> arch <> ")"
    Tilde -> "(" <> atom <> " ~" <> arch <> ")"

laneCeilingLane :: LaneId -> CeilingLane
laneCeilingLane (LaneId arch tier) = CeilingLane arch tier

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

-- | Full plan for one DepsAndAssets package (runtime lanes).
data GoLanePlan = GoLanePlan
  { glpLanes :: [LaneTarget],
    glpEbuilds :: [PlannedEbuild],
    glpUniquePVs :: [EbuildVersion],
    -- | Runtime package atom for labels (e.g. @dev-lang/go@).
    glpRuntimeAtom :: Text
  }
  deriving (Eq, Show)

type LanePlan = GoLanePlan

-- | One outdated/success report line.
data GapLine = GapLine
  { glFrom :: EbuildVersion,
    glTo :: EbuildVersion,
    glLabel :: Text
  }
  deriving (Eq, Show)

-- | Upstream version with optional runtime req (Nothing = unparseable / skip for selection).
data VersionCandidate = VersionCandidate
  { vcPV :: EbuildVersion,
    vcGoReq :: Maybe Text
  }
  deriving (Eq, Show)

-- | Whether package runtime req is ≤ ceiling (same rules as host gate).
goReqMeetsCeiling :: Text -> EbuildVersion -> Maybe Bool
goReqMeetsCeiling goReq ceilingPV =
  let ceilingTok = renderRuntimeCeiling ceilingPV
   in case compareGoVersions goReq ceilingTok of
        Just GT -> Just False
        Just _ -> Just True
        Nothing -> Nothing

renderRuntimeCeiling :: EbuildVersion -> Text
renderRuntimeCeiling (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)
renderRuntimeCeiling (Raw t) = t

-- | Max package PV among candidates with parseable req ≤ ceiling.
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
selectLaneTarget :: RuntimeCeilings -> [VersionCandidate] -> LaneId -> LaneTarget
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

selectAllLaneTargets :: RuntimeCeilings -> [VersionCandidate] -> [LaneTarget]
selectAllLaneTargets ceilings candidates =
  map (selectLaneTarget ceilings candidates) (lanesFromCeilings ceilings)

-- | KEYWORDS tokens from lane membership (plain → bare arch; tilde-only → @~arch@).
assembleKeywords :: [LaneId] -> [Text]
assembleKeywords lanes =
  [ token
  | arch <- arches,
    Just token <- [tokenForArch arch]
  ]
  where
    arches = sort (nub (map liArch lanes))
    tokenForArch arch
      | any (\l -> liArch l == arch && liTier l == Plain) lanes =
          Just arch
      | any (\l -> liArch l == arch && liTier l == Tilde) lanes =
          Just ("~" <> arch)
      | otherwise = Nothing

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
      let lanes = [lid | (Just p, lid) <- withPV, samePV p pv || p == pv]
       in PlannedEbuild
            { pePV = pv,
              peKeywords = assembleKeywords lanes,
              peLanes = lanes
            }

planFromTargets :: [LaneTarget] -> GoLanePlan
planFromTargets = planFromTargetsWithAtom "dev-lang/go"

planFromTargetsWithAtom :: Text -> [LaneTarget] -> GoLanePlan
planFromTargetsWithAtom atom targets =
  let ebuilds = collapsePlannedEbuilds targets
   in GoLanePlan
        { glpLanes = targets,
          glpEbuilds = ebuilds,
          glpUniquePVs = map pePV ebuilds,
          glpRuntimeAtom = atom
        }

-- | True when local set differs from planned unique PVs or content needs work.
planNeedsWork ::
  [EbuildVersion] ->
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

extrasToDelete :: [EbuildVersion] -> GoLanePlan -> [EbuildVersion]
extrasToDelete localPVs plan =
  [ loc
  | loc <- localPVs,
    not (any (samePV loc) (glpUniquePVs plan))
  ]

buildGapLines ::
  [EbuildVersion] ->
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
      atom = glpRuntimeAtom plan
   in zipWith (mkLine atom sortedPool) [0 ..] unsatisfied
  where
    mkLine atom pool idx t =
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
              glLabel = laneLabelWith atom (ltLane t)
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

-- | Candidate PVs = non-live local ∪ upstream strictly greater than max local.
filterCandidateVersions ::
  [EbuildVersion] ->
  [EbuildVersion] ->
  Either Text [EbuildVersion]
filterCandidateVersions localPVs upstream =
  case localPVs of
    [] ->
      Left
        "DepsAndAssets requires at least one non-live local ebuild \
        \(first import / empty package dirs are not supported)"
    _ ->
      let maxLocal = foldl1 maxVer localPVs
          newer =
            [ u
            | u <- upstream,
              case comparePV maxLocal u of
                Just LT -> True
                _ -> False
            ]
          localsBare = map stripRev localPVs
          combined = nub (localsBare <> map stripRev newer)
       in Right combined
  where
    stripRev (Numeric comps _) = Numeric comps Nothing
    stripRev r = r
    maxVer a b =
      case comparePV a b of
        Just LT -> b
        _ -> a

zeroPlannedPVsError :: Text
zeroPlannedPVsError =
  "runtime-lane planning produced no ebuild targets \
  \(no candidate satisfies any runtime ceiling)"
