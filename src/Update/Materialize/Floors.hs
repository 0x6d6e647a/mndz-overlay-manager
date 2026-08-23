{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Toolchain floors for the materialize image: needed set, satisfy, union.
module Update.Materialize.Floors
  ( NeededFloors (..),
    emptyFloors,
    floorsIsEmpty,
    maxFloor,
    unionFloors,
    floorsSatisfy,
    neededFloorsFromClassified,
    fullPathKeysFromClassify,
    overlayBunFloorFromMetas,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:?), (.=))
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Overlay.Version (comparePV, renderPV)
import Update.Apply.Plan
  ( ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    PackagePlanResult (..),
    PlannedWork (..),
    planResultKey,
  )
import Update.DiskSpace (MaterializeClass (..))
import Update.Go.Lanes (LaneTarget (..), RuntimeLanePlan (..))
import Update.Go.Version (compareGoVersions)
import Update.Runtime.Ceilings (RuntimeEbuildMeta (..))
import Update.Types
  ( EcosystemSpec (..),
    PackageKey,
    ecosystemIsBun,
  )

-- | Per-toolchain minimum versions this prepare needs in the image.
-- 'Nothing' means that toolchain is not required. @Just \"0\"@ means the
-- toolchain is required at any version (probe missing).
data NeededFloors = NeededFloors
  { nfGo :: Maybe Text,
    nfNode :: Maybe Text,
    nfBun :: Maybe Text,
    nfRust :: Maybe Text,
    nfSbcl :: Maybe Text
  }
  deriving (Eq, Show)

instance ToJSON NeededFloors where
  toJSON f =
    object $
      catMaybes
        [ ("go" .=) <$> nfGo f,
          ("node" .=) <$> nfNode f,
          ("bun" .=) <$> nfBun f,
          ("rust" .=) <$> nfRust f,
          ("sbcl" .=) <$> nfSbcl f
        ]

instance FromJSON NeededFloors where
  parseJSON = withObject "satisfies" $ \o ->
    NeededFloors
      <$> o .:? "go"
      <*> o .:? "node"
      <*> o .:? "bun"
      <*> o .:? "rust"
      <*> o .:? "sbcl"

emptyFloors :: NeededFloors
emptyFloors =
  NeededFloors
    { nfGo = Nothing,
      nfNode = Nothing,
      nfBun = Nothing,
      nfRust = Nothing,
      nfSbcl = Nothing
    }

floorsIsEmpty :: NeededFloors -> Bool
floorsIsEmpty f =
  all
    (== Nothing)
    [nfGo f, nfNode f, nfBun f, nfRust f, nfSbcl f]

-- | Monotonic max of two version tokens ('Nothing' loses).
maxFloor :: Maybe Text -> Maybe Text -> Maybe Text
maxFloor Nothing x = x
maxFloor x Nothing = x
maxFloor (Just a) (Just b) =
  case compareGoVersions a b of
    Just LT -> Just b
    Just _ -> Just a
    Nothing -> Just a

unionFloors :: NeededFloors -> NeededFloors -> NeededFloors
unionFloors a b =
  NeededFloors
    { nfGo = maxFloor (nfGo a) (nfGo b),
      nfNode = maxFloor (nfNode a) (nfNode b),
      nfBun = maxFloor (nfBun a) (nfBun b),
      nfRust = maxFloor (nfRust a) (nfRust b),
      nfSbcl = maxFloor (nfSbcl a) (nfSbcl b)
    }

-- | Recorded image satisfies this prepare when every needed toolchain is
-- present at a version greater than or equal to the needed floor.
floorsSatisfy :: NeededFloors -> NeededFloors -> Bool
floorsSatisfy recorded needed =
  fieldOk (nfGo recorded) (nfGo needed)
    && fieldOk (nfNode recorded) (nfNode needed)
    && fieldOk (nfBun recorded) (nfBun needed)
    && fieldOk (nfRust recorded) (nfRust needed)
    && fieldOk (nfSbcl recorded) (nfSbcl needed)
  where
    fieldOk _ Nothing = True
    fieldOk Nothing (Just _) = False
    fieldOk (Just recV) (Just needV) =
      case compareGoVersions recV needV of
        Just LT -> False
        Just _ -> True
        Nothing -> False

-- | Floors from classified full-path units plus overlay bun-bin PV when Bun
-- is needed. GitMv / reuse-path units do not contribute.
neededFloorsFromClassified ::
  [ClassifyPackageResult] ->
  [PackagePlanResult] ->
  Maybe Text ->
  NeededFloors
neededFloorsFromClassified classifyResults planResults mOverlayBun =
  let fullKeys = fullPathKeysFromClassify classifyResults
      plansByKey =
        [ (planResultKey r, r)
        | r <- planResults
        ]
      fromPlans =
        foldl'
          unionFloors
          emptyFloors
          [ floorsForPlan work
          | k <- fullKeys,
            Just (PlanNeedsWork _ work) <- [lookup k plansByKey]
          ]
      withBun =
        if any bunFull classifyResults
          then fromPlans {nfBun = maxFloor (nfBun fromPlans) mOverlayBun}
          else fromPlans
   in withBun
  where
    bunFull (ClassifyOk _ us) = any (ecosystemIsBun . cpuEco) (filter isFull us)
    bunFull _ = False

fullPathKeysFromClassify :: [ClassifyPackageResult] -> [PackageKey]
fullPathKeysFromClassify =
  concatMap $ \case
    ClassifyOk k us | any isFull us -> [k]
    _ -> []

isFull :: ClassifiedPvUnit -> Bool
isFull u = case cpuClass u of
  ReusePath -> False
  GitMvFetch -> False
  FullGo -> True
  FullCargo -> True
  FullNpmBun -> True
  FullSbcl -> True

floorsForPlan :: PlannedWork -> NeededFloors
floorsForPlan = \case
  PlannedGitMv {} -> emptyFloors
  PlannedDeps eco _src plan _ _ ->
    let req = needAtLeast (maxReqFromPlan plan)
     in case eco of
          Go _ -> emptyFloors {nfGo = req}
          NpmEco -> emptyFloors {nfNode = req}
          Bun -> emptyFloors {nfBun = req}
          Cargo {} -> emptyFloors {nfRust = req}
          Sbcl -> emptyFloors {nfSbcl = req}

-- | Any-version floor when the probe did not yield a token.
needAtLeast :: Maybe Text -> Maybe Text
needAtLeast Nothing = Just "0"
needAtLeast (Just v) = Just v

maxReqFromPlan :: RuntimeLanePlan -> Maybe Text
maxReqFromPlan plan =
  foldl' maxFloor Nothing (map ltGoReq (glpLanes plan))

-- | Highest overlay bun-bin PV as a floor token.
overlayBunFloorFromMetas :: [RuntimeEbuildMeta] -> Maybe Text
overlayBunFloorFromMetas metas =
  case map remPV metas of
    [] -> Nothing
    (p : ps) -> Just (renderPV (foldl' maxPV p ps))
  where
    maxPV a b = case comparePV a b of
      Just LT -> b
      _ -> a
