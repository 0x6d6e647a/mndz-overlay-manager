{-# LANGUAGE OverloadedStrings #-}

module Update.Cargo.Msrv
  ( normalizeRustVersion,
    parseRustVersionField,
    parseRustMinVerFromEbuild,
    maxRustVersion,
    combineMsrv,
    probeRustVersionFromCargoTomls,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Update.Go.Version (compareGoVersions, parseGoVersionToken)
import Update.TextUtil (stripSurroundingQuotes)

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

-- | Extract @rust-version@ from a Cargo.toml body (package table, simple form).
-- Supports @rust-version = "1.88.0"@ and @rust-version = "1.88"@.
parseRustVersionField :: Text -> Maybe Text
parseRustVersionField content =
  case mapMaybe lineRust [T.strip l | l <- T.lines content] of
    (v : _) -> normalizeRustVersion v
    [] -> Nothing
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineRust ln
      | T.null ln = Nothing
      | "#" `T.isPrefixOf` ln = Nothing
      | otherwise =
          case T.breakOn "=" ln of
            (key, rest)
              | T.strip key == "rust-version",
                Just ('=', val0) <- T.uncons rest ->
                  let val = T.strip val0
                      unquoted = stripSurroundingQuotes val
                   in if T.null unquoted then Nothing else Just unquoted
              | otherwise -> Nothing

-- | Parse @RUST_MIN_VER="…"@ from ebuild content.
parseRustMinVerFromEbuild :: Text -> Maybe Text
parseRustMinVerFromEbuild content =
  case mapMaybe lineMin [T.stripStart l | l <- T.lines content] of
    (v : _) -> normalizeRustVersion v
    [] -> Nothing
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineMin ln
      | "RUST_MIN_VER=" `T.isPrefixOf` ln =
          let raw = T.drop (T.length ("RUST_MIN_VER=" :: Text)) ln
              unquoted = stripSurroundingQuotes (T.strip raw)
           in if T.null unquoted then Nothing else Just unquoted
      | otherwise = Nothing

-- | Try package subdir, lock subdir, then repository root for @package.rust-version@.
-- @fetch@ receives each candidate subdirectory ('Nothing' = root) and returns the
-- Cargo.toml body or an error; first successful parse wins.
probeRustVersionFromCargoTomls ::
  Maybe FilePath ->
  Maybe FilePath ->
  (Maybe FilePath -> IO (Either e Text)) ->
  IO (Maybe Text)
probeRustVersionFromCargoTomls mPkg mLock fetch = go [mPkg, mLock, Nothing]
  where
    go [] = pure Nothing
    go (mSub : rest) = do
      eres <- fetch mSub
      case eres of
        Left _ -> go rest
        Right body ->
          case parseRustVersionField body of
            Just ver -> pure (normalizeRustVersion ver)
            Nothing -> go rest

-- | Maximum of two normalized rust versions; prefers the higher one.
maxRustVersion :: Text -> Text -> Maybe Text
maxRustVersion a b =
  case compareGoVersions a b of
    Just LT -> Just b
    Just _ -> Just a
    Nothing ->
      case (normalizeRustVersion a, normalizeRustVersion b) of
        (Just a', Just b') -> maxRustVersion a' b'
        (Just a', Nothing) -> Just a'
        (Nothing, Just b') -> Just b'
        _ -> Nothing

-- | Combine optional root, max-deps, and donor MSRV via max; 'Nothing' if all absent.
combineMsrv :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text
combineMsrv mRoot mDeps mDonor =
  let parts = [v | Just r <- [mRoot, mDeps, mDonor], Just v <- [normalizeRustVersion r]]
   in case parts of
        [] -> Nothing
        (x : xs) -> foldl' step (Just x) xs
  where
    step acc y = case acc of
      Nothing -> Just y
      Just a -> maxRustVersion a y
