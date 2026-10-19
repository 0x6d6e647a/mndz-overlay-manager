{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Parser for committed @uv.lock@ documents (version 1).
--
-- Does not run @uv lock@. A document this module cannot read is an error
-- for the caller to turn into a package hard-fail.
module Update.Uv.Lock
  ( UvLock (..),
    UvPackage (..),
    UvSource (..),
    UvEdge (..),
    UvFile (..),
    parseUvLock,
    parseUvLockFile,
    parsePyprojectRequiresPython,
    lockRequiresPython,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import Toml (Table, Value, forgetTableAnns, parse)
import Toml.Semantics.Types
  ( Table' (MkTable),
    pattern Integer,
    pattern List,
    pattern Table,
    pattern Text,
  )

-- | One locked distribution.
data UvPackage = UvPackage
  { upName :: Text,
    upVersion :: Text,
    upSource :: UvSource,
    upDependencies :: [UvEdge],
    upDevDependencies :: Map Text [UvEdge],
    upSdist :: Maybe UvFile,
    upWheels :: [UvFile]
  }
  deriving (Eq, Show)

data UvSource
  = UvRegistry Text
  | UvEditable Text
  | UvGit Text Text
  | UvPath Text
  | UvSourceOther
  deriving (Eq, Show)

-- | A dependency edge. 'Nothing' marker is unconditional.
data UvEdge = UvEdge
  { ueName :: Text,
    ueMarker :: Maybe Text,
    ueExtra :: Maybe Text
  }
  deriving (Eq, Show)

data UvFile = UvFile
  { ufUrl :: Text,
    ufHash :: Text
  }
  deriving (Eq, Show)

data UvLock = UvLock
  { ulVersion :: Int,
    ulRevision :: Maybe Int,
    ulRequiresPython :: Maybe Text,
    ulPackages :: [UvPackage]
  }
  deriving (Eq, Show)

lockRequiresPython :: UvLock -> Maybe Text
lockRequiresPython = ulRequiresPython

-- | Read and parse a lock file. A missing path is a hard error.
parseUvLockFile :: FilePath -> IO (Either Text UvLock)
parseUvLockFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("uv.lock is missing: " <> T.pack path))
    else parseUvLock <$> TIO.readFile path

-- | Parse a version-1 lock. Revisions 2 and 3 are accepted, as is any other
-- revision that still uses the package-table shape.
parseUvLock :: Text -> Either Text UvLock
parseUvLock body =
  case parse body of
    Left _ -> Left "unreadable uv.lock"
    Right tab' -> lockFromTable (forgetTableAnns tab')

lockFromTable :: Table -> Either Text UvLock
lockFromTable tab = do
  ver <- case tableLookup "version" tab of
    Just (Integer n)
      | n >= 1 && n <= fromIntegral (maxBound :: Int) ->
          Right (fromIntegral n)
    Just (Integer _) -> Left "unsupported uv.lock version"
    _ -> Left "uv.lock is missing version"
  whenLeft (ver /= 1) (Left "unsupported uv.lock version")
  let rev = case tableLookup "revision" tab of
        Just (Integer n)
          | n >= 0 && n <= fromIntegral (maxBound :: Int) ->
              Just (fromIntegral n)
        _ -> Nothing
      req = case tableLookup "requires-python" tab of
        Just (Text t) -> Just t
        _ -> Nothing
  pkgs <- case tableLookup "package" tab of
    Nothing -> Right []
    Just (List vs) -> mapM parsePackage vs
    Just _ -> Left "uv.lock package array is unreadable"
  pure
    UvLock
      { ulVersion = ver,
        ulRevision = rev,
        ulRequiresPython = req,
        ulPackages = pkgs
      }

whenLeft :: Bool -> Either Text () -> Either Text ()
whenLeft True err = err
whenLeft False _ = Right ()

parsePackage :: Value -> Either Text UvPackage
parsePackage (Table tab) = do
  name <- requireText "package name" (tableLookup "name" tab)
  ver <- requireText "package version" (tableLookup "version" tab)
  let source = case tableLookup "source" tab of
        Just (Table s) -> parseSource s
        _ -> UvSourceOther
  deps <- parseEdgeList (tableLookup "dependencies" tab)
  dev <- parseDevGroups (tableLookup "dev-dependencies" tab)
  sdist <- parseMaybeFile (tableLookup "sdist" tab)
  wheels <- parseFileList (tableLookup "wheels" tab)
  pure
    UvPackage
      { upName = name,
        upVersion = ver,
        upSource = source,
        upDependencies = deps,
        upDevDependencies = dev,
        upSdist = sdist,
        upWheels = wheels
      }
parsePackage _ = Left "uv.lock package entry is not a table"

parseSource :: Table -> UvSource
parseSource tab =
  case (tableLookup "registry" tab, tableLookup "git" tab, tableLookup "path" tab, tableLookup "editable" tab) of
    (Just (Text url), _, _, _) -> UvRegistry url
    (_, Just (Text url), _, _) ->
      case tableLookup "rev" tab of
        Just (Text rev) -> UvGit url rev
        _ -> UvGit url ""
    (_, _, Just (Text p), _) -> UvPath p
    (_, _, _, Just (Text p)) -> UvEditable p
    _ -> UvSourceOther

parseDevGroups :: Maybe Value -> Either Text (Map Text [UvEdge])
parseDevGroups Nothing = Right Map.empty
parseDevGroups (Just (Table tab)) =
  Map.traverseWithKey (\_ v -> parseEdgeList (Just v)) (tableMap tab)
parseDevGroups (Just _) = Left "uv.lock dev-dependencies is unreadable"

parseEdgeList :: Maybe Value -> Either Text [UvEdge]
parseEdgeList Nothing = Right []
parseEdgeList (Just (List vs)) = mapM parseEdge vs
parseEdgeList (Just _) = Left "uv.lock dependency list is unreadable"

parseEdge :: Value -> Either Text UvEdge
parseEdge (Text name) =
  Right UvEdge {ueName = name, ueMarker = Nothing, ueExtra = Nothing}
parseEdge (Table tab) = do
  name <- requireText "dependency name" (tableLookup "name" tab)
  let marker = case tableLookup "marker" tab of
        Just (Text t) -> Just t
        _ -> Nothing
      extra = case tableLookup "extra" tab of
        Just (Text t) -> Just t
        _ -> Nothing
  pure UvEdge {ueName = name, ueMarker = marker, ueExtra = extra}
parseEdge _ = Left "uv.lock dependency edge is unreadable"

parseMaybeFile :: Maybe Value -> Either Text (Maybe UvFile)
parseMaybeFile Nothing = Right Nothing
parseMaybeFile (Just v) = Just <$> parseFile v

parseFileList :: Maybe Value -> Either Text [UvFile]
parseFileList Nothing = Right []
parseFileList (Just (List vs)) = mapM parseFile vs
parseFileList (Just _) = Left "uv.lock file list is unreadable"

parseFile :: Value -> Either Text UvFile
parseFile (Table tab) = do
  url <- requireText "distribution url" (tableLookup "url" tab)
  hash <- requireText "distribution hash" (tableLookup "hash" tab)
  pure UvFile {ufUrl = url, ufHash = hash}
parseFile _ = Left "uv.lock distribution file is unreadable"

requireText :: Text -> Maybe Value -> Either Text Text
requireText label = \case
  Just (Text t) | not (T.null t) -> Right t
  _ -> Left ("uv.lock is missing " <> label)

-- | @[project].requires-python@ from a pyproject document.
parsePyprojectRequiresPython :: Text -> Either Text (Maybe Text)
parsePyprojectRequiresPython body =
  case parse body of
    Left _ -> Left "unreadable pyproject.toml"
    Right tab' ->
      case tableLookup "project" (forgetTableAnns tab') of
        Just (Table proj) ->
          case tableLookup "requires-python" proj of
            Just (Text t) -> Right (Just t)
            _ -> Right Nothing
        _ -> Right Nothing

tableLookup :: Text -> Table -> Maybe Value
tableLookup key (MkTable m) = snd <$> Map.lookup key m

tableMap :: Table -> Map Text Value
tableMap (MkTable m) = fmap snd m
