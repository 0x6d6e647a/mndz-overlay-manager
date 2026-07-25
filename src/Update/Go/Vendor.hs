{-# LANGUAGE OverloadedStrings #-}

module Update.Go.Vendor
  ( VendorOps (..),
    VendorProgress (..),
    VendorResult (..),
    productionVendorOps,
    mkVendorOps,
    noopVendorProgress,
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
import Update.Go.Version
  ( enrichGoModDownloadError,
    goVersionTooOldMessage,
    hostMeetsGoRequirement,
    parseGoModGoDirective,
    parseGoVersionOutput,
  )
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
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

-- | Progress callbacks for long vendor sub-phases (UI-free; mirror @PlanProgress@).
--
-- Host Go version gating runs under the download phase (no separate hooks).
-- Done hooks fire only after the phase succeeds; failures leave the active phase
-- without a done event so the caller can surface the current step name.
data VendorProgress = VendorProgress
  { vpOnCloneStart :: IO (),
    vpOnCloneDone :: IO (),
    vpOnDownloadStart :: IO (),
    vpOnDownloadDone :: IO (),
    vpOnCompressStart :: IO (),
    vpOnCompressDone :: IO ()
  }

noopVendorProgress :: VendorProgress
noopVendorProgress =
  VendorProgress
    { vpOnCloneStart = pure (),
      vpOnCloneDone = pure (),
      vpOnDownloadStart = pure (),
      vpOnDownloadDone = pure (),
      vpOnCompressStart = pure (),
      vpOnCompressDone = pure ()
    }

-- | Build vendor ops over an injectable command runner (Unit heat surface).
mkVendorOps :: CommandRunner -> VendorOps
mkVendorOps run =
  VendorOps
    { voClone = gitCloneTag run,
      voHostGoVersion = probeHostGoVersion run,
      voGoModDownload = goModDownload run,
      voTarXz = tarXzGoMod run
    }

productionVendorOps :: VendorOps
productionVendorOps = mkVendorOps productionCommandRunner

githubCloneUrl :: Text -> Text -> Text
githubCloneUrl owner repo =
  "https://github.com/" <> owner <> "/" <> repo <> ".git"

versionTag :: Text -> Text -> Text
versionTag prefix pv = prefix <> pv

-- | Clone upstream at tag, gate on host Go vs go.mod, run go mod download,
-- produce vendor tarball in @outDir@ as @tarballName@.
buildVendorTarball ::
  VendorOps ->
  VendorProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text VendorResult)
buildVendorTarball ops progress owner repo prefix pv mSubdir outDir tarballName = do
  createDirectoryIfMissing True outDir
  let tag = versionTag prefix pv
      url = githubCloneUrl owner repo
      outPath = outDir </> tarballName
  withSystemTempDirectory "mndz-go-vendor-" $ \tmp -> do
    let cloneDir = tmp </> "src"
    vpOnCloneStart progress
    cloned <- voClone ops url tag cloneDir
    case cloned of
      Left err -> pure (Left err)
      Right () -> do
        vpOnCloneDone progress
        let goDir = case mSubdir of
              Nothing -> cloneDir
              Just sub -> cloneDir </> sub
        hasMod <- doesFileExist (goDir </> "go.mod")
        if not hasMod
          then pure $ Left ("go.mod not found in " <> T.pack goDir)
          else do
            modText <- TIO.readFile (goDir </> "go.mod")
            let mReq = parseGoModGoDirective modText
            -- Host Go gate + go mod download share the download progress phase.
            vpOnDownloadStart progress
            gated <- gateHostGo ops mReq
            case gated of
              Left err -> pure (Left err)
              Right () -> do
                downloaded <- voGoModDownload ops goDir
                case downloaded of
                  Left err -> pure (Left err)
                  Right () -> do
                    vpOnDownloadDone progress
                    vpOnCompressStart progress
                    tared <- voTarXz ops goDir "go-mod" outPath
                    case tared of
                      Left err -> pure (Left err)
                      Right () -> do
                        vpOnCompressDone progress
                        pure $
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

probeHostGoVersion :: CommandRunner -> IO (Either Text Text)
probeHostGoVersion run = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "go" ["version"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then Left ("go version failed: " <> T.pack (prStderr res))
      else case parseGoVersionOutput (T.pack (prStdout res)) of
        Just v -> Right v
        Nothing ->
          Left $
            "could not parse host Go version from: "
              <> T.strip (T.pack (prStdout res))

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

goModDownload :: CommandRunner -> FilePath -> IO (Either Text ())
goModDownload run goDir = do
  let cacheDir = goDir </> "go-mod"
  createDirectoryIfMissing True cacheDir
  env0 <- getEnvironment
  -- Only override GOMODCACHE; do not force GOTOOLCHAIN=auto.
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "go" ["mod", "download", "-modcacherw"],
          prCwd = Just goDir,
          prEnv = Just (("GOMODCACHE", cacheDir) : filter ((/= "GOMODCACHE") . fst) env0),
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (enrichGoModDownloadError (T.pack (prStderr res)))

tarXzGoMod :: CommandRunner -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
tarXzGoMod run goDir entryName outPath = do
  env0 <- getEnvironment
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "tar" ["-acf", outPath, entryName],
          prCwd = Just goDir,
          prEnv = Just (("XZ_OPT", "-T0 -9") : filter ((/= "XZ_OPT") . fst) env0),
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("tar failed: " <> T.pack (prStderr res))
