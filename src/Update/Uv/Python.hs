{-# LANGUAGE OverloadedStrings #-}

-- | Python slot ceilings and Uv runtime-lane selection.
--
-- Ceilings are @dev-lang/python@ slots (major.minor), not package versions.
-- Frozen sync filters the slots @requires-python@ already allows. A plain
-- lane accepts a candidate only when that lane's ceiling slot itself synced.
-- The ebuild slot is the newest bare-keyworded synced slot, else the newest
-- tilde-keyworded synced slot.
module Update.Uv.Python
  ( PyVer (..),
    PythonSlot (..),
    PythonSlotInventory,
    UvCandidate (..),
    ProbeStep (..),
    discoverPythonSlotInventory,
    inventoryFromRows,
    pythonEbuildRows,
    pythonEbuildSlot,
    plainCeilingSlot,
    tildeCeilingSlot,
    parseRequiresPython,
    slotSatisfies,
    slotsInProbeOrder,
    chooseSlot,
    probeOrdered,
    classifyPythonFind,
    planUvFromCandidates,
    pythonRuntimeAtom,
  )
where

import Data.Char (isDigit, isSpace)
import Data.Containers.ListUtils (nubOrd)
import Data.List (sort, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    samePV,
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import Update.EbuildEdit (parseEbuildSlot)
import Update.Go.Lanes
  ( LaneId (..),
    LaneTarget (..),
    PlanError (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    filterCandidateVersions,
  )
import Update.Runtime.Ceilings
  ( Arch,
    KeywordTier (..),
    PortageqRunner,
    gentooRepoPath,
    isLiveRuntimeVersion,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    parseKeywordsField,
  )

pythonRuntimeAtom :: Text
pythonRuntimeAtom = "dev-lang/python"

data PyVer = PyVer Int Int
  deriving (Eq, Ord, Show)

data PythonSlot = PythonSlot
  { psSlot :: Text,
    psVer :: PyVer,
    psBare :: Set Arch,
    psAny :: Set Arch
  }
  deriving (Eq, Show)

newtype PythonSlotInventory = PythonSlotInventory
  { psiSlots :: [PythonSlot]
  }
  deriving (Eq, Show)

-- | One probed upstream (or local) PV.
data UvCandidate = UvCandidate
  { ucPV :: EbuildVersion,
    ucTag :: Text,
    -- | 'Nothing' means the specifier is missing or unrecognized.
    ucRequires :: Maybe Text,
    -- | Slots whose frozen sync succeeded. Production records the first success only.
    ucSynced :: Set Text
  }
  deriving (Eq, Show)

-- | One slot attempt. A hard failure stops the probe. A rejection tries the next slot.
data ProbeStep
  = ProbeHardFail Text
  | ProbeReject
  | ProbeOk
  deriving (Eq, Show)

-- | Non-live @dev-lang/python@ ebuilds grouped by SLOT. @_rc@ and @9999@ are ignored.
discoverPythonSlotInventory :: PortageqRunner -> IO (Either Text PythonSlotInventory)
discoverPythonSlotInventory run = do
  pathResult <- gentooRepoPath run
  case pathResult of
    Left err -> pure (Left err)
    Right gentooRoot -> readPythonDir (gentooRoot </> "dev-lang" </> "python")

readPythonDir :: FilePath -> IO (Either Text PythonSlotInventory)
readPythonDir dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure (Left ("directory not found: " <> T.pack dir))
    else do
      names <- listDirectory dir
      let ebuilds =
            [ n
            | n <- names,
              ".ebuild" `T.isSuffixOf` T.pack n,
              "python-" `T.isPrefixOf` T.pack n
            ]
      rows <- mapM (readPythonEbuild dir) ebuilds
      pure (Right (inventoryFromRows (concat rows)))

readPythonEbuild :: FilePath -> FilePath -> IO [(Text, [Text])]
readPythonEbuild dir name = do
  content <- TIO.readFile (dir </> name)
  pure $
    case rawPythonPv name of
      Nothing -> []
      Just pv -> pythonEbuildRows pv content

rawPythonPv :: FilePath -> Maybe Text
rawPythonPv name =
  case T.stripSuffix ".ebuild" (T.pack (takeFileName name)) of
    Just rest
      | "python-" `T.isPrefixOf` rest ->
          Just (T.drop (T.length "python-") rest)
    _ -> Nothing

-- | Rows for one @dev-lang/python@ ebuild. @_rc@ and @9999@ contribute nothing.
-- Gentoo sets @SLOT=\"${PYVER}\"@. Regular ebuilds use @PYVER=$(ver_cut 1-2)@.
-- Free-threaded ebuilds use @PYVER=\"$(ver_cut 2-3)t\"@ and are not ceiling slots.
pythonEbuildRows :: Text -> Text -> [(Text, [Text])]
pythonEbuildRows pv content
  | "_rc" `T.isInfixOf` pv = []
  | "9999" `elem` versionComponents pv = []
  | isLiveRuntimeVersion (parseEbuildVersion pv) = []
  | otherwise =
      case pythonEbuildSlot pv content of
        Nothing -> []
        Just slot -> [(slot, parseKeywordsField content)]

-- | Resolved slot, when this ebuild is a ceiling candidate.
pythonEbuildSlot :: Text -> Text -> Maybe Text
pythonEbuildSlot pv content =
  case pyverAssignment content of
    Just expr
      | expr == "$(ver_cut1-2)" -> verCut 1 2 pv
      | expr == "$(ver_cut2-3)t" -> Nothing
      | otherwise -> literalSlot
    Nothing -> literalSlot
  where
    literalSlot =
      case parseSlotVer (parseEbuildSlot content) of
        Just _ -> Just (parseEbuildSlot content)
        Nothing -> Nothing

pyverAssignment :: Text -> Maybe Text
pyverAssignment content =
  case mapMaybe one (T.lines content) of
    (expr : _) -> Just expr
    [] -> Nothing
  where
    one ln =
      let stripped = T.stripStart ln
       in if "PYVER=" `T.isPrefixOf` stripped
            then
              Just
                ( T.filter
                    (not . isSpace)
                    (stripQuotes (T.strip (T.drop (T.length ("PYVER=" :: Text)) stripped)))
                )
            else Nothing
    stripQuotes t
      | "\"" `T.isPrefixOf` t && "\"" `T.isSuffixOf` t && T.length t >= 2 =
          T.drop 1 (T.dropEnd 1 t)
      | otherwise = t

verCut :: Int -> Int -> Text -> Maybe Text
verCut start end pv
  | start >= 1 && end >= start =
      let comps = versionComponents pv
          slice = take (end - start + 1) (drop (start - 1) comps)
       in if length slice == end - start + 1
            then Just (T.intercalate "." slice)
            else Nothing
  | otherwise = Nothing

versionComponents :: Text -> [Text]
versionComponents pv =
  let lead = T.takeWhile (\c -> isDigit c || c == '.') pv
   in filter (not . T.null) (T.splitOn "." lead)

-- | Build an inventory from @(slot, KEYWORDS tokens)@ rows. Test fixture entry.
inventoryFromRows :: [(Text, [Text])] -> PythonSlotInventory
inventoryFromRows rows =
  PythonSlotInventory
    { psiSlots =
        map merge (Map.toList (foldl' insert Map.empty rows))
    }
  where
    insert acc (slot, kws) =
      case parseSlotVer slot of
        Nothing -> acc
        Just _ ->
          Map.insertWith
            (\(a, b) (c, d) -> (a <> c, b <> d))
            slot
            (bareArches kws, anyArches kws)
            acc
    merge (slot, (bare, anyA)) =
      PythonSlot
        { psSlot = slot,
          psVer = case parseSlotVer slot of
            Just v -> v
            Nothing -> PyVer 0 0,
          psBare = Set.fromList bare,
          psAny = Set.fromList anyA
        }

bareArches :: [Text] -> [Arch]
bareArches kws =
  [ arch
  | arch <- keywordArches kws,
    keywordsHasBare arch kws
  ]

anyArches :: [Text] -> [Arch]
anyArches kws =
  [ arch
  | arch <- keywordArches kws,
    keywordsHasTildeOrBare arch kws
  ]

keywordArches :: [Text] -> [Arch]
keywordArches kws =
  nubOrd
    [ if "~" `T.isPrefixOf` tok then T.drop 1 tok else tok
    | tok <- kws,
      not ("-" `T.isPrefixOf` tok),
      not ("*" `T.isInfixOf` tok)
    ]

plainCeilingSlot :: Arch -> PythonSlotInventory -> Maybe Text
plainCeilingSlot arch inv =
  psSlot <$> maxSlot [s | s <- psiSlots inv, arch `Set.member` psBare s]

tildeCeilingSlot :: Arch -> PythonSlotInventory -> Maybe Text
tildeCeilingSlot arch inv =
  psSlot <$> maxSlot [s | s <- psiSlots inv, arch `Set.member` psAny s]

maxSlot :: [PythonSlot] -> Maybe PythonSlot
maxSlot [] = Nothing
maxSlot (s : ss) = Just (foldl' newer s ss)
  where
    newer a b = if psVer b > psVer a then b else a

parseSlotVer :: Text -> Maybe PyVer
parseSlotVer raw =
  case T.splitOn "." (T.strip raw) of
    [maj, mn]
      | Just major <- readInt maj,
        Just minor <- readInt mn ->
          Just (PyVer major minor)
    _ -> Nothing

-- | Comma-separated PEP 440 clauses compared as major.minor.
-- Unrecognized syntax is 'Left'.
parseRequiresPython :: Text -> Either Text [PyClause]
parseRequiresPython raw =
  let parts = filter (not . T.null) (map T.strip (T.splitOn "," raw))
   in if null parts
        then Left "empty requires-python"
        else mapM parseClause parts

data PyClause
  = CEq PyVer
  | CNe PyVer
  | CGe PyVer
  | CGt PyVer
  | CLe PyVer
  | CLt PyVer
  | CCompat PyVer
  deriving (Eq, Show)

parseClause :: Text -> Either Text PyClause
parseClause raw =
  let s = T.filter (/= ' ') raw
      ops =
        [ ("~=", CCompat),
          (">=", CGe),
          ("<=", CLe),
          ("!=", CNe),
          ("==", CEq),
          (">", CGt),
          ("<", CLt)
        ]
   in case firstOp ops s of
        Nothing -> Left ("unrecognized requires-python clause: " <> raw)
        Just (ctor, rest) -> ctor <$> parsePyVer rest

firstOp :: [(Text, PyVer -> PyClause)] -> Text -> Maybe (PyVer -> PyClause, Text)
firstOp [] _ = Nothing
firstOp ((op, ctor) : rest) s
  | op `T.isPrefixOf` s = Just (ctor, T.drop (T.length op) s)
  | otherwise = firstOp rest s

parsePyVer :: Text -> Either Text PyVer
parsePyVer raw =
  let cleaned = T.takeWhile (\c -> c == '.' || isDigit c) raw
      parts = filter (not . T.null) (T.splitOn "." cleaned)
   in case parts of
        [] -> Left ("unrecognized python version: " <> raw)
        [maj] | Just major <- readInt maj -> Right (PyVer major 0)
        (maj : mn : _)
          | Just major <- readInt maj,
            Just minor <- readInt mn ->
              Right (PyVer major minor)
        _ -> Left ("unrecognized python version: " <> raw)

readInt :: Text -> Maybe Int
readInt t =
  case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

slotSatisfies :: PyVer -> [PyClause] -> Bool
slotSatisfies ver = all (clauseOk ver)

clauseOk :: PyVer -> PyClause -> Bool
clauseOk ver = \case
  CEq v -> ver == v
  CNe v -> ver /= v
  CGe v -> ver >= v
  CGt v -> ver > v
  CLe v -> ver <= v
  CLt v -> ver < v
  CCompat v@(PyVer maj mn) -> ver >= v && ver < PyVer maj (mn + 1)

-- | Satisfying bare slots, newest first, then satisfying tilde-only slots.
-- The production probe stops at the first success; this list is the order.
slotsInProbeOrder :: PythonSlotInventory -> [PyClause] -> [Text]
slotsInProbeOrder inv clauses =
  let ok = [s | s <- psiSlots inv, slotSatisfies (psVer s) clauses]
      bare = [s | s <- ok, not (Set.null (psBare s))]
      tildeOnly =
        [ s
        | s <- ok,
          Set.null (psBare s),
          not (Set.null (psAny s))
        ]
   in map psSlot (newestFirst bare ++ newestFirst tildeOnly)
  where
    newestFirst = sortBy (\a b -> compare (psVer b) (psVer a))

-- | Newest bare-keyworded synced slot, else newest tilde-keyworded synced slot.
chooseSlot :: PythonSlotInventory -> Set Text -> [PyClause] -> Maybe Text
chooseSlot inv synced clauses =
  let ok =
        [ s
        | s <- psiSlots inv,
          psSlot s `Set.member` synced,
          slotSatisfies (psVer s) clauses
        ]
      bare = [s | s <- ok, not (Set.null (psBare s))]
      tilde = [s | s <- ok, not (Set.null (psAny s))]
      pool = if null bare then tilde else bare
   in psSlot <$> maxSlot pool

-- | Plain eligibility is the ceiling slot itself. Tilde eligibility is any
-- synced slot at or below the ceiling.
laneEligible ::
  PythonSlotInventory ->
  KeywordTier ->
  Text ->
  Set Text ->
  [PyClause] ->
  Bool
laneEligible inv tier ceil synced clauses =
  case parseSlotVer ceil of
    Nothing -> False
    Just ceilVer ->
      case tier of
        Plain ->
          ceil `Set.member` synced && slotSatisfies ceilVer clauses
        Tilde ->
          any
            ( \s ->
                psVer s <= ceilVer
                  && psSlot s `Set.member` synced
                  && slotSatisfies (psVer s) clauses
            )
            (psiSlots inv)

-- | Walk slots until the first success. A hard failure does not try the next slot.
probeOrdered ::
  (Monad m) =>
  (Text -> m ProbeStep) ->
  [Text] ->
  m (Either Text (Set Text))
probeOrdered step = go
  where
    go [] = pure (Right Set.empty)
    go (slot : rest) = do
      result <- step slot
      case result of
        ProbeHardFail msg -> pure (Left msg)
        ProbeOk -> pure (Right (Set.singleton slot))
        ProbeReject -> go rest

-- | @uv python find@ success means the interpreter is installed.
-- A missing-interpreter failure is distinct from any other failure text.
classifyPythonFind :: Text -> ExitCode -> Text -> Text -> Either Text ()
classifyPythonFind _ ExitSuccess _ _ = Right ()
classifyPythonFind slot _ out err
  | interpreterMissing combined || T.null combined =
      Left ("python slot " <> slot <> " is not installed")
  | otherwise = Left combined
  where
    combined = T.strip (out <> "\n" <> err)

interpreterMissing :: Text -> Bool
interpreterMissing msg =
  let low = T.toLower msg
   in "no interpreter found" `T.isInfixOf` low
        || "failed to find python" `T.isInfixOf` low

-- | Select Uv lanes from already-probed candidates.
planUvFromCandidates ::
  PythonSlotInventory ->
  [Arch] ->
  [EbuildVersion] ->
  [UvCandidate] ->
  Either PlanError RuntimeLanePlan
planUvFromCandidates inv allowlist locals candidates =
  case filterCandidateVersions locals (map ucPV candidates) of
    Left err -> Left err
    Right wanted ->
      let usable =
            [ c
            | c <- candidates,
              any (\pv -> samePV pv (ucPV c)) wanted
            ]
          lanes = inventoryLanes allowlist inv
          targets = map (selectLane inv usable) lanes
          ebuilds = collapseUv allowlist inv targets
       in if null ebuilds
            then Left PlanZeroPlannedPVs
            else
              Right
                RuntimeLanePlan
                  { glpLanes = targets,
                    glpEbuilds = ebuilds,
                    glpUniquePVs = map pePV ebuilds,
                    glpRuntimeAtom = pythonRuntimeAtom,
                    glpDirectTagFloors = [],
                    glpFloorPolicy = Nothing,
                    glpUvTags =
                      [ (ucPV c, ucTag c)
                      | c <- usable,
                        not (T.null (ucTag c))
                      ]
                  }

inventoryLanes :: [Arch] -> PythonSlotInventory -> [LaneId]
inventoryLanes allowlist inv =
  let arches =
        sort
          ( nubOrd
              [ arch
              | slot <- psiSlots inv,
                arch <- Set.toList (psAny slot),
                null allowlist || arch `elem` allowlist
              ]
          )
   in [ LaneId arch tier
      | arch <- arches,
        tier <- [Plain, Tilde],
        isJust (ceilingForTier inv arch tier)
      ]

ceilingForTier :: PythonSlotInventory -> Arch -> KeywordTier -> Maybe Text
ceilingForTier inv arch = \case
  Plain -> plainCeilingSlot arch inv
  Tilde -> tildeCeilingSlot arch inv

selectLane :: PythonSlotInventory -> [UvCandidate] -> LaneId -> LaneTarget
selectLane inv candidates lid =
  let mCeil = ceilingForTier inv (liArch lid) (liTier lid)
      eligible = case mCeil of
        Nothing -> []
        Just ceil ->
          [ c
          | c <- candidates,
            Just spec <- [ucRequires c],
            Right clauses <- [parseRequiresPython spec],
            laneEligible inv (liTier lid) ceil (ucSynced c) clauses
          ]
      best = newest eligible
      chosen = best >>= \c -> chooseParsed inv (ucSynced c) (ucRequires c)
   in LaneTarget
        { ltLane = lid,
          ltCeiling = parseEbuildVersion <$> mCeil,
          ltPackagePV = ucPV <$> best,
          ltGoReq = chosen
        }

chooseParsed :: PythonSlotInventory -> Set Text -> Maybe Text -> Maybe Text
chooseParsed inv synced mSpec =
  case mSpec >>= eitherToMaybe . parseRequiresPython of
    Nothing -> Nothing
    Just clauses -> chooseSlot inv synced clauses

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just

newest :: [UvCandidate] -> Maybe UvCandidate
newest [] = Nothing
newest (c : cs) = Just (foldl' newer c cs)
  where
    newer a b =
      case comparePV (ucPV a) (ucPV b) of
        Just LT -> b
        _ -> a

collapseUv :: [Arch] -> PythonSlotInventory -> [LaneTarget] -> [PlannedEbuild]
collapseUv allowlist inv targets =
  let pvs =
        sortBy
          cmpPV
          ( nubOrd
              [ pv
              | t <- targets,
                Just pv <- [ltPackagePV t]
              ]
          )
   in map (oneEbuild inv allowlist targets) pvs
  where
    cmpPV a b =
      case comparePV a b of
        Just o -> o
        Nothing -> compare (show a) (show b)

oneEbuild ::
  PythonSlotInventory ->
  [Arch] ->
  [LaneTarget] ->
  EbuildVersion ->
  PlannedEbuild
oneEbuild inv allowlist targets pv =
  let lanes = [t | t <- targets, maybe False (`samePV` pv) (ltPackagePV t)]
      slot = case [s | t <- lanes, Just s <- [ltGoReq t]] of
        (s : _) -> s
        [] -> ""
      slotArches = case [s | s <- psiSlots inv, psSlot s == slot] of
        (s : _) -> psAny s
        [] -> Set.empty
      laneArches = nubOrd (map (liArch . ltLane) lanes)
      arches = sort [a | a <- laneArches, a `Set.member` slotArches]
      toks = map ("~" <>) arches
   in PlannedEbuild
        { pePV = pv,
          peKeywords = if null allowlist then toks else "-*" : toks,
          peLanes = map ltLane lanes
        }
