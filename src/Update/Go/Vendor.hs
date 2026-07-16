{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Vendor
  ( VendorOps (..),
    VendorResult (..),
    productionVendorOps,
    buildVendorTarball,
    githubCloneUrl,
    versionTag,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), cwd, env, proc, readCreateProcessWithExitCode)
import Update.Go.Version
  ( enrichGoModDownloadError,
    goVersionTooOldMessage,
    hostMeetsGoRequirement,
    parseGoModGoDirective,
    parseGoVersionOutput,
  )

-- | Result of a successful vendor tarball build.
data VendorResult = VendorResult
  { vrTarballPath :: FilePath,
    -- | Exact @go@ directive version from go.mod (for BDEPEND), if present.
    vrGoModVersion :: Maybe Text
  }

-- | Injectable process steps for vendor construction.
data VendorOps = VendorOps
  { voClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    -- | Host Go language version string (e.g. @"1.26.4"@), or error.
    voHostGoVersion :: IO (Either Text Text),
    voGoModDownload :: FilePath -> IO (Either Text ()),
    voTarXz :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
  }

productionVendorOps :: VendorOps
productionVendorOps =
  VendorOps
    { voClone = gitCloneTag,
      voHostGoVersion = probeHostGoVersion,
      voGoModDownload = goModDownload,
      voTarXz = tarXzGoMod
    }

githubCloneUrl :: Text -> Text -> Text
githubCloneUrl owner repo =
  "https://github.com/" <> owner <> "/" <> repo <> ".git"

versionTag :: Text -> Text -> Text
versionTag prefix pv = prefix <> pv

-- | Clone upstream at tag, gate on host Go vs go.mod, run go mod download,
-- produce vendor tarball in @outDir@ as @tarballName@.
buildVendorTarball ::
  VendorOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text VendorResult)
buildVendorTarball ops owner repo prefix pv mSubdir outDir tarballName = do
  createDirectoryIfMissing True outDir
  let tag = versionTag prefix pv
      url = githubCloneUrl owner repo
      outPath = outDir </> tarballName
  withSystemTempDirectory "mndz-go-vendor-" $ \tmp -> do
    let cloneDir = tmp </> "src"
    cloned <- voClone ops url tag cloneDir
    case cloned of
      Left err -> pure (Left err)
      Right () -> do
        let goDir = case mSubdir of
              Nothing -> cloneDir
              Just sub -> cloneDir </> sub
        hasMod <- doesFileExist (goDir </> "go.mod")
        if not hasMod
          then pure $ Left ("go.mod not found in " <> T.pack goDir)
          else do
            modText <- TIO.readFile (goDir </> "go.mod")
            let mReq = parseGoModGoDirective modText
            gated <- gateHostGo ops mReq
            case gated of
              Left err -> pure (Left err)
              Right () -> do
                downloaded <- voGoModDownload ops goDir
                case downloaded of
                  Left err -> pure (Left err)
                  Right () -> do
                    tared <- voTarXz ops goDir "go-mod" outPath
                    pure $ case tared of
                      Left err -> Left err
                      Right () ->
                        Right
                          VendorResult
                            { vrTarballPath = outPath,
                              vrGoModVersion = mReq
                            }

-- | If go.mod has a parseable @go@ line, require host Go >= that version.
gateHostGo :: VendorOps -> Maybe Text -> IO (Either Text ())
gateHostGo _ Nothing = pure (Right ())
gateHostGo ops (Just required) = do
  hostE <- voHostGoVersion ops
  pure $ case hostE of
    Left err -> Left err
    Right host ->
      case hostMeetsGoRequirement host required of
        Just True -> Right ()
        Just False -> Left (goVersionTooOldMessage host required)
        Nothing ->
          Left $
            "could not compare host Go version "
              <> host
              <> " with go.mod requirement "
              <> required

probeHostGoVersion :: IO (Either Text Text)
probeHostGoVersion = do
  (code, out, err) <-
    readCreateProcessWithExitCode (proc "go" ["version"]) ""
  pure $
    if code /= ExitSuccess
      then Left ("go version failed: " <> T.pack err)
      else case parseGoVersionOutput (T.pack out) of
        Just v -> Right v
        Nothing ->
          Left $
            "could not parse host Go version from: "
              <> T.strip (T.pack out)

gitCloneTag :: Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag url tag dest = do
  (code, _, err) <-
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

goModDownload :: FilePath -> IO (Either Text ())
goModDownload goDir = do
  let cacheDir = goDir </> "go-mod"
  createDirectoryIfMissing True cacheDir
  env0 <- getEnvironment
  -- Only override GOMODCACHE; do not force GOTOOLCHAIN=auto.
  let cp =
        (proc "go" ["mod", "download", "-modcacherw"])
          { cwd = Just goDir,
            env = Just (("GOMODCACHE", cacheDir) : filter ((/= "GOMODCACHE") . fst) env0)
          }
  (code, _, err) <- readCreateProcessWithExitCode cp ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left (enrichGoModDownloadError (T.pack err))

tarXzGoMod :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzGoMod goDir entryName outPath = do
  env0 <- getEnvironment
  let cp =
        (proc "tar" ["-acf", outPath, entryName])
          { cwd = Just goDir,
            env = Just (("XZ_OPT", "-T0 -9") : filter ((/= "XZ_OPT") . fst) env0)
          }
  (code, _, err) <- readCreateProcessWithExitCode cp ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("tar failed: " <> T.pack err)
