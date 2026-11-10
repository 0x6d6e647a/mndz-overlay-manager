{-# LANGUAGE OverloadedStrings #-}

module Update.Targets
  ( TargetError (..),
    PackageSelection (..),
    targetErrorMessage,
    resolveTargets,
    resolveTargetToken,
    selectExcluding,
    exclusionWarning,
    emptySelectionError,
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.Either (lefts, rights)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Update.Check (PackageEntry (..))
import Update.Types (PackageKey (..), packageKeyText, splitPackageKey)

data TargetError
  = AmbiguousPackage Text [PackageKey]
  | UnknownPackage Text
  deriving (Eq, Show)

targetErrorMessage :: TargetError -> Text
targetErrorMessage = \case
  AmbiguousPackage name keys ->
    "ambiguous package name "
      <> name
      <> "; matches: "
      <> T.intercalate ", " (map packageKeyText keys)
  UnknownPackage tok ->
    "unknown package target: " <> tok

-- | Resolve CLI tokens to package keys present in the inventory.
-- Empty token list means \"all inventory keys\" (caller filters outdated).
resolveTargets ::
  [PackageEntry] ->
  [Text] ->
  Either [TargetError] [PackageKey]
resolveTargets entries tokens =
  case tokens of
    [] -> Right (map peKey entries)
    _ ->
      let results = map (resolveTargetToken entries) tokens
          errs = lefts results
          keys = nubOrd (rights results)
       in if null errs then Right keys else Left errs

-- | Resolve one @category/package@ or bare @package@ token.
resolveTargetToken :: [PackageEntry] -> Text -> Either TargetError PackageKey
resolveTargetToken entries token
  | T.isInfixOf "/" token =
      let key = PackageKey token
       in if key `elem` inventoryKeys
            then Right key
            else Left (UnknownPackage token)
  | otherwise =
      case matches of
        [k] -> Right k
        [] -> Left (UnknownPackage token)
        ks -> Left (AmbiguousPackage token ks)
  where
    inventoryKeys = map peKey entries
    matches =
      [ peKey e
      | e <- entries,
        Just (_, pn) <- [splitPackageKey (peKey e)],
        pn == token
      ]

data PackageSelection = PackageSelection
  { selectedKeys :: [PackageKey],
    removedKeys :: [PackageKey]
  }
  deriving (Eq, Show)

-- | Base keys minus exclusions.
--
-- An empty positional list is every inventory key, in entry order. An empty
-- exclude list removes nothing (it is not "all keys"). Errors from either
-- side are returned together and nothing is subtracted. 'selectedKeys' keeps
-- base order. 'removedKeys' is the excluded base keys in entry order.
selectExcluding ::
  [PackageEntry] ->
  [Text] ->
  [Text] ->
  Either [TargetError] PackageSelection
selectExcluding entries positionals excludes =
  case (resolveTargets entries positionals, resolveExcludeTokens entries excludes) of
    (Left posErrs, Left exErrs) -> Left (posErrs <> exErrs)
    (Left posErrs, Right _) -> Left posErrs
    (Right _, Left exErrs) -> Left exErrs
    (Right base, Right excludeKeys) ->
      let excludeSet = Set.fromList excludeKeys
          baseSet = Set.fromList base
       in Right
            PackageSelection
              { selectedKeys = filter (`Set.notMember` excludeSet) base,
                removedKeys =
                  nubOrd
                    [ key
                    | e <- entries,
                      let key = peKey e,
                      key `Set.member` baseSet,
                      key `Set.member` excludeSet
                    ]
              }
  where
    -- resolveTargets treats [] as every inventory key. Exclusions do not.
    resolveExcludeTokens _ [] = Right []
    resolveExcludeTokens inv tokens = resolveTargets inv tokens

-- | One warning for a non-empty removal. One key is @excluding <key>@;
-- several are @excluding <N> packages: <key>, <key>@ in the given order.
exclusionWarning :: [PackageKey] -> Maybe Text
exclusionWarning = \case
  [] -> Nothing
  [key] -> Just ("excluding " <> packageKeyText key)
  keys ->
    Just
      ( "excluding "
          <> T.pack (show (length keys))
          <> " packages: "
          <> joinKeys keys
      )

-- | Empty selection after a removal. Names the removed keys in the given order.
emptySelectionError :: [PackageKey] -> Text
emptySelectionError keys =
  "exclusions removed every selected package: " <> joinKeys keys

joinKeys :: [PackageKey] -> Text
joinKeys keys = T.intercalate ", " (map packageKeyText keys)
