{-# LANGUAGE OverloadedStrings #-}

module Update.Bun.Cache
  ( BunCacheOps (..),
    BunCacheProgress (..),
    productionBunCacheOps,
    buildBunDepsTarball,
    parseEnginesBunFromPackageJson,
    hostBunVersion,
    hostMeetsBunRequirement,
    bunVersionTooOldMessage,
  )
where

import Data.Aeson (Value, eitherDecode, withObject, (.:), (.:?))
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
import System.Process
  ( CreateProcess (..),
    cwd,
    env,
    proc,
    readCreateProcessWithExitCode,
  )
import Update.Engines (parseEnginesMinimum)
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Go.Version
  ( compareGoVersions,
    parseGoVersionToken,
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

productionBunCacheOps :: BunCacheOps
productionBunCacheOps =
  BunCacheOps
    { bcoClone = gitCloneTag,
      bcoHostBunVersion = hostBunVersion,
      bcoBunInstall = bunInstallCache,
      bcoTarXz = tarXzBunCache
    }

hostBunVersion :: IO (Either Text Text)
hostBunVersion = do
  (code, out, err) <- readCreateProcessWithExitCode (proc "bun" ["--version"]) ""
  pure $
    if code /= ExitSuccess
      then Left ("could not determine host Bun version: " <> T.pack err)
      else case parseBunVersionOutput (T.pack out) of
        Just v -> Right v
        Nothing ->
          Left ("could not parse host Bun version from: " <> T.strip (T.pack out))

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
    <> " is older than engines.bun requirement "
    <> required
    <> "; install/upgrade dev-lang/bun-bin to at least "
    <> required

parseEnginesBunFromPackageJson :: Text -> Maybe Text
parseEnginesBunFromPackageJson body =
  case eitherDecode (BL.fromStrict (TE.encodeUtf8 body)) of
    Right val -> parseEnginesMinimum =<< parseMaybe parseEnginesBun val
    Left _ -> Nothing

parseEnginesBun :: Value -> Parser Text
parseEnginesBun =
  withObject "package.json" $ \o -> do
    mengines <- o .:? "engines"
    case mengines of
      Nothing -> fail "no engines"
      Just eng ->
        withObject "engines" (.: "bun") eng

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

gitCloneTag :: Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag url tag dest = do
  (code, _out, err) <-
    readCreateProcessWithExitCode
      ( proc
          "git"
          [ "clone",
            "--depth",
            "1",
            "--branch",
            T.unpack tag,
            T.unpack url,
            dest
          ]
      )
      ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("git clone failed: " <> T.pack err)

bunInstallCache :: FilePath -> FilePath -> IO (Either Text ())
bunInstallCache cloneDir cacheDir = do
  (code, _out, err) <-
    readCreateProcessWithExitCode
      ( proc
          "bun"
          [ "install",
            "--frozen-lockfile",
            "--cache-dir",
            cacheDir
          ]
      )
        { cwd = Just cloneDir
        }
      ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("bun install failed: " <> T.pack err)

tarXzBunCache :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzBunCache workDir entry outPath = do
  baseEnv <- getEnvironment
  let env' = ("XZ_OPT", "-T0 -9") : filter (\(k, _) -> k /= "XZ_OPT") baseEnv
  (code, _out, err) <-
    readCreateProcessWithExitCode
      (proc "tar" ["-acf", outPath, entry])
        { cwd = Just workDir,
          env = Just env'
        }
      ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("tar xz bun-cache failed: " <> T.pack err)
