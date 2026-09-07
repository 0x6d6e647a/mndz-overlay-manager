{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Update.Cargo.Msrv
  ( normalizeRustVersion,
    parseDirectRustVersion,
    parseRustVersionField,
    parseRustMinVerFromEbuild,
    maxRustVersion,
    maxMaybeRustVersions,
    combineMsrv,
    rustMinVerTooLow,
    CargoTomlFetch (..),
    cargoFloorPolicyVersion,
    cargoFloorPolicyKey,
    orderedCargoTomlProbePaths,
    probeDirectTagFloor,
    TagFloorResult (..),
    probePolicyTagFloor,
    fetchCargoTomlFromDir,
    windowsOnlyDepNames,
    parseRustToolchainChannel,
    applyRustToolchainFloor,
    fetchRustToolchainFromDir,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Char (isAlpha, isAlphaNum)
import Data.Containers.ListUtils (nubOrd)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( canonicalizePath,
    doesFileExist,
    doesPathExist,
  )
import System.FilePath
  ( addTrailingPathSeparator,
    isAbsolute,
    joinPath,
    normalise,
    splitDirectories,
    (</>),
  )
import Toml (Table, Value, forgetTableAnns, parse)
import Toml.Semantics.Types
  ( Table' (MkTable),
    pattern Bool,
    pattern List,
    pattern Table,
    pattern Text,
  )
import Update.Go.Version (compareGoVersions, parseGoVersionToken)
import Update.TextUtil (stripSurroundingQuotes)

-- | Floor-policy/parser version stored with Cargo deps-plan snapshots.
cargoFloorPolicyVersion :: Text
cargoFloorPolicyVersion = "3"

-- | Cache-validity key for the tag probe that produced Cargo floor snapshots.
cargoFloorPolicyKey :: Text -> Maybe FilePath -> Maybe FilePath -> Text
cargoFloorPolicyKey prefix mPkg mLock =
  T.intercalate
    "|"
    [ cargoFloorPolicyVersion,
      "prefix=" <> prefix,
      "pkg=" <> maybe "" T.pack mPkg,
      "lock=" <> maybe "" T.pack mLock
    ]

-- | Normalize a rust-version / RUST_MIN_VER token to three numeric components
-- (@1.91@ → @1.91.0@). Returns 'Nothing' when the token is not a version.
normalizeRustVersion :: Text -> Maybe Text
normalizeRustVersion raw =
  case parseGoVersionToken (T.strip raw) of
    Just [a, b, c] ->
      Just $
        T.intercalate
          "."
          [T.pack (show a), T.pack (show b), T.pack (show c)]
    _ -> Nothing

-- | Table-aware direct Rust declaration in a Cargo.toml body.
--
-- @Right (Just ver)@ is a normalized direct @\[package\].rust-version@, else
-- direct @\[workspace.package\].rust-version@. @Right Nothing@ is explicit
-- absence (including a valid @rust-version.workspace = true@ marker).
-- @Left@ is malformed TOML or a malformed present value.
parseDirectRustVersion :: Text -> Either Text (Maybe Text)
parseDirectRustVersion content =
  case parse content of
    Left _ -> Left "malformed Cargo.toml"
    Right tab' -> directFromTable (forgetTableAnns tab')

-- | Alias for 'parseDirectRustVersion'.
parseRustVersionField :: Text -> Either Text (Maybe Text)
parseRustVersionField = parseDirectRustVersion

directFromTable :: Table -> Either Text (Maybe Text)
directFromTable tab =
  case tableLookup "package" tab of
    Just (Table pkg) ->
      case rustVersionInTable pkg of
        Left err -> Left err
        Right (Just ver) -> Right (Just ver)
        Right Nothing -> workspacePackageRust tab
    Just _ -> Left "malformed Cargo.toml"
    Nothing -> workspacePackageRust tab

workspacePackageRust :: Table -> Either Text (Maybe Text)
workspacePackageRust tab =
  case tableLookup "workspace" tab of
    Just (Table ws) ->
      case tableLookup "package" ws of
        Just (Table pkg) -> rustVersionInTable pkg
        Just _ -> Left "malformed Cargo.toml"
        Nothing -> Right Nothing
    Just _ -> Left "malformed Cargo.toml"
    Nothing -> Right Nothing

-- | Direct rust-version in one table: string value, or workspace-inheritance
-- marker (absent). Missing key is absent.
rustVersionInTable :: Table -> Either Text (Maybe Text)
rustVersionInTable tab =
  case rustDeclInTable tab of
    Left err -> Left err
    Right (RustDirect ver) -> Right (Just ver)
    Right _ -> Right Nothing

data RustDecl
  = RustDirect Text
  | RustInherit
  | RustAbsent

rustDeclInTable :: Table -> Either Text RustDecl
rustDeclInTable tab =
  case tableLookup "rust-version" tab of
    Nothing -> Right RustAbsent
    Just val -> interpretRustDecl val

interpretRustDecl :: Value -> Either Text RustDecl
interpretRustDecl = \case
  Text raw ->
    case normalizeRustVersion raw of
      Just ver -> Right (RustDirect ver)
      Nothing -> Left "malformed rust-version in Cargo.toml"
  Table inner ->
    case tableLookup "workspace" inner of
      Just (Bool _) -> Right RustInherit
      Just _ -> Left "malformed rust-version in Cargo.toml"
      Nothing -> Left "malformed rust-version in Cargo.toml"
  _ -> Left "malformed rust-version in Cargo.toml"

tableLookup :: Text -> Table -> Maybe Value
tableLookup key (MkTable m) = snd <$> Map.lookup key m

tableAssoc :: Table -> [(Text, Value)]
tableAssoc (MkTable m) = [(k, snd av) | (k, av) <- Map.toList m]

-- | Parse @RUST_MIN_VER="…"@ from ebuild content.
parseRustMinVerFromEbuild :: Text -> Maybe Text
parseRustMinVerFromEbuild content =
  case [v | ln <- T.lines content, Just v <- [lineMin (T.stripStart ln)]] of
    (v : _) -> normalizeRustVersion v
    [] -> Nothing
  where
    lineMin ln
      | "RUST_MIN_VER=" `T.isPrefixOf` ln =
          let raw = T.drop (T.length ("RUST_MIN_VER=" :: Text)) ln
              unquoted = stripSurroundingQuotes (T.strip raw)
           in if T.null unquoted then Nothing else Just unquoted
      | otherwise = Nothing

-- | Callback result for one tagged Cargo.toml probe location.
data CargoTomlFetch
  = -- | Expected path absence (HTTP 404).
    CargoTomlMissing
  | -- | Transport, auth, server, or other fetch failure.
    CargoTomlError Text
  | CargoTomlBody Text
  deriving (Eq, Show)

-- | Ordered, deduplicated probe locations: effective package path
-- (@package \<|\> lock@), lock path, repository root.
orderedCargoTomlProbePaths :: Maybe FilePath -> Maybe FilePath -> [Maybe FilePath]
orderedCargoTomlProbePaths mPkg mLock =
  nubOrd [mPkg <|> mLock, mLock, Nothing]

-- | Probe direct rust-version along 'orderedCargoTomlProbePaths'.
-- Expected missing paths continue; fetch and parse errors fail closed.
-- Complete absence is @Right Nothing@.
probeDirectTagFloor ::
  Maybe FilePath ->
  Maybe FilePath ->
  (Maybe FilePath -> IO CargoTomlFetch) ->
  IO (Either Text (Maybe Text))
probeDirectTagFloor mPkg mLock fetch =
  go (orderedCargoTomlProbePaths mPkg mLock)
  where
    go [] = pure (Right Nothing)
    go (mSub : rest) = do
      eres <- fetch mSub
      case eres of
        CargoTomlMissing -> go rest
        CargoTomlError err -> pure (Left err)
        CargoTomlBody body ->
          case parseDirectRustVersion body of
            Left err -> pure (Left err)
            Right (Just ver) -> pure (Right (Just ver))
            Right Nothing -> go rest

-- | Maximum of two rust versions; prefers the higher one.
maxRustVersion :: Text -> Text -> Maybe Text
maxRustVersion a b =
  case (normalizeRustVersion a, normalizeRustVersion b) of
    (Just a', Just b') ->
      case compareGoVersions a' b' of
        Just LT -> Just b'
        Just _ -> Just a'
        Nothing -> Nothing
    (Just a', Nothing) -> Just a'
    (Nothing, Just b') -> Just b'
    _ -> Nothing

-- | Numeric maximum across optional rust versions; 'Nothing' if all absent.
maxMaybeRustVersions :: [Maybe Text] -> Maybe Text
maxMaybeRustVersions ms =
  case [v | Just r <- ms, Just v <- [normalizeRustVersion r]] of
    [] -> Nothing
    (x : xs) -> foldl' step (Just x) xs
  where
    step acc y = case acc of
      Nothing -> Just y
      Just a -> maxRustVersion a y

-- | Combine optional root, max-deps, and donor MSRV via max; 'Nothing' if all absent.
combineMsrv :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text
combineMsrv mRoot mDeps mDonor = maxMaybeRustVersions [mRoot, mDeps, mDonor]

-- | True when a written floor is missing/malformed or numerically below @needed@.
rustMinVerTooLow :: Text -> Text -> Bool
rustMinVerTooLow written needed =
  case (normalizeRustVersion written, normalizeRustVersion needed) of
    (Just a, Just b) ->
      case compareGoVersions a b of
        Just LT -> True
        Just _ -> False
        Nothing -> True
    _ -> True

------------------------------------------------------------------------
-- Policy-package path-closure walker
------------------------------------------------------------------------

-- | Outcome of one tag/clone path-closure walk.
data TagFloorResult
  = TagFloorComplete (Maybe Text) [(FilePath, Maybe Text)]
  | TagFloorIncomplete [Text] [(FilePath, Maybe Text)]
  | TagFloorFailed Text
  deriving (Eq, Show)

-- | Walk the policy-package local path closure.
--
-- @mDiskRoot@ is @Just@ the clone root for harvest (canonicalize bound);
-- @Nothing@ at tag time (logical @..@ bound only).
probePolicyTagFloor ::
  Maybe FilePath ->
  Maybe FilePath ->
  Maybe FilePath ->
  (Maybe FilePath -> IO CargoTomlFetch) ->
  IO TagFloorResult
probePolicyTagFloor mPkg mLock mDisk fetch = do
  cache <- newIORef Map.empty
  case (normalizePolicy mPkg, normalizePolicy mLock) of
    (Left err, _) -> pure (TagFloorFailed err)
    (_, Left err) -> pure (TagFloorFailed err)
    (Right pkg, Right lock) -> do
      let env =
            WalkEnv
              { weFetch = fetch,
                weLock = lock,
                weDisk = mDisk,
                wePkgSet = isJust mPkg,
                weCache = cache
              }
      start <- discoverStart env pkg lock
      case start of
        Left err -> pure (TagFloorFailed err)
        Right Nothing ->
          pure (TagFloorIncomplete ["policy Cargo.toml not found"] [])
        Right (Just startPath) -> walkClosure env startPath

normalizePolicy :: Maybe FilePath -> Either Text (Maybe FilePath)
normalizePolicy Nothing = Right Nothing
normalizePolicy (Just p) = collapseRel p

data WalkEnv = WalkEnv
  { weFetch :: Maybe FilePath -> IO CargoTomlFetch,
    weLock :: Maybe FilePath,
    weDisk :: Maybe FilePath,
    wePkgSet :: Bool,
    weCache :: IORef (Map (Maybe FilePath) Loaded)
  }

data Loaded
  = LoadedMissing
  | LoadedTable Table

data Reach
  = ReachActive
  | ReachWatched
  deriving (Eq, Ord, Show)

data WalkState = WalkState
  { wsFailed :: Maybe Text,
    wsIncomplete :: [Text],
    wsActive :: [(FilePath, Maybe Text)],
    wsWatched :: [(FilePath, Maybe Text)],
    wsSeen :: Map (Maybe FilePath) (Reach, Set Text),
    wsQueue :: [(Maybe FilePath, Reach, Set Text)]
  }

data HardSoft
  = Hard Text
  | Soft Text

data TargetClass
  = TActive
  | TWatched
  | TIgnore
  | TIncomplete Text

data DepSpec = DepSpec
  { dsName :: Text,
    dsPath :: Maybe FilePath,
    dsWorkspace :: Bool,
    dsOptional :: Bool,
    dsDefaultFeatures :: Maybe Bool,
    dsFeatures :: [Text]
  }

data CfgAst
  = CfgAtom Text (Maybe Text)
  | CfgNot CfgAst
  | CfgAll [CfgAst]
  | CfgAny [CfgAst]

data Fam
  = FamLinux
  | FamMacos
  | FamBsd
  | FamWindows
  | FamWasm
  deriving (Eq, Ord, Show, Enum, Bounded)

discoverStart ::
  WalkEnv ->
  Maybe FilePath ->
  Maybe FilePath ->
  IO (Either Text (Maybe (Maybe FilePath)))
discoverStart env pkg lock = do
  let candidates =
        if wePkgSet env
          then [pkg]
          else nubOrd [lock, Nothing]
  go candidates
  where
    go [] = pure (Right Nothing)
    go (p : ps) = do
      loaded <- loadToml env p
      case loaded of
        Left err -> pure (Left err)
        Right Nothing -> go ps
        Right (Just tab)
          | isVirtualWorkspace tab && not (wePkgSet env) ->
              pure $
                Left
                  "virtual Cargo workspace requires a package subdirectory"
          | isVirtualWorkspace tab ->
              pure $
                Left
                  "virtual Cargo workspace requires a package subdirectory"
          | not (hasPackageTable tab) && not (hasWorkspaceTable tab) ->
              go ps
          | not (hasPackageTable tab) ->
              go ps
          | otherwise -> pure (Right (Just p))

isVirtualWorkspace :: Table -> Bool
isVirtualWorkspace tab = hasWorkspaceTable tab && not (hasPackageTable tab)

hasPackageTable :: Table -> Bool
hasPackageTable tab =
  case tableLookup "package" tab of
    Just (Table _) -> True
    _ -> False

hasWorkspaceTable :: Table -> Bool
hasWorkspaceTable tab =
  case tableLookup "workspace" tab of
    Just (Table _) -> True
    _ -> False

walkClosure :: WalkEnv -> Maybe FilePath -> IO TagFloorResult
walkClosure env start = do
  let st0 =
        WalkState
          { wsFailed = Nothing,
            wsIncomplete = [],
            wsActive = [],
            wsWatched = [],
            wsSeen = Map.singleton start (ReachActive, Set.singleton "default"),
            wsQueue = [(start, ReachActive, Set.singleton "default")]
          }
  st <- drain env st0
  pure (finishWalk st)

drain :: WalkEnv -> WalkState -> IO WalkState
drain env st
  | isJust (wsFailed st) = pure st
  | otherwise =
      case wsQueue st of
        [] -> pure st
        ((path, reach, feats) : rest) -> do
          st' <- visitNode env st {wsQueue = rest} path reach feats
          drain env st'

visitNode ::
  WalkEnv ->
  WalkState ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  IO WalkState
visitNode env st path reach reqFeats = do
  loaded <- loadToml env path
  case loaded of
    Left err -> pure (st {wsFailed = Just err})
    Right Nothing ->
      pure (addIncomplete st ("missing Cargo.toml at " <> renderRel path))
    Right (Just tab)
      | isVirtualWorkspace tab ->
          pure
            ( addIncomplete
                st
                ("virtual workspace at " <> renderRel path)
            )
      | otherwise ->
          case tableLookup "package" tab of
            Just (Table pkg) ->
              visitPackage env st path reach reqFeats tab pkg
            Just _ ->
              pure (st {wsFailed = Just "malformed Cargo.toml"})
            Nothing ->
              pure
                ( addIncomplete
                    st
                    ("no [package] table at " <> renderRel path)
                )

visitPackage ::
  WalkEnv ->
  WalkState ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  Table ->
  Table ->
  IO WalkState
visitPackage env st path reach reqFeats tab pkg = do
  rust <- effectiveRust env path pkg
  case rust of
    Left (Hard err) -> pure (st {wsFailed = Just err})
    Left (Soft reason) -> do
      st1 <- enqueuePatches env (recordIncomplete rustSt reason) path tab
      enqueuePackageDeps env st1 path reach reqFeats tab
      where
        rustSt = recordFloor st path reach Nothing
    Right mFloor -> do
      st1 <- enqueuePatches env (recordFloor st path reach mFloor) path tab
      enqueuePackageDeps env st1 path reach reqFeats tab

recordFloor :: WalkState -> Maybe FilePath -> Reach -> Maybe Text -> WalkState
recordFloor st path reach mFloor =
  let key = relFile path
      strip = filter ((/= key) . fst)
   in case reach of
        ReachActive ->
          st
            { wsActive = (key, mFloor) : strip (wsActive st),
              wsWatched = strip (wsWatched st)
            }
        ReachWatched ->
          if any ((== key) . fst) (wsActive st)
            then st
            else st {wsWatched = (key, mFloor) : strip (wsWatched st)}

recordIncomplete :: WalkState -> Text -> WalkState
recordIncomplete = addIncomplete

addIncomplete :: WalkState -> Text -> WalkState
addIncomplete st reason = st {wsIncomplete = wsIncomplete st <> [reason]}

enqueuePatches ::
  WalkEnv ->
  WalkState ->
  Maybe FilePath ->
  Table ->
  IO WalkState
enqueuePatches env st path tab =
  case parsePatchPaths tab of
    Left reason ->
      pure (addIncomplete st (reason <> " at " <> renderRel path))
    Right rels -> foldM (enqueuePatch env path) st rels

enqueuePatch ::
  WalkEnv ->
  Maybe FilePath ->
  WalkState ->
  FilePath ->
  IO WalkState
enqueuePatch env from st rel = do
  dest <- resolveRel env from rel
  case dest of
    Left err -> pure (st {wsFailed = Just err})
    Right p ->
      pure
        ( enqueueNode
            st
            p
            ReachActive
            (Set.singleton "default")
        )

enqueuePackageDeps ::
  WalkEnv ->
  WalkState ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  Table ->
  IO WalkState
enqueuePackageDeps env st path reach reqFeats tab =
  case parseFeaturesTable tab of
    Left reason -> do
      -- Still follow non-optional path deps when features are unreadable.
      let stI = addIncomplete st (reason <> " at " <> renderRel path)
      followParsed env stI path reach Set.empty tab
    Right featMap ->
      let enabled = expandFeatures featMap reqFeats
       in followParsed env st path reach enabled tab

followParsed ::
  WalkEnv ->
  WalkState ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  Table ->
  IO WalkState
followParsed env st path reach enabled tab =
  case collectClassifiedDeps tab of
    Left reason ->
      pure (addIncomplete st (reason <> " at " <> renderRel path))
    Right classified -> do
      st1 <- foldM (followOne env path reach enabled) st classified
      -- Also resolve workspace = true using the workspace document.
      foldM (followWorkspace env path reach enabled tab) st1 classified

followOne ::
  WalkEnv ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  WalkState ->
  (TargetClass, DepSpec) ->
  IO WalkState
followOne env from parentReach enabled st (klass, spec)
  | not (depEnabled enabled spec) = pure st
  | dsWorkspace spec = pure st -- resolved in followWorkspace
  | otherwise =
      case klass of
        TIgnore -> pure st
        TIncomplete reason ->
          pure (addIncomplete st (reason <> " at " <> renderRel from))
        TActive ->
          followPath env from st spec (combineReach parentReach ReachActive) enabled
        TWatched ->
          followPath env from st spec (combineReach parentReach ReachWatched) enabled

followWorkspace ::
  WalkEnv ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  Table ->
  WalkState ->
  (TargetClass, DepSpec) ->
  IO WalkState
followWorkspace env from parentReach enabled pkgTab st (klass, spec)
  | not (dsWorkspace spec) = pure st
  | not (depEnabled enabled spec) = pure st
  | otherwise =
      case klass of
        TIgnore -> pure st
        TIncomplete reason ->
          pure (addIncomplete st (reason <> " at " <> renderRel from))
        TActive -> go (combineReach parentReach ReachActive)
        TWatched -> go (combineReach parentReach ReachWatched)
  where
    go reach = do
      ws <- findWorkspaceDoc env from pkgTab
      case ws of
        Left (Hard err) -> pure (st {wsFailed = Just err})
        Left (Soft reason) ->
          pure (addIncomplete st (reason <> " for " <> renderRel from))
        Right (wsPath, wsTab) ->
          case lookupWorkspaceDep spec wsTab of
            Left reason ->
              pure (addIncomplete st (reason <> " at " <> renderRel from))
            Right Nothing -> pure st -- registry / non-path
            Right (Just merged) ->
              followPath env wsPath st merged reach enabled

followPath ::
  WalkEnv ->
  Maybe FilePath ->
  WalkState ->
  DepSpec ->
  Reach ->
  Set Text ->
  IO WalkState
followPath env from st spec reach enabled =
  case dsPath spec of
    Nothing -> pure st
    Just rel -> do
      dest <- resolveRel env from rel
      case dest of
        Left err -> pure (st {wsFailed = Just err})
        Right p ->
          let req =
                Set.fromList (dsFeatures spec)
                  <> namespacedFeatures (dsName spec) enabled
                  <> if fromMaybe True (dsDefaultFeatures spec)
                    then Set.singleton "default"
                    else Set.empty
           in pure (enqueueNode st p reach req)

depEnabled :: Set Text -> DepSpec -> Bool
depEnabled enabled spec
  | not (dsOptional spec) = True
  | otherwise =
      let n = dsName spec
       in n `Set.member` enabled
            || ("dep:" <> n) `Set.member` enabled
            || any (isStrongNamespaced n) enabled

-- | Strong @dep/feature@ tokens enable optional path dep @dep@.
isStrongNamespaced :: Text -> Text -> Bool
isStrongNamespaced depName tok =
  (depName <> "/") `T.isPrefixOf` tok

-- | Features requested on @depName@ via @dep/feature@ or weak @dep?/feature@.
namespacedFeatures :: Text -> Set Text -> Set Text
namespacedFeatures depName enabled =
  Set.fromList
    [ feat
    | tok <- Set.toList enabled,
      Just feat <- [namespacedFeat depName tok]
    ]

namespacedFeat :: Text -> Text -> Maybe Text
namespacedFeat depName tok
  | Just rest <- T.stripPrefix (depName <> "/") tok,
    readableFeatName rest =
      Just rest
  | Just rest <- T.stripPrefix (depName <> "?/") tok,
    readableFeatName rest =
      Just rest
  | otherwise = Nothing

readableFeatName :: Text -> Bool
readableFeatName t =
  not (T.null t) && not (T.any (\c -> c == '/' || c == '?') t)

combineReach :: Reach -> Reach -> Reach
combineReach ReachWatched _ = ReachWatched
combineReach _ ReachWatched = ReachWatched
combineReach _ _ = ReachActive

enqueueNode ::
  WalkState ->
  Maybe FilePath ->
  Reach ->
  Set Text ->
  WalkState
enqueueNode st path reach feats =
  case Map.lookup path (wsSeen st) of
    Nothing ->
      st
        { wsSeen = Map.insert path (reach, feats) (wsSeen st),
          wsQueue = wsQueue st <> [(path, reach, feats)]
        }
    Just (oldR, oldF) ->
      let newR = minReach oldR reach
          newF = Set.union oldF feats
       in if newR == oldR && newF == oldF
            then st
            else
              st
                { wsSeen = Map.insert path (newR, newF) (wsSeen st),
                  wsQueue = wsQueue st <> [(path, newR, newF)]
                }

-- Active is stronger (less) than Watched for upgrade purposes.
minReach :: Reach -> Reach -> Reach
minReach ReachActive _ = ReachActive
minReach _ ReachActive = ReachActive
minReach a _ = a

finishWalk :: WalkState -> TagFloorResult
finishWalk st =
  case wsFailed st of
    Just err -> TagFloorFailed err
    Nothing ->
      case watchedRaise (wsWatched st) (wsActive st) of
        Just err -> TagFloorFailed err
        Nothing
          | not (null (wsIncomplete st)) ->
              TagFloorIncomplete (wsIncomplete st) (wsActive st)
          | otherwise ->
              TagFloorComplete
                (maxMaybeRustVersions (map snd (wsActive st)))
                (wsActive st)

watchedRaise ::
  [(FilePath, Maybe Text)] ->
  [(FilePath, Maybe Text)] ->
  Maybe Text
watchedRaise watched active =
  case [(p, v) | (p, Just v) <- watched] of
    [] -> Nothing
    (x0 : xs) ->
      let (wpath, wfloor) = foldl' maxPair x0 xs
          activeMax = maxMaybeRustVersions (map snd active)
       in case activeMax of
            Nothing -> Just (watchedErr wpath wfloor "absent")
            Just a ->
              case compareGoVersions wfloor a of
                Just GT -> Just (watchedErr wpath wfloor a)
                _ -> Nothing
  where
    maxPair (pa, va) (pb, vb) =
      case maxRustVersion va vb of
        Just m | m == vb && va /= vb -> (pb, vb)
        _ -> (pa, va)

watchedErr :: FilePath -> Text -> Text -> Text
watchedErr wpath wfloor activeFloor =
  "watched rust-version "
    <> wfloor
    <> " at "
    <> T.pack wpath
    <> " exceeds active floor "
    <> activeFloor

------------------------------------------------------------------------
-- Load / path / inheritance
------------------------------------------------------------------------

loadToml :: WalkEnv -> Maybe FilePath -> IO (Either Text (Maybe Table))
loadToml env path = do
  cache <- readIORef (weCache env)
  case Map.lookup path cache of
    Just LoadedMissing -> pure (Right Nothing)
    Just (LoadedTable t) -> pure (Right (Just t))
    Nothing -> do
      eres <- weFetch env path
      case eres of
        CargoTomlMissing -> do
          modifyIORef' (weCache env) (Map.insert path LoadedMissing)
          pure (Right Nothing)
        CargoTomlError err -> pure (Left err)
        CargoTomlBody body ->
          case parse body of
            Left _ -> pure (Left "malformed Cargo.toml")
            Right tab' -> do
              let t = forgetTableAnns tab'
              modifyIORef' (weCache env) (Map.insert path (LoadedTable t))
              pure (Right (Just t))

effectiveRust ::
  WalkEnv ->
  Maybe FilePath ->
  Table ->
  IO (Either HardSoft (Maybe Text))
effectiveRust env path pkg =
  case rustDeclInTable pkg of
    Left err -> pure (Left (Hard err))
    Right (RustDirect ver) -> pure (Right (Just ver))
    Right RustAbsent -> pure (Right Nothing)
    Right RustInherit -> do
      ws <- findWorkspaceDoc env path pkg
      pure $ case ws of
        Left e -> Left e
        Right (_, wsTab) ->
          case workspacePackageRust wsTab of
            Left err -> Left (Hard err)
            Right m -> Right m

findWorkspaceDoc ::
  WalkEnv ->
  Maybe FilePath ->
  Table ->
  IO (Either HardSoft (Maybe FilePath, Table))
findWorkspaceDoc env from pkg =
  case packageWorkspacePath pkg of
    Left err -> pure (Left (Hard err))
    Right (Just rel) -> do
      dest <- resolveRel env from rel
      case dest of
        Left err -> pure (Left (Hard err))
        Right p -> loadWorkspace env p
    Right Nothing ->
      let cands = nubOrd [weLock env, Nothing]
       in search cands
  where
    search [] =
      pure (Left (Soft ("unknown workspace document for " <> renderRel from)))
    search (p : ps) = do
      loaded <- loadToml env p
      case loaded of
        Left err -> pure (Left (Hard err))
        Right Nothing -> search ps
        Right (Just t)
          | hasWorkspaceTable t -> pure (Right (p, t))
          | otherwise -> search ps

loadWorkspace ::
  WalkEnv ->
  Maybe FilePath ->
  IO (Either HardSoft (Maybe FilePath, Table))
loadWorkspace env p = do
  loaded <- loadToml env p
  pure $ case loaded of
    Left err -> Left (Hard err)
    Right Nothing ->
      Left (Soft ("unknown workspace document for " <> renderRel p))
    Right (Just t)
      | hasWorkspaceTable t -> Right (p, t)
      | otherwise ->
          Left (Soft ("unknown workspace document for " <> renderRel p))

packageWorkspacePath :: Table -> Either Text (Maybe FilePath)
packageWorkspacePath pkg =
  case tableLookup "workspace" pkg of
    Nothing -> Right Nothing
    Just (Text p) -> Right (Just (T.unpack p))
    Just _ -> Left "malformed package.workspace in Cargo.toml"

resolveRel ::
  WalkEnv ->
  Maybe FilePath ->
  FilePath ->
  IO (Either Text (Maybe FilePath))
resolveRel env from rel
  | isAbsolute rel =
      pure (Left ("path escapes repository: " <> T.pack rel))
  | otherwise =
      case joinRel from rel of
        Left err -> pure (Left err)
        Right dest ->
          case weDisk env of
            Nothing -> pure (Right dest)
            Just root -> do
              bound <- assertUnderDisk root dest
              pure $ case bound of
                Left err -> Left err
                Right () -> Right dest

joinRel :: Maybe FilePath -> FilePath -> Either Text (Maybe FilePath)
joinRel base rel =
  let joined = case base of
        Nothing -> rel
        Just b -> b </> rel
   in collapseRel joined

collapseRel :: FilePath -> Either Text (Maybe FilePath)
collapseRel p =
  let parts = filter (`notElem` [".", ""]) (splitDirectories (normalise p))
   in go [] parts
  where
    go acc [] =
      Right $ case reverse acc of
        [] -> Nothing
        xs -> Just (joinPath xs)
    go [] (".." : _) =
      Left ("path escapes repository: " <> T.pack p)
    go (_ : as) (".." : rest) = go as rest
    go acc (x : xs) = go (x : acc) xs

assertUnderDisk :: FilePath -> Maybe FilePath -> IO (Either Text ())
assertUnderDisk root rel = do
  let absPath = case rel of
        Nothing -> root
        Just p -> root </> p
  exists <- doesPathExist absPath
  if not exists
    then pure (Right ())
    else do
      cRoot <- canonicalizePath root
      cAbs <- canonicalizePath absPath
      let rootSep = addTrailingPathSeparator cRoot
      if cAbs == cRoot || rootSep `isPrefixOf` cAbs
        then pure (Right ())
        else
          pure
            ( Left
                ("path escapes repository: " <> T.pack (relFile rel))
            )

relFile :: Maybe FilePath -> FilePath
relFile Nothing = "Cargo.toml"
relFile (Just p) = p </> "Cargo.toml"

renderRel :: Maybe FilePath -> Text
renderRel = T.pack . relFile

------------------------------------------------------------------------
-- Features, deps, patches, targets
------------------------------------------------------------------------

parseFeaturesTable :: Table -> Either Text (Map Text [Text])
parseFeaturesTable tab =
  case tableLookup "features" tab of
    Nothing -> Right Map.empty
    Just (Table ft) -> foldM addFeat Map.empty (tableAssoc ft)
    Just _ -> Left "unreadable feature syntax"
  where
    addFeat m (k, v) = do
      xs <- parseFeatureList v
      pure (Map.insert k xs m)

parseFeatureList :: Value -> Either Text [Text]
parseFeatureList = \case
  List xs -> mapM parseFeatItem xs
  _ -> Left "unreadable feature syntax"

parseFeatItem :: Value -> Either Text Text
parseFeatItem = \case
  Text t
    | readableFeatureToken t -> Right t
    | otherwise -> Left "unreadable feature syntax"
  _ -> Left "unreadable feature syntax"

-- | Local feature, @dep:name@, @name/feature@, or weak @name?/feature@.
-- Weak @dep:name?@ stays unreadable.
readableFeatureToken :: Text -> Bool
readableFeatureToken t
  | T.null t = False
  | otherwise =
      case T.break (== '/') t of
        (pre, rest)
          | not (T.null rest) ->
              let feat = T.drop 1 rest
                  crate =
                    if "?" `T.isSuffixOf` pre
                      then T.dropEnd 1 pre
                      else pre
               in readableCrateName crate && readableFeatName feat
          | T.any (== '?') t -> False
          | otherwise ->
              case T.stripPrefix "dep:" t of
                Just n -> readableCrateName n
                Nothing -> readableFeatName t

readableCrateName :: Text -> Bool
readableCrateName t =
  not (T.null t) && not (T.any (\c -> c == '/' || c == '?') t)

expandFeatures :: Map Text [Text] -> Set Text -> Set Text
expandFeatures featMap = go Set.empty
  where
    go seen want
      | Set.null want = seen
      | otherwise =
          let (x, rest) = Set.deleteFindMin want
           in if x `Set.member` seen
                then go seen rest
                else
                  let extra = Map.findWithDefault [] x featMap
                   in go
                        (Set.insert x seen)
                        (Set.union rest (Set.fromList extra))

collectClassifiedDeps :: Table -> Either Text [(TargetClass, DepSpec)]
collectClassifiedDeps tab = do
  rootDeps <- sectionDeps TActive tab
  targets <- parseTargetTables tab
  nested <- concat <$> mapM (uncurry sectionDeps) targets
  pure (rootDeps <> nested)

sectionDeps :: TargetClass -> Table -> Either Text [(TargetClass, DepSpec)]
sectionDeps klass tab = do
  d1 <- parseDepSection "dependencies" tab
  d2 <- parseDepSection "build-dependencies" tab
  pure [(klass, s) | s <- d1 <> d2]

parseDepSection :: Text -> Table -> Either Text [DepSpec]
parseDepSection key tab =
  case tableLookup key tab of
    Nothing -> Right []
    Just (Table deps) -> mapM (uncurry parseDepSpec) (tableAssoc deps)
    Just _ -> Left "unreadable dependency syntax"

parseDepSpec :: Text -> Value -> Either Text DepSpec
parseDepSpec name = \case
  Text _ -> Right (registrySpec name)
  Table t -> parseDepTable name t
  _ -> Left "unreadable dependency syntax"

registrySpec :: Text -> DepSpec
registrySpec name =
  DepSpec
    { dsName = name,
      dsPath = Nothing,
      dsWorkspace = False,
      dsOptional = False,
      dsDefaultFeatures = Just True,
      dsFeatures = []
    }

parseDepTable :: Text -> Table -> Either Text DepSpec
parseDepTable name t = do
  feats <- case tableLookup "features" t of
    Nothing -> Right []
    Just v -> parseFeatureList v
  mPath <- case tableLookup "path" t of
    Nothing -> Right Nothing
    Just (Text p) -> Right (Just (T.unpack p))
    Just _ -> Left "unreadable dependency syntax"
  ws <- case tableLookup "workspace" t of
    Nothing -> Right False
    Just (Bool b) -> Right b
    Just _ -> Left "unreadable dependency syntax"
  optional <- case tableLookup "optional" t of
    Nothing -> Right False
    Just (Bool b) -> Right b
    Just _ -> Left "unreadable dependency syntax"
  defF <- case tableLookup "default-features" t of
    Nothing -> Right Nothing
    Just (Bool b) -> Right (Just b)
    Just _ -> Left "unreadable dependency syntax"
  pure
    DepSpec
      { dsName = name,
        dsPath = mPath,
        dsWorkspace = ws,
        dsOptional = optional,
        dsDefaultFeatures = defF,
        dsFeatures = feats
      }

lookupWorkspaceDep :: DepSpec -> Table -> Either Text (Maybe DepSpec)
lookupWorkspaceDep spec wsTab =
  case tableLookup "workspace" wsTab of
    Just (Table ws) ->
      case tableLookup "dependencies" ws of
        Nothing -> Right Nothing
        Just (Table deps) ->
          case tableLookup (dsName spec) deps of
            Nothing -> Right Nothing
            Just val -> do
              wsSpec <- parseDepSpec (dsName spec) val
              pure (Just (mergeWorkspaceDep spec wsSpec))
        Just _ -> Left "unreadable workspace.dependencies"
    _ -> Right Nothing

mergeWorkspaceDep :: DepSpec -> DepSpec -> DepSpec
mergeWorkspaceDep line ws =
  ws
    { dsOptional = dsOptional line || dsOptional ws,
      dsDefaultFeatures = dsDefaultFeatures line <|> dsDefaultFeatures ws,
      dsFeatures = nubOrd (dsFeatures ws <> dsFeatures line)
    }

parsePatchPaths :: Table -> Either Text [FilePath]
parsePatchPaths tab =
  case tableLookup "patch" tab of
    Nothing -> Right []
    Just (Table pt) -> concat <$> mapM patchGroup (tableAssoc pt)
    Just _ -> Left "unreadable patch table"
  where
    patchGroup (_, v) =
      case v of
        Table inner -> catMaybes <$> mapM patchEntry (tableAssoc inner)
        _ -> Left "unreadable patch table"
    patchEntry (_, v) =
      case depPathOf v of
        Left err -> Left err
        Right mp -> Right mp

depPathOf :: Value -> Either Text (Maybe FilePath)
depPathOf = \case
  Table t ->
    case tableLookup "path" t of
      Nothing -> Right Nothing
      Just (Text p) -> Right (Just (T.unpack p))
      Just _ -> Left "unreadable patch table"
  _ -> Right Nothing

parseTargetTables :: Table -> Either Text [(TargetClass, Table)]
parseTargetTables tab =
  case tableLookup "target" tab of
    Nothing -> Right []
    Just (Table tt) -> mapM oneTarget (tableAssoc tt)
    Just _ -> Left "unreadable target table"
  where
    oneTarget (k, v) =
      case v of
        Table inner -> Right (classifyTargetKey k, inner)
        _ -> Left "unreadable target table"

classifyTargetKey :: Text -> TargetClass
classifyTargetKey raw =
  let k = T.strip raw
   in if "cfg(" `T.isPrefixOf` k
        then case parseCfgKey k of
          Nothing -> TIncomplete ("unparsed cfg " <> k)
          Just ast -> evalCfgClass ast k
        else classifyTriple k

classifyTriple :: Text -> TargetClass
classifyTriple k
  | isWindows || isWasm = TIgnore
  | isApple || isBsd = TWatched
  | "linux" `T.isInfixOf` t = TActive
  | otherwise = TIncomplete ("unparsed target " <> k)
  where
    t = T.toLower k
    hasAny = any (`T.isInfixOf` t)
    isWindows =
      hasAny ["pc-windows", "-windows-", "win32"]
        || ("windows" `T.isInfixOf` t && "pc-" `T.isInfixOf` t)
    isWasm = hasAny ["wasm32", "wasm64", "wasi"]
    isApple =
      hasAny
        ["apple-darwin", "apple-ios", "apple-tvos", "apple-watchos"]
    isBsd = hasAny ["freebsd", "netbsd", "openbsd", "dragonfly"]

parseCfgKey :: Text -> Maybe CfgAst
parseCfgKey src = do
  rest0 <- T.stripPrefix "cfg(" (T.strip src)
  (ast, rest1) <- parseCfgExpr rest0
  rest2 <- T.stripPrefix ")" (skipSp rest1)
  if T.null (skipSp rest2) then Just ast else Nothing

parseCfgExpr :: Text -> Maybe (CfgAst, Text)
parseCfgExpr t0 =
  let t = skipSp t0
   in case parseIdent t of
        Just (name, t1)
          | name == "not" -> do
              t2 <- expectTok "(" t1
              (inner, t3) <- parseCfgExpr t2
              t4 <- expectTok ")" t3
              Just (CfgNot inner, t4)
          | name == "all" -> parseCfgList CfgAll t1
          | name == "any" -> parseCfgList CfgAny t1
          | otherwise ->
              let t2 = skipSp t1
               in case T.uncons t2 of
                    Just ('=', t3) -> do
                      (val, t4) <- parseQuoted (skipSp t3)
                      Just (CfgAtom name (Just val), t4)
                    _ -> Just (CfgAtom name Nothing, t2)
        Nothing -> Nothing

parseCfgList :: ([CfgAst] -> CfgAst) -> Text -> Maybe (CfgAst, Text)
parseCfgList ctor t1 = do
  t2 <- expectTok "(" t1
  (xs, t3) <- parseCommaSep t2
  t4 <- expectTok ")" t3
  Just (ctor xs, t4)

parseCommaSep :: Text -> Maybe ([CfgAst], Text)
parseCommaSep t0 =
  let t = skipSp t0
   in case T.uncons t of
        Just (')', _) -> Just ([], t)
        _ -> do
          (x, t1) <- parseCfgExpr t
          go [x] t1
  where
    go acc t1 =
      let t = skipSp t1
       in case T.uncons t of
            Just (',', t2) -> do
              (x, t3) <- parseCfgExpr t2
              go (acc <> [x]) t3
            _ -> Just (acc, t1)

parseIdent :: Text -> Maybe (Text, Text)
parseIdent t0 =
  let t = skipSp t0
      (tok, rest) = T.span identChar t
   in case T.uncons tok of
        Just (c, _)
          | isAlpha c || c == '_' -> Just (tok, rest)
        _ -> Nothing
  where
    identChar c = isAlphaNum c || c == '_'

parseQuoted :: Text -> Maybe (Text, Text)
parseQuoted t0 = do
  t1 <- T.stripPrefix "\"" (skipSp t0)
  let (val, rest) = T.break (== '"') t1
  rest' <- T.stripPrefix "\"" rest
  Just (val, rest')

expectTok :: Text -> Text -> Maybe Text
expectTok tok t = T.stripPrefix tok (skipSp t)

skipSp :: Text -> Text
skipSp = T.dropWhile (\c -> c == ' ' || c == '\t')

evalCfgClass :: CfgAst -> Text -> TargetClass
evalCfgClass ast raw =
  case traverse (cfgHolds ast) [minBound .. maxBound] of
    Nothing -> TIncomplete ("unparsed cfg " <> raw)
    Just holds ->
      let matched = [f | (f, True) <- zip [minBound .. maxBound] holds]
       in if FamLinux `elem` matched
            then TActive
            else
              if any (`elem` matched) [FamMacos, FamBsd]
                then TWatched
                else TIgnore

cfgHolds :: CfgAst -> Fam -> Maybe Bool
cfgHolds ast fam =
  case ast of
    CfgAtom name mVal -> atomHolds name mVal fam
    CfgNot inner -> fmap not (cfgHolds inner fam)
    CfgAll xs -> fmap and (traverse (`cfgHolds` fam) xs)
    CfgAny xs -> fmap or (traverse (`cfgHolds` fam) xs)

atomHolds :: Text -> Maybe Text -> Fam -> Maybe Bool
atomHolds name mVal fam =
  case (name, fmap T.toLower mVal) of
    ("windows", Nothing) -> Just (fam == FamWindows)
    ("unix", Nothing) ->
      Just (fam `elem` [FamLinux, FamMacos, FamBsd])
    ("target_os", Just "linux") -> Just (fam == FamLinux)
    ("target_os", Just "macos") -> Just (fam == FamMacos)
    ("target_os", Just "macosx") -> Just (fam == FamMacos)
    ("target_os", Just "darwin") -> Just (fam == FamMacos)
    ("target_os", Just "freebsd") -> Just (fam == FamBsd)
    ("target_os", Just "netbsd") -> Just (fam == FamBsd)
    ("target_os", Just "openbsd") -> Just (fam == FamBsd)
    ("target_os", Just "dragonfly") -> Just (fam == FamBsd)
    ("target_os", Just "windows") -> Just (fam == FamWindows)
    ("target_os", Just "win32") -> Just (fam == FamWindows)
    -- Known predicate, OS we do not model (android, ios, fuchsia, …):
    -- does not hold for linux/macos/bsd/windows/wasm. Codex tui uses
    -- cfg(not(target_os = "android")); treating that as unparsed made the
    -- whole tag-floor walk incomplete and skipped rust-toolchain.toml.
    ("target_os", Just _) -> Just False
    ("target_family", Just "unix") ->
      Just (fam `elem` [FamLinux, FamMacos, FamBsd])
    ("target_family", Just "windows") -> Just (fam == FamWindows)
    ("target_family", Just "wasm") -> Just (fam == FamWasm)
    ("target_family", Just _) -> Just False
    ("target_arch", Just "wasm32") -> Just (fam == FamWasm)
    ("target_arch", Just "wasm64") -> Just (fam == FamWasm)
    _ -> Nothing

-- | Dependency names listed only in windows-only (or wasm-only) target tables.
-- | Dotted @channel@ from @rust-toolchain.toml@. @stable@/@nightly@ and
-- missing channel are explicit absence (@Right Nothing@). Unparseable TOML
-- is @Left@.
parseRustToolchainChannel :: Text -> Either Text (Maybe Text)
parseRustToolchainChannel content =
  case parse content of
    Left _ -> Left "malformed rust-toolchain.toml"
    Right tab' -> channelFromTable (forgetTableAnns tab')

channelFromTable :: Table -> Either Text (Maybe Text)
channelFromTable tab =
  case tableLookup "toolchain" tab of
    Nothing -> Right Nothing
    Just (Table t) ->
      case tableLookup "channel" t of
        Nothing -> Right Nothing
        Just (Text raw) ->
          let stripped = T.strip raw
              unv = fromMaybe stripped (T.stripPrefix "v" stripped)
           in Right (normalizeRustVersion unv)
        Just _ -> Left "malformed rust-toolchain.toml channel"
    Just _ -> Left "malformed rust-toolchain.toml"

-- | When the active set supplied no rust-version, read lock-root then
-- repository-root @rust-toolchain.toml@ via @fetch@.
applyRustToolchainFloor ::
  Maybe FilePath ->
  (Maybe FilePath -> IO CargoTomlFetch) ->
  Maybe Text ->
  IO (Either Text (Maybe Text))
applyRustToolchainFloor mLock fetch mFloor =
  case mFloor of
    Just ver -> pure (Right (Just ver))
    Nothing -> go (nubOrd [mLock, Nothing])
  where
    go [] = pure (Right Nothing)
    go (p : ps) = do
      eres <- fetch p
      case eres of
        CargoTomlMissing -> go ps
        CargoTomlError err -> pure (Left err)
        CargoTomlBody body ->
          case parseRustToolchainChannel body of
            Left err -> pure (Left err)
            Right (Just ver) -> pure (Right (Just ver))
            Right Nothing ->
              -- File exists but channel is not a dotted version.
              pure (Right Nothing)

windowsOnlyDepNames :: Text -> Either Text [Text]
windowsOnlyDepNames content =
  case parse content of
    Left _ -> Left "malformed Cargo.toml"
    Right tab' ->
      case collectClassifiedDeps (forgetTableAnns tab') of
        Left err -> Left err
        Right classified ->
          Right (nubOrd [dsName spec | (TIgnore, spec) <- classified])

------------------------------------------------------------------------
-- Filesystem fetch (clone harvest)
------------------------------------------------------------------------

-- | Read @Cargo.toml@ under a clone/workspace root.
fetchCargoTomlFromDir :: FilePath -> Maybe FilePath -> IO CargoTomlFetch
fetchCargoTomlFromDir root = fetchNamedFromDir root "Cargo.toml"

-- | Read @rust-toolchain.toml@ under a clone/workspace root.
fetchRustToolchainFromDir :: FilePath -> Maybe FilePath -> IO CargoTomlFetch
fetchRustToolchainFromDir root = fetchNamedFromDir root "rust-toolchain.toml"

fetchNamedFromDir :: FilePath -> FilePath -> Maybe FilePath -> IO CargoTomlFetch
fetchNamedFromDir root name mSub = do
  let path = case mSub of
        Nothing -> root </> name
        Just sub -> root </> sub </> name
  exists <- doesFileExist path
  if not exists
    then pure CargoTomlMissing
    else CargoTomlBody <$> TIO.readFile path
