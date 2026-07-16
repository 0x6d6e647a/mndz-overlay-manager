{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Version
  ( parseGoModGoDirective,
    parseGoVersionOutput,
    parseGoVersionToken,
    compareGoVersions,
    hostMeetsGoRequirement,
    goVersionTooOldMessage,
    looksLikeToolchainError,
    enrichGoModDownloadError,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

-- | Extract the top-level @go X.Y@ / @go X.Y.Z@ directive from go.mod content.
-- Returns the version token as written (e.g. @"1.26.5"@). Ignores @toolchain@
-- lines and commented lines.
parseGoModGoDirective :: Text -> Maybe Text
parseGoModGoDirective content =
  case mapMaybe lineGo [T.strip l | l <- T.lines content] of
    (v : _) -> Just v
    [] -> Nothing
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineGo ln
      | T.null ln = Nothing
      | "//" `T.isPrefixOf` ln = Nothing
      | otherwise =
          case T.words ln of
            ("go" : ver : _)
              | isGoVersionToken ver -> Just ver
            _ -> Nothing

-- | True when the token looks like a Go language version (@1.22@, @1.26.5@).
isGoVersionToken :: Text -> Bool
isGoVersionToken t =
  case parseGoVersionToken t of
    Just _ -> True
    Nothing -> False

-- | Parse a version token into numeric components (missing patch = 0 for compare).
-- Also accepts a leading @go@ prefix (@go1.26.4@).
parseGoVersionToken :: Text -> Maybe [Int]
parseGoVersionToken raw =
  let t0 = T.strip raw
      t1 =
        if "go" `T.isPrefixOf` t0 && T.length t0 > 2 && isDigit (T.index t0 2)
          then T.drop 2 t0
          else t0
      -- Strip distro/experiment suffixes: 1.26.4-X:nodwarf5 → 1.26.4
      core = T.takeWhile (\c -> isDigit c || c == '.') t1
   in if T.null core
        then Nothing
        else
          let parts = T.splitOn "." core
           in case traverse readInt parts of
                Just comps@(_ : _) -> Just (pad3 comps)
                _ -> Nothing
  where
    readInt s
      | T.null s = Nothing
      | T.all isDigit s = Just (read (T.unpack s) :: Int)
      | otherwise = Nothing
    pad3 [a] = [a, 0, 0]
    pad3 [a, b] = [a, b, 0]
    pad3 (a : b : c : _) = [a, b, c]
    pad3 [] = [0, 0, 0]

-- | Parse @go version@ command output (e.g. @go version go1.26.4 linux\/amd64@).
parseGoVersionOutput :: Text -> Maybe Text
parseGoVersionOutput out =
  case [v | w <- T.words out, Just v <- [extractGoPrefixed w]] of
    (v : _) -> Just v
    [] -> Nothing
  where
    -- go1.26.4 or go1.26.4-X:nodwarf5 → normalized display "1.26.4"
    extractGoPrefixed w
      | "go" `T.isPrefixOf` w
          && T.length w > 2
          && isDigit (T.index w 2) =
          case parseGoVersionToken w of
            Just comps -> Just (formatComps comps w)
            Nothing -> Nothing
      | otherwise = Nothing
    -- Prefer original core without go prefix for messages; use comps for structure
    formatComps comps w =
      let core = T.takeWhile (\c -> isDigit c || c == '.') (T.drop 2 w)
       in if T.null core then T.intercalate "." (map (T.pack . show) comps) else core

-- | Compare two version tokens. @LT@ means left is older than right.
compareGoVersions :: Text -> Text -> Maybe Ordering
compareGoVersions a b = do
  ca <- parseGoVersionToken a
  cb <- parseGoVersionToken b
  pure (compare ca cb)

-- | Whether host version meets the go.mod requirement (host >= required).
hostMeetsGoRequirement :: Text -> Text -> Maybe Bool
hostMeetsGoRequirement host required =
  case compareGoVersions host required of
    Just LT -> Just False
    Just _ -> Just True
    Nothing -> Nothing

-- | Operator-facing hard-fail message when host Go is too old.
goVersionTooOldMessage :: Text -> Text -> Text
goVersionTooOldMessage host required =
  "host Go "
    <> host
    <> " is older than go.mod requirement go "
    <> required
    <> "; install/upgrade dev-lang/go to at least "
    <> required
    <> " (keyword unmask or wait for the Gentoo tree if needed). "
    <> "This tool does not set GOTOOLCHAIN=auto or download Go toolchains."

-- | Heuristic: go stderr looks like a toolchain / language version problem.
looksLikeToolchainError :: Text -> Bool
looksLikeToolchainError err =
  let e = T.toLower err
   in any
        (`T.isInfixOf` e)
        [ "toolchain",
          "go.mod requires",
          "requires go >=",
          "goto toolchain",
          "download go",
          "unsupported version of go"
        ]

-- | Append upgrade guidance when download fails with a toolchain-looking error.
enrichGoModDownloadError :: Text -> Text
enrichGoModDownloadError err
  | looksLikeToolchainError err =
      "go mod download failed: "
        <> err
        <> " (host Go may be older than go.mod; upgrade dev-lang/go — "
        <> "this tool does not set GOTOOLCHAIN=auto)"
  | otherwise = "go mod download failed: " <> err
