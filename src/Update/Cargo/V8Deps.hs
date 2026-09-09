{-# LANGUAGE OverloadedStrings #-}

-- | Parse Chromium @v8/DEPS@ GCS Linux_x64 clang / rust-toolchain objects
-- without executing the file as Python.
module Update.Cargo.V8Deps
  ( V8GcsLinuxDists (..),
    parseV8DepsGcsLinux,
    extractV8DepsFromSnapshot,
  )
where

import Data.Char (isSpace)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName)
import System.Process (readProcessWithExitCode)

-- | Chromium GCS distfile basenames for Linux_x64 host clang and rust-toolchain.
data V8GcsLinuxDists = V8GcsLinuxDists
  { v8ClangDist :: Text,
    v8RustTcDist :: Text
  }
  deriving (Eq, Show)

clangBlockKey :: Text
clangBlockKey = "third_party/llvm-build/Release+Asserts"

rustBlockKey :: Text
rustBlockKey = "third_party/rust-toolchain"

clangPrefix :: Text
clangPrefix = "clang-llvmorg-"

rustPrefix :: Text
rustPrefix = "rust-toolchain-"

linuxObjectPrefix :: Text
linuxObjectPrefix = "Linux_x64/"

linuxHostCondition :: Text
linuxHostCondition = "host_os == \"linux\""

-- | Unique Linux_x64 @host_os == \"linux\"@ GCS objects for clang and rust-toolchain.
-- | Extract @v8/DEPS@ from a hermetic rusty_v8 snapshot tarball (@tar -xJOf@).
extractV8DepsFromSnapshot :: FilePath -> IO (Either Text Text)
extractV8DepsFromSnapshot tarball = do
  (code, out, err) <-
    readProcessWithExitCode "tar" ["-xJOf", tarball, "v8/DEPS"] ""
  pure $
    if code == ExitSuccess
      then Right (T.pack out)
      else
        Left
          ( "could not extract v8/DEPS from "
              <> T.pack tarball
              <> ": "
              <> T.strip (T.pack err)
          )

parseV8DepsGcsLinux :: Text -> Either Text V8GcsLinuxDists
parseV8DepsGcsLinux body = do
  clang <- uniqueLinuxGcsObject clangBlockKey clangPrefix body
  rust <- uniqueLinuxGcsObject rustBlockKey rustPrefix body
  pure V8GcsLinuxDists {v8ClangDist = clang, v8RustTcDist = rust}

uniqueLinuxGcsObject :: Text -> Text -> Text -> Either Text Text
uniqueLinuxGcsObject key prefix body = do
  block <- extractNamedBlock key body
  depType <-
    case quotedField "dep_type" block of
      Nothing -> Left ("missing dep_type in DEPS block " <> key)
      Just t -> Right t
  if depType /= "gcs"
    then Left ("non-GCS dep type in DEPS block " <> key <> ": " <> depType)
    else
      let kept =
            [ takeFileNameText name
            | obj <- gcsObjects block,
              Just name <- [quotedField "object_name" obj],
              linuxObjectPrefix `T.isPrefixOf` name,
              quotedField "condition" obj == Just linuxHostCondition,
              prefix `T.isPrefixOf` takeFileNameText name
            ]
       in case kept of
            [one] -> Right one
            [] ->
              Left
                ( "no unique Linux_x64 host_os == \"linux\" "
                    <> prefix
                    <> " object in DEPS block "
                    <> key
                )
            _ ->
              Left
                ( "duplicate Linux_x64 host_os == \"linux\" "
                    <> prefix
                    <> " objects in DEPS block "
                    <> key
                )

takeFileNameText :: Text -> Text
takeFileNameText = T.pack . takeFileName . T.unpack

extractNamedBlock :: Text -> Text -> Either Text Text
extractNamedBlock key body =
  let needle = "'" <> key <> "'"
   in case T.breakOn needle body of
        (_, rest)
          | T.null rest -> Left ("missing DEPS key " <> key)
          | otherwise ->
              let afterKey = T.drop (T.length needle) rest
                  afterColon = T.dropWhile (/= '{') afterKey
               in case extractBrace afterColon of
                    Nothing -> Left ("unclosed DEPS block " <> key)
                    Just inner -> Right inner

-- | Inner text of the first brace-matched @{...}@, string-aware.
extractBrace :: Text -> Maybe Text
extractBrace t =
  case T.uncons (T.dropWhile isSpace t) of
    Just ('{', rest) -> go 1 False '\0' rest []
    _ -> Nothing
  where
    go :: Int -> Bool -> Char -> Text -> String -> Maybe Text
    go n inQ q s acc
      | n == 0 = Just (T.pack (reverse acc))
      | otherwise =
          case T.uncons s of
            Nothing -> Nothing
            Just (c, rest)
              | inQ && c == '\\' ->
                  case T.uncons rest of
                    Nothing -> Nothing
                    Just (c2, rest2) -> go n True q rest2 (c2 : c : acc)
              | inQ && c == q -> go n False '\0' rest (c : acc)
              | inQ -> go n True q rest (c : acc)
              | c == '\'' || c == '"' -> go n True c rest (c : acc)
              | c == '{' -> go (n + 1) False '\0' rest (c : acc)
              | c == '}' ->
                  if n == 1
                    then go 0 False '\0' rest acc
                    else go (n - 1) False '\0' rest (c : acc)
              | otherwise -> go n False '\0' rest (c : acc)

gcsObjects :: Text -> [Text]
gcsObjects block =
  case T.breakOn "'objects'" block of
    (_, rest)
      | T.null rest -> []
      | otherwise ->
          let after = T.dropWhile (/= '[') (T.drop (T.length ("'objects'" :: Text)) rest)
           in case T.uncons after of
                Just ('[', inner) ->
                  let listBody = T.takeWhile (/= ']') inner
                   in mapMaybe extractBrace (objectStarts listBody)
                _ -> []
  where
    objectStarts t =
      case T.break (== '{') t of
        (_, rest)
          | T.null rest -> []
          | otherwise -> rest : objectStarts (T.drop 1 rest)

quotedField :: Text -> Text -> Maybe Text
quotedField key block =
  let needles = ["'" <> key <> "'", "\"" <> key <> "\""]
      hits = mapMaybe (tryNeedle block) needles
   in case hits of
        (v : _) -> Just v
        [] -> Nothing
  where
    tryNeedle hay needle =
      case T.breakOn needle hay of
        (_, rest)
          | T.null rest -> Nothing
          | otherwise ->
              let after = T.drop (T.length needle) rest
                  afterColon = T.dropWhile isSpace (T.dropWhile (/= ':') after)
                  valSide = T.dropWhile (\c -> isSpace c || c == ':') afterColon
               in readQuoted valSide

readQuoted :: Text -> Maybe Text
readQuoted t =
  case T.uncons (T.dropWhile isSpace t) of
    Just (q, rest)
      | q == '\'' || q == '"' ->
          let (body, _) = T.break (== q) rest
           in Just body
    _ -> Nothing
