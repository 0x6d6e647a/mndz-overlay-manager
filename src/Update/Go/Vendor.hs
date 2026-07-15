{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Vendor
  ( VendorOps (..),
    productionVendorOps,
    buildVendorTarball,
    githubCloneUrl,
    versionTag,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), cwd, env, proc, readCreateProcessWithExitCode)

-- | Injectable process steps for vendor construction.
data VendorOps = VendorOps
  { voClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    voGoModDownload :: FilePath -> IO (Either Text ()),
    voTarXz :: FilePath -> FilePath -> FilePath -> IO (Either Text ())
  }

productionVendorOps :: VendorOps
productionVendorOps =
  VendorOps
    { voClone = gitCloneTag,
      voGoModDownload = goModDownload,
      voTarXz = tarXzGoMod
    }

githubCloneUrl :: Text -> Text -> Text
githubCloneUrl owner repo =
  "https://github.com/" <> owner <> "/" <> repo <> ".git"

versionTag :: Text -> Text -> Text
versionTag prefix pv = prefix <> pv

-- | Clone upstream at tag, run go mod download, produce vendor tarball in
-- @outDir@ as @tarballName@. Uses a system temp directory for the clone.
buildVendorTarball ::
  VendorOps ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
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
            downloaded <- voGoModDownload ops goDir
            case downloaded of
              Left err -> pure (Left err)
              Right () -> do
                tared <- voTarXz ops goDir "go-mod" outPath
                pure $ case tared of
                  Left err -> Left err
                  Right () -> Right outPath

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
  let cp =
        (proc "go" ["mod", "download", "-modcacherw"])
          { cwd = Just goDir,
            env = Just (("GOMODCACHE", cacheDir) : filter ((/= "GOMODCACHE") . fst) env0)
          }
  (code, _, err) <- readCreateProcessWithExitCode cp ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("go mod download failed: " <> T.pack err)

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
