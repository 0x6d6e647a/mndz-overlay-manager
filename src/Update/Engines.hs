{-# LANGUAGE OverloadedStrings #-}

module Update.Engines
  ( parseEnginesMinimum,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

-- | Parse minimum engines forms: bare @X.Y.Z@, optional leading @v@, or @>=X.Y.Z@.
-- Complex ranges (@^@, @||@, @<@, @*@, spaces with multiple clauses) are unparseable.
parseEnginesMinimum :: Text -> Maybe Text
parseEnginesMinimum raw =
  let t0 = T.strip raw
   in if T.null t0 || isComplex t0
        then Nothing
        else
          let t1 =
                if ">=" `T.isPrefixOf` t0
                  then T.strip (T.drop 2 t0)
                  else t0
              t2 =
                if "v" `T.isPrefixOf` t1
                  && T.length t1 > 1
                  && isDigit (T.index t1 1)
                  then T.drop 1 t1
                  else t1
           in if isVersionToken t2 then Just t2 else Nothing
  where
    isComplex t =
      any
        (`T.isInfixOf` t)
        ["||", "^", "~", "*", "<", " - ", " -", "- "]
        || " " `T.isInfixOf` t
        || "," `T.isInfixOf` t
    isVersionToken t =
      let parts = T.splitOn "." t
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts
            && length parts <= 4
