{-# LANGUAGE OverloadedStrings #-}

module Update.Bun.Cache
  ( BunCacheOps (..),
    BunCacheProgress (..),
    BunPackagingMode (..),
    productionBunCacheOps,
    mkBunCacheOps,
    buildBunDepsTarball,
    bunPackagingModeFor,
    collectInstallTreeEntries,
    parseEnginesBunFromPackageJson,
    parsePackageManagerBun,
    hostBunVersion,
    hostMeetsBunRequirement,
    bunVersionTooOldMessage,
    rewriteBunCacheSymlinks,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, forM)
import Data.Aeson (Value, eitherDecode, withObject, (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Either (fromRight)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getSymbolicLinkTarget,
    listDirectory,
    makeAbsolute,
    pathIsSymbolicLink,
    removeFile,
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( addTrailingPathSeparator,
    equalFilePath,
    isAbsolute,
    joinPath,
    normalise,
    splitDirectories,
    takeDirectory,
    takeFileName,
    (</>),
  )
import Update.DiskSpace
  ( MaterializeClass (FullNpmBun),
    checkPostCloneForClass,
  )
import Update.Engines (parseEnginesMinimum)
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Go.Version
  ( compareGoVersions,
    parseGoVersionToken,
  )
import Update.Pack.XzTar (packTarXz)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Types (PackageKey (..))

-- | How the Bun deps tarball is packaged for Portage.
data BunPackagingMode
  = -- | Top-level @bun-cache/@ only (e.g. ralph-tui). Ebuild re-runs
    -- @bun install --cache-dir@ at compile time.
    BunCache
  | -- | Repo-relative install tree (@node_modules@ layout) so Portage can
    -- skip @bun install@ entirely (e.g. opencode under network-sandbox).
    InstallTree
  deriving (Eq, Show)

-- | Package-specific packaging mode. @dev-util/opencode@ uses InstallTree;
-- other Bun packages keep BunCache.
bunPackagingModeFor :: PackageKey -> BunPackagingMode
bunPackagingModeFor (PackageKey "dev-util/opencode") = InstallTree
bunPackagingModeFor _ = BunCache

-- | Injectable process steps for bun cache / install-tree construction.
data BunCacheOps = BunCacheOps
  { bcoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    bcoHostBunVersion :: IO (Either Text Text),
    bcoBunInstall :: FilePath -> FilePath -> IO (Either Text ()),
    -- | @workDir@, relative entry paths, output tarball path.
    bcoTarXz :: FilePath -> [FilePath] -> FilePath -> IO (Either Text ())
  }

data BunCacheProgress = BunCacheProgress
  { bcpOnCloneStart :: IO (),
    bcpOnCloneDone :: IO (),
    bcpOnInstallStart :: IO (),
    bcpOnInstallDone :: IO (),
    bcpOnCompressStart :: IO (),
    bcpOnCompressDone :: IO ()
  }

-- | Build bun cache ops over an injectable command runner (Unit heat surface).
mkBunCacheOps :: CommandRunner -> BunCacheOps
mkBunCacheOps run =
  BunCacheOps
    { bcoClone = gitCloneTag run,
      bcoHostBunVersion = hostBunVersion run,
      bcoBunInstall = bunInstallCache run,
      bcoTarXz = tarXzEntries run
    }

productionBunCacheOps :: BunCacheOps
productionBunCacheOps = mkBunCacheOps productionCommandRunner

hostBunVersion :: CommandRunner -> IO (Either Text Text)
hostBunVersion run = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "bun" ["--version"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then Left ("could not determine materialize image Bun version: " <> T.pack (prStderr res))
      else case parseBunVersionOutput (T.pack (prStdout res)) of
        Just v -> Right v
        Nothing ->
          Left
            ( "could not parse materialize image Bun version from: "
                <> T.strip (T.pack (prStdout res))
            )

parseBunVersionOutput :: Text -> Maybe Text
parseBunVersionOutput out =
  case [v | w <- T.words out, Just v <- [tok w]] of
    (v : _) -> Just v
    [] -> Nothing
  where
    tok w =
      let t = if "v" `T.isPrefixOf` w then T.drop 1 w else w
          core = T.takeWhile (\c -> c == '.' || isDigit c) t
       in case parseGoVersionToken core of
            Just _ -> Just core
            Nothing -> Nothing

hostMeetsBunRequirement :: Text -> Text -> Maybe Bool
hostMeetsBunRequirement host required =
  case compareGoVersions host required of
    Just LT -> Just False
    Just _ -> Just True
    Nothing -> Nothing

bunVersionTooOldMessage :: Text -> Text -> Text
bunVersionTooOldMessage host required =
  "materialize image Bun "
    <> host
    <> " is older than Bun requirement "
    <> required
    <> "; rebuild the materialize image with Bun at least "
    <> required

-- | Bun minimum from @package.json@: parseable @engines.bun@ wins; else
-- @packageManager@ form @bun@X.Y.Z@ (optional build metadata ignored).
parseEnginesBunFromPackageJson :: Text -> Maybe Text
parseEnginesBunFromPackageJson body =
  case eitherDecode (BL.fromStrict (TE.encodeUtf8 body)) of
    Right val -> parseMaybe parseBunRequirement val
    Left _ -> Nothing

-- | Parse @packageManager@ value @bun@X.Y.Z@ (optional leading @v@; strip
-- build metadata after @+@).
parsePackageManagerBun :: Text -> Maybe Text
parsePackageManagerBun raw =
  let t0 = T.strip raw
   in case T.stripPrefix "bun@" t0 of
        Nothing -> Nothing
        Just rest ->
          let noMeta = T.takeWhile (/= '+') rest
              noV =
                if "v" `T.isPrefixOf` noMeta
                  && T.length noMeta > 1
                  && isDigit (T.index noMeta 1)
                  then T.drop 1 noMeta
                  else noMeta
              core = T.takeWhile (\c -> c == '.' || isDigit c) noV
           in case parseGoVersionToken core of
                Just _ -> Just core
                Nothing -> Nothing

parseBunRequirement :: Value -> Parser Text
parseBunRequirement =
  withObject "package.json" $ \o -> do
    mEngines <- o .:? "engines"
    mFromEngines <- case mEngines of
      Nothing -> pure Nothing
      Just eng -> do
        mBun <- withObject "engines" (.:? "bun") eng
        pure (parseEnginesMinimum =<< mBun)
    case mFromEngines of
      Just v -> pure v
      Nothing -> do
        mPm <- o .:? "packageManager"
        case mPm of
          Just t
            | Just v <- parsePackageManagerBun t -> pure v
          _ -> fail "no parseable engines.bun or packageManager bun@X.Y.Z"

-- | Clone tag → require bun.lock → bun install → pack per 'BunPackagingMode'.
-- Clone and bun-cache live under unit @workDir@; tarball under @outDir@.
buildBunDepsTarball ::
  BunCacheOps ->
  BunCacheProgress ->
  BunPackagingMode ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  -- | Unit @work/@ (clone + bun-cache).
  FilePath ->
  -- | Unit @out/@ (staged tarball).
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildBunDepsTarball ops progress mode owner repo prefix pv bunReq workDir outDir tarballName = do
  hostResult <- bcoHostBunVersion ops
  case hostResult of
    Left err -> pure (Left err)
    Right host ->
      case hostMeetsBunRequirement host bunReq of
        Just False -> pure (Left (bunVersionTooOldMessage host bunReq))
        Nothing ->
          pure $
            Left
              ( "could not compare materialize image Bun "
                  <> host
                  <> " to engines.bun "
                  <> bunReq
              )
        Just True -> do
          createDirectoryIfMissing True workDir
          createDirectoryIfMissing True outDir
          let cloneDir = workDir </> "src"
              cacheDir = workDir </> "bun-cache"
              tag = versionTag prefix pv
              url = githubCloneUrl owner repo
          createDirectoryIfMissing True cacheDir
          bcpOnCloneStart progress
          cloned <- bcoClone ops url tag cloneDir
          case cloned of
            Left err -> pure (Left err)
            Right () -> do
              bcpOnCloneDone progress
              spaceOk <- checkPostCloneForClass FullNpmBun cloneDir
              case spaceOk of
                Left err -> pure (Left err)
                Right () -> do
                  let lockPath = cloneDir </> "bun.lock"
                  hasLock <- doesFileExist lockPath
                  if not hasLock
                    then
                      pure $
                        Left
                          "bun.lock missing at repository root; \
                          \DepsAndAssets Bun requires a root bun.lock"
                    else do
                      bcpOnInstallStart progress
                      installed <- bcoBunInstall ops cloneDir cacheDir
                      case installed of
                        Left err -> pure (Left err)
                        Right () -> do
                          bcpOnInstallDone progress
                          packResult <-
                            packAfterInstall ops mode workDir cloneDir cacheDir
                          case packResult of
                            Left err -> pure (Left err)
                            Right (tarWorkDir, entries) -> do
                              let outPath = outDir </> tarballName
                              bcpOnCompressStart progress
                              compressed <-
                                bcoTarXz ops tarWorkDir entries outPath
                              case compressed of
                                Left err -> pure (Left err)
                                Right () -> do
                                  bcpOnCompressDone progress
                                  pure (Right outPath)

-- | Resolve tar work directory and relative members after a successful install.
packAfterInstall ::
  BunCacheOps ->
  BunPackagingMode ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text (FilePath, [FilePath]))
packAfterInstall _ BunCache tmp _cloneDir cacheDir = do
  rewritten <- rewriteBunCacheSymlinks cacheDir
  pure $ case rewritten of
    Left err -> Left err
    Right () -> Right (tmp, ["bun-cache"])
-- InstallTree uses the shared hermetic tar only (no bun-cache alias rewrite).
packAfterInstall _ InstallTree _tmp cloneDir _cacheDir = do
  entries <- collectInstallTreeEntries cloneDir
  pure $
    case entries of
      [] ->
        Left
          "InstallTree packaging found no node_modules under the clone; \
          \bun install may have produced an empty tree"
      _ -> Right (cloneDir, entries)

-- | Repo-relative @node_modules@ directories (not nested under another
-- @node_modules@). Sorted for stable tar member order.
collectInstallTreeEntries :: FilePath -> IO [FilePath]
collectInstallTreeEntries root = sort <$> findNodeModules root ""
  where
    skipName n =
      n `elem` [".git", ".hg", ".svn", "dist", "coverage", ".turbo", ".cache"]

    findNodeModules :: FilePath -> FilePath -> IO [FilePath]
    findNodeModules base rel = do
      let absDir = if null rel then base else base </> rel
      names <- listDirectory absDir
      let nmRel =
            [ if null rel then "node_modules" else rel </> "node_modules"
            | "node_modules" `elem` names
            ]
      children <-
        forM [n | n <- names, n /= "node_modules", not (skipName n)] $ \n -> do
          let childRel = if null rel then n else rel </> n
          isDir <- doesDirectoryExist (base </> childRel)
          if isDir
            then findNodeModules base childRel
            else pure []
      pure (nmRel ++ concat children)

-- | Rewrite absolute @bun-cache/@ alias symlinks to posix-relative in-tree
-- targets. Hard-fails if any absolute link remains or a rewritten target is
-- missing from the tree.
rewriteBunCacheSymlinks :: FilePath -> IO (Either Text ())
rewriteBunCacheSymlinks cacheRoot = do
  exists <- doesDirectoryExist cacheRoot
  if not exists
    then
      pure $
        Left
          ( "bun-cache directory missing at "
              <> T.pack cacheRoot
          )
    else do
      absRoot <- makeAbsolute cacheRoot
      rewritten <- rewriteWalk absRoot absRoot
      case rewritten of
        Left err -> pure (Left err)
        Right () -> verifyNoAbsolute absRoot absRoot

rewriteWalk :: FilePath -> FilePath -> IO (Either Text ())
rewriteWalk root dir = do
  names <- listDirectory dir
  foldM
    ( \acc name ->
        case acc of
          Left err -> pure (Left err)
          Right () -> do
            let p = dir </> name
            isLink <- pathIsSymbolicLink p
            if isLink
              then rewriteOne root p
              else do
                isDir <- doesDirectoryExist p
                if isDir then rewriteWalk root p else pure (Right ())
    )
    (Right ())
    names

rewriteOne :: FilePath -> FilePath -> IO (Either Text ())
rewriteOne root linkPath = do
  target <- getSymbolicLinkTarget linkPath
  if not (isAbsolute target)
    then pure (Right ())
    else do
      mDest <- resolveInTree root target
      case mDest of
        Nothing ->
          pure $
            Left
              ( "bun-cache symlink "
                  <> T.pack linkPath
                  <> " points at "
                  <> T.pack target
                  <> " which is not in the bun-cache tree"
              )
        Just dest -> do
          present <- pathPresent dest
          if not present
            then
              pure $
                Left
                  ( "bun-cache rewritten target missing: "
                      <> T.pack dest
                      <> " (from "
                      <> T.pack linkPath
                      <> ")"
                  )
            else do
              let rel = relativeUnder (takeDirectory linkPath) dest
              if isAbsolute rel || null rel
                then
                  pure $
                    Left
                      ( "bun-cache could not compute a relative target for "
                          <> T.pack linkPath
                      )
                else do
                  removeFile linkPath
                  createFileLink rel linkPath
                  pure (Right ())

resolveInTree :: FilePath -> FilePath -> IO (Maybe FilePath)
resolveInTree root target = do
  let under = if pathIsUnder root target then Just (normalise target) else Nothing
  case under of
    Just dest -> do
      ok <- pathPresent dest
      if ok then pure (Just dest) else trySuffix
    Nothing -> trySuffix
  where
    trySuffix = do
      let rel = dropBunCachePrefix target
          dest = normalise (root </> rel)
      ok <- pathPresent dest
      if ok && pathIsUnder root dest
        then pure (Just dest)
        else pure Nothing

dropBunCachePrefix :: FilePath -> FilePath
dropBunCachePrefix target =
  case break (== "bun-cache") (splitDirectories target) of
    (_, "bun-cache" : rest@(_ : _)) -> joinPath rest
    _ -> takeFileName target

pathIsUnder :: FilePath -> FilePath -> Bool
pathIsUnder root path =
  let nRoot = addTrailingPathSeparator (normalise root)
      nPath = normalise path
   in nRoot `isPrefixOf` nPath || equalFilePath root path

-- | Relative path from @fromDir@ to @dest@ using path components.
-- 'makeRelative' is not safe here: @gifwrap@ is a string prefix of
-- @gifwrap@0.10.1@@@1@ without a trailing separator.
relativeUnder :: FilePath -> FilePath -> FilePath
relativeUnder fromDir dest =
  let fromParts = splitDirectories (normalise fromDir)
      destParts = splitDirectories (normalise dest)
      common = length (takeWhile id (zipWith equalFilePath fromParts destParts))
      ups = replicate (length fromParts - common) ".."
      downs = drop common destParts
   in case ups ++ downs of
        [] -> "."
        parts -> joinPath parts

pathPresent :: FilePath -> IO Bool
pathPresent p = do
  exists <- doesPathExist p
  if exists
    then pure True
    else do
      eLink <- try (pathIsSymbolicLink p) :: IO (Either IOException Bool)
      pure (fromRight False eLink)

verifyNoAbsolute :: FilePath -> FilePath -> IO (Either Text ())
verifyNoAbsolute root dir = do
  names <- listDirectory dir
  foldM
    ( \acc name ->
        case acc of
          Left err -> pure (Left err)
          Right () -> do
            let p = dir </> name
            isLink <- pathIsSymbolicLink p
            if isLink
              then do
                target <- getSymbolicLinkTarget p
                if isAbsolute target
                  then
                    pure $
                      Left
                        ( "bun-cache symlink still absolute after rewrite: "
                            <> T.pack p
                            <> " -> "
                            <> T.pack target
                        )
                  else do
                    let dest = normalise (takeDirectory p </> target)
                    present <- pathPresent dest
                    if not present
                      then
                        pure $
                          Left
                            ( "bun-cache relative symlink target missing: "
                                <> T.pack p
                                <> " -> "
                                <> T.pack target
                            )
                      else pure (Right ())
              else do
                isDir <- doesDirectoryExist p
                if isDir then verifyNoAbsolute root p else pure (Right ())
    )
    (Right ())
    names

gitCloneTag :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag run url tag dest = do
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "git"
              [ "clone",
                "--depth",
                "1",
                "--branch",
                T.unpack tag,
                T.unpack url,
                dest
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("git clone failed: " <> T.pack (prStderr res))

bunInstallCache :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
bunInstallCache run cloneDir cacheDir = do
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "bun"
              [ "install",
                "--frozen-lockfile",
                "--cache-dir",
                cacheDir
              ],
          prCwd = Just cloneDir,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("bun install failed: " <> T.pack (prStderr res))

tarXzEntries :: CommandRunner -> FilePath -> [FilePath] -> FilePath -> IO (Either Text ())
tarXzEntries run workDir =
  packTarXz run "tar xz bun deps failed" (Just workDir) Nothing
