{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Parser for committed @pdm.lock@ documents.
--
-- Does not run @pdm lock@ or @pdm export@. A document this module cannot
-- read, or a missing lock file, is an error for the caller to turn into
-- a package hard-fail.
module Update.Pdm.Lock
  ( PdmLock (..),
    PdmPackage (..),
    PdmFile (..),
    parsePdmLock,
    parsePdmLockFile,
    pdmLockRequiresPython,
  )
where

import Control.Applicative ((<|>))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import Toml (Table, Value, forgetTableAnns, parse)
import Toml.Semantics.Types
  ( Table' (MkTable),
    pattern List,
    pattern Table,
    pattern Text,
  )

-- | One file recorded for a locked distribution. @pfUrl@ is optional:
-- cross-platform PDM locks store a filename and a hash and no download URL.
data PdmFile = PdmFile
  { pfFile :: Text,
    pfHash :: Text,
    pfUrl :: Maybe Text
  }
  deriving (Eq, Show)

-- | One locked distribution. @ppGroups@ is empty when the lock records no
-- per-distribution group membership. @ppExtras@ is empty for the base entry.
data PdmPackage = PdmPackage
  { ppName :: Text,
    ppVersion :: Text,
    ppRequiresPython :: Maybe Text,
    ppExtras :: [Text],
    ppGroups :: [Text],
    ppDependencies :: [Text],
    ppFiles :: [PdmFile]
  }
  deriving (Eq, Show)

data PdmLock = PdmLock
  { plRequiresPython :: Maybe Text,
    plPackages :: [PdmPackage]
  }
  deriving (Eq, Show)

pdmLockRequiresPython :: PdmLock -> Maybe Text
pdmLockRequiresPython = plRequiresPython

-- | Read and parse a lock file. A missing path is a hard error.
parsePdmLockFile :: FilePath -> IO (Either Text PdmLock)
parsePdmLockFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("pdm.lock is missing: " <> T.pack path))
    else parsePdmLock <$> TIO.readFile path

-- | Parse a lock. Entries may omit a download URL and group membership.
parsePdmLock :: Text -> Either Text PdmLock
parsePdmLock body =
  case parse body of
    Left _ -> Left "unreadable pdm.lock"
    Right tab' -> lockFromTable (forgetTableAnns tab')

lockFromTable :: Table -> Either Text PdmLock
lockFromTable tab = do
  let metaReq = case tableLookup "metadata" tab of
        Just (Table meta) -> textField "requires_python" meta <|> textField "requires-python" meta
        _ -> Nothing
      topReq = textField "requires-python" tab <|> textField "requires_python" tab
  pkgs <- case tableLookup "package" tab of
    Nothing -> Right []
    Just (List vs) -> mapM parsePackage vs
    Just _ -> Left "unreadable pdm.lock"
  pure
    PdmLock
      { plRequiresPython = metaReq <|> topReq,
        plPackages = pkgs
      }

parsePackage :: Value -> Either Text PdmPackage
parsePackage (Table tab) = do
  name <- requireText "package name" (tableLookup "name" tab)
  ver <- requireText "package version" (tableLookup "version" tab)
  files <- parseFileList (tableLookup "files" tab)
  extras <- parseTextList (tableLookup "extras" tab)
  groups <- parseTextList (tableLookup "groups" tab)
  deps <- parseTextList (tableLookup "dependencies" tab)
  pure
    PdmPackage
      { ppName = name,
        ppVersion = ver,
        ppRequiresPython = textField "requires_python" tab <|> textField "requires-python" tab,
        ppExtras = extras,
        ppGroups = groups,
        ppDependencies = deps,
        ppFiles = files
      }
parsePackage _ = Left "unreadable pdm.lock"

parseFileList :: Maybe Value -> Either Text [PdmFile]
parseFileList Nothing = Right []
parseFileList (Just (List vs)) = mapM parseFile vs
parseFileList (Just _) = Left "unreadable pdm.lock"

parseFile :: Value -> Either Text PdmFile
parseFile (Table tab) = do
  file <- requireText "distribution filename" (tableLookup "file" tab)
  hash <- requireText "distribution hash" (tableLookup "hash" tab)
  let url = textField "url" tab
  pure PdmFile {pfFile = file, pfHash = hash, pfUrl = url}
parseFile _ = Left "unreadable pdm.lock"

textField :: Text -> Table -> Maybe Text
textField key tab =
  case tableLookup key tab of
    Just (Text t) | not (T.null (T.strip t)) -> Just t
    _ -> Nothing

-- | String list. A missing key is empty. A non-string element is unreadable.
parseTextList :: Maybe Value -> Either Text [Text]
parseTextList Nothing = Right []
parseTextList (Just (List vs)) = mapM one vs
  where
    one (Text t) = Right t
    one _ = Left "unreadable pdm.lock"
parseTextList (Just _) = Left "unreadable pdm.lock"

requireText :: Text -> Maybe Value -> Either Text Text
requireText label = \case
  Just (Text t) | not (T.null (T.strip t)) -> Right t
  _ -> Left ("unreadable pdm.lock: missing " <> label)

tableLookup :: Text -> Table -> Maybe Value
tableLookup key (MkTable m) = snd <$> Map.lookup key m
