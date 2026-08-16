{-# LANGUAGE OverloadedStrings #-}

module Update.Npm.Cache
  ( NpmCacheOps (..),
    NpmCacheProgress (..),
    productionNpmCacheOps,
    mkNpmCacheOps,
    buildNpmDepsTarball,
    fetchNpmEnginesNode,
    fetchNpmEnginesNodeHttpLbs,
    listNpmVersions,
    listNpmVersionsHttpLbs,
    hostNodeVersion,
    hostMeetsNodeRequirement,
    nodeVersionTooOldMessage,
    prepareNpmCacheForPack,
    npmUserconfigName,
  )
where

import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecode, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Char (isDigit)
import Data.List (isPrefixOf, sortBy)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( Manager,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
    removePathForcibly,
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Update.Engines (parseEnginesMinimum)
import Update.Go.Version
  ( compareGoVersions,
    parseGoVersionToken,
  )
import Update.Http (HttpLbs, httpLbsEither)
import Update.Pack.XzTar (packTarXz)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
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

-- | Build npm cache ops over an injectable command runner (Unit heat surface).
mkNpmCacheOps :: CommandRunner -> NpmCacheOps
mkNpmCacheOps run =
  NpmCacheOps
    { ncoHostNodeVersion = hostNodeVersion run,
      ncoNpmPack = npmPack run,
      ncoNpmInstallCache = npmInstallCache run,
      ncoTarXz = tarXzNpmCache run
    }

productionNpmCacheOps :: NpmCacheOps
productionNpmCacheOps = mkNpmCacheOps productionCommandRunner

hostNodeVersion :: CommandRunner -> IO (Either Text Text)
hostNodeVersion run = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "node" ["--version"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then Left ("could not determine materialize image Node version: " <> T.pack (prStderr res))
      else case parseNodeVersionOutput (T.pack (prStdout res)) of
        Just v -> Right v
        Nothing ->
          Left
            ( "could not parse materialize image Node version from: "
                <> T.strip (T.pack (prStdout res))
            )

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
  "materialize image Node "
    <> host
    <> " is older than engines.node requirement "
    <> required
    <> "; rebuild the materialize image with Node at least "
    <> required

-- | Registry-only: npm pack → npm --cache install → tar npm-cache/.
-- Pack and @npm-cache/@ live under unit @workDir@; tarball under @outDir@.
buildNpmDepsTarball ::
  NpmCacheOps ->
  NpmCacheProgress ->
  Text ->
  Text ->
  Text ->
  -- | Unit @work/@ (pack + npm-cache).
  FilePath ->
  -- | Unit @out/@ (staged tarball).
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildNpmDepsTarball ops progress npmPkg pv nodeReq workDir outDir tarballName = do
  hostResult <- ncoHostNodeVersion ops
  case hostResult of
    Left err -> pure (Left err)
    Right host ->
      case hostMeetsNodeRequirement host nodeReq of
        Just False -> pure (Left (nodeVersionTooOldMessage host nodeReq))
        Nothing ->
          pure $
            Left
              ( "could not compare materialize image Node "
                  <> host
                  <> " to engines.node "
                  <> nodeReq
              )
        Just True -> do
          createDirectoryIfMissing True workDir
          createDirectoryIfMissing True outDir
          ncpOnPackStart progress
          packed <- ncoNpmPack ops npmPkg pv workDir
          case packed of
            Left err -> pure (Left err)
            Right tgz -> do
              ncpOnPackDone progress
              let cacheDir = workDir </> "npm-cache"
              createDirectoryIfMissing True cacheDir
              ncpOnInstallStart progress
              installed <- ncoNpmInstallCache ops tgz cacheDir
              case installed of
                Left err -> pure (Left err)
                Right () -> do
                  ncpOnInstallDone progress
                  let outPath = outDir </> tarballName
                  ncpOnCompressStart progress
                  compressed <- ncoTarXz ops workDir "npm-cache" outPath
                  case compressed of
                    Left err -> pure (Left err)
                    Right () -> do
                      ncpOnCompressDone progress
                      pure (Right outPath)

-- | Empty npm userconfig basename under the unit @work/@ (not the operator @~\/.npmrc@).
npmUserconfigName :: FilePath
npmUserconfigName = "npm-userconfig"

writeEmptyUserconfig :: FilePath -> IO FilePath
writeEmptyUserconfig workDir = do
  let path = workDir </> npmUserconfigName
  writeFile path ""
  pure path

-- | Drop npm debug logs and update-notifier state before packing.
prepareNpmCacheForPack :: FilePath -> IO ()
prepareNpmCacheForPack cacheDir = do
  exists <- doesDirectoryExist cacheDir
  if not exists
    then pure ()
    else do
      removePathForcibly (cacheDir </> "_logs")
      names <- listDirectory cacheDir
      mapM_
        ( \n ->
            when
              ("_update-notifier" `isPrefixOf` n)
              (removePathForcibly (cacheDir </> n))
        )
        names

npmPack :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text FilePath)
npmPack run npmPkg pv workDir = do
  createDirectoryIfMissing True workDir
  uc <- writeEmptyUserconfig workDir
  let spec = T.unpack npmPkg <> "@" <> T.unpack pv
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "npm"
              ["pack", spec, "--pack-destination", workDir, "--userconfig", uc],
          prCwd = Just workDir,
          prEnv = Nothing,
          prStdin = ""
        }
  if prExitCode res /= ExitSuccess
    then pure (Left ("npm pack failed: " <> T.pack (prStderr res) <> T.pack (prStdout res)))
    else do
      names <- listDirectory workDir
      let tgzs = [workDir </> n | n <- names, ".tgz" `T.isSuffixOf` T.pack n]
      pure $ case tgzs of
        (p : _) -> Right p
        [] -> Left "npm pack produced no .tgz file"

npmInstallCache :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
npmInstallCache run tgz cacheDir = do
  let workDir = takeDirectory tgz
  uc <- writeEmptyUserconfig workDir
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "npm"
              ["--userconfig", uc, "--cache", cacheDir, "install", tgz],
          prCwd = Just workDir,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("npm --cache install failed: " <> T.pack (prStderr res))

tarXzNpmCache :: CommandRunner -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzNpmCache run workDir entry outPath = do
  prepareNpmCacheForPack (workDir </> entry)
  packTarXz run "tar xz npm-cache failed" (Just workDir) Nothing [entry] outPath

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
fetchNpmEnginesNode mgr =
  fetchNpmEnginesNodeHttpLbs (httpLbsEither mgr)

-- | Injectable HTTP path for engines.node registry fetch.
fetchNpmEnginesNodeHttpLbs :: HttpLbs -> Text -> Text -> IO (Either Text Text)
fetchNpmEnginesNodeHttpLbs http npmPkg pv = do
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
  eres <- http req
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
listNpmVersions mgr = listNpmVersionsHttpLbs (httpLbsEither mgr)

-- | Injectable HTTP path for npm packument version listing.
listNpmVersionsHttpLbs :: HttpLbs -> Text -> IO (Either Text [EbuildVersion])
listNpmVersionsHttpLbs http npmPkg = do
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
  eres <- http req
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
