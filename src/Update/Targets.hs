{-# LANGUAGE OverloadedStrings #-}

module Update.Targets
  ( TargetError (..),
    targetErrorMessage,
    resolveTargets,
    resolveTargetToken,
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.Either (lefts, rights)
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
