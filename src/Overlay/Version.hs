{-# LANGUAGE OverloadedStrings #-}

module Overlay.Version
  ( EbuildVersion (..),
    parseEbuildVersion,
    prettyVersion,
    renderPV,
    comparePV,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

-- | Numeric components with optional Gentoo revision, or an unparsed raw string.
data EbuildVersion
  = Numeric
      { evComponents :: [Word],
        evRevision :: Maybe Word
      }
  | Raw Text
  deriving (Eq, Show)

-- | Parse a Gentoo-style version string. Non-numeric forms become 'Raw'.
parseEbuildVersion :: Text -> EbuildVersion
parseEbuildVersion t =
  case parseNumeric (T.unpack t) of
    Just v -> v
    Nothing -> Raw t

parseNumeric :: String -> Maybe EbuildVersion
parseNumeric s = do
  (comps, rest) <- parseComponents s
  case rest of
    "" -> Just (Numeric comps Nothing)
    '-' : 'r' : revStr -> do
      rev <- parseWord revStr
      if null revStr then Nothing else Just (Numeric comps (Just rev))
    _ -> Nothing
  where
    parseComponents :: String -> Maybe ([Word], String)
    parseComponents input = go input []
      where
        go [] _ = Nothing
        go str acc = do
          let (digits, rest') = span isDigit str
          if null digits
            then Nothing
            else do
              n <- parseWord digits
              let acc' = acc ++ [n]
              case rest' of
                '.' : more -> go more acc'
                other -> Just (acc', other)

    parseWord :: String -> Maybe Word
    parseWord xs
      | null xs = Nothing
      | all isDigit xs = Just (fromInteger (read xs :: Integer))
      | otherwise = Nothing

-- | Pretty-render for display as PV form (optional @-rN@, no leading @v@).
-- Currently identical to 'renderPV'; kept as a named display hook.
prettyVersion :: EbuildVersion -> Text
prettyVersion = renderPV

-- | Render stored/compared PV form (optional @-rN@, no leading @v@).
renderPV :: EbuildVersion -> Text
renderPV (Raw t) = t
renderPV (Numeric comps mrev) =
  T.intercalate "." (map (T.pack . show) comps)
    <> case mrev of
      Nothing -> ""
      Just r -> "-r" <> T.pack (show r)

-- | Compare for update detection: numeric components only, revision ignored.
-- Returns 'Nothing' if incomparable (raw involved or empty components).
comparePV :: EbuildVersion -> EbuildVersion -> Maybe Ordering
comparePV (Numeric a _) (Numeric b _) =
  Just (compareComponents a b)
comparePV _ _ = Nothing

compareComponents :: [Word] -> [Word] -> Ordering
compareComponents = go
  where
    go [] [] = EQ
    go [] (y : ys')
      | y == 0 && all (== 0) ys' = EQ
      | otherwise = LT
    go (x : xs') []
      | x == 0 && all (== 0) xs' = EQ
      | otherwise = GT
    go (x : xs') (y : ys') =
      case compare x y of
        EQ -> go xs' ys'
        o -> o
