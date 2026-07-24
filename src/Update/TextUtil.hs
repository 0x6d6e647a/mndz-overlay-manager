module Update.TextUtil
  ( stripSurroundingQuotes,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | Strip one layer of surrounding double or single quotes, if both ends match.
-- Otherwise return the text unchanged.
stripSurroundingQuotes :: Text -> Text
stripSurroundingQuotes t
  | T.length t >= 2,
    T.head t == '"',
    T.last t == '"' =
      T.init (T.tail t)
  | T.length t >= 2,
    T.head t == '\'',
    T.last t == '\'' =
      T.init (T.tail t)
  | otherwise = t
