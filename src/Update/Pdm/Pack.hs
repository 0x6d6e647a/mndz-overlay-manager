{-# LANGUAGE OverloadedStrings #-}

-- | Pure pack plan for a PDM deps tarball.
--
-- The closure authority is the name set from @pdm sync -G dev --dry-run@.
-- This module does not run @pdm lock@, @pdm export@, or a PyPI @pdm sync@.
module Update.Pdm.Pack
  ( PackedFile (..),
    BackendOffer (..),
    pdmUseArgs,
    pdmDryRunArgs,
    pdmArgsAvoidFetch,
    parsePdmDryRun,
    chooseLockedFile,
    verifyFileHash,
    platformOnlyNames,
    finalizePack,
  )
where

import Data.Char (isAlphaNum, isSpace)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName, (</>))
import Update.Pdm.Lock
  ( PdmFile (..),
    PdmLock (..),
    PdmPackage (..),
  )
import Update.Uv.Pack (requirementName)
import Update.Uv.Python
  ( PyVer (..),
    parseRequiresPython,
    slotSatisfies,
  )

-- | One file staged at @dists/\<file\>@.
data PackedFile = PackedFile
  { pkName :: Text,
    pkFile :: Text,
    pkHash :: Text,
    pkPath :: FilePath
  }
  deriving (Eq, Show)

-- | One PyPI release offered for an unpinned build backend.
data BackendOffer = BackendOffer
  { boVersion :: Text,
    boRequiresPython :: Maybe Text,
    boFiles :: [PdmFile]
  }
  deriving (Eq, Show)

-- | @pdm use -f@ aimed at the image interpreter. No @--auto-install-*@.
pdmUseArgs :: Text -> [Text]
pdmUseArgs slot = ["use", "-f", "/usr/bin/python" <> slot]

-- | Closure authority. Default group plus @dev@. Not @-d@.
pdmDryRunArgs :: [Text]
pdmDryRunArgs = ["sync", "-G", "dev", "--dry-run"]

-- | True when the argument list does not fetch or refresh a lock.
pdmArgsAvoidFetch :: [Text] -> Bool
pdmArgsAvoidFetch args =
  not (any forbidden args)
  where
    forbidden a =
      a `elem` ["lock", "export", "-d"]
        || "--auto-install" `T.isPrefixOf` a

-- | Names and versions from a non-tty @pdm sync --dry-run@ summary.
-- Removals are ignored. An update line keeps the new version.
-- An empty summary (everything already synced) fails: the dev set was not listed.
parsePdmDryRun :: Text -> Either Text [(Text, Text)]
parsePdmDryRun body =
  case go Nothing [] (T.lines body) of
    [] -> Left "pdm sync -G dev did not list the dev set"
    names -> Right (reverse names)
  where
    go _ acc [] = acc
    go section acc (raw : rest) =
      let line = T.strip (stripRich raw)
       in case sectionOf line of
            Just next -> go (Just next) acc rest
            Nothing ->
              case section of
                Just Remove -> go section acc rest
                Just kind ->
                  case parseItem kind line of
                    Just item -> go section (item : acc) rest
                    Nothing -> go section acc rest
                Nothing -> go section acc rest

data SummaryKind = Add | Update | Remove
  deriving (Eq, Show)

sectionOf :: Text -> Maybe SummaryKind
sectionOf line
  | "Packages to add" `T.isPrefixOf` line = Just Add
  | "Packages to update" `T.isPrefixOf` line = Just Update
  | "Packages to remove" `T.isPrefixOf` line = Just Remove
  | otherwise = Nothing

parseItem :: SummaryKind -> Text -> Maybe (Text, Text)
parseItem Remove _ = Nothing
parseItem Add line =
  case T.words (T.dropWhile isBullet line) of
    (name : ver : _)
      | name /= "->" ->
          Just (cleanName name, ver)
    _ -> Nothing
parseItem Update line =
  case break (== "->") (T.words (T.dropWhile isBullet line)) of
    (name : _, "->" : ver : _) -> Just (cleanName name, ver)
    _ -> Nothing

isBullet :: Char -> Bool
isBullet c = isSpace c || c == '-'

cleanName :: Text -> Text
cleanName = T.takeWhile (\c -> c /= '[' && c /= ',')

stripRich :: Text -> Text
stripRich t =
  case T.breakOn "[" t of
    (before, rest)
      | T.null rest -> t
      | otherwise ->
          case T.breakOn "]" (T.drop 1 rest) of
            (_, more)
              | T.null more -> t
              | otherwise -> before <> stripRich (T.drop 1 more)

-- | Pure wheel when the lock has one, otherwise the sdist and no wheel.
-- A @pp*@ wheel is not a pure wheel.
chooseLockedFile :: PdmPackage -> Either Text PdmFile
chooseLockedFile pkg =
  case firstMatch ["-py3-none-any.whl"] of
    Just f -> Right f
    Nothing ->
      case firstMatch ["-py2.py3-none-any.whl"] of
        Just f -> Right f
        Nothing ->
          case [f | f <- ppFiles pkg, ".tar.gz" `T.isSuffixOf` T.toLower (pfFile f)] of
            (f : _) -> Right f
            [] ->
              Left
                ( "locked distribution "
                    <> ppName pkg
                    <> " has no pure wheel or sdist"
                )
  where
    firstMatch suffixes =
      case [f | f <- ppFiles pkg, any (\s -> s `T.isSuffixOf` T.toLower (pfFile f)) suffixes] of
        (f : _) -> Just f
        [] -> Nothing

-- | Lock hash @sha256:\<hex\>@ against the digest of the downloaded bytes.
verifyFileHash :: Text -> Text -> Either Text ()
verifyFileHash expected actual
  | T.null (hexOf expected) || T.null (hexOf actual) =
      Left "locked file hash is missing"
  | hexOf expected == hexOf actual = Right ()
  | otherwise =
      Left
        ( "hash mismatch for locked file: expected "
            <> hexOf expected
            <> ", got "
            <> hexOf actual
        )

hexOf :: Text -> Text
hexOf t =
  case T.breakOn ":" t of
    (whole, "") -> T.toLower (T.strip whole)
    (_, rest) -> T.toLower (T.strip (T.drop 1 rest))

-- | Names whose incoming edges are all Windows or macOS platform markers.
-- A name with no incoming edge is not platform-only.
platformOnlyNames :: PdmLock -> Set Text
platformOnlyNames lock =
  Set.fromList
    [ norm name
    | (name, edges) <- Map.toList (incoming lock),
      not (null edges),
      all edgeIsPlatformOnly edges
    ]

-- | Files for the dry-run set, then one artifact for each direct
-- @build-system.requires@ of a packed sdist and for the project backends.
-- A wheel does not enqueue its own build requires.
finalizePack ::
  PdmLock ->
  -- | Project name. A dry-run line for this name is skipped.
  Text ->
  -- | @(name, version)@ from 'parsePdmDryRun'.
  [(Text, Text)] ->
  -- | Chosen slot, used to filter unpinned backend releases.
  Text ->
  -- | Direct build requires of a packed sdist, keyed by distribution name.
  Map Text [Text] ->
  -- | Project @build-system.requires@.
  [Text] ->
  -- | Unpinned backends absent from the lock, keyed by requirement name.
  Map Text [BackendOffer] ->
  Either Text [PackedFile]
finalizePack lock project selected slot sdistRequires projectRequires catalog = do
  let dropped = platformOnlyNames lock
      wanted =
        [ item
        | item@(name, _) <- selected,
          norm name /= norm project,
          norm name `Set.notMember` dropped
        ]
  locked <- mapM (selectLocked lock) wanted
  let seeds =
        [ requirementName req
        | pk <- locked,
          ".tar.gz" `T.isSuffixOf` T.toLower (pkFile pk),
          req <- Map.findWithDefault [] (pkName pk) sdistRequires
        ]
          ++ map requirementName projectRequires
  extras <- walkBackends lock slot sdistRequires catalog (packedNames locked) seeds []
  pure (locked ++ reverse extras)

selectLocked :: PdmLock -> (Text, Text) -> Either Text PackedFile
selectLocked lock (name, ver) =
  case preferBase
    [ pkg
    | pkg <- plPackages lock,
      norm (ppName pkg) == norm name,
      ppVersion pkg == ver
    ] of
    Nothing ->
      Left ("pdm.lock has no distribution " <> name <> " " <> ver)
    Just pkg -> do
      file <- chooseLockedFile pkg
      pure (packed (ppName pkg) file)

preferBase :: [PdmPackage] -> Maybe PdmPackage
preferBase pkgs =
  case [pkg | pkg <- pkgs, null (ppExtras pkg)] of
    (pkg : _) -> Just pkg
    [] ->
      case pkgs of
        (pkg : _) -> Just pkg
        [] -> Nothing

walkBackends ::
  PdmLock ->
  Text ->
  Map Text [Text] ->
  Map Text [BackendOffer] ->
  Set Text ->
  [Text] ->
  [PackedFile] ->
  Either Text [PackedFile]
walkBackends _ _ _ _ _ [] acc = Right acc
walkBackends lock slot sdistRequires catalog seen (name : rest) acc
  | norm name `Set.member` seen =
      walkBackends lock slot sdistRequires catalog seen rest acc
  | otherwise = do
      file <- resolveBackend lock slot catalog name
      let seen' = Set.insert (norm name) seen
          more =
            if ".tar.gz" `T.isSuffixOf` T.toLower (pkFile file)
              then map requirementName (Map.findWithDefault [] name sdistRequires)
              else []
      walkBackends lock slot sdistRequires catalog seen' (rest ++ more) (file : acc)

resolveBackend ::
  PdmLock ->
  Text ->
  Map Text [BackendOffer] ->
  Text ->
  Either Text PackedFile
resolveBackend lock slot catalog name =
  case preferBase
    [ pkg
    | pkg <- plPackages lock,
      norm (ppName pkg) == norm name
    ] of
    Just pkg -> do
      file <- chooseLockedFile pkg
      pure (packed (ppName pkg) file)
    Nothing ->
      case newestPure slot (Map.findWithDefault [] (norm name) catalog) of
        Nothing ->
          Left ("no pure wheel for build backend " <> name <> " at slot " <> slot)
        Just (_, file) ->
          pure
            PackedFile
              { pkName = name,
                pkFile = pfFile file,
                pkHash = pfHash file,
                pkPath = "dists" </> takeFileName (T.unpack (pfFile file))
              }

newestPure :: Text -> [BackendOffer] -> Maybe (BackendOffer, PdmFile)
newestPure slot offers =
  case sortOn (Down . verKey . boVersion) (filter (offerAllows slot) offers) of
    [] -> Nothing
    ordered ->
      case [(offer, file) | offer <- ordered, Right file <- [pureWheel (boFiles offer)]] of
        (hit : _) -> Just hit
        [] -> Nothing

offerAllows :: Text -> BackendOffer -> Bool
offerAllows slot offer =
  case boRequiresPython offer of
    Nothing -> True
    Just spec -> slotAllows slot spec

slotAllows :: Text -> Text -> Bool
slotAllows slot spec =
  case (parseSlot slot, parseRequiresPython spec) of
    (Just ver, Right clauses) -> slotSatisfies ver clauses
    _ -> False

parseSlot :: Text -> Maybe PyVer
parseSlot slot =
  case T.splitOn "." slot of
    [maj, mn]
      | Just major <- readInt maj,
        Just minor <- readInt mn ->
          Just (PyVer major minor)
    _ -> Nothing

readInt :: Text -> Maybe Int
readInt t =
  case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

pureWheel :: [PdmFile] -> Either Text PdmFile
pureWheel files =
  chooseLockedFile
    PdmPackage
      { ppName = "",
        ppVersion = "",
        ppRequiresPython = Nothing,
        ppExtras = [],
        ppGroups = [],
        ppDependencies = [],
        ppFiles = files
      }
    >>= \file ->
      if ".whl" `T.isSuffixOf` T.toLower (pfFile file)
        then Right file
        else Left "sdist"

packed :: Text -> PdmFile -> PackedFile
packed name file =
  PackedFile
    { pkName = name,
      pkFile = pfFile file,
      pkHash = pfHash file,
      pkPath = "dists" </> takeFileName (T.unpack (pfFile file))
    }

packedNames :: [PackedFile] -> Set Text
packedNames files = Set.fromList (map (norm . pkName) files)

verKey :: Text -> [Int]
verKey t =
  map (fromMaybe (-1) . readInt) (T.splitOn "." (T.takeWhile isVer t))
  where
    isVer c = isAlphaNum c || c == '.'

incoming :: PdmLock -> Map Text [(Text, Maybe Text)]
incoming lock =
  foldl' addEdge Map.empty (concatMap depEdges (plPackages lock))
  where
    addEdge acc (name, marker) =
      Map.insertWith (++) (norm name) [(name, marker)] acc

depEdges :: PdmPackage -> [(Text, Maybe Text)]
depEdges pkg =
  [ (requirementName req, marker)
  | raw <- ppDependencies pkg,
    let (req, marker) = splitMarker raw
  ]

splitMarker :: Text -> (Text, Maybe Text)
splitMarker raw =
  case T.breakOn ";" raw of
    (req, "") -> (req, Nothing)
    (req, rest) -> (req, Just (T.strip (T.drop 1 rest)))

edgeIsPlatformOnly :: (Text, Maybe Text) -> Bool
edgeIsPlatformOnly (_, Nothing) = False
edgeIsPlatformOnly (_, Just marker) = markerIsPlatformOnly marker

markerIsPlatformOnly :: Text -> Bool
markerIsPlatformOnly raw =
  let normed = T.toLower (T.strip raw)
      clauses = map T.strip (T.splitOn " and " normed)
   in not (T.null normed)
        && not (" or " `T.isInfixOf` (" " <> normed <> " "))
        && not (null clauses)
        && all isPlatformClause clauses

isPlatformClause :: Text -> Bool
isPlatformClause clause =
  clause
    `elem` [ "sys_platform == 'win32'",
             "sys_platform == \"win32\"",
             "platform_system == 'windows'",
             "platform_system == \"windows\"",
             "os_name == 'nt'",
             "os_name == \"nt\"",
             "sys_platform == 'darwin'",
             "sys_platform == \"darwin\"",
             "platform_system == 'darwin'",
             "platform_system == \"darwin\""
           ]

norm :: Text -> Text
norm = T.toLower . T.replace "_" "-"
