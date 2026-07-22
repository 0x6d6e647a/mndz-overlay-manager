{-# LANGUAGE OverloadedStrings #-}

-- | Portage md5-dict cache: layout gate, consistency checks, and @egencache@.
--
-- Production @egencache@ argv (spike-confirmed on Gentoo with Portage masters):
--
-- @
-- egencache --repo mndz
--   --repositories-configuration=$'\[gentoo\]\\nlocation = \<gentoo\>\\nmasters =\\n\\n\[mndz\]\\nlocation = \<overlay\>\\nmasters = gentoo\\nauto-sync = false\\n'
--   --update [category/package ...]
--   [-j N]
-- @
--
-- The repositories-configuration fragment always sets @mndz@ @location@ to the
-- absolute effective overlay path so ambient @repos.conf@ cannot redirect writes.
-- Gentoo location is resolved via @portageq get_repo_path / gentoo@ when that
-- succeeds, otherwise @\/var\/db\/repos\/gentoo@ when that directory exists.
module Update.Md5Cache
  ( VersionCacheStatus (..),
    PackageCacheIssue (..),
    EgencacheRequest (..),
    EgencacheRunner,
    productionEgencacheRunner,
    buildRepositoriesConfiguration,
    discoverGentooLocation,
    checkLayoutCacheFormats,
    layoutConfPath,
    ebuildFileMd5,
    readCacheMd5Field,
    cacheFilePath,
    listNonLiveEbuildVersions,
    classifyVersionCache,
    inspectPackageCache,
    packageCacheGateError,
    listPackageMd5CacheRelPaths,
    runPackageEgencache,
    collectPackageCachePathspecs,
    gencacheRequiredTools,
    preflightGencache,
    preflightGencacheWith,
    decideGencacheAction,
    GencacheAction (..),
    gencacheCommitMessage,
    gencachePackages,
    packageDirForKey,
  )
where

import Crypto.Hash (Digest, MD5 (..), hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Char (isSpace)
import Data.List (nub)
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (parseEbuildVersion)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    findExecutable,
    listDirectory,
    makeAbsolute,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Update.Git (GitOps (..))
import Update.Go.Plan (isLivePackageVersion)
import Update.Types (PackageKey (..), packageKeyText, splitPackageKey)

-- | Per-version md5-cache consistency against a non-live ebuild.
data VersionCacheStatus
  = VersionCacheMatch
  | VersionCacheMissing
  | VersionCacheMismatch
  deriving (Eq, Show)

-- | Package-level gate failure (any non-live version incomplete).
data PackageCacheIssue
  = -- | At least one required cache file is absent.
    PackageCacheMissing [Text]
  | -- | At least one cache file has a wrong @_md5_@ (missing takes priority).
    PackageCacheMismatch [Text]
  deriving (Eq, Show)

-- | Request passed to an injectable @egencache@ runner.
data EgencacheRequest = EgencacheRequest
  { erOverlayRoot :: FilePath,
    -- | @category/package@ atoms; empty means full-repo @--update@.
    erAtoms :: [Text],
    erJobs :: Maybe Int
  }
  deriving (Eq, Show)

type EgencacheRunner = EgencacheRequest -> IO (Either Text ())

-- | Tools required on PATH for @gencache@.
gencacheRequiredTools :: [String]
gencacheRequiredTools = ["git", "egencache", "gpg"]

preflightGencacheWith :: (String -> IO (Maybe FilePath)) -> IO (Either Text ())
preflightGencacheWith findTool = do
  results <- mapM (\t -> (t,) <$> findTool t) gencacheRequiredTools
  let missing = [name | (name, path) <- results, isNothing path]
  pure $ case missing of
    [] -> Right ()
    ms ->
      Left $
        "gencache requires the following tools on PATH: "
          <> T.intercalate ", " (map T.pack ms)

-- | Production @gencache@ tool preflight using @findExecutable@.
preflightGencache :: IO (Either Text ())
preflightGencache = preflightGencacheWith findExecutable

-- | Signed commit message for a successful @gencache@ run.
gencacheCommitMessage :: Text
gencacheCommitMessage = "metadata: regenerate md5-cache"

------------------------------------------------------------------------
-- layout.conf gate
------------------------------------------------------------------------

layoutConfPath :: FilePath -> FilePath
layoutConfPath overlayRoot = overlayRoot </> "metadata" </> "layout.conf"

-- | Require @cache-formats@ to list @md5-dict@ (case-insensitive token match).
checkLayoutCacheFormats :: FilePath -> IO (Either Text ())
checkLayoutCacheFormats overlayRoot = do
  let path = layoutConfPath overlayRoot
  exists <- doesFileExist path
  if not exists
    then
      pure $
        Left
          "missing metadata/layout.conf; add cache-formats = md5-dict and commit \
          \before cache work"
    else do
      text <- TIO.readFile path
      pure $
        if layoutHasMd5Dict text
          then Right ()
          else
            Left
              "metadata/layout.conf must list md5-dict in cache-formats \
              \(e.g. cache-formats = md5-dict); commit that change before \
              \running gencache or update"

-- | Pure parse of layout.conf body for tests.
layoutHasMd5Dict :: Text -> Bool
layoutHasMd5Dict body =
  any lineHasMd5Dict (T.lines body)
  where
    lineHasMd5Dict line =
      case breakKv (T.strip line) of
        Just (k, v)
          | T.toLower (T.strip k) == "cache-formats" ->
              any
                (\tok -> T.toLower tok == "md5-dict")
                (T.words v)
        _ -> False

breakKv :: Text -> Maybe (Text, Text)
breakKv line =
  case T.break (== '=') line of
    (k, rest)
      | Just ('=', v) <- T.uncons rest ->
          Just (T.strip k, T.strip v)
    _ -> Nothing

------------------------------------------------------------------------
-- MD5 helpers
------------------------------------------------------------------------

-- | Lowercase hex MD5 of file contents (binary read).
ebuildFileMd5 :: FilePath -> IO Text
ebuildFileMd5 path = do
  bs <- BS.readFile path
  pure $ md5Hex bs

md5Hex :: BS.ByteString -> Text
md5Hex bs =
  T.toLower . decodeUtf8 $ convertToBase Base16 (hash bs :: Digest MD5)

-- | Read @_md5_@ field from an md5-dict cache file (if present and parseable).
readCacheMd5Field :: FilePath -> IO (Maybe Text)
readCacheMd5Field path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      text <- TIO.readFile path
      pure $ findMd5Field text

findMd5Field :: Text -> Maybe Text
findMd5Field body =
  case mapMaybe parseMd5Line (T.lines body) of
    (v : _) -> Just v
    [] -> Nothing
  where
    parseMd5Line line =
      case T.break (== '=') (T.strip line) of
        (k, rest)
          | T.toLower (T.strip k) == "_md5_",
            Just ('=', v) <- T.uncons rest ->
              let val = T.strip v
               in if T.null val then Nothing else Just val
        _ -> Nothing

cacheFilePath :: FilePath -> Text -> Text -> Text -> FilePath
cacheFilePath overlayRoot category pn verText =
  overlayRoot
    </> "metadata"
    </> "md5-cache"
    </> T.unpack category
    </> (T.unpack pn <> "-" <> T.unpack verText)

------------------------------------------------------------------------
-- Package inventory and classification
------------------------------------------------------------------------

-- | Non-live ebuild versions under a package directory: @(version text, path)@.
listNonLiveEbuildVersions :: FilePath -> Text -> IO [(Text, FilePath)]
listNonLiveEbuildVersions pkgDir pn = do
  exists <- doesDirectoryExist pkgDir
  if not exists
    then pure []
    else do
      names <- listDirectory pkgDir
      pure $
        [ (T.pack verStr, pkgDir </> name)
        | name <- names,
          Just (pkg, verStr) <- [parseEbuildFileName name],
          T.pack pkg == pn,
          let v = parseEbuildVersion (T.pack verStr),
          not (isLivePackageVersion v)
        ]

classifyVersionCache :: FilePath -> Text -> Text -> Text -> FilePath -> IO VersionCacheStatus
classifyVersionCache overlayRoot category pn verText ebuildPath = do
  let cpath = cacheFilePath overlayRoot category pn verText
  exists <- doesFileExist cpath
  if not exists
    then pure VersionCacheMissing
    else do
      fileMd5 <- ebuildFileMd5 ebuildPath
      mCache <- readCacheMd5Field cpath
      pure $ case mCache of
        Just c | T.toLower c == T.toLower fileMd5 -> VersionCacheMatch
        Just _ -> VersionCacheMismatch
        Nothing -> VersionCacheMismatch

-- | Inspect all non-live versions; missing wins over mismatch for gate messaging.
inspectPackageCache ::
  FilePath ->
  Text ->
  Text ->
  FilePath ->
  IO (Either PackageCacheIssue ())
inspectPackageCache overlayRoot category pn pkgDir = do
  vers <- listNonLiveEbuildVersions pkgDir pn
  statuses <-
    mapM
      ( \(verText, path) -> do
          st <- classifyVersionCache overlayRoot category pn verText path
          pure (verText, st)
      )
      vers
  let missing = [v | (v, VersionCacheMissing) <- statuses]
      mismatch = [v | (v, VersionCacheMismatch) <- statuses]
  pure $ case (missing, mismatch) of
    ([], []) -> Right ()
    (ms@(_ : _), _) -> Left (PackageCacheMissing ms)
    ([], ms) -> Left (PackageCacheMismatch ms)

-- | Human-readable hard-fail for the update unit gate.
packageCacheGateError :: PackageKey -> PackageCacheIssue -> Text
packageCacheGateError key = \case
  PackageCacheMissing _ ->
    "md5-cache missing for one or more ebuilds; bootstrap with: gencache "
      <> packageKeyText key
  PackageCacheMismatch _ ->
    "md5-cache _md5_ mismatch for one or more ebuilds; reconcile with: gencache --force "
      <> packageKeyText key

------------------------------------------------------------------------
-- Cache pathspecs for git
------------------------------------------------------------------------

-- | Relative pathspecs under @metadata/md5-cache/category/@ for this package.
listPackageMd5CacheRelPaths :: FilePath -> Text -> Text -> IO [FilePath]
listPackageMd5CacheRelPaths overlayRoot category pn = do
  let dir =
        overlayRoot
          </> "metadata"
          </> "md5-cache"
          </> T.unpack category
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      names <- listDirectory dir
      pure
        [ "metadata"
            </> "md5-cache"
            </> T.unpack category
            </> name
        | name <- names,
          Just (pkg, _) <- [parseCacheEntryName name],
          T.pack pkg == pn
        ]

-- | Same version-hyphen rule as ebuild filenames, without @.ebuild@.
parseCacheEntryName :: String -> Maybe (String, String)
parseCacheEntryName name = parseEbuildFileName (name <> ".ebuild")

-- | Before/after union of package cache pathspecs (covers adds and deletions).
collectPackageCachePathspecs ::
  FilePath ->
  Text ->
  Text ->
  [FilePath] ->
  IO [FilePath]
collectPackageCachePathspecs overlayRoot category pn before = do
  after <- listPackageMd5CacheRelPaths overlayRoot category pn
  pure (nub (before <> after))

------------------------------------------------------------------------
-- egencache runner
------------------------------------------------------------------------

-- | Resolve gentoo master location for the injected repositories configuration.
discoverGentooLocation :: IO (Either Text FilePath)
discoverGentooLocation = do
  (code, out, _err) <-
    readProcessWithExitCode "portageq" ["get_repo_path", "/", "gentoo"] ""
  let fromPq =
        if code == ExitSuccess
          then
            let p = stripSpaces out
             in if null p then Nothing else Just p
          else Nothing
  case fromPq of
    Just p -> do
      ok <- doesDirectoryExist p
      if ok
        then pure (Right p)
        else tryDefault
    Nothing -> tryDefault
  where
    tryDefault = do
      let def = "/var/db/repos/gentoo"
      ok <- doesDirectoryExist def
      pure $
        if ok
          then Right def
          else
            Left
              "could not resolve gentoo repository location \
              \(portageq get_repo_path / gentoo failed and /var/db/repos/gentoo \
              \is missing)"

stripSpaces :: String -> String
stripSpaces = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | Build the @--repositories-configuration@ string (repos.conf format).
buildRepositoriesConfiguration :: FilePath -> FilePath -> Text
buildRepositoriesConfiguration gentooLoc overlayLoc =
  T.unlines
    [ "[gentoo]",
      "location = " <> T.pack gentooLoc,
      "masters =",
      "",
      "[mndz]",
      "location = " <> T.pack overlayLoc,
      "masters = gentoo",
      "auto-sync = false"
    ]

productionEgencacheRunner :: EgencacheRunner
productionEgencacheRunner req = do
  gentoo <- discoverGentooLocation
  case gentoo of
    Left err -> pure (Left err)
    Right gentooLoc -> do
      rootAbs <- makeAbsolute (erOverlayRoot req)
      let reposConf = T.unpack (buildRepositoriesConfiguration gentooLoc rootAbs)
          atoms = map T.unpack (erAtoms req)
          jobsArgs = case erJobs req of
            Just n | n > 0 -> ["--jobs", show n]
            _ -> []
          args =
            [ "--repo",
              "mndz",
              "--repositories-configuration",
              reposConf,
              "--update"
            ]
              <> atoms
              <> jobsArgs
      (code, _out, err) <- readProcessWithExitCode "egencache" args ""
      pure $
        if code == ExitSuccess
          then Right ()
          else Left ("egencache failed: " <> T.pack err)

-- | Run package-scoped egencache and return pathspecs for git (before∪after).
runPackageEgencache ::
  EgencacheRunner ->
  FilePath ->
  PackageKey ->
  Maybe Int ->
  IO (Either Text [FilePath])
runPackageEgencache runner overlayRoot key mJobs =
  case splitPackageKey key of
    Nothing -> pure (Left ("invalid package key: " <> packageKeyText key))
    Just (category, pn) -> do
      before <- listPackageMd5CacheRelPaths overlayRoot category pn
      result <-
        runner
          EgencacheRequest
            { erOverlayRoot = overlayRoot,
              erAtoms = [packageKeyText key],
              erJobs = mJobs
            }
      case result of
        Left err -> pure (Left err)
        Right () -> do
          paths <- collectPackageCachePathspecs overlayRoot category pn before
          pure (Right paths)

------------------------------------------------------------------------
-- gencache decision (strict-strict)
------------------------------------------------------------------------

data GencacheAction
  = -- | Run egencache for this package.
    GencacheGenerate
  | -- | Already matching; skip unless force.
    GencacheSkip
  | -- | Mismatch without force.
    GencacheError Text
  deriving (Eq, Show)

-- | Strict-strict decision for one package under @gencache@.
decideGencacheAction :: Bool -> Either PackageCacheIssue () -> GencacheAction
decideGencacheAction force = \case
  _
    | force -> GencacheGenerate
  Right () -> GencacheSkip
  Left (PackageCacheMissing _) -> GencacheGenerate
  Left (PackageCacheMismatch _) ->
    GencacheError
      "md5-cache _md5_ mismatch; re-run with --force to regenerate \
      \(e.g. gencache --force category/package)"

-- | Package directory for a @category/package@ key under the overlay root.
packageDirForKey :: FilePath -> PackageKey -> Maybe FilePath
packageDirForKey overlayRoot key =
  case splitPackageKey key of
    Just (cat, pn) -> Just (overlayRoot </> T.unpack cat </> T.unpack pn)
    Nothing -> Nothing

-- | Strict-strict @gencache@ loop: generate/skip/error per package, then one
-- signed commit of changed @metadata/md5-cache/**@ paths when the tree is dirty.
--
-- Returns @Right Nothing@ when nothing changed (no empty commit).
-- Returns @Right (Just paths)@ after a successful signed commit.
gencachePackages ::
  EgencacheRunner ->
  GitOps ->
  FilePath ->
  [PackageKey] ->
  Bool ->
  Maybe Int ->
  IO (Either Text (Maybe [FilePath]))
gencachePackages runner gitOps overlayRoot keys force mJobs = do
  beforeAll <- listAllMd5CacheRelPaths overlayRoot
  let go [] = pure (Right ())
      go (key : rest) =
        case splitPackageKey key of
          Nothing -> pure (Left ("invalid package key: " <> packageKeyText key))
          Just (category, pn) ->
            case packageDirForKey overlayRoot key of
              Nothing -> pure (Left ("invalid package key: " <> packageKeyText key))
              Just pkgDir -> do
                inspected <- inspectPackageCache overlayRoot category pn pkgDir
                case decideGencacheAction force inspected of
                  GencacheSkip -> go rest
                  GencacheError msg ->
                    pure $
                      Left (packageKeyText key <> ": " <> msg)
                  GencacheGenerate -> do
                    result <-
                      runner
                        EgencacheRequest
                          { erOverlayRoot = overlayRoot,
                            erAtoms = [packageKeyText key],
                            erJobs = mJobs
                          }
                    case result of
                      Left err ->
                        pure $
                          Left (packageKeyText key <> ": " <> err)
                      Right () -> go rest
  decided <- go keys
  case decided of
    Left err -> pure (Left err)
    Right () -> do
      afterAll <- listAllMd5CacheRelPaths overlayRoot
      let pathspecs = nub (beforeAll <> afterAll)
      if null pathspecs
        then pure (Right Nothing)
        else do
          dirty <- goPathsDirty gitOps overlayRoot pathspecs
          case dirty of
            Left err -> pure (Left err)
            Right False -> pure (Right Nothing)
            Right True -> do
              committed <-
                goAddAndCommit gitOps overlayRoot pathspecs gencacheCommitMessage
              pure $ case committed of
                Left err -> Left err
                Right () -> Right (Just pathspecs)

-- | All relative paths currently under @metadata/md5-cache/@.
listAllMd5CacheRelPaths :: FilePath -> IO [FilePath]
listAllMd5CacheRelPaths overlayRoot = do
  let root = overlayRoot </> "metadata" </> "md5-cache"
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      cats <- listDirectory root
      concat
        <$> mapM
          ( \cat -> do
              let catDir = root </> cat
              isDir <- doesDirectoryExist catDir
              if not isDir
                then pure []
                else do
                  names <- listDirectory catDir
                  pure
                    [ "metadata" </> "md5-cache" </> cat </> name
                    | name <- names
                    ]
          )
          cats
