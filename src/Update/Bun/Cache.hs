{-# LANGUAGE OverloadedStrings #-}

module Update.Bun.Cache
  ( BunCacheOps (..),
    BunCacheProgress (..),
    productionBunCacheOps,
    mkBunCacheOps,
    buildBunDepsTarball,
    parseEnginesBunFromPackageJson,
    parsePackageManagerBun,
    hostBunVersion,
    hostMeetsBunRequirement,
    bunVersionTooOldMessage,
  )
where

import Data.Aeson (Value, eitherDecode, withObject, (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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

-- | Injectable process steps for bun cache construction.
data BunCacheOps = BunCacheOps
  { bcoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    bcoHostBunVersion :: IO (Either Text Text),
    bcoBunInstall :: FilePath -> FilePath -> IO (Either Text ()),
    bcoTarXz :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
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
      bcoTarXz = tarXzBunCache run
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

-- | Clone tag → require bun.lock → bun install --frozen-lockfile --cache-dir → tar.
buildBunDepsTarball ::
  BunCacheOps ->
  BunCacheProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildBunDepsTarball ops progress owner repo prefix pv bunReq outDir tarballName = do
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
        Just True ->
          withSystemTempDirectory "mndz-bun-cache-" $ \tmp -> do
            let cloneDir = tmp </> "src"
                cacheDir = tmp </> "bun-cache"
                tag = versionTag prefix pv
                url = githubCloneUrl owner repo
            createDirectoryIfMissing True cacheDir
            bcpOnCloneStart progress
            cloned <- bcoClone ops url tag cloneDir
            case cloned of
              Left err -> pure (Left err)
              Right () -> do
                bcpOnCloneDone progress
                let lockPath = cloneDir </> "bun.lock"
                hasLock <- doesFileExist lockPath
                if not hasLock
                  then
                    pure $
                      Left
                        "bun.lock missing at repository root; \
                        \DepsAndAssets Bun requires a root bun.lock"
                  else do
                    -- Optional: read package.json for engines (caller may already have)
                    bcpOnInstallStart progress
                    installed <- bcoBunInstall ops cloneDir cacheDir
                    case installed of
                      Left err -> pure (Left err)
                      Right () -> do
                        bcpOnInstallDone progress
                        let outPath = outDir </> tarballName
                        bcpOnCompressStart progress
                        compressed <- bcoTarXz ops tmp "bun-cache" outPath
                        case compressed of
                          Left err -> pure (Left err)
                          Right () -> do
                            bcpOnCompressDone progress
                            pure (Right outPath)

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

tarXzBunCache :: CommandRunner -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzBunCache run workDir entry outPath = do
  baseEnv <- getEnvironment
  let env' = ("XZ_OPT", "-T0 -9") : filter (\(k, _) -> k /= "XZ_OPT") baseEnv
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "tar" ["-acf", outPath, entry],
          prCwd = Just workDir,
          prEnv = Just env',
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("tar xz bun-cache failed: " <> T.pack (prStderr res))
