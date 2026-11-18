{-# LANGUAGE OverloadedStrings #-}

-- | Pure smoke run planning: which runs exist for each on-disk ebuild, in
-- what order, from host-arch runtime ceilings and the ebuilds' own floors.
module Smoke.Plan
  ( LaneRuntime (..),
    laneRuntimeFor,
    runtimeLabelAtom,
    runtimeCapPackages,
    HostCeilings (..),
    RuntimeCap (..),
    SmokeRun (..),
    PlannedItem (..),
    PackageInput (..),
    planSmokeRuns,
    planPvRuns,
    readPackageInput,
    runLabel,
    runAtom,
    itemAtom,
    ebuildPV,
  )
where

import Control.Exception (IOException, try)
import Data.List (isSuffixOf, nubBy, sort, sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion, renderPVNoRev)
import Smoke.Floors (ecosystemFloor, pythonSlot)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Update.EbuildEdit (parseKeywordsLine)
import Update.Go.Lanes (LaneId (..), laneLabelWith)
import Update.Runtime.Ceilings
  ( KeywordTier (..),
    bunBinRuntimeAtom,
    goRuntimeAtom,
    isLiveRuntimeVersion,
    keywordsHasTildeOrBare,
    nodejsRuntimeAtom,
    rustUnionRuntimeAtom,
    sbclRuntimeAtom,
  )
import Update.Types (EcosystemSpec (..), PackageKey, UpdateTechnique (..), packageKeyText, splitPackageKey)

-- | Runtime a lane-gated ecosystem is capped on. One per ecosystem.
data LaneRuntime
  = RuntimeGo
  | RuntimeNodejs
  | RuntimeBun
  | RuntimeRust
  | RuntimeSbcl
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Lane-gated runtime of a technique; 'Nothing' for packages outside
-- runtime lanes (GitMv, Unsupported, Uv, Pdm).
laneRuntimeFor :: UpdateTechnique -> Maybe LaneRuntime
laneRuntimeFor = \case
  DepsAndAssets eco -> case eco of
    Go _ -> Just RuntimeGo
    NpmEco -> Just RuntimeNodejs
    Bun -> Just RuntimeBun
    Cargo {} -> Just RuntimeRust
    Sbcl -> Just RuntimeSbcl
    Uv _ -> Nothing
    Pdm _ -> Nothing
  _ -> Nothing

-- | Atom in lane labels, as @runtime-lanes@ prints it.
runtimeLabelAtom :: LaneRuntime -> Text
runtimeLabelAtom = \case
  RuntimeGo -> goRuntimeAtom
  RuntimeNodejs -> nodejsRuntimeAtom
  RuntimeBun -> bunBinRuntimeAtom
  RuntimeRust -> rustUnionRuntimeAtom
  RuntimeSbcl -> sbclRuntimeAtom

-- | Packages masked above and accepted at or below a run's ceiling.
runtimeCapPackages :: LaneRuntime -> [Text]
runtimeCapPackages = \case
  RuntimeRust -> ["dev-lang/rust", "dev-lang/rust-bin"]
  rt -> [runtimeLabelAtom rt]

-- | Plain and tilde ceilings of one runtime on the host architecture.
data HostCeilings = HostCeilings
  { hcPlain :: Maybe EbuildVersion,
    hcTilde :: Maybe EbuildVersion
  }
  deriving (Eq, Show)

-- | The runtime cap of one run.
data RuntimeCap = RuntimeCap
  { capRuntime :: LaneRuntime,
    capTier :: KeywordTier,
    capCeiling :: EbuildVersion
  }
  deriving (Eq, Show)

-- | One install-and-check run.
data SmokeRun = SmokeRun
  { srKey :: PackageKey,
    srEbuild :: Ebuild,
    srVersion :: EbuildVersion,
    -- | Host @KEYWORDS@ token (@amd64@), for lane labels and accept lines.
    srArch :: Text,
    srCap :: Maybe RuntimeCap,
    -- | Python slot of a Uv or Pdm ebuild.
    srPythonSlot :: Maybe Text
  }
  deriving (Eq, Show)

data PlannedItem
  = PlannedRun SmokeRun
  | -- | Not installed; the reason names the missing keyword.
    PlannedSkip Ebuild Text
  | -- | Failed at stage @plan@ without a container.
    PlannedFail Ebuild Text
  deriving (Eq, Show)

-- | One selected package with its policy technique and on-disk ebuild texts.
data PackageInput = PackageInput
  { piKey :: PackageKey,
    piTechnique :: UpdateTechnique,
    piEbuilds :: [(Ebuild, Text)]
  }
  deriving (Eq, Show)

-- | Plan every package, ordered by package key, then ascending version, then
-- plain before tilde. @arch@ is the host @KEYWORDS@ token.
planSmokeRuns :: Text -> Map LaneRuntime HostCeilings -> [PackageInput] -> [PlannedItem]
planSmokeRuns arch ceilings inputs =
  concatMap (planPackage arch ceilings) (sortBy (comparing piKey) inputs)

-- | The items 'planSmokeRuns' gives one package's ebuild at version @pvr@,
-- in plan order. Lanes are derived from every ebuild in the input, so the
-- result is what @smoke@ would run for that version alone.
planPvRuns :: Text -> Map LaneRuntime HostCeilings -> PackageInput -> Text -> [PlannedItem]
planPvRuns arch ceilings pkg pvr =
  filter ((== pvr) . ebuildVersion . itemEbuild) (planPackage arch ceilings pkg)
  where
    itemEbuild = \case
      PlannedRun run -> srEbuild run
      PlannedSkip e _ -> e
      PlannedFail e _ -> e

-- | One package's ebuilds and their texts under the overlay @root@.
readPackageInput :: FilePath -> PackageKey -> UpdateTechnique -> IO (Either Text PackageInput)
readPackageInput root key technique = case splitPackageKey key of
  Nothing -> pure (Left ("invalid package key " <> packageKeyText key))
  Just (cat, pn) -> do
    let dir = root </> T.unpack cat </> T.unpack pn
    listed <- try @IOException (listDirectory dir)
    case listed of
      Left err -> pure (Left ("could not list " <> T.pack dir <> ": " <> T.pack (show err)))
      Right names -> do
        let ebuilds =
              [ Ebuild {ebuildCategory = cat, ebuildPackage = pn, ebuildVersion = T.pack ver, ebuildPath = dir </> name}
              | name <- sort names,
                ".ebuild" `isSuffixOf` name,
                Just (n, ver) <- [parseEbuildFileName name],
                n == T.unpack pn
              ]
        bodies <- try @IOException (traverse (TIO.readFile . ebuildPath) ebuilds)
        pure $ case bodies of
          Left err -> Left ("could not read the ebuilds of " <> packageKeyText key <> ": " <> T.pack (show err))
          Right texts -> Right PackageInput {piKey = key, piTechnique = technique, piEbuilds = zip ebuilds texts}

planPackage :: Text -> Map LaneRuntime HostCeilings -> PackageInput -> [PlannedItem]
planPackage arch ceilings pkg =
  concatMap itemsFor ordered
  where
    ordered =
      sortBy
        (\(a, _) (b, _) -> versionOrder (ebuildPV a) (ebuildPV b))
        [e | e@(eb, _) <- piEbuilds pkg, not (isLiveRuntimeVersion (ebuildPV eb))]
    keyworded = [e | e@(_, body) <- ordered, hostKeyworded body]
    hostKeyworded = keywordsHasTildeOrBare arch . parseKeywordsLine
    mRuntime = laneRuntimeFor (piTechnique pkg)
    host = fromMaybe (HostCeilings Nothing Nothing) (mRuntime >>= (`Map.lookup` ceilings))
    floorOf body = case piTechnique pkg of
      DepsAndAssets eco -> ecosystemFloor eco body
      _ -> Nothing
    lanes = [(t, c) | (t, Just c) <- [(Plain, hcPlain host), (Tilde, hcTilde host)]]
    servers =
      [ (tier, ceil', eb)
      | (tier, ceil') <- lanes,
        (eb, _) : _ <-
          [ reverse
              [ e
              | e@(_, body) <- keyworded,
                floorAtOrBelow (floorOf body) ceil'
              ]
          ]
      ]
    itemsFor (eb, body)
      | not (hostKeyworded body) =
          [ PlannedSkip eb $
              "KEYWORDS has neither "
                <> arch
                <> " nor ~"
                <> arch
          ]
      | otherwise = case mRuntime of
          Nothing -> [PlannedRun (mkRun eb Nothing (slotFor body))]
          Just rt -> laneItems rt eb (floorOf body)
    slotFor body = case piTechnique pkg of
      DepsAndAssets (Uv _) -> pythonSlot body
      DepsAndAssets (Pdm _) -> pythonSlot body
      _ -> Nothing
    mkRun eb cap slot =
      SmokeRun
        { srKey = piKey pkg,
          srEbuild = eb,
          srVersion = ebuildPV eb,
          srArch = arch,
          srCap = cap,
          srPythonSlot = slot
        }
    laneItems rt eb mFloor =
      case distinctCeilings [(t, c) | (t, c, e) <- servers, ebuildPath e == ebuildPath eb] of
        [] -> case [(t, c) | (t, c) <- lanes, floorAtOrBelow mFloor c] of
          (t, c) : _ -> [PlannedRun (mkRun eb (Just (RuntimeCap rt t c)) Nothing)]
          [] -> [PlannedFail eb (noCeilingReason rt mFloor)]
        served ->
          [PlannedRun (mkRun eb (Just (RuntimeCap rt t c)) Nothing) | (t, c) <- served]
    noCeilingReason rt mFloor =
      case lanes of
        [] -> "no " <> runtimeLabelAtom rt <> " ceiling for " <> arch
        _ ->
          runtimeLabelAtom rt
            <> " floor "
            <> maybe "none" renderPVNoRev mFloor
            <> " is above every "
            <> arch
            <> " ceiling ("
            <> T.intercalate ", " [tierName t <> " " <> renderPVNoRev c | (t, c) <- lanes]
            <> ")"
    tierName = \case
      Plain -> "plain"
      Tilde -> "tilde"

-- | Lanes served by one ebuild, collapsed by equal ceiling (plain kept).
distinctCeilings :: [(KeywordTier, EbuildVersion)] -> [(KeywordTier, EbuildVersion)]
distinctCeilings = nubBy (\(_, a) (_, b) -> versionOrder a b == EQ) . sortBy (comparing fst)

floorAtOrBelow :: Maybe EbuildVersion -> EbuildVersion -> Bool
floorAtOrBelow mFloor ceil' = case mFloor of
  Nothing -> True
  Just f -> comparePV f ceil' `elem` [Just LT, Just EQ]

-- | Numeric order with revision as tie-break; incomparable versions fall back
-- to structural order so sorting stays total.
versionOrder :: EbuildVersion -> EbuildVersion -> Ordering
versionOrder a b = case comparePV a b of
  Just EQ -> comparing revision a b
  Just o -> o
  Nothing -> compare a b
  where
    revision = \case
      Numeric _ r -> r
      Raw _ -> Nothing

ebuildPV :: Ebuild -> EbuildVersion
ebuildPV = parseEbuildVersion . ebuildVersion

-- | Lane label of a run (@(dev-lang/go ~amd64)@), or 'Nothing' when unlabeled.
runLabel :: SmokeRun -> Maybe Text
runLabel run = case srCap run of
  Nothing -> Nothing
  Just cap ->
    Just (laneLabelWith (runtimeLabelAtom (capRuntime cap)) (LaneId (srArch run) (capTier cap)))

-- | @category/package-PVR@ plus the lane label when present.
runAtom :: SmokeRun -> Text
runAtom run = ebuildAtom (srEbuild run) <> maybe "" (" " <>) (runLabel run)

-- | Result-line prefix of any planned item.
itemAtom :: PlannedItem -> Text
itemAtom = \case
  PlannedRun run -> runAtom run
  PlannedSkip eb _ -> ebuildAtom eb
  PlannedFail eb _ -> ebuildAtom eb
