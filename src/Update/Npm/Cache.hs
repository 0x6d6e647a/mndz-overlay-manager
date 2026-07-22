{-# LANGUAGE OverloadedStrings #-}

module Update.Npm.Cache
  ( NpmCacheOps (..),
    NpmCacheProgress (..),
    productionNpmCacheOps,
    buildNpmDepsTarball,
    parseEnginesNodeFromPackageJson,
    fetchNpmEnginesNode,
    listNpmVersions,
    hostNodeVersion,
    hostMeetsNodeRequirement,
    nodeVersionTooOldMessage,
  )
where

import Control.Exception (SomeException, catch)
import Data.Aeson (Value (..), eitherDecode, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List (sortBy)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client
  ( Manager,
    httpLbs,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (..),
    cwd,
    env,
    proc,
    readCreateProcessWithExitCode,
  )
import Update.Engines (parseEnginesMinimum)
import Update.Go.Version
  ( compareGoVersions,
    parseGoVersionToken,
  )

-- | Injectable process steps for npm cache construction.
data NpmCacheOps = NpmCacheOps
  { ncoHostNodeVersion :: IO (Either Text Text),
    ncoNpmPack :: Text -> Text -> FilePath -> IO (Either Text FilePath),
    ncoNpmInstallCache :: FilePath -> FilePath -> IO (Either Text ()),
    ncoTarXz :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
  }

data NpmCacheProgress = NpmCacheProgress
  { ncpOnPackStart :: IO (),
    ncpOnPackDone :: IO (),
    ncpOnInstallStart :: IO (),
    ncpOnInstallDone :: IO (),
    ncpOnCompressStart :: IO (),
    ncpOnCompressDone :: IO ()
  }

productionNpmCacheOps :: NpmCacheOps
productionNpmCacheOps =
  NpmCacheOps
    { ncoHostNodeVersion = hostNodeVersion,
      ncoNpmPack = npmPack,
      ncoNpmInstallCache = npmInstallCache,
      ncoTarXz = tarXzNpmCache
    }

hostNodeVersion :: IO (Either Text Text)
hostNodeVersion = do
  (code, out, err) <- readCreateProcessWithExitCode (proc "node" ["--version"]) ""
  pure $
    if code /= ExitSuccess
      then Left ("could not determine host Node version: " <> T.pack err)
      else case parseNodeVersionOutput (T.pack out) of
        Just v -> Right v
        Nothing ->
          Left ("could not parse host Node version from: " <> T.strip (T.pack out))

parseNodeVersionOutput :: Text -> Maybe Text
parseNodeVersionOutput out =
  case [v | w <- T.words out, Just v <- [stripV w]] of
    (v : _) -> Just v
    [] -> Nothing
  where
    stripV w =
      let t = if "v" `T.isPrefixOf` w then T.drop 1 w else w
          core = T.takeWhile (\c -> c == '.' || isDigit c) t
       in case parseGoVersionToken core of
            Just _ -> Just core
            Nothing -> Nothing

hostMeetsNodeRequirement :: Text -> Text -> Maybe Bool
hostMeetsNodeRequirement host required =
  case compareGoVersions host required of
    Just LT -> Just False
    Just _ -> Just True
    Nothing -> Nothing

nodeVersionTooOldMessage :: Text -> Text -> Text
nodeVersionTooOldMessage host required =
  "host Node "
    <> host
    <> " is older than engines.node requirement "
    <> required
    <> "; install/upgrade net-libs/nodejs to at least "
    <> required

-- | Registry-only: npm pack → npm --cache install → tar npm-cache/.
buildNpmDepsTarball ::
  NpmCacheOps ->
  NpmCacheProgress ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildNpmDepsTarball ops progress npmPkg pv nodeReq outDir tarballName = do
  hostResult <- ncoHostNodeVersion ops
  case hostResult of
    Left err -> pure (Left err)
    Right host ->
      case hostMeetsNodeRequirement host nodeReq of
        Just False -> pure (Left (nodeVersionTooOldMessage host nodeReq))
        Nothing ->
          pure $
            Left
              ( "could not compare host Node "
                  <> host
                  <> " to engines.node "
                  <> nodeReq
              )
        Just True ->
          withSystemTempDirectory "mndz-npm-cache-" $ \tmp -> do
            ncpOnPackStart progress
            packed <- ncoNpmPack ops npmPkg pv tmp
            case packed of
              Left err -> pure (Left err)
              Right tgz -> do
                ncpOnPackDone progress
                let cacheDir = tmp </> "npm-cache"
                createDirectoryIfMissing True cacheDir
                ncpOnInstallStart progress
                installed <- ncoNpmInstallCache ops tgz cacheDir
                case installed of
                  Left err -> pure (Left err)
                  Right () -> do
                    ncpOnInstallDone progress
                    let outPath = outDir </> tarballName
                    ncpOnCompressStart progress
                    compressed <- ncoTarXz ops tmp "npm-cache" outPath
                    case compressed of
                      Left err -> pure (Left err)
                      Right () -> do
                        ncpOnCompressDone progress
                        pure (Right outPath)

npmPack :: Text -> Text -> FilePath -> IO (Either Text FilePath)
npmPack npmPkg pv workDir = do
  let spec = T.unpack npmPkg <> "@" <> T.unpack pv
  (code, out, err) <-
    readCreateProcessWithExitCode
      (proc "npm" ["pack", spec, "--pack-destination", workDir])
        { cwd = Just workDir
        }
      ""
  if code /= ExitSuccess
    then pure (Left ("npm pack failed: " <> T.pack err <> T.pack out))
    else do
      names <- listDirectory workDir
      let tgzs = [workDir </> n | n <- names, ".tgz" `T.isSuffixOf` T.pack n]
      pure $ case tgzs of
        (p : _) -> Right p
        [] -> Left "npm pack produced no .tgz file"

npmInstallCache :: FilePath -> FilePath -> IO (Either Text ())
npmInstallCache tgz cacheDir = do
  (code, _out, err) <-
    readCreateProcessWithExitCode
      (proc "npm" ["--cache", cacheDir, "install", tgz])
        { cwd = Just (takeDirectory tgz)
        }
      ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("npm --cache install failed: " <> T.pack err)

tarXzNpmCache :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzNpmCache workDir entry outPath = do
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
      else Left ("tar xz npm-cache failed: " <> T.pack err)

parseEnginesNodeFromPackageJson :: Text -> Maybe Text
parseEnginesNodeFromPackageJson body =
  case eitherDecode (BL.fromStrict (TE.encodeUtf8 body)) of
    Right val -> parseEnginesMinimum =<< parseMaybe parseEnginesNode val
    Left _ -> Nothing

parseEnginesNode :: Value -> Parser Text
parseEnginesNode =
  withObject "package.json" $ \o -> do
    mengines <- o .:? "engines"
    case mengines of
      Nothing -> fail "no engines"
      Just eng ->
        withObject "engines" (.: "node") eng

-- | Fetch engines.node for a package version from the npm registry.
fetchNpmEnginesNode :: Manager -> Text -> Text -> IO (Either Text Text)
fetchNpmEnginesNode mgr npmPkg pv = do
  let url =
        "https://registry.npmjs.org/"
          <> T.unpack npmPkg
          <> "/"
          <> T.unpack pv
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/json")
              ]
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then case eitherDecode (responseBody resp) of
              Left e -> Left (T.pack e)
              Right val ->
                case parseMaybe parseEnginesNode val of
                  Nothing ->
                    Left
                      ( "missing engines.node for "
                          <> npmPkg
                          <> "@"
                          <> pv
                      )
                  Just raw ->
                    case parseEnginesMinimum raw of
                      Just v -> Right v
                      Nothing ->
                        Left
                          ( "unparseable engines.node for "
                              <> npmPkg
                              <> "@"
                              <> pv
                              <> ": "
                              <> raw
                          )
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

-- | List published versions from the npm registry (newest-first).
listNpmVersions :: Manager -> Text -> IO (Either Text [EbuildVersion])
listNpmVersions mgr npmPkg = do
  let url = "https://registry.npmjs.org/" <> T.unpack npmPkg
  req0 <- parseRequest url
  let req =
        req0
          { method = "GET",
            requestHeaders =
              [ ("User-Agent", "mndz-overlay-manager"),
                ("Accept", "application/json")
              ]
          }
  eres <- tryHttp (httpLbs req mgr)
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then case eitherDecode (responseBody resp) of
              Left e -> Left (T.pack e)
              Right val ->
                case parseMaybe parseVersionKeys val of
                  Nothing -> Left "could not parse npm versions"
                  Just vers ->
                    Right
                      ( sortNewest
                          (map parseEbuildVersion vers)
                      )
            else Left ("HTTP " <> T.pack (show code) <> " from " <> T.pack url)

parseVersionKeys :: Value -> Parser [Text]
parseVersionKeys =
  withObject "npm-packument" $ \o -> do
    versVal <- o .: "versions"
    case versVal of
      Object vo -> pure (map Key.toText (KeyMap.keys vo))
      _ -> fail "versions is not an object"

sortNewest :: [EbuildVersion] -> [EbuildVersion]
sortNewest =
  sortBy
    ( \a b ->
        case comparePV a b of
          Just LT -> GT
          Just GT -> LT
          Just EQ -> EQ
          Nothing -> compare (show b) (show a)
    )

tryHttp :: IO a -> IO (Either Text a)
tryHttp action =
  (Right <$> action) `catch` \(e :: SomeException) ->
    pure (Left (T.pack (show e)))
