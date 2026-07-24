{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Tree
  ( Arch,
    KeywordTier (..),
    CeilingLane (..),
    ArchCeilings (..),
    RuntimeCeilings (..),
    GoCeilings,
    RuntimeEbuildMeta (..),
    GoEbuildMeta,
    PortageqRunner,
    productionPortageqRunner,
    gentooRepoPath,
    goPackageDir,
    nodejsPackageDir,
    bunBinPackageDir,
    parseKeywordsField,
    normalizeArchToken,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    isLiveRuntimeVersion,
    isLiveGoVersion,
    parseRuntimeEbuildMeta,
    parseGoEbuildMeta,
    discoverArches,
    computeCeilings,
    emptyCeilings,
    ceilingFor,
    allCeilingLanes,
    discoverRuntimeCeilingsInDir,
    discoverGoCeilingsWith,
    discoverNodejsCeilingsWith,
    discoverBunBinCeilings,
    discoverRustUnionCeilingsWith,
    mergeCeilingsMax,
    goRuntimeAtom,
    nodejsRuntimeAtom,
    bunBinRuntimeAtom,
    rustUnionRuntimeAtom,
    rustPackageDir,
    rustBinPackageDir,
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.Process (readProcessWithExitCode)

-- | Architecture token without leading @~@ (e.g. @"amd64"@, @"loong"@).
type Arch = Text

-- | Plain (stable) vs tilde (~) keyword tier.
data KeywordTier = Plain | Tilde
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One runtime ceiling lane: arch × tier.
data CeilingLane = CeilingLane
  { clArch :: Arch,
    clTier :: KeywordTier
  }
  deriving (Eq, Ord, Show)

-- | Plain and tilde ceilings for one arch.
data ArchCeilings = ArchCeilings
  { acPlain :: Maybe EbuildVersion,
    acTilde :: Maybe EbuildVersion
  }
  deriving (Eq, Show)

-- | Runtime ceilings discovered from a runtime package's KEYWORDS (all arches).
data RuntimeCeilings = RuntimeCeilings
  { -- | Runtime package atom for labels, e.g. @"dev-lang/go"@.
    rcAtom :: Text,
    -- | Per-arch plain/tilde ceilings.
    rcByArch :: Map Arch ArchCeilings
  }
  deriving (Eq, Show)

-- | Historical alias used by Go planning paths.
type GoCeilings = RuntimeCeilings

goRuntimeAtom :: Text
goRuntimeAtom = "dev-lang/go"

nodejsRuntimeAtom :: Text
nodejsRuntimeAtom = "net-libs/nodejs"

bunBinRuntimeAtom :: Text
bunBinRuntimeAtom = "dev-lang/bun-bin"

-- | Fixed union id for cargo lane labels (rust || rust-bin).
rustUnionRuntimeAtom :: Text
rustUnionRuntimeAtom = "dev-lang/rust|rust-bin"

emptyCeilings :: Text -> RuntimeCeilings
emptyCeilings atom = RuntimeCeilings {rcAtom = atom, rcByArch = Map.empty}

ceilingFor :: RuntimeCeilings -> CeilingLane -> Maybe EbuildVersion
ceilingFor c (CeilingLane arch tier) =
  case Map.lookup arch (rcByArch c) of
    Nothing -> Nothing
    Just ac -> case tier of
      Plain -> acPlain ac
      Tilde -> acTilde ac

-- | All lanes that have a defined ceiling (non-Nothing).
allCeilingLanes :: RuntimeCeilings -> [CeilingLane]
allCeilingLanes c =
  concatMap lanesFor (Map.toAscList (rcByArch c))
  where
    lanesFor (arch, ac) =
      [CeilingLane arch Plain | Just _ <- [acPlain ac]]
        <> [CeilingLane arch Tilde | Just _ <- [acTilde ac]]

-- | Parsed non-live runtime ebuild metadata.
data RuntimeEbuildMeta = RuntimeEbuildMeta
  { remPV :: EbuildVersion,
    remKeywords :: [Text]
  }
  deriving (Eq, Show)

type GoEbuildMeta = RuntimeEbuildMeta

-- | Injectable @portageq@ runner: args → stdout or error.
type PortageqRunner = [String] -> IO (Either Text Text)

productionPortageqRunner :: PortageqRunner
productionPortageqRunner args = do
  (code, out, err) <- readProcessWithExitCode "portageq" args ""
  pure $
    if code == ExitSuccess
      then Right (T.strip (T.pack out))
      else
        Left
          ( "portageq "
              <> T.intercalate " " (map T.pack args)
              <> " failed: "
              <> T.pack err
          )

-- | Resolve Gentoo repository path via @portageq get_repo_path / gentoo@.
gentooRepoPath :: PortageqRunner -> IO (Either Text FilePath)
gentooRepoPath run = do
  result <- run ["get_repo_path", "/", "gentoo"]
  pure $ case result of
    Left err -> Left err
    Right path
      | T.null path -> Left "portageq get_repo_path / gentoo returned empty path"
      | otherwise -> Right (T.unpack path)

goPackageDir :: FilePath -> FilePath
goPackageDir gentooRoot = gentooRoot </> "dev-lang" </> "go"

nodejsPackageDir :: FilePath -> FilePath
nodejsPackageDir gentooRoot = gentooRoot </> "net-libs" </> "nodejs"

bunBinPackageDir :: FilePath -> FilePath
bunBinPackageDir overlayRoot = overlayRoot </> "dev-lang" </> "bun-bin"

rustPackageDir :: FilePath -> FilePath
rustPackageDir gentooRoot = gentooRoot </> "dev-lang" </> "rust"

rustBinPackageDir :: FilePath -> FilePath
rustBinPackageDir gentooRoot = gentooRoot </> "dev-lang" </> "rust-bin"

-- | Parse KEYWORDS=... from ebuild body into token list.
-- Shell comments after the assignment (@# …@) are stripped so rust-bin lines like
-- @KEYWORDS=\"…\" # \"~mips ~sparc\"@ do not pollute arch discovery.
parseKeywordsField :: Text -> [Text]
parseKeywordsField content =
  case mapMaybe lineKeywords (T.lines content) of
    (toks : _) -> toks
    [] -> []
  where
    lineKeywords ln =
      let stripped = T.stripStart ln
       in if "KEYWORDS=" `T.isPrefixOf` stripped
            then Just (tokenizeKeywordsValue (T.drop (T.length ("KEYWORDS=" :: Text)) stripped))
            else Nothing

    tokenizeKeywordsValue raw =
      let noComment = stripShellComment (T.strip raw)
          unquoted = stripQuotes noComment
       in mapMaybe cleanKeywordToken (T.words unquoted)

    -- Drop @#…@ only when @#@ is outside a still-open quote (best-effort for one line).
    stripShellComment t =
      let go inQ i
            | i >= T.length t = t
            | T.index t i == '"' = go (not inQ) (i + 1)
            | T.index t i == '#' && not inQ = T.take i t
            | otherwise = go inQ (i + 1)
       in T.strip (go False 0)

    stripQuotes t
      | T.length t >= 2,
        T.head t == '"',
        T.last t == '"' =
          T.init (T.tail t)
      | T.length t >= 2,
        T.head t == '\'',
        T.last t == '\'' =
          T.init (T.tail t)
      | otherwise = t

    cleanKeywordToken t =
      let t1 = T.dropWhile (== '"') (T.dropWhileEnd (== '"') (T.strip t))
       in if T.null t1 then Nothing else Just t1

-- | True when KEYWORDS contain the bare arch token (exact word, not @~arch@).
keywordsHasBare :: Arch -> [Text] -> Bool
keywordsHasBare arch toks = arch `elem` toks

-- | True when KEYWORDS contain @~arch@ or bare @arch@.
keywordsHasTildeOrBare :: Arch -> [Text] -> Bool
keywordsHasTildeOrBare arch toks =
  let tilde = "~" <> arch
   in arch `elem` toks || tilde `elem` toks

-- | Live / unversioned ebuilds are ignored for ceilings.
isLiveRuntimeVersion :: EbuildVersion -> Bool
isLiveRuntimeVersion (Numeric [9999] _) = True
isLiveRuntimeVersion (Numeric comps _)
  | comps == [9999] = True
  | otherwise = False
isLiveRuntimeVersion (Raw t) =
  T.strip t == "9999" || "9999" `T.isPrefixOf` t

isLiveGoVersion :: EbuildVersion -> Bool
isLiveGoVersion = isLiveRuntimeVersion

-- | Discover arch names from KEYWORDS (strip @~@; ignore @-*@).
discoverArches :: [RuntimeEbuildMeta] -> [Arch]
discoverArches metas =
  sort $
    nub
      [ arch
      | m <- metas,
        tok <- remKeywords m,
        Just arch <- [normalizeArchToken tok]
      ]

normalizeArchToken :: Text -> Maybe Arch
normalizeArchToken tok
  | tok == "-*" = Nothing
  | tok == "*" = Nothing
  | tok == "#" = Nothing
  | "-" `T.isPrefixOf` tok = Nothing
  | "~" `T.isPrefixOf` tok =
      let arch = T.drop 1 tok
       in validArchName arch
  | otherwise = validArchName tok

-- | Gentoo arch token: letters, digits, @-@, @_@ only (reject @#@, quotes, etc.).
validArchName :: Text -> Maybe Arch
validArchName a
  | T.null a = Nothing
  | T.all isArchChar a = Just a
  | otherwise = Nothing
  where
    isArchChar c =
      isAsciiLower c
        || isAsciiUpper c
        || isDigit c
        || c == '-'
        || c == '_'

-- | Parse PV + KEYWORDS from a runtime ebuild path and content.
parseRuntimeEbuildMeta :: FilePath -> Text -> Maybe RuntimeEbuildMeta
parseRuntimeEbuildMeta path content =
  case parseEbuildFileName (takeFileName path) of
    Nothing -> Nothing
    Just (_pn, verStr) ->
      let pv = parseEbuildVersion (T.pack verStr)
       in if isLiveRuntimeVersion pv
            then Nothing
            else
              Just
                RuntimeEbuildMeta
                  { remPV = pv,
                    remKeywords = parseKeywordsField content
                  }

parseGoEbuildMeta :: FilePath -> Text -> Maybe GoEbuildMeta
parseGoEbuildMeta = parseRuntimeEbuildMeta

-- | Compute ceilings from already-parsed runtime ebuild metadata.
computeCeilings :: Text -> [RuntimeEbuildMeta] -> RuntimeCeilings
computeCeilings atom metas =
  let arches = discoverArches metas
      byArch =
        Map.fromList
          [ (arch, ceilingsForArch arch metas)
          | arch <- arches
          ]
   in RuntimeCeilings {rcAtom = atom, rcByArch = byArch}

ceilingsForArch :: Arch -> [RuntimeEbuildMeta] -> ArchCeilings
ceilingsForArch arch metas =
  ArchCeilings
    { acPlain = maxPV [remPV m | m <- metas, keywordsHasBare arch (remKeywords m)],
      acTilde = maxPV [remPV m | m <- metas, keywordsHasTildeOrBare arch (remKeywords m)]
    }

maxPV :: [EbuildVersion] -> Maybe EbuildVersion
maxPV [] = Nothing
maxPV (x : xs) = Just (foldl' maxOne x xs)
  where
    maxOne a b =
      case comparePV a b of
        Just LT -> b
        _ -> a

-- | Scan a package directory of @*.ebuild@ files for ceilings.
discoverRuntimeCeilingsInDir ::
  Text ->
  FilePath ->
  -- | Optional filename prefix filter (e.g. @"go-"@); Nothing = all ebuilds.
  Maybe Text ->
  IO (Either Text RuntimeCeilings)
discoverRuntimeCeilingsInDir atom pkgDir mPrefix = do
  exists <- doesDirectoryExist pkgDir
  if not exists
    then
      pure $
        Left
          ( atom
              <> " directory not found: "
              <> T.pack pkgDir
          )
    else do
      names <- listDirectory pkgDir
      let ebuildNames =
            [ n
            | n <- names,
              ".ebuild" `T.isSuffixOf` T.pack n,
              case mPrefix of
                Nothing -> True
                Just p -> p `T.isPrefixOf` T.pack n
            ]
      metas <- mapM (readMeta pkgDir) ebuildNames
      pure $ Right (computeCeilings atom (catMaybes metas))
  where
    readMeta dir name = do
      let path = dir </> name
      content <- TIO.readFile path
      pure (parseRuntimeEbuildMeta path content)

-- | Discover Go ceilings with injectable portageq; scans @dev-lang/go@.
discoverGoCeilingsWith :: PortageqRunner -> IO (Either Text RuntimeCeilings)
discoverGoCeilingsWith run = do
  pathResult <- gentooRepoPath run
  case pathResult of
    Left err -> pure (Left err)
    Right gentooRoot ->
      discoverRuntimeCeilingsInDir goRuntimeAtom (goPackageDir gentooRoot) (Just "go-")

-- | Discover nodejs ceilings from gentoo @net-libs/nodejs@.
discoverNodejsCeilingsWith :: PortageqRunner -> IO (Either Text RuntimeCeilings)
discoverNodejsCeilingsWith run = do
  pathResult <- gentooRepoPath run
  case pathResult of
    Left err -> pure (Left err)
    Right gentooRoot ->
      discoverRuntimeCeilingsInDir
        nodejsRuntimeAtom
        (nodejsPackageDir gentooRoot)
        (Just "nodejs-")

-- | Discover bun-bin ceilings from the overlay package directory.
discoverBunBinCeilings :: FilePath -> IO (Either Text RuntimeCeilings)
discoverBunBinCeilings overlayRoot =
  discoverRuntimeCeilingsInDir
    bunBinRuntimeAtom
    (bunBinPackageDir overlayRoot)
    (Just "bun-bin-")

-- | Discover cargo ceilings: U1 max of gentoo @dev-lang/rust@ ∪ @dev-lang/rust-bin@.
-- Missing side is ignored; both missing is an error.
discoverRustUnionCeilingsWith :: PortageqRunner -> IO (Either Text RuntimeCeilings)
discoverRustUnionCeilingsWith run = do
  pathResult <- gentooRepoPath run
  case pathResult of
    Left err -> pure (Left err)
    Right gentooRoot -> do
      rustExists <- doesDirectoryExist (rustPackageDir gentooRoot)
      binExists <- doesDirectoryExist (rustBinPackageDir gentooRoot)
      if not rustExists && not binExists
        then
          pure $
            Left
              ( "neither "
                  <> "dev-lang/rust"
                  <> " nor "
                  <> "dev-lang/rust-bin"
                  <> " found under "
                  <> T.pack gentooRoot
              )
        else do
          rustC <-
            if rustExists
              then
                discoverRuntimeCeilingsInDir
                  "dev-lang/rust"
                  (rustPackageDir gentooRoot)
                  (Just "rust-")
              else pure (Right (emptyCeilings "dev-lang/rust"))
          binC <-
            if binExists
              then
                discoverRuntimeCeilingsInDir
                  "dev-lang/rust-bin"
                  (rustBinPackageDir gentooRoot)
                  (Just "rust-bin-")
              else pure (Right (emptyCeilings "dev-lang/rust-bin"))
          pure $ case (rustC, binC) of
            (Left err, _) -> Left err
            (_, Left err) -> Left err
            (Right a, Right b) ->
              Right (mergeCeilingsMax rustUnionRuntimeAtom a b)

-- | Per arch×tier ceiling = max of the two inputs (U1).
mergeCeilingsMax :: Text -> RuntimeCeilings -> RuntimeCeilings -> RuntimeCeilings
mergeCeilingsMax atom a b =
  let arches = sort $ nub (Map.keys (rcByArch a) <> Map.keys (rcByArch b))
      byArch =
        Map.fromList
          [ (arch, mergeArch (lookupArch a arch) (lookupArch b arch))
          | arch <- arches
          ]
   in RuntimeCeilings {rcAtom = atom, rcByArch = byArch}
  where
    lookupArch c arch =
      Map.findWithDefault (ArchCeilings Nothing Nothing) arch (rcByArch c)
    mergeArch x y =
      ArchCeilings
        { acPlain = maxMaybe (acPlain x) (acPlain y),
          acTilde = maxMaybe (acTilde x) (acTilde y)
        }
    maxMaybe Nothing o = o
    maxMaybe o Nothing = o
    maxMaybe (Just x) (Just y) =
      Just $
        case comparePV x y of
          Just LT -> y
          _ -> x
