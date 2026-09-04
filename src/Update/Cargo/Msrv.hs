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
  )
where

import Control.Applicative ((<|>))
import Data.Containers.ListUtils (nubOrd)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Toml (Table, Value, forgetTableAnns, parse)
import Toml.Semantics.Types
  ( Table' (MkTable),
    pattern Bool,
    pattern Table,
    pattern Text,
  )
import Update.Go.Version (compareGoVersions, parseGoVersionToken)
import Update.TextUtil (stripSurroundingQuotes)

-- | Floor-policy/parser version stored with Cargo deps-plan snapshots.
cargoFloorPolicyVersion :: Text
cargoFloorPolicyVersion = "1"

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
  case tableLookup "rust-version" tab of
    Nothing -> Right Nothing
    Just val -> interpretRustVersionValue val

interpretRustVersionValue :: Value -> Either Text (Maybe Text)
interpretRustVersionValue = \case
  Text raw ->
    case normalizeRustVersion raw of
      Just ver -> Right (Just ver)
      Nothing -> Left "malformed rust-version in Cargo.toml"
  Table inner ->
    case tableLookup "workspace" inner of
      Just (Bool _) -> Right Nothing
      Just _ -> Left "malformed rust-version in Cargo.toml"
      Nothing -> Left "malformed rust-version in Cargo.toml"
  _ -> Left "malformed rust-version in Cargo.toml"

tableLookup :: Text -> Table -> Maybe Value
tableLookup key (MkTable m) = snd <$> Map.lookup key m

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
