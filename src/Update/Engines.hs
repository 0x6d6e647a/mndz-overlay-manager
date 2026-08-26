{-# LANGUAGE OverloadedStrings #-}

module Update.Engines
  ( parseEnginesMinimum,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Update.Go.Version (compareGoVersions)

-- | Parse a minimum engines version from:
--
-- * bare @X.Y.Z@, optional leading @v@, or @>=X.Y.Z@
-- * caret @^X.Y.Z@ (minimum @X.Y.Z@; caret cap is not encoded)
-- * a disjunction of those clauses joined by @||@ (lowest lower-bound)
--
-- Unparseable forms (@*@, @<@, hyphen ranges, @~@, empty) yield 'Nothing'.
parseEnginesMinimum :: Text -> Maybe Text
parseEnginesMinimum raw =
  let t0 = T.strip raw
   in if T.null t0
        then Nothing
        else
          let clauses = map T.strip (T.splitOn "||" t0)
           in if null clauses || any T.null clauses
                then Nothing
                else case traverse parseClause clauses of
                  Just (x : xs) -> Just (foldl' minVer x xs)
                  _ -> Nothing
  where
    parseClause t
      | isUnparseable t = Nothing
      | otherwise =
          let t1
                | ">=" `T.isPrefixOf` t = T.strip (T.drop 2 t)
                | "^" `T.isPrefixOf` t = T.strip (T.drop 1 t)
                | otherwise = t
              t2 = stripV t1
           in if isVersionToken t2 then Just t2 else Nothing
    stripV t1 =
      if "v" `T.isPrefixOf` t1
        && T.length t1 > 1
        && isDigit (T.index t1 1)
        then T.drop 1 t1
        else t1
    isUnparseable t =
      any
        (`T.isInfixOf` t)
        ["~", "*", "<", " - ", " -", "- "]
        || " " `T.isInfixOf` t
        || "," `T.isInfixOf` t
    isVersionToken t =
      let parts = T.splitOn "." t
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts
            && length parts <= 4
    minVer a b = case compareGoVersions a b of
      Just GT -> b
      _ -> a
