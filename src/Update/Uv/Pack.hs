{-# LANGUAGE OverloadedStrings #-}

-- | Pure pack plan for a Uv deps tarball.
--
-- The resolved name set is the closure authority (a Linux @uv sync --frozen@).
-- This module does not run @uv lock@ and does not download wheels.
module Update.Uv.Pack
  ( SdistPack (..),
    frozenUvSyncArgs,
    frozenUvSyncEnv,
    packRunsUvLock,
    acceptFrozenSync,
    windowsOnlyNames,
    nameKeptDespiteWindowsMarker,
    packSdists,
    PyprojectBuild (..),
    setuptoolsFallbackRequires,
    classifyPyprojectBuild,
    buildRequiresOf,
    requirementName,
    parseSelectingSdists,
    parseDryRunSdists,
  )
where

import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName, (</>))
import Update.Uv.Lock
  ( UvEdge (..),
    UvFile (..),
    UvLock (..),
    UvPackage (..),
  )

-- | One sdist inside the deps tarball (@sdists/\<file\>@).
data SdistPack = SdistPack
  { spName :: Text,
    spRelativePath :: FilePath,
    spUrl :: Text,
    spHash :: Text,
    -- | Rust sdist with no @vendor/@; the packer runs @cargo vendor@ inside it.
    spCargoVendor :: Bool
  }
  deriving (Eq, Show)

-- | Arguments after the @uv@ executable for the closure sync.
frozenUvSyncArgs :: Text -> [Text]
frozenUvSyncArgs slot =
  [ "sync",
    "--frozen",
    "--all-groups",
    "--no-install-project",
    "--python",
    slot
  ]

-- | Sync must not download a CPython build.
frozenUvSyncEnv :: [(String, String)]
frozenUvSyncEnv = [("UV_PYTHON_DOWNLOADS", "never")]

-- | The pack plan never runs @uv lock@ (including @uv lock --check@).
packRunsUvLock :: Bool
packRunsUvLock = False

-- | Frozen success is enough. A lock that @uv lock --check@ would reject
-- still packs when the second flag is true.
acceptFrozenSync ::
  -- | @uv sync --frozen@ succeeded.
  Bool ->
  -- | @uv lock --check@ would fail.
  Bool ->
  Either Text ()
acceptFrozenSync True _ = Right ()
acceptFrozenSync False _ = Left "uv sync --frozen failed"

-- | Distributions whose incoming edges are all Windows platform markers.
-- Entries with no incoming edge are not treated as Windows-only.
windowsOnlyNames :: UvLock -> Set Text
windowsOnlyNames lock =
  Set.fromList
    [ upName pkg
    | pkg <- ulPackages lock,
      let edges = incomingEdges lock (upName pkg),
      not (null edges),
      all edgeIsWindowsOnly edges
    ]

-- | True when @name@ has both an unconditional (or non-Windows) edge and a
-- Windows-marker edge, so the pack keeps it.
nameKeptDespiteWindowsMarker :: UvLock -> Text -> Bool
nameKeptDespiteWindowsMarker lock name =
  let edges = incomingEdges lock name
      win = filter edgeIsWindowsOnly edges
      other = filter (not . edgeIsWindowsOnly) edges
   in not (null win) && not (null other)

-- | Pack sdists for @resolved@ (the Linux closure). @unvendoredRust@ names
-- Rust sdists that ship without @vendor/@. A selected distribution with no
-- sdist is a hard failure. Wheels are not packed.
packSdists :: UvLock -> Set Text -> Set Text -> Either Text [SdistPack]
packSdists lock resolved unvendoredRust =
  mapM one (sort (Set.toList resolved))
  where
    one name =
      case findPackage lock name of
        Nothing ->
          Left ("uv.lock has no distribution named " <> name)
        Just pkg ->
          case upSdist pkg of
            Nothing ->
              Left ("selected distribution " <> name <> " has no sdist")
            Just file ->
              let base = takeFileName (T.unpack (ufUrl file))
               in Right
                    SdistPack
                      { spName = upName pkg,
                        spRelativePath = "sdists" </> base,
                        spUrl = ufUrl file,
                        spHash = ufHash file,
                        spCargoVendor = normalizeName name `Set.member` Set.map normalizeName unvendoredRust
                      }

findPackage :: UvLock -> Text -> Maybe UvPackage
findPackage lock name =
  case [pkg | pkg <- ulPackages lock, normalizeName (upName pkg) == normalizeName name] of
    (pkg : _) -> Just pkg
    [] -> Nothing

normalizeName :: Text -> Text
normalizeName = T.toLower . T.replace "_" "-"

incomingEdges :: UvLock -> Text -> [UvEdge]
incomingEdges lock name =
  [ edge
  | pkg <- ulPackages lock,
    edge <- packageEdges pkg,
    normalizeName (ueName edge) == normalizeName name
  ]

packageEdges :: UvPackage -> [UvEdge]
packageEdges pkg =
  upDependencies pkg ++ concat (Map.elems (upDevDependencies pkg))

edgeIsWindowsOnly :: UvEdge -> Bool
edgeIsWindowsOnly edge =
  maybe False markerIsWindowsOnly (ueMarker edge)

-- | A marker is Windows-only when every @and@ clause is a Windows platform
-- test and the marker has no @or@.
markerIsWindowsOnly :: Text -> Bool
markerIsWindowsOnly raw =
  let norm = T.toLower (T.strip raw)
      clauses = map T.strip (T.splitOn " and " norm)
   in not (T.null norm)
        && not (" or " `T.isInfixOf` (" " <> norm <> " "))
        && not (null clauses)
        && all isWindowsClause clauses

isWindowsClause :: Text -> Bool
isWindowsClause clause =
  clause
    `elem` [ "sys_platform == 'win32'",
             "sys_platform == \"win32\"",
             "os_name == 'nt'",
             "os_name == \"nt\""
           ]

-- | How a packed sdist declares its PEP 517 build.
data PyprojectBuild
  = NoBuildSystem
  | BuildRequires [Text]
  deriving (Eq, Show)

-- | Legacy sdists with no @build-system@ table build through setuptools.
setuptoolsFallbackRequires :: [Text]
setuptoolsFallbackRequires = ["setuptools", "wheel"]

-- | Requirements the packer must fetch so this sdist can build offline.
buildRequiresOf :: PyprojectBuild -> [Text]
buildRequiresOf NoBuildSystem = setuptoolsFallbackRequires
buildRequiresOf (BuildRequires reqs) = reqs

-- | Read @[build-system] requires@. A missing table is 'NoBuildSystem'.
classifyPyprojectBuild :: Text -> Either Text PyprojectBuild
classifyPyprojectBuild body =
  case buildSystemSection body of
    Nothing -> Right NoBuildSystem
    Just section ->
      case sectionRequires section of
        Left err -> Left err
        Right reqs -> Right (BuildRequires reqs)

-- | Distribution name at the start of a PEP 508 requirement.
requirementName :: Text -> Text
requirementName = normalizeName . T.takeWhile isReqName . T.strip

-- | Sdist selections from @uv pip install --dry-run -v@.
-- A selected file that is not a @.tar.gz@ is a hard failure.
parseSelectingSdists :: Text -> Either Text [(Text, Text, Text)]
parseSelectingSdists body =
  mapM parseSelectingLine [line | line <- T.lines body, "Selecting: " `T.isInfixOf` line]

-- | Sdists from @uv pip install --dry-run -v@.
-- Verbose logs also print @Selecting:@ for candidates that were rejected.
-- Only the @Would install@ set is kept, and each of those must be a @.tar.gz@.
parseDryRunSdists :: Text -> Either Text [(Text, Text, Text)]
parseDryRunSdists body = do
  files <- selectingTarGz body
  mapM (wantedFile files) (parseWouldInstall body)

parseWouldInstall :: Text -> [(Text, Text)]
parseWouldInstall body =
  [ (normalizeName (T.strip name), version)
  | line <- T.lines body,
    Just rest <- [T.stripPrefix " + " line],
    let (name, rest0) = T.breakOn "==" rest,
    not (T.null rest0),
    let version = T.takeWhile (/= ' ') (T.drop 2 rest0),
    not (T.null version),
    not (T.null (T.strip name))
  ]

selectingTarGz :: Text -> Either Text (Map.Map (Text, Text) Text)
selectingTarGz body = go Map.empty (T.lines body)
  where
    go acc [] = Right acc
    go acc (line : rest) =
      case selectingTarOf line of
        Nothing -> go acc rest
        Just (key, filename) ->
          case Map.lookup key acc of
            Just prev
              | prev /= filename ->
                  Left ("build backend has conflicting sdist names: " <> filename)
            _ -> go (Map.insert key filename acc) rest

selectingTarOf :: Text -> Maybe ((Text, Text), Text)
selectingTarOf line
  | "Selecting: " `T.isInfixOf` line =
      case parseSelectingLine line of
        Right (name, version, filename) -> Just ((name, version), filename)
        Left _ -> Nothing
  | otherwise = Nothing

wantedFile :: Map.Map (Text, Text) Text -> (Text, Text) -> Either Text (Text, Text, Text)
wantedFile files (name, version) =
  case Map.lookup (name, version) files of
    Just filename -> Right (name, version, filename)
    Nothing ->
      Left ("build backend resolved to a non-sdist: " <> name <> "==" <> version)

buildSystemSection :: Text -> Maybe Text
buildSystemSection body =
  case dropWhile (not . isBuildSystemHeader) (T.lines body) of
    [] -> Nothing
    (_header : rest) ->
      Just (T.unlines (takeWhile (not . isTableHeader) rest))

isBuildSystemHeader :: Text -> Bool
isBuildSystemHeader line = T.strip (stripComment line) == "[build-system]"

isTableHeader :: Text -> Bool
isTableHeader line =
  let stripped = T.strip (stripComment line)
   in T.isPrefixOf "[" stripped && T.isSuffixOf "]" stripped

sectionRequires :: Text -> Either Text [Text]
sectionRequires section =
  let flat = T.unwords (map (T.strip . stripComment) (T.lines section))
   in case T.breakOn "requires" flat of
        (_, rest)
          | T.null rest -> Left "build-system table has no requires"
          | otherwise ->
              let afterKey = T.stripStart (T.drop (T.length "requires") rest)
               in case T.uncons afterKey of
                    Just ('=', value) -> parseStringArray (T.stripStart value)
                    _ -> Left "build-system requires is not an array"

parseStringArray :: Text -> Either Text [Text]
parseStringArray text =
  case T.uncons (T.stripStart text) of
    Just ('[', rest) -> parseItems (T.stripStart rest)
    _ -> Left "build-system requires is not an array"

parseItems :: Text -> Either Text [Text]
parseItems text =
  case T.uncons text of
    Nothing -> Left "build-system requires array is not closed"
    Just (']', _) -> Right []
    Just (',', rest) -> parseItems (T.stripStart rest)
    Just ('"', rest) -> parseOne '"' rest
    Just ('\'', rest) -> parseOne '\'' rest
    _ -> Left "build-system requires array has a non-string"

parseOne :: Char -> Text -> Either Text [Text]
parseOne quote rest =
  case takeString quote rest of
    Left err -> Left err
    Right (item, more) ->
      case parseItems (T.stripStart more) of
        Left err -> Left err
        Right items -> Right (item : items)

takeString :: Char -> Text -> Either Text (Text, Text)
takeString quote = go []
  where
    go acc input =
      case T.uncons input of
        Nothing -> Left "unterminated build requirement string"
        Just ('\\', more) ->
          case T.uncons more of
            Nothing -> Left "unterminated build requirement string"
            Just (ch, rest) -> go (ch : acc) rest
        Just (ch, rest)
          | ch == quote -> Right (T.pack (reverse acc), rest)
          | otherwise -> go (ch : acc) rest

stripComment :: Text -> Text
stripComment = T.pack . go False False . T.unpack
  where
    go _ _ [] = []
    go False False ('#' : _) = []
    go inDouble inSingle ('\\' : ch : rest) = '\\' : ch : go inDouble inSingle rest
    go False inSingle ('"' : rest) = '"' : go True inSingle rest
    go True inSingle ('"' : rest) = '"' : go False inSingle rest
    go inDouble False ('\'' : rest) = '\'' : go inDouble True rest
    go inDouble True ('\'' : rest) = '\'' : go inDouble False rest
    go inDouble inSingle (ch : rest) = ch : go inDouble inSingle rest

isReqName :: Char -> Bool
isReqName ch = isAlphaNum ch || ch == '_' || ch == '-' || ch == '.'

parseSelectingLine :: Text -> Either Text (Text, Text, Text)
parseSelectingLine line =
  let after = T.drop (T.length "Selecting: ") (snd (T.breakOn "Selecting: " line))
      (name, rest0) = T.breakOn "==" after
   in if T.null rest0
        then Left ("could not parse uv selection: " <> T.strip line)
        else
          let rest = T.drop 2 rest0
              (version, afterVer) = T.break (== ' ') rest
              fileAndMore = snd (T.breakOn "(" afterVer)
           in if T.null fileAndMore
                then Left ("uv selection has no filename: " <> T.strip line)
                else
                  let filename = T.takeWhile (/= ')') (T.drop 1 fileAndMore)
                   in if T.isSuffixOf ".tar.gz" filename
                        then Right (normalizeName (T.strip name), version, filename)
                        else Left ("build backend resolved to a non-sdist: " <> filename)
