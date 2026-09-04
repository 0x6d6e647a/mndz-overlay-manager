{-# LANGUAGE OverloadedStrings #-}

-- | Exact Manifest DIST record selection. A required basename matches only
-- when the first token is exactly DIST and the second token is exactly that
-- basename. Conflicting duplicate exact records fail rather than picking one.
module Update.Manifest.Dist
  ( ManifestDistRecord (..),
    DistLookup (..),
    parseExactDistRecords,
    lookupExactDist,
    manifestHasExactDist,
    exactDistSHA512,
    exactDistSize,
  )
where

import Data.Char (isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName)

-- | One exact @DIST <name> <size> …@ record.
data ManifestDistRecord = ManifestDistRecord
  { mdrName :: Text,
    mdrSize :: Maybe Integer,
    mdrSHA512 :: Maybe Text
  }
  deriving (Eq, Show)

-- | Lookup of one required basename among exact DIST records.
data DistLookup
  = DistAbsent
  | DistPresent ManifestDistRecord
  | DistConflict Text
  deriving (Eq, Show)

-- | Parse exact DIST records (first token DIST, second token the basename).
parseExactDistRecords :: Text -> [ManifestDistRecord]
parseExactDistRecords content =
  [ rec
  | ln <- T.lines content,
    Just rec <- [parseLine ln]
  ]
  where
    parseLine ln =
      case T.words ln of
        ("DIST" : name : rest) ->
          Just
            ManifestDistRecord
              { mdrName = name,
                mdrSize = parseSize rest,
                mdrSHA512 = extractSha512 rest
              }
        _ -> Nothing
    parseSize (sizeTxt : _) =
      case reads (T.unpack sizeTxt) of
        [(n, "")] -> Just n
        _ -> Nothing
    parseSize [] = Nothing

extractSha512 :: [Text] -> Maybe Text
extractSha512 = go
  where
    go [] = Nothing
    go ("SHA512" : hex : _)
      | T.all isHexDigit hex = Just (T.toLower hex)
      | otherwise = Nothing
    go (_ : xs) = go xs

-- | Exact lookup for a required basename. Duplicate records with disagreeing
-- size or SHA512 are a conflict.
lookupExactDist :: Text -> FilePath -> DistLookup
lookupExactDist manifestContent distfile =
  let name = T.pack (takeFileName distfile)
      matching = [r | r <- parseExactDistRecords manifestContent, mdrName r == name]
   in case matching of
        [] -> DistAbsent
        [r] -> DistPresent r
        (r : rest) ->
          if all (sameFacts r) rest
            then DistPresent r
            else DistConflict name
  where
    sameFacts a b =
      mdrSize a == mdrSize b && mdrSHA512 a == mdrSHA512 b

-- | True when a unique exact DIST record exists for the basename.
-- Conflicts do not satisfy presence.
manifestHasExactDist :: Text -> FilePath -> Bool
manifestHasExactDist manifestContent distfile =
  case lookupExactDist manifestContent distfile of
    DistPresent {} -> True
    _ -> False

-- | SHA512 from the unique exact DIST record. 'Left' on conflicting duplicates.
exactDistSHA512 :: Text -> FilePath -> Either Text (Maybe Text)
exactDistSHA512 manifestContent distfile =
  case lookupExactDist manifestContent distfile of
    DistAbsent -> Right Nothing
    DistPresent r -> Right (mdrSHA512 r)
    DistConflict name ->
      Left ("conflicting duplicate Manifest DIST records for " <> name)

-- | Positive size from the unique exact DIST record.
exactDistSize :: Text -> FilePath -> Maybe Integer
exactDistSize manifestContent distfile =
  case lookupExactDist manifestContent distfile of
    DistPresent r ->
      case mdrSize r of
        Just n | n > 0 -> Just n
        _ -> Nothing
    _ -> Nothing
