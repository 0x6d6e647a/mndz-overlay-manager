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
  )
where

import Control.Monad (forM)
import Data.Aeson (Value, eitherDecode, withObject, (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
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
      then Left ("could not determine host Bun version: " <> T.pack (prStderr res))
      else case parseBunVersionOutput (T.pack (prStdout res)) of
        Just v -> Right v
        Nothing ->
          Left ("could not parse host Bun version from: " <> T.strip (T.pack (prStdout res)))

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
  "host Bun "
    <> host
    <> " is older than Bun requirement "
    <> required
    <> "; install/upgrade dev-lang/bun-bin to at least "
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
              ( "could not compare host Bun "
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
packAfterInstall _ BunCache tmp _cloneDir _cacheDir =
  pure (Right (tmp, ["bun-cache"]))
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
tarXzEntries run workDir entries outPath = do
  baseEnv <- getEnvironment
  let env' = ("XZ_OPT", "-T0 -9") : filter (\(k, _) -> k /= "XZ_OPT") baseEnv
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "tar" (["-acf", outPath] ++ entries),
          prCwd = Just workDir,
          prEnv = Just env',
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("tar xz bun deps failed: " <> T.pack (prStderr res))
