{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Tree
  ( GoArch (..),
    KeywordTier (..),
    GoCeilingLane (..),
    GoCeilings (..),
    GoEbuildMeta (..),
    PortageqRunner,
    productionPortageqRunner,
    gentooRepoPath,
    goPackageDir,
    parseKeywordsField,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    isLiveGoVersion,
    parseGoEbuildMeta,
    computeCeilings,
    discoverGoCeilingsWith,
    emptyCeilings,
    ceilingFor,
  )
where

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

-- | Arches supported by the tree-lane planner.
data GoArch = Amd64 | Arm64
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Plain (stable) vs tilde (~) keyword tier for dev-lang/go.
data KeywordTier = Plain | Tilde
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One of the four Go ceiling lanes.
data GoCeilingLane = GoCeilingLane
  { gclArch :: GoArch,
    gclTier :: KeywordTier
  }
  deriving (Eq, Ord, Show)

-- | Four ceilings; 'Nothing' means no matching non-live go ebuild.
data GoCeilings = GoCeilings
  { gcAmd64Plain :: Maybe EbuildVersion,
    gcAmd64Tilde :: Maybe EbuildVersion,
    gcArm64Plain :: Maybe EbuildVersion,
    gcArm64Tilde :: Maybe EbuildVersion
  }
  deriving (Eq, Show)

emptyCeilings :: GoCeilings
emptyCeilings =
  GoCeilings
    { gcAmd64Plain = Nothing,
      gcAmd64Tilde = Nothing,
      gcArm64Plain = Nothing,
      gcArm64Tilde = Nothing
    }

ceilingFor :: GoCeilings -> GoCeilingLane -> Maybe EbuildVersion
ceilingFor c (GoCeilingLane Amd64 Plain) = gcAmd64Plain c
ceilingFor c (GoCeilingLane Amd64 Tilde) = gcAmd64Tilde c
ceilingFor c (GoCeilingLane Arm64 Plain) = gcArm64Plain c
ceilingFor c (GoCeilingLane Arm64 Tilde) = gcArm64Tilde c

-- | Parsed non-live go ebuild metadata.
data GoEbuildMeta = GoEbuildMeta
  { gemPV :: EbuildVersion,
    gemKeywords :: [Text]
  }
  deriving (Eq, Show)

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

-- | Parse KEYWORDS=... from ebuild body into token list.
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
      let unquoted = stripQuotes (T.strip raw)
       in filter (not . T.null) (T.words unquoted)

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

-- | True when KEYWORDS contain the bare arch token (exact word, not @~arch@).
keywordsHasBare :: GoArch -> [Text] -> Bool
keywordsHasBare arch toks = archToken arch `elem` toks

-- | True when KEYWORDS contain @~arch@ or bare @arch@.
keywordsHasTildeOrBare :: GoArch -> [Text] -> Bool
keywordsHasTildeOrBare arch toks =
  let bare = archToken arch
      tilde = "~" <> bare
   in bare `elem` toks || tilde `elem` toks

archToken :: GoArch -> Text
archToken Amd64 = "amd64"
archToken Arm64 = "arm64"

-- | Live / unversioned go ebuilds are ignored for ceilings.
isLiveGoVersion :: EbuildVersion -> Bool
isLiveGoVersion (Numeric [9999] _) = True
isLiveGoVersion (Numeric comps _)
  | comps == [9999] = True
  | otherwise = False
isLiveGoVersion (Raw t) =
  T.strip t == "9999" || "9999" `T.isPrefixOf` t

-- | Parse PV + KEYWORDS from a go ebuild path and content.
parseGoEbuildMeta :: FilePath -> Text -> Maybe GoEbuildMeta
parseGoEbuildMeta path content =
  case parseEbuildFileName (takeFileName path) of
    Nothing -> Nothing
    Just (_pn, verStr) ->
      let pv = parseEbuildVersion (T.pack verStr)
       in if isLiveGoVersion pv
            then Nothing
            else
              Just
                GoEbuildMeta
                  { gemPV = pv,
                    gemKeywords = parseKeywordsField content
                  }

-- | Compute four ceilings from already-parsed go ebuild metadata.
computeCeilings :: [GoEbuildMeta] -> GoCeilings
computeCeilings =
  foldl' acc emptyCeilings
  where
    acc c m =
      let pv = gemPV m
          kws = gemKeywords m
          bump f =
            case f c of
              Nothing -> Just pv
              Just old ->
                case comparePV old pv of
                  Just LT -> Just pv
                  _ -> Just old
       in c
            { gcAmd64Plain =
                if keywordsHasBare Amd64 kws
                  then bump gcAmd64Plain
                  else gcAmd64Plain c,
              gcAmd64Tilde =
                if keywordsHasTildeOrBare Amd64 kws
                  then bump gcAmd64Tilde
                  else gcAmd64Tilde c,
              gcArm64Plain =
                if keywordsHasBare Arm64 kws
                  then bump gcArm64Plain
                  else gcArm64Plain c,
              gcArm64Tilde =
                if keywordsHasTildeOrBare Arm64 kws
                  then bump gcArm64Tilde
                  else gcArm64Tilde c
            }

-- | Discover ceilings with injectable portageq; scans @dev-lang/go@ under the repo.
discoverGoCeilingsWith :: PortageqRunner -> IO (Either Text GoCeilings)
discoverGoCeilingsWith run = do
  pathResult <- gentooRepoPath run
  case pathResult of
    Left err -> pure (Left err)
    Right gentooRoot -> do
      let pkgDir = goPackageDir gentooRoot
      exists <- doesDirectoryExist pkgDir
      if not exists
        then
          pure $
            Left
              ( "gentoo dev-lang/go directory not found: "
                  <> T.pack pkgDir
              )
        else do
          names <- listDirectory pkgDir
          let ebuildNames =
                [ n
                | n <- names,
                  ".ebuild" `T.isSuffixOf` T.pack n,
                  "go-" `T.isPrefixOf` T.pack n
                ]
          metas <- mapM (readMeta pkgDir) ebuildNames
          pure $ Right (computeCeilings (catMaybes metas))
  where
    readMeta pkgDir name = do
      let path = pkgDir </> name
      content <- TIO.readFile path
      pure (parseGoEbuildMeta path content)
