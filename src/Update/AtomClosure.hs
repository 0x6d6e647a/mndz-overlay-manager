{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

-- | Overlay-internal DEPEND-family parse, PV satisfiability, reverse-dep
-- keep, and overlay-write wait/refuse (not Graph 1 wait-edges).
module Update.AtomClosure
  ( OverlayAtom (..),
    VersionOp (..),
    DepNeed (..),
    ProviderVer (..),
    GitMvRenamePlan (..),
    asSlotZero,
    AtomClosureSession (..),
    AtomClosureTerminal (..),
    parseConsumerNeeds,
    prettyOverlayAtom,
    atomMatchesPV,
    pvsSatisfyNeed,
    keepProviderPVs,
    extrasBeyondKeep,
    keepPVsForProvider,
    renameAwayUnsatisfied,
    waitCycleWithEdge,
    prettyWaitCycle,
    atomClosureRefuseMessage,
    atomClosureProviderFailedMessage,
    atomClosureParseMessage,
    atomClosureSlotMessage,
    atomClosureBlockerMessage,
    atomClosureUnknownOpMessage,
    atomClosureWaitReason,
    listOverlayPackageKeys,
    listNonLiveProviderPVs,
    remainingConsumerBodies,
    mkAtomClosureSession,
    plannedRemainingFromWork,
    wireAtomClosureSlots,
    recordAtomClosureTerminal,
    ensureAtomClosedForWrite,
    guardGitMvRenameAway,
  )
where

import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar
  ( MVar,
    modifyMVar,
    newEmptyMVar,
    newMVar,
    putMVar,
    readMVar,
    tryPutMVar,
    tryReadMVar,
  )
import Control.Exception (IOException, try)
import Control.Monad (foldM, join, unless, void)
import Data.Char (isAlphaNum)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (find, for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version
  ( EbuildVersion,
    comparePV,
    parseEbuildVersion,
    renderPV,
    samePV,
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Update.EbuildEdit (parseEbuildSlot)
import Update.Go.Plan (isLivePackageVersion)
import Update.Types
  ( PackageKey (..),
    mkPackageKey,
    packageKeyText,
    splitPackageKey,
  )

------------------------------------------------------------------------
-- Public types
------------------------------------------------------------------------

data VersionOp
  = OpUnversioned
  | OpGe
  | OpLe
  | OpGt
  | OpLt
  | OpEq
  | OpApprox
  deriving (Eq, Show)

data OverlayAtom = OverlayAtom
  { oaKey :: PackageKey,
    oaOp :: VersionOp,
    oaVersion :: Maybe EbuildVersion
  }
  deriving (Eq, Show)

-- | Retained provider ebuild PV plus whether @SLOT@ is @0@ (or omitted).
data ProviderVer = ProviderVer
  { pvVersion :: EbuildVersion,
    pvSlotZero :: Bool
  }
  deriving (Eq, Show)

-- | GitMv mutation after the rename-away guard.
data GitMvRenamePlan
  = GitMvRenameNewest
  | GitMvAddKeepPin
  deriving (Eq, Show)

asSlotZero :: [EbuildVersion] -> [ProviderVer]
asSlotZero = map (`ProviderVer` True)

bunBinKey :: PackageKey
bunBinKey = mkPackageKey "dev-lang" "bun-bin"

-- | Required overlay-internal constraint after USE over-approx and
-- non-overlay @||@ filtering.
data DepNeed
  = NeedAtom OverlayAtom
  | -- | At least one overlay-named alternative.
    NeedOr [OverlayAtom]
  deriving (Eq, Show)

data AtomClosureTerminal
  = TerminalOverlayOk
  | TerminalOverlayFail
  | TerminalOverlayCycle Text
  deriving (Eq, Show)

data AtomClosureSession = AtomClosureSession
  { -- | Selected packages' planned remaining non-live PVs.
    acsPlannedRemaining :: Map PackageKey [EbuildVersion],
    acsGates :: Map PackageKey (MVar AtomClosureTerminal),
    acsWaiting :: MVar (Map PackageKey PackageKey),
    acsSlotRelease :: IORef (IO ()),
    acsSlotAcquire :: IORef (IO ())
  }

------------------------------------------------------------------------
-- Operator-facing messages
------------------------------------------------------------------------

prettyOverlayAtom :: OverlayAtom -> Text
prettyOverlayAtom atom =
  opPrefix (oaOp atom)
    <> packageKeyText (oaKey atom)
    <> maybe "" (\v -> "-" <> renderPV v) (oaVersion atom)
  where
    opPrefix = \case
      OpUnversioned -> ""
      OpGe -> ">="
      OpLe -> "<="
      OpGt -> ">"
      OpLt -> "<"
      OpEq -> "="
      OpApprox -> "~"

atomClosureRefuseMessage :: PackageKey -> OverlayAtom -> Text
atomClosureRefuseMessage consumer atom =
  packageKeyText consumer
    <> ": overlay-internal atom "
    <> prettyOverlayAtom atom
    <> " is unsatisfied by remaining "
    <> packageKeyText (oaKey atom)
    <> " ebuilds; update "
    <> packageKeyText (oaKey atom)
    <> " or run untargeted `update`"

atomClosureProviderFailedMessage :: PackageKey -> PackageKey -> Text
atomClosureProviderFailedMessage consumer provider =
  packageKeyText consumer
    <> ": overlay-internal atom provider "
    <> packageKeyText provider
    <> " hard-failed; not overlay-mutating"

atomClosureParseMessage :: PackageKey -> Text -> Text
atomClosureParseMessage consumer reason =
  packageKeyText consumer
    <> ": could not parse overlay-internal DEPEND-family atoms: "
    <> reason

atomClosureSlotMessage :: PackageKey -> Text -> Text
atomClosureSlotMessage consumer atomText =
  packageKeyText consumer
    <> ": overlay-internal atom "
    <> atomText
    <> " has an explicit slot other than 0"

atomClosureBlockerMessage :: PackageKey -> Text -> Text
atomClosureBlockerMessage consumer atomText =
  packageKeyText consumer
    <> ": overlay-internal blocker "
    <> atomText
    <> " is not supported"

atomClosureUnknownOpMessage :: PackageKey -> Text -> Text
atomClosureUnknownOpMessage consumer tok =
  packageKeyText consumer
    <> ": overlay-internal atom "
    <> tok
    <> " has an unknown version operator"

atomClosureWaitReason :: PackageKey -> Text
atomClosureWaitReason provider = "waiting on " <> packageKeyText provider

prettyWaitCycle :: [PackageKey] -> Text
prettyWaitCycle keys =
  "overlay-internal atom-closure wait cycle: "
    <> T.intercalate " -> " (map packageKeyText keys)

------------------------------------------------------------------------
-- PV match / keep / rename-away (pure)
------------------------------------------------------------------------

atomMatchesPV :: OverlayAtom -> EbuildVersion -> Bool
atomMatchesPV atom pv =
  case (oaOp atom, oaVersion atom) of
    (OpUnversioned, _) -> True
    (_, Nothing) -> False
    (OpGe, Just want) -> cmp (Just GT) (Just EQ)
      where
        cmp a b = comparePV pv want `elem` [a, b]
    (OpLe, Just want) -> comparePV pv want `elem` [Just LT, Just EQ]
    (OpGt, Just want) -> comparePV pv want == Just GT
    (OpLt, Just want) -> comparePV pv want == Just LT
    (OpEq, Just want) -> samePV pv want
    (OpApprox, Just want) -> samePV pv want

-- | bun-bin floor / omitted-slot atoms match SLOT=0 only; exact @=@ matches any SLOT.
atomMatchesProvider :: OverlayAtom -> ProviderVer -> Bool
atomMatchesProvider atom pv =
  atomMatchesPV atom (pvVersion pv) && bunSlotOk
  where
    bunSlotOk
      | oaKey atom /= bunBinKey = True
      | oaOp atom == OpEq = True
      | otherwise = pvSlotZero pv

pvsSatisfyNeed :: (PackageKey -> [ProviderVer]) -> DepNeed -> Bool
pvsSatisfyNeed pvsOf = \case
  NeedAtom atom -> any (atomMatchesProvider atom) (pvsOf (oaKey atom))
  NeedOr atoms ->
    any (\atom -> any (atomMatchesProvider atom) (pvsOf (oaKey atom))) atoms

-- | Planned unique PVs that exist on disk, plus extras still required by
-- remaining consumer needs. Never invents a PV that is not on disk.
keepProviderPVs ::
  PackageKey ->
  [EbuildVersion] ->
  [ProviderVer] ->
  (PackageKey -> [ProviderVer]) ->
  [DepNeed] ->
  [EbuildVersion]
keepProviderPVs provider unique disk pvsOf needs =
  let uniqueOnDisk = [p | p <- disk, any (samePV (pvVersion p)) unique]
      extras = [p | p <- disk, not (any (samePV (pvVersion p)) unique)]
      relevant = filter (needMentions provider) needs
      pvsWith pPvs k
        | k == provider = pPvs
        | otherwise = pvsOf k
      closed pPvs = all (pvsSatisfyNeed (pvsWith pPvs)) relevant
      go kept [] = kept
      go kept (e : es)
        | closed kept = kept ++ skipRest es
        | closed (kept ++ [e]) = go (kept ++ [e]) es
        | otherwise = go kept es
      skipRest _ = []
      versions = map pvVersion
   in -- If unique already closes, drop extras. Otherwise add extras that help.
      if closed uniqueOnDisk
        then versions uniqueOnDisk
        else versions (go uniqueOnDisk extras)

needMentions :: PackageKey -> DepNeed -> Bool
needMentions k = \case
  NeedAtom atom -> oaKey atom == k
  NeedOr atoms -> any (\a -> oaKey a == k) atoms

extrasBeyondKeep :: [EbuildVersion] -> [EbuildVersion] -> [EbuildVersion]
extrasBeyondKeep disk keep =
  [p | p <- disk, not (any (samePV p) keep)]

-- | Remaining provider PVs after renaming Old to New (New included; Old dropped
-- unless it is the same PV as New).
remainingAfterRename ::
  [ProviderVer] ->
  EbuildVersion ->
  EbuildVersion ->
  [ProviderVer]
remainingAfterRename disk old new =
  ProviderVer new True
    : [p | p <- disk, not (samePV (pvVersion p) old)]

-- | 'Just' the first remaining consumer need that remaining provider PVs
-- would not satisfy.
renameAwayUnsatisfied ::
  PackageKey ->
  [ProviderVer] ->
  EbuildVersion ->
  EbuildVersion ->
  (PackageKey -> [ProviderVer]) ->
  [DepNeed] ->
  Maybe OverlayAtom
renameAwayUnsatisfied provider disk old new pvsOf needs =
  let remaining = remainingAfterRename disk old new
      pvs k
        | k == provider = remaining
        | otherwise = pvsOf k
      relevant = filter (needMentions provider) needs
   in firstUnsatisfiedAtom pvs relevant

isExactBunBinPin :: PackageKey -> EbuildVersion -> OverlayAtom -> Bool
isExactBunBinPin provider old atom =
  provider == bunBinKey
    && oaKey atom == bunBinKey
    && oaOp atom == OpEq
    && maybe False (samePV old) (oaVersion atom)

firstUnsatisfiedAtom :: (PackageKey -> [ProviderVer]) -> [DepNeed] -> Maybe OverlayAtom
firstUnsatisfiedAtom pvsOf = go
  where
    go [] = Nothing
    go (NeedAtom atom : rest)
      | pvsSatisfyNeed pvsOf (NeedAtom atom) = go rest
      | otherwise = Just atom
    go (NeedOr atoms : rest)
      | pvsSatisfyNeed pvsOf (NeedOr atoms) = go rest
      | otherwise =
          case atoms of
            (a : _) -> Just a
            [] -> go rest

-- | If adding consumer→provider creates a cycle, return the cycle path
-- starting at consumer.
waitCycleWithEdge ::
  Map PackageKey PackageKey ->
  PackageKey ->
  PackageKey ->
  Maybe [PackageKey]
waitCycleWithEdge waiting consumer provider
  | consumer == provider = Just [consumer]
  | otherwise =
      case pathTo consumer provider waiting of
        Just back -> Just (consumer : back)
        Nothing -> Nothing

pathTo :: PackageKey -> PackageKey -> Map PackageKey PackageKey -> Maybe [PackageKey]
pathTo target from waiting = go Set.empty from
  where
    go seen cur
      | cur == target = Just [cur]
      | cur `Set.member` seen = Nothing
      | otherwise =
          case Map.lookup cur waiting of
            Nothing -> Nothing
            Just nxt -> (cur :) <$> go (Set.insert cur seen) nxt

------------------------------------------------------------------------
-- DEPEND-family parse
------------------------------------------------------------------------

dependVars :: [Text]
dependVars = ["DEPEND", "RDEPEND", "BDEPEND", "PDEPEND", "IDEPEND"]

parseConsumerNeeds ::
  Set PackageKey ->
  PackageKey ->
  Text ->
  Either Text [DepNeed]
parseConsumerNeeds overlayKeys consumer body =
  case expandDependFamily body of
    Left err -> Left (atomClosureParseMessage consumer err)
    Right expanded -> parseDepString overlayKeys consumer expanded

expandDependFamily :: Text -> Either Text Text
expandDependFamily body = do
  assigns <- extractDependAssignments body
  let env0 = Map.fromList [(v, "") | v <- dependVars]
  env <- foldM applyAssign env0 assigns
  let parts = [Map.findWithDefault "" v env | v <- dependVars]
  pure (T.unwords (filter (not . T.null) parts))

data AssignOp = AssignSet | AssignAppend
  deriving (Eq)

applyAssign :: Map Text Text -> (Text, AssignOp, Text) -> Either Text (Map Text Text)
applyAssign env (var, op, raw) =
  let expanded = expandVars env raw
   in Right $
        case op of
          AssignSet -> Map.insert var expanded env
          AssignAppend ->
            Map.insert
              var
              (T.unwords (filter (not . T.null) [Map.findWithDefault "" var env, expanded]))
              env

expandVars :: Map Text Text -> Text -> Text
expandVars env t =
  foldl'
    (\acc v -> T.replace ("${" <> v <> "}") (Map.findWithDefault "" v env) acc)
    t
    dependVars

-- | DEPEND-family assignments in file order, including @+=@.
extractDependAssignments :: Text -> Either Text [(Text, AssignOp, Text)]
extractDependAssignments body = go True [] (T.unpack body)
  where
    go _ acc [] = Right (reverse acc)
    go lined acc xs@(c : cs)
      | lined,
        Just (var, rest) <- matchVar (dropWhile isHoriz xs),
        Just (op, afterEq) <- matchEq rest =
          case takeAssignValue afterEq of
            Left err -> Left err
            Right (val, rest') ->
              -- Remainder starts after the value; not a line start until a newline.
              go False ((var, op, val) : acc) rest'
      | otherwise = go (c == '\n') acc cs
    isHoriz ch = ch == ' ' || ch == '\t'

matchVar :: String -> Maybe (Text, String)
matchVar s = go dependVars
  where
    go [] = Nothing
    go (v : vs) =
      let u = T.unpack v
       in if u `isPrefixOf` s
            then Just (v, drop (length u) s)
            else go vs

matchEq :: String -> Maybe (AssignOp, String)
matchEq s =
  let s' = dropWhile (\c -> c == ' ' || c == '\t') s
   in case s' of
        '+' : '=' : rest -> Just (AssignAppend, rest)
        '=' : rest -> Just (AssignSet, rest)
        _ -> Nothing

isPrefixOf :: String -> String -> Bool
isPrefixOf pref xs = take (length pref) xs == pref

takeAssignValue :: String -> Either Text (Text, String)
takeAssignValue s =
  let s' = dropWhile (\c -> c == ' ' || c == '\t') s
   in case s' of
        '"' : rest ->
          case spanUnescaped '"' rest of
            Nothing -> Left "unparseable DEPEND-family assignment (unterminated \")"
            Just (val, after) -> Right (T.pack val, after)
        '\'' : rest ->
          case spanUnescaped '\'' rest of
            Nothing -> Left "unparseable DEPEND-family assignment (unterminated ')"
            Just (val, after) -> Right (T.pack val, after)
        _ ->
          let (tok, rest) = span (\c -> c /= ' ' && c /= '\t' && c /= '\n' && c /= '#') s'
           in Right (T.pack tok, rest)

spanUnescaped :: Char -> String -> Maybe (String, String)
spanUnescaped q = go []
  where
    go _ [] = Nothing
    go acc (x : xs)
      | x == '\\',
        y : ys <- xs =
          go (acc ++ [y]) ys
      | x == q = Just (acc, xs)
      | otherwise = go (acc ++ [x]) xs

------------------------------------------------------------------------
-- Dep string tokenizer / parser
------------------------------------------------------------------------

data Tok
  = TokWord Text
  | TokUse Text
  | TokOr
  | TokLParen
  | TokRParen
  deriving (Eq, Show)

tokenizeDep :: Text -> [Tok]
tokenizeDep = go . T.unpack
  where
    go [] = []
    go (c : cs)
      | c == '#' = go (dropWhile (/= '\n') cs)
      | c == ' ' || c == '\t' || c == '\n' || c == '\r' = go cs
      | c == '(' = TokLParen : go cs
      | c == ')' = TokRParen : go cs
      | c == '|', '|' : rest <- cs = TokOr : go rest
      | otherwise =
          let (w, rest) = span atomChar (c : cs)
           in if null w
                then go cs
                else case rest of
                  '?' : rest' -> TokUse (T.pack w) : go rest'
                  _ -> TokWord (T.pack w) : go rest
    atomChar ch =
      isAlphaNum ch
        || ch `elem` ("_+-./:~!<>=*[]" :: String)

parseDepString ::
  Set PackageKey ->
  PackageKey ->
  Text ->
  Either Text [DepNeed]
parseDepString overlayKeys consumer txt = do
  let toks = tokenizeDep txt
  (items, rest) <- parseSeq overlayKeys consumer toks
  unless (null rest) $
    Left "unparseable DEPEND-family (unbalanced group)"
  pure (concat items)

-- | Sequence of items until RParen or end. Each item yields zero or more needs.
parseSeq ::
  Set PackageKey ->
  PackageKey ->
  [Tok] ->
  Either Text ([[DepNeed]], [Tok])
parseSeq overlayKeys consumer = go []
  where
    go acc [] = Right (reverse acc, [])
    go acc (TokRParen : rest) = Right (reverse acc, TokRParen : rest)
    go acc toks = do
      (item, rest) <- parseItem overlayKeys consumer toks
      go (item : acc) rest

parseItem ::
  Set PackageKey ->
  PackageKey ->
  [Tok] ->
  Either Text ([DepNeed], [Tok])
parseItem overlayKeys consumer = \case
  [] -> Left "unparseable DEPEND-family (unexpected end)"
  (TokOr : TokLParen : rest) -> do
    (inner, rest') <- parseSeq overlayKeys consumer rest
    case rest' of
      (TokRParen : more) -> do
        let atoms = concatMap needAtoms (concat inner)
        if null atoms
          then Right ([], more)
          else Right ([NeedOr atoms], more)
      _ -> Left "unparseable DEPEND-family (unterminated || group)"
  (TokUse _ : TokLParen : rest) -> do
    -- USE over-approx: still required.
    (inner, rest') <- parseSeq overlayKeys consumer rest
    case rest' of
      (TokRParen : more) -> Right (concat inner, more)
      _ -> Left "unparseable DEPEND-family (unterminated USE group)"
  (TokUse _ : rest) ->
    -- Flag token without a group; ignore.
    Right ([], rest)
  (TokLParen : rest) -> do
    (inner, rest') <- parseSeq overlayKeys consumer rest
    case rest' of
      (TokRParen : more) -> Right (concat inner, more)
      _ -> Left "unparseable DEPEND-family (unterminated group)"
  (TokRParen : _) -> Left "unparseable DEPEND-family (unexpected )"
  (TokWord w : rest) -> do
    mNeed <- classifyWord overlayKeys consumer w
    Right (maybeToList mNeed, rest)
  (TokOr : _) -> Left "unparseable DEPEND-family (|| without group)"

needAtoms :: DepNeed -> [OverlayAtom]
needAtoms = \case
  NeedAtom a -> [a]
  NeedOr as -> as

classifyWord ::
  Set PackageKey ->
  PackageKey ->
  Text ->
  Either Text (Maybe DepNeed)
classifyWord overlayKeys consumer w
  | T.null w = Right Nothing
  | otherwise =
      case parseAtomToken w of
        Left (AtomFailBlocker txt) ->
          case atomKeyFromFail txt of
            Just k
              | k `Set.member` overlayKeys && k /= consumer ->
                  Left (atomClosureBlockerMessage consumer txt)
            _ -> Right Nothing
        Left (AtomFailSlot txt) ->
          case atomKeyFromFail txt of
            Just k
              | k `Set.member` overlayKeys && k /= consumer ->
                  Left (atomClosureSlotMessage consumer txt)
            _ -> Right Nothing
        Left (AtomFailUnknownOp txt) ->
          case atomKeyFromFail txt of
            Just k
              | k `Set.member` overlayKeys && k /= consumer ->
                  Left (atomClosureUnknownOpMessage consumer txt)
            _ -> Right Nothing
        Left (AtomFailUnparseable txt) ->
          case atomKeyFromFail txt of
            Just k
              | k `Set.member` overlayKeys && k /= consumer ->
                  Left
                    ( atomClosureParseMessage
                        consumer
                        ("could not parse atom " <> txt)
                    )
            _ -> Right Nothing
        Right atom
          | oaKey atom == consumer -> Right Nothing
          | oaKey atom `Set.member` overlayKeys ->
              Right (Just (NeedAtom atom))
          | otherwise -> Right Nothing

data AtomFail
  = AtomFailBlocker Text
  | AtomFailSlot Text
  | AtomFailUnknownOp Text
  | AtomFailUnparseable Text

-- | Best-effort cat/pkg from a failed token (strip ops/blockers/slot).
atomKeyFromFail :: Text -> Maybe PackageKey
atomKeyFromFail tok =
  let t0 = T.dropWhile (== '!') tok
      t1 = dropOpPrefix t0
      noUse = T.takeWhile (/= '[') t1
      noSlot = T.takeWhile (/= ':') noUse
   in parseCatPkgKey noSlot

dropOpPrefix :: Text -> Text
dropOpPrefix t
  | ">=" `T.isPrefixOf` t = T.drop 2 t
  | "<=" `T.isPrefixOf` t = T.drop 2 t
  | "=" `T.isPrefixOf` t = T.drop 1 t
  | ">" `T.isPrefixOf` t = T.drop 1 t
  | "<" `T.isPrefixOf` t = T.drop 1 t
  | "~" `T.isPrefixOf` t = T.drop 1 t
  | "*" `T.isPrefixOf` t = T.drop 1 t
  | otherwise = t

parseCatPkgKey :: Text -> Maybe PackageKey
parseCatPkgKey t =
  case T.breakOn "/" t of
    (cat, rest)
      | not (T.null cat),
        Just ('/', pkgVer) <- T.uncons rest,
        not (T.null pkgVer) ->
          let pkg = stripVersionSuffix pkgVer
           in if T.null pkg then Nothing else Just (mkPackageKey cat pkg)
    _ -> Nothing

stripVersionSuffix :: Text -> Text
stripVersionSuffix pkgVer =
  case parseEbuildFileName (T.unpack (pkgVer <> ".ebuild")) of
    Just (pkg, _) -> T.pack pkg
    Nothing -> pkgVer

parseAtomToken :: Text -> Either AtomFail OverlayAtom
parseAtomToken raw0
  | T.null raw0 = Left (AtomFailUnparseable raw0)
  | otherwise =
      let (bang, afterBang) = T.span (== '!') raw0
          noUse = T.takeWhile (/= '[') afterBang
       in if T.length bang >= 1
            then Left (AtomFailBlocker raw0)
            else parseOpAtom noUse raw0

parseOpAtom :: Text -> Text -> Either AtomFail OverlayAtom
parseOpAtom tok raw =
  case splitOp tok of
    Left err -> Left err
    Right (op, rest) ->
      case splitSlot rest of
        Left err -> Left err
        Right restNoSlot ->
          case splitCatPkgVer restNoSlot of
            Nothing -> Left (AtomFailUnparseable raw)
            Just (key, mVer) ->
              case (op, mVer) of
                (OpUnversioned, Nothing) ->
                  Right OverlayAtom {oaKey = key, oaOp = op, oaVersion = Nothing}
                (OpUnversioned, Just v) ->
                  -- Bare cat/pkg-ver without operator is still an unversioned
                  -- name with a version suffix in the token; treat as exact PV
                  -- (Portage simple atom). Overlay-internal simple atoms in
                  -- mndz-overlay are unversioned cat/pkg *or* operator+ver.
                  -- A versioned atom without operator is valid Portage
                  -- (equals implied). Map to OpEq.
                  Right OverlayAtom {oaKey = key, oaOp = OpEq, oaVersion = Just v}
                (_, Nothing) -> Left (AtomFailUnknownOp raw)
                (_, Just v) ->
                  Right OverlayAtom {oaKey = key, oaOp = op, oaVersion = Just v}

splitOp :: Text -> Either AtomFail (VersionOp, Text)
splitOp t
  | ">=" `T.isPrefixOf` t = Right (OpGe, T.drop 2 t)
  | "<=" `T.isPrefixOf` t = Right (OpLe, T.drop 2 t)
  | "=" `T.isPrefixOf` t = Right (OpEq, T.drop 1 t)
  | ">" `T.isPrefixOf` t = Right (OpGt, T.drop 1 t)
  | "<" `T.isPrefixOf` t = Right (OpLt, T.drop 1 t)
  | "~" `T.isPrefixOf` t = Right (OpApprox, T.drop 1 t)
  | "*" `T.isPrefixOf` t = Left (AtomFailUnknownOp t)
  | otherwise = Right (OpUnversioned, t)

-- | Strip @:=@ / omitted-or-0 slots; fail on explicit non-0 slot.
splitSlot :: Text -> Either AtomFail Text
splitSlot t =
  case T.breakOn ":" t of
    (_, rest)
      | T.null rest -> Right t
      | otherwise ->
          let slotPart = T.drop 1 rest
              pkg = fst (T.breakOn ":" t)
           in if slotIsOmittedOrZero slotPart
                then Right pkg
                else Left (AtomFailSlot t)

slotIsOmittedOrZero :: Text -> Bool
slotIsOmittedOrZero s =
  let noEq = T.dropWhileEnd (== '=') s
      noSub = fst (T.breakOn "/" noEq)
   in T.null noEq || noSub == "0"

splitCatPkgVer :: Text -> Maybe (PackageKey, Maybe EbuildVersion)
splitCatPkgVer t =
  case T.breakOn "/" t of
    (cat, rest)
      | not (T.null cat),
        Just ('/', pkgVer) <- T.uncons rest,
        not (T.null pkgVer),
        validCatPkg cat pkgVer ->
          case parseEbuildFileName (T.unpack (pkgVer <> ".ebuild")) of
            Just (pkg, verStr) ->
              Just (mkPackageKey cat (T.pack pkg), Just (parseEbuildVersion (T.pack verStr)))
            Nothing ->
              Just (mkPackageKey cat pkgVer, Nothing)
    _ -> Nothing

validCatPkg :: Text -> Text -> Bool
validCatPkg cat pkgVer =
  T.all validCatChar cat
    && not (T.null pkgVer)
    && T.all validPkgChar pkgVer
  where
    validCatChar c = isAlphaNum c || c == '-' || c == '+' || c == '_'
    validPkgChar c = isAlphaNum c || c == '-' || c == '+' || c == '_' || c == '.'

------------------------------------------------------------------------
-- Overlay tree IO
------------------------------------------------------------------------

listOverlayPackageKeys :: FilePath -> IO (Either Text (Set PackageKey))
listOverlayPackageKeys overlayRoot = do
  exists <- doesDirectoryExist overlayRoot
  if not exists
    then pure (Right Set.empty)
    else do
      entries <- listDirectory overlayRoot
      keys <- concat <$> mapM (categoryKeys overlayRoot) entries
      pure (Right (Set.fromList keys))

categoryKeys :: FilePath -> FilePath -> IO [PackageKey]
categoryKeys overlayRoot cat = do
  let catPath = overlayRoot </> cat
  isDir <- doesDirectoryExist catPath
  if not isDir || skipRootEntry cat
    then pure []
    else do
      children <- listDirectory catPath
      mapMaybeM (packageKeyIfEbuilds overlayRoot cat) children

skipRootEntry :: FilePath -> Bool
skipRootEntry name =
  name `elem` ["metadata", "profiles", "eclass", "licenses", "scripts", ".git"]

packageKeyIfEbuilds :: FilePath -> FilePath -> FilePath -> IO (Maybe PackageKey)
packageKeyIfEbuilds overlayRoot cat pkg = do
  let pkgPath = overlayRoot </> cat </> pkg
  isDir <- doesDirectoryExist pkgPath
  if not isDir
    then pure Nothing
    else do
      files <- listDirectory pkgPath
      pure $
        if any (\f -> ".ebuild" `T.isSuffixOf` T.pack f) files
          then Just (mkPackageKey (T.pack cat) (T.pack pkg))
          else Nothing

mapMaybeM :: (a -> IO (Maybe b)) -> [a] -> IO [b]
mapMaybeM f = go
  where
    go [] = pure []
    go (x : xs) = do
      m <- f x
      rest <- go xs
      pure $ case m of
        Just y -> y : rest
        Nothing -> rest

listNonLiveProviderPVs :: FilePath -> PackageKey -> IO [EbuildVersion]
listNonLiveProviderPVs overlayRoot key =
  map pvVersion <$> listNonLiveProviders overlayRoot key

listNonLiveProviders :: FilePath -> PackageKey -> IO [ProviderVer]
listNonLiveProviders overlayRoot key =
  case splitPackageKey key of
    Nothing -> pure []
    Just (cat, pn) -> do
      let pkgDir = overlayRoot </> T.unpack cat </> T.unpack pn
      exists <- doesDirectoryExist pkgDir
      if not exists
        then pure []
        else do
          names <- listDirectory pkgDir
          catMaybes
            <$> mapM
              ( \n ->
                  case parseEbuildFileName n of
                    Just (pkg, verStr)
                      | T.pack pkg == pn -> do
                          let v = parseEbuildVersion (T.pack verStr)
                          if isLivePackageVersion v
                            then pure Nothing
                            else do
                              eBody <-
                                try (TIO.readFile (pkgDir </> n)) ::
                                  IO (Either IOException Text)
                              pure $
                                case eBody of
                                  Left _ -> Nothing
                                  Right body ->
                                    Just (ProviderVer v (parseEbuildSlot body == "0"))
                    _ -> pure Nothing
              )
              names

readPackageEbuildBodies ::
  FilePath ->
  PackageKey ->
  [EbuildVersion] ->
  IO [(EbuildVersion, Text)]
readPackageEbuildBodies overlayRoot key wanted =
  case splitPackageKey key of
    Nothing -> pure []
    Just (cat, pn) -> do
      let pkgDir = overlayRoot </> T.unpack cat </> T.unpack pn
      exists <- doesDirectoryExist pkgDir
      if not exists
        then pure []
        else do
          names <- listDirectory pkgDir
          let wantedSet = wanted
          pairs <-
            mapM
              ( \n ->
                  case parseEbuildFileName n of
                    Just (pkg, verStr)
                      | T.pack pkg == pn -> do
                          let v = parseEbuildVersion (T.pack verStr)
                          if any (samePV v) wantedSet && not (isLivePackageVersion v)
                            then do
                              body <- TIO.readFile (pkgDir </> n)
                              pure (Just (v, body))
                            else pure Nothing
                    _ -> pure Nothing
              )
              names
          pure (catMaybes pairs)

-- | Remaining consumer ebuild bodies: selected packages use planned remaining
-- PVs (on-disk files only); unselected packages use on-disk non-live ebuilds.
remainingConsumerBodies ::
  Maybe AtomClosureSession ->
  FilePath ->
  Set PackageKey ->
  PackageKey ->
  IO [(PackageKey, Text)]
remainingConsumerBodies mSession overlayRoot overlayKeys self = do
  let others = Set.toList (Set.delete self overlayKeys)
  concat <$> mapM (bodiesFor overlayRoot mSession) others

bodiesFor ::
  FilePath ->
  Maybe AtomClosureSession ->
  PackageKey ->
  IO [(PackageKey, Text)]
bodiesFor overlayRoot mSession key = do
  disk <- listNonLiveProviderPVs overlayRoot key
  let remaining = case mSession of
        Just s -> Map.findWithDefault disk key (acsPlannedRemaining s)
        Nothing -> disk
      -- Only PVs that exist on disk (do not invent).
      onDiskRemaining = [p | p <- remaining, any (samePV p) disk]
  pairs <- readPackageEbuildBodies overlayRoot key onDiskRemaining
  pure [(key, body) | (_, body) <- pairs]

parseBodiesNeeds ::
  Set PackageKey ->
  [(PackageKey, Text)] ->
  Either Text [DepNeed]
parseBodiesNeeds overlayKeys = fmap concat . mapM one
  where
    one (k, body) = parseConsumerNeeds overlayKeys k body

-- | Reverse-dep keep-set for a provider after successful planned-PV apply.
keepPVsForProvider ::
  Maybe AtomClosureSession ->
  FilePath ->
  PackageKey ->
  [EbuildVersion] ->
  IO (Either Text [EbuildVersion])
keepPVsForProvider mSession overlayRoot provider unique = do
  eKeys <- listOverlayPackageKeys overlayRoot
  case eKeys of
    Left err -> pure (Left err)
    Right overlayKeys -> do
      diskP <- listNonLiveProviders overlayRoot provider
      bodies <- remainingConsumerBodies mSession overlayRoot overlayKeys provider
      case parseBodiesNeeds overlayKeys bodies of
        Left err -> pure (Left err)
        Right needs -> do
          otherPvs <- currentPvs overlayRoot overlayKeys
          let pvsOf k =
                case mSession of
                  Just s | Just ps <- Map.lookup k (acsPlannedRemaining s) -> asSlotZero ps
                  _ -> otherPvs k
          pure (Right (keepProviderPVs provider unique diskP pvsOf needs))

------------------------------------------------------------------------
-- Session / wait
------------------------------------------------------------------------

plannedRemainingFromWork ::
  FilePath ->
  PackageKey ->
  EbuildVersion ->
  -- | @Left@ unique PVs (DepsAndAssets) or @Right@ GitMv remote.
  Either [EbuildVersion] EbuildVersion ->
  IO [EbuildVersion]
plannedRemainingFromWork overlayRoot key local = \case
  Left unique -> pure unique
  Right remote -> do
    disk <- listNonLiveProviderPVs overlayRoot key
    let siblings = [p | p <- disk, not (samePV p local)]
    keepOld <- bunBinWouldKeepPin overlayRoot key local remote
    let kept = [local | keepOld]
    pure (nubOrd (siblings ++ kept ++ [remote]))

-- | Best-effort: bun-bin exact pin on Old means GitMv will add-keep, so Old remains.
bunBinWouldKeepPin ::
  FilePath ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  IO Bool
bunBinWouldKeepPin overlayRoot provider old new
  | provider /= bunBinKey = pure False
  | otherwise = do
      eKeys <- listOverlayPackageKeys overlayRoot
      case eKeys of
        Left _ -> pure False
        Right overlayKeys -> do
          disk <- listNonLiveProviders overlayRoot provider
          bodies <- remainingConsumerBodies Nothing overlayRoot overlayKeys provider
          case parseBodiesNeeds overlayKeys bodies of
            Left _ -> pure False
            Right needs -> do
              otherPvs <- currentPvs overlayRoot overlayKeys
              pure $
                case renameAwayUnsatisfied provider disk old new otherPvs needs of
                  Just atom -> isExactBunBinPin provider old atom
                  Nothing -> False

mkAtomClosureSession ::
  Map PackageKey [EbuildVersion] ->
  Set PackageKey ->
  Map PackageKey AtomClosureTerminal ->
  IO AtomClosureSession
mkAtomClosureSession remaining selected prefilled = do
  gates <-
    Map.fromList
      <$> mapM
        ( \k -> do
            v <- newEmptyMVar
            for_ (Map.lookup k prefilled) (putMVar v)
            pure (k, v)
        )
        (Set.toList selected)
  waiting <- newMVar Map.empty
  rel <- newIORef (pure ())
  acq <- newIORef (pure ())
  pure
    AtomClosureSession
      { acsPlannedRemaining = remaining,
        acsGates = gates,
        acsWaiting = waiting,
        acsSlotRelease = rel,
        acsSlotAcquire = acq
      }

wireAtomClosureSlots :: AtomClosureSession -> IO () -> IO () -> IO ()
wireAtomClosureSlots session release acquire = do
  writeIORef (acsSlotRelease session) release
  writeIORef (acsSlotAcquire session) acquire

recordAtomClosureTerminal ::
  Maybe AtomClosureSession ->
  PackageKey ->
  AtomClosureTerminal ->
  IO ()
recordAtomClosureTerminal Nothing _ _ = pure ()
recordAtomClosureTerminal (Just session) key term =
  case Map.lookup key (acsGates session) of
    Nothing -> pure ()
    Just gate -> void (tryPutMVar gate term)

ensureAtomClosedForWrite ::
  Maybe AtomClosureSession ->
  MultiHandle ->
  FilePath ->
  PackageKey ->
  Text ->
  IO (Either Text ())
ensureAtomClosedForWrite mSession mh overlayRoot consumer body = do
  eKeys <- listOverlayPackageKeys overlayRoot
  case eKeys of
    Left err -> pure (Left (atomClosureParseMessage consumer err))
    Right overlayKeys ->
      case parseConsumerNeeds overlayKeys consumer body of
        Left err -> pure (Left err)
        Right needs -> closeNeeds mSession mh overlayRoot overlayKeys consumer needs

closeNeeds ::
  Maybe AtomClosureSession ->
  MultiHandle ->
  FilePath ->
  Set PackageKey ->
  PackageKey ->
  [DepNeed] ->
  IO (Either Text ())
closeNeeds mSession mh overlayRoot overlayKeys consumer needs = go Set.empty
  where
    go waited = do
      pvs <- currentPvs overlayRoot overlayKeys
      case find (not . pvsSatisfyNeed pvs) needs of
        Nothing -> pure (Right ())
        Just need -> decideWait waited need
    decideWait waited need =
      case waitableAtom mSession waited need of
        WaitRefuse atom ->
          pure (Left (atomClosureRefuseMessage consumer atom))
        WaitProvider p -> do
          waitedRes <- waitForProvider mSession mh consumer p
          case waitedRes of
            Left err -> pure (Left err)
            Right () -> go (Set.insert p waited)
        WaitAlreadyDone atom ->
          pure (Left (atomClosureRefuseMessage consumer atom))

data WaitChoice
  = WaitProvider PackageKey
  | WaitRefuse OverlayAtom
  | WaitAlreadyDone OverlayAtom

waitableAtom ::
  Maybe AtomClosureSession ->
  Set PackageKey ->
  DepNeed ->
  WaitChoice
waitableAtom mSession waited need =
  let atoms = needAtoms need
      fallback =
        case atoms of
          (a : _) -> a
          [] -> unversionedAtom (PackageKey "unknown/unknown")
      choices = map (atomWaitChoice mSession waited) atoms
   in case [p | WaitProvider p <- choices] of
        (p : _) -> WaitProvider p
        []
          | any isAlreadyDone choices -> WaitAlreadyDone fallback
          | otherwise -> WaitRefuse fallback

isAlreadyDone :: WaitChoice -> Bool
isAlreadyDone WaitAlreadyDone {} = True
isAlreadyDone _ = False

atomWaitChoice ::
  Maybe AtomClosureSession ->
  Set PackageKey ->
  OverlayAtom ->
  WaitChoice
atomWaitChoice Nothing _ atom = WaitRefuse atom
atomWaitChoice (Just session) waited atom =
  let provider = oaKey atom
      planned = Map.findWithDefault [] provider (acsPlannedRemaining session)
      inSelection = Map.member provider (acsGates session)
      plannedOk = any (atomMatchesPV atom) planned
   in if not inSelection || not plannedOk
        then WaitRefuse atom
        else
          if provider `Set.member` waited
            then WaitAlreadyDone atom
            else WaitProvider provider

currentPvs :: FilePath -> Set PackageKey -> IO (PackageKey -> [ProviderVer])
currentPvs overlayRoot overlayKeys = do
  pairs <-
    mapM
      (\k -> (k,) <$> listNonLiveProviders overlayRoot k)
      (Set.toList overlayKeys)
  let m = Map.fromList pairs
  pure (\k -> Map.findWithDefault [] k m)

waitForProvider ::
  Maybe AtomClosureSession ->
  MultiHandle ->
  PackageKey ->
  PackageKey ->
  IO (Either Text ())
waitForProvider Nothing _ consumer provider =
  pure (Left (atomClosureRefuseMessage consumer (unversionedAtom provider)))
waitForProvider (Just session) mh consumer provider =
  case Map.lookup provider (acsGates session) of
    Nothing ->
      pure (Left (atomClosureRefuseMessage consumer (unversionedAtom provider)))
    Just gate -> do
      -- If already terminal, do not occupy wait chrome / slots.
      already <- tryReadMVar gate
      case already of
        Just TerminalOverlayFail ->
          pure (Left (atomClosureProviderFailedMessage consumer provider))
        Just (TerminalOverlayCycle msg) -> pure (Left msg)
        Just TerminalOverlayOk -> pure (Right ())
        Nothing -> do
          cycleOrWait <-
            modifyMVar (acsWaiting session) $ \waiting ->
              case waitCycleWithEdge waiting consumer provider of
                Just cyc -> do
                  let msg = prettyWaitCycle cyc
                  failCycle session cyc msg
                  pure (waiting, Left msg)
                Nothing ->
                  pure (Map.insert consumer provider waiting, Right ())
          case cycleOrWait of
            Left err -> pure (Left err)
            Right () -> do
              mhWait mh consumer (atomClosureWaitReason provider)
              join (readIORef (acsSlotRelease session))
              term <- readMVar gate
              join (readIORef (acsSlotAcquire session))
              modifyMVar (acsWaiting session) $ \w ->
                pure (Map.delete consumer w, ())
              mhStart mh consumer
              pure $ case term of
                TerminalOverlayOk -> Right ()
                TerminalOverlayFail ->
                  Left (atomClosureProviderFailedMessage consumer provider)
                TerminalOverlayCycle msg -> Left msg

unversionedAtom :: PackageKey -> OverlayAtom
unversionedAtom k =
  OverlayAtom {oaKey = k, oaOp = OpUnversioned, oaVersion = Nothing}

failCycle :: AtomClosureSession -> [PackageKey] -> Text -> IO ()
failCycle session keys msg =
  for_
    keys
    ( \k ->
        recordAtomClosureTerminal
          (Just session)
          k
          (TerminalOverlayCycle msg)
    )

------------------------------------------------------------------------
-- Overlay-write / GitMv guards
------------------------------------------------------------------------

guardGitMvRenameAway ::
  Maybe AtomClosureSession ->
  FilePath ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  IO (Either Text GitMvRenamePlan)
guardGitMvRenameAway mSession overlayRoot provider old new = do
  eKeys <- listOverlayPackageKeys overlayRoot
  case eKeys of
    Left err -> pure (Left err)
    Right overlayKeys -> do
      disk <- listNonLiveProviders overlayRoot provider
      bodies <- remainingConsumerBodies mSession overlayRoot overlayKeys provider
      case parseBodiesNeeds overlayKeys bodies of
        Left err -> pure (Left err)
        Right needs -> do
          otherPvs <- currentPvs overlayRoot overlayKeys
          -- Selected packages: planned remaining overrides current disk.
          let pvsOf k =
                case mSession of
                  Just s | Just ps <- Map.lookup k (acsPlannedRemaining s) -> asSlotZero ps
                  _ -> otherPvs k
          pure $
            case renameAwayUnsatisfied provider disk old new pvsOf needs of
              Nothing -> Right GitMvRenameNewest
              Just atom
                | isExactBunBinPin provider old atom -> Right GitMvAddKeepPin
                | otherwise ->
                    Left $
                      packageKeyText provider
                        <> ": GitMv rename-away would leave overlay-internal atom "
                        <> prettyOverlayAtom atom
                        <> " unsatisfied; not renaming"
