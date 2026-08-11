{-# LANGUAGE OverloadedStrings #-}

-- | Autolith-style SBCL deps tarball materialize (@.qlot/@ + vendored fff).
module Update.Sbcl.Deps
  ( SbclDepsOps (..),
    SbclDepsProgress (..),
    productionSbclDepsOps,
    mkSbclDepsOps,
    buildSbclDepsTarball,
    parseSbclVersionFloor,
    defaultQuicklispSetup,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
    removePathForcibly,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.DiskSpace
  ( MaterializeClass (FullSbcl),
    checkPostCloneForClass,
  )
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Pack.XzTar (packTarXz)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Injectable host ops for SBCL deps materialize.
data SbclDepsOps = SbclDepsOps
  { sdoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    sdoQlotInstall :: FilePath -> FilePath -> FilePath -> IO (Either Text ()),
    -- | Copy @src/.qlot@ into @stage/.qlot@ (dereference symlinks).
    sdoCopyQlot :: FilePath -> FilePath -> IO (Either Text ()),
    sdoMaterializeFff :: FilePath -> FilePath -> IO (Either Text ()),
    sdoPackTarball :: FilePath -> FilePath -> IO (Either Text ()),
    sdoQuicklispSetup :: IO (Either Text FilePath)
  }

data SbclDepsProgress = SbclDepsProgress
  { sdpOnCloneStart :: IO (),
    sdpOnCloneDone :: IO (),
    sdpOnQlotStart :: IO (),
    sdpOnQlotDone :: IO (),
    sdpOnFffStart :: IO (),
    sdpOnFffDone :: IO (),
    sdpOnCompressStart :: IO (),
    sdpOnCompressDone :: IO ()
  }

mkSbclDepsOps :: CommandRunner -> SbclDepsOps
mkSbclDepsOps run =
  SbclDepsOps
    { sdoClone = gitCloneTag run,
      sdoQlotInstall = qlotInstall run,
      sdoCopyQlot = copyQlotTree run,
      sdoMaterializeFff = materializeFff run,
      sdoPackTarball = packDepsTarball run,
      sdoQuicklispSetup = defaultQuicklispSetup
    }

productionSbclDepsOps :: SbclDepsOps
productionSbclDepsOps = mkSbclDepsOps productionCommandRunner

-- | Default Quicklisp setup path: @$HOME/quicklisp/setup.lisp@.
defaultQuicklispSetup :: IO (Either Text FilePath)
defaultQuicklispSetup = do
  home <- getHomeDirectory
  let path = home </> "quicklisp" </> "setup.lisp"
  exists <- doesFileExist path
  pure $
    if exists
      then Right path
      else
        Left
          ( "Quicklisp setup not found at "
              <> T.pack path
              <> " (install Quicklisp or ensure setup.lisp exists)"
          )

-- | Parse trimmed @sbcl.version@ content as a dotted numeric floor.
parseSbclVersionFloor :: Text -> Maybe Text
parseSbclVersionFloor body =
  let t = T.strip body
   in if validDottedVersion t then Just t else Nothing
  where
    validDottedVersion v =
      let parts = T.splitOn "." v
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts

-- | Clone tag → qlot install → fff vendor → pack @{pn}-{pv}-deps.tar.xz@.
-- Clone and stage live under unit @workDir@; tarball under @outDir@.
buildSbclDepsTarball ::
  SbclDepsOps ->
  SbclDepsProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  -- | Unit @work/@ (clone + stage).
  FilePath ->
  -- | Unit @out/@ (staged tarball).
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildSbclDepsTarball
  ops
  progress
  owner
  repo
  prefix
  pv
  workDir
  outDir
  tarballName = do
    createDirectoryIfMissing True outDir
    createDirectoryIfMissing True workDir
    let tag = versionTag prefix pv
        url = githubCloneUrl owner repo
        outPath = outDir </> tarballName
        cloneDir = workDir </> "src"
        stageDir = workDir </> "stage"
    qlResult <- sdoQuicklispSetup ops
    case qlResult of
      Left err -> pure (Left err)
      Right qlSetup -> do
        createDirectoryIfMissing True stageDir
        sdpOnCloneStart progress
        cloned <- sdoClone ops url tag cloneDir
        case cloned of
          Left err -> pure (Left err)
          Right () -> do
            sdpOnCloneDone progress
            spaceOk <- checkPostCloneForClass FullSbcl cloneDir
            case spaceOk of
              Left err -> pure (Left err)
              Right () ->
                preflightClone cloneDir >>= \case
                  Left err -> pure (Left err)
                  Right () -> do
                    sdpOnQlotStart progress
                    qlot <- sdoQlotInstall ops cloneDir "sbcl" qlSetup
                    case qlot of
                      Left err -> pure (Left err)
                      Right () -> do
                        sdpOnQlotDone progress
                        qlotOk <- sdoCopyQlot ops cloneDir stageDir
                        case qlotOk of
                          Left err -> pure (Left err)
                          Right () -> do
                            sdpOnFffStart progress
                            fff <- sdoMaterializeFff ops cloneDir stageDir
                            case fff of
                              Left err -> pure (Left err)
                              Right () -> do
                                sdpOnFffDone progress
                                sdpOnCompressStart progress
                                packed <- sdoPackTarball ops stageDir outPath
                                case packed of
                                  Left err -> pure (Left err)
                                  Right () -> do
                                    sdpOnCompressDone progress
                                    hasTar <- doesFileExist outPath
                                    pure $
                                      if hasTar
                                        then Right outPath
                                        else
                                          Left
                                            ( "SBCL deps pack did not produce tarball at "
                                                <> T.pack outPath
                                            )

preflightClone :: FilePath -> IO (Either Text ())
preflightClone root = do
  hasQlfile <- doesFileExist (root </> "qlfile")
  hasLock <- doesFileExist (root </> "qlfile.lock")
  hasFffPin <- doesFileExist (root </> "native" </> "fff" </> "commit")
  pure $
    if not hasQlfile || not hasLock
      then
        Left
          ( "qlfile / qlfile.lock not found under "
              <> T.pack root
              <> " (DepsAndAssets Sbcl requires a locked Autolith-style tree)"
          )
      else
        if not hasFffPin
          then
            Left
              ( "native/fff/commit not found under "
                  <> T.pack root
              )
          else Right ()

copyQlotTree :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
copyQlotTree run cloneDir stageDir = do
  let src = cloneDir </> ".qlot"
      dest = stageDir </> ".qlot"
  exists <- doesDirectoryExist src
  if not exists
    then pure (Left "qlot install did not create .qlot/")
    else do
      removePathForcibly dest
      -- Dereference symlinks so the tarball is self-contained (qlot cache links).
      env0 <- getEnvironment
      res <-
        run
          ProcessRequest
            { prMode = ExecCmd "cp" ["-aL", src, dest],
              prCwd = Nothing,
              prEnv = Just env0,
              prStdin = ""
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right ()
          else Left ("copy .qlot failed: " <> T.pack (prStderr res))

------------------------------------------------------------------------
-- Production command runners
------------------------------------------------------------------------

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

qlotInstall ::
  CommandRunner ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
qlotInstall run root sbclBin qlSetup = do
  let installer = root </> "script" </> "qlot-install.lisp"
  hasInstaller <- doesFileExist installer
  home <- getHomeDirectory
  env0 <- getEnvironment
  let env = ("HOME", home) : filter ((/= "HOME") . fst) env0
      defaultQl = home </> "quicklisp" </> "setup.lisp"
  if hasInstaller && qlSetup == defaultQl
    then do
      res <-
        run
          ProcessRequest
            { prMode =
                ExecCmd
                  sbclBin
                  [ "--noinform",
                    "--non-interactive",
                    "--no-userinit",
                    "--no-sysinit",
                    "--load",
                    installer
                  ],
              prCwd = Just root,
              prEnv = Just env,
              prStdin = ""
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right ()
          else Left ("qlot install failed: " <> T.pack (prStderr res))
    else do
      let lisp =
            T.unpack $
              T.unlines
                [ "(require :asdf)",
                  "(load \"" <> T.pack qlSetup <> "\")",
                  "(ql:quickload :qlot :silent t)",
                  "(let ((qlot-project-root (find-symbol \"*PROJECT-ROOT*\" \"QLOT\")))",
                  "  (unless qlot-project-root",
                  "    (error \"The loaded Qlot does not expose its project root.\"))",
                  "  (progv (list qlot-project-root) (list #p\""
                    <> T.pack root
                    <> "/\")",
                  "    (uiop:with-current-directory (#p\""
                    <> T.pack root
                    <> "/\")",
                  "      (uiop:symbol-call '#:qlot '#:install))))"
                ]
      res <-
        run
          ProcessRequest
            { prMode =
                ExecCmd
                  sbclBin
                  [ "--noinform",
                    "--non-interactive",
                    "--no-userinit",
                    "--no-sysinit",
                    "--eval",
                    lisp
                  ],
              prCwd = Just root,
              prEnv = Just env,
              prStdin = ""
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right ()
          else Left ("qlot install failed: " <> T.pack (prStderr res))

materializeFff :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
materializeFff run root stageDir = do
  commitRaw <- TIO.readFile (root </> "native" </> "fff" </> "commit")
  let commit = T.strip commitRaw
      fffDir = stageDir </> "fff"
  removePathForcibly fffDir
  createDirectoryIfMissing True fffDir
  cloneRes <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "git"
              [ "clone",
                "--filter=blob:none",
                "https://github.com/dmtrKovalenko/fff.git",
                fffDir
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  if prExitCode cloneRes /= ExitSuccess
    then pure (Left ("fff clone failed: " <> T.pack (prStderr cloneRes)))
    else do
      fetchRes <-
        run
          ProcessRequest
            { prMode =
                ExecCmd
                  "git"
                  ["-C", fffDir, "fetch", "--depth", "1", "origin", T.unpack commit],
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = ""
            }
      if prExitCode fetchRes /= ExitSuccess
        then pure (Left ("fff fetch failed: " <> T.pack (prStderr fetchRes)))
        else do
          coRes <-
            run
              ProcessRequest
                { prMode =
                    ExecCmd
                      "git"
                      [ "-C",
                        fffDir,
                        "checkout",
                        "--detach",
                        "--force",
                        "FETCH_HEAD"
                      ],
                  prCwd = Nothing,
                  prEnv = Nothing,
                  prStdin = ""
                }
          if prExitCode coRes /= ExitSuccess
            then pure (Left ("fff checkout failed: " <> T.pack (prStderr coRes)))
            else do
              headRes <-
                run
                  ProcessRequest
                    { prMode = ExecCmd "git" ["-C", fffDir, "rev-parse", "HEAD"],
                      prCwd = Nothing,
                      prEnv = Nothing,
                      prStdin = ""
                    }
              let actual = T.strip (T.pack (prStdout headRes))
              if prExitCode headRes /= ExitSuccess || actual /= commit
                then
                  pure $
                    Left
                      ( "fetched fff "
                          <> actual
                          <> ", expected "
                          <> commit
                      )
                else do
                  removePathForcibly (fffDir </> "vendor")
                  vendorRes <-
                    run
                      ProcessRequest
                        { prMode =
                            ExecCmd
                              "cargo"
                              ["vendor", "--locked", "--versioned-dirs", "vendor"],
                          prCwd = Just fffDir,
                          prEnv = Nothing,
                          prStdin = ""
                        }
                  if prExitCode vendorRes /= ExitSuccess
                    then
                      pure
                        ( Left
                            ( "cargo vendor failed: "
                                <> T.pack (prStderr vendorRes)
                            )
                        )
                    else do
                      createDirectoryIfMissing True (fffDir </> ".cargo")
                      TIO.writeFile
                        (fffDir </> ".cargo" </> "config.toml")
                        "# Generated by mndz-overlay-manager for offline Portage builds.\n\
                        \[source.crates-io]\n\
                        \replace-with = \"vendored-sources\"\n\
                        \\n\
                        \[source.vendored-sources]\n\
                        \directory = \"vendor\"\n"
                      removePathForcibly (fffDir </> ".git")
                      removePathForcibly (fffDir </> "target")
                      pure (Right ())

packDepsTarball :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
packDepsTarball run stageDir =
  packTarXz
    run
    "tar pack failed"
    Nothing
    (Just stageDir)
    [".qlot", "fff"]
