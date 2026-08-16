{-# LANGUAGE OverloadedStrings #-}

module Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    productionCargoOps,
    mkCargoOps,
    buildCargoCratesTarball,
    crateTarballPrefix,
    maxRustVersionInTree,
    -- Pack helpers (unit-tested)
    RegistryPackage (..),
    parseRegistryPackages,
    cargoChecksumJson,
    packCratesTarball,
  )
where

import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.Cargo.Lock
  ( RegistryPackage (..),
    crateDirName,
    crateFilename,
    parseRegistryPackages,
  )
import Update.Cargo.Msrv
  ( combineMsrv,
    maxRustVersion,
    parseRustMinVerFromEbuild,
    parseRustVersionField,
  )
import Update.DiskSpace
  ( MaterializeClass (FullCargo),
    checkPostCloneForClass,
  )
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Pack.XzTar (packTarXzAtomic)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Internal tarball path prefix expected by cargo.eclass.
crateTarballPrefix :: Text
crateTarballPrefix = "cargo_home/gentoo"

data CargoResult = CargoResult
  { crTarballPath :: FilePath,
    -- | Combined MSRV written as RUST_MIN_VER.
    crMsrv :: Text,
    -- | Ebuild body after pycargoebuild inplace update (before manager SRC_URI patches).
    crEbuildBody :: Text
  }

data CargoOps = CargoOps
  { coClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    -- | Run pycargoebuild: ebuild path, lock root / pkg dir, tarball out path, temp distdir.
    coPycargoebuild :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ()),
    -- | Pack registry crates: lock root, distdir, stage dir, final tarball path.
    coPackCrates :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
  }

data CargoProgress = CargoProgress
  { cgpOnCloneStart :: IO (),
    cgpOnCloneDone :: IO (),
    cgpOnPycargoStart :: IO (),
    cgpOnPycargoDone :: IO (),
    cgpOnPackStart :: IO (),
    cgpOnPackDone :: IO ()
  }

-- | Build cargo ops over an injectable command runner (Unit heat surface).
mkCargoOps :: CommandRunner -> CargoOps
mkCargoOps run =
  CargoOps
    { coClone = gitCloneTag run,
      coPycargoebuild = runPycargoebuild run,
      coPackCrates = packCratesTarball run
    }

productionCargoOps :: CargoOps
productionCargoOps = mkCargoOps productionCommandRunner

-- | Clone @tag@, run pycargoebuild with no-write crate tarball, pack crates, return
-- tarball + MSRV + ebuild body.
-- Clone, distdir, and stage live under unit @workDir@; tarball under @outDir@.
buildCargoCratesTarball ::
  CargoOps ->
  CargoProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  -- | Donor ebuild content (from overlay template).
  Text ->
  -- | Overlay package name (for ebuild filename in work dir).
  Text ->
  -- | Unit @work/@ (clone, distdir, stage, donor ebuild).
  FilePath ->
  -- | Unit @out/@ (staged tarball).
  FilePath ->
  FilePath ->
  IO (Either Text CargoResult)
buildCargoCratesTarball
  ops
  progress
  owner
  repo
  prefix
  pv
  mLockSub
  mPkgSub
  donorContent
  pn
  workDir
  outDir
  tarballName = do
    createDirectoryIfMissing True outDir
    createDirectoryIfMissing True workDir
    let tag = versionTag prefix pv
        url = githubCloneUrl owner repo
        outPath = outDir </> tarballName
        cloneDir = workDir </> "src"
        distDir = workDir </> "distdir"
        stageDir = workDir </> "stage"
        ebuildName = T.unpack pn <> "-" <> T.unpack pv <> ".ebuild"
        ebuildPath = workDir </> ebuildName
    createDirectoryIfMissing True distDir
    cgpOnCloneStart progress
    cloned <- coClone ops url tag cloneDir
    case cloned of
      Left err -> pure (Left err)
      Right () -> do
        cgpOnCloneDone progress
        spaceOk <- checkPostCloneForClass FullCargo cloneDir
        case spaceOk of
          Left err -> pure (Left err)
          Right () -> do
            let lockRoot = case mLockSub of
                  Nothing -> cloneDir
                  Just sub -> cloneDir </> sub
                pkgDir = case mPkgSub of
                  Nothing -> lockRoot
                  Just sub -> cloneDir </> sub
                -- pycargoebuild rejects workspace roots; run in the package member
                -- when set (e.g. usage's cli/). Cargo.lock is still resolved upward.
                pycargoDir = case mPkgSub of
                  Just sub -> cloneDir </> sub
                  Nothing -> lockRoot
            hasLock <- doesFileExist (lockRoot </> "Cargo.lock")
            if not hasLock
              then
                pure $
                  Left
                    ( "Cargo.lock not found at "
                        <> T.pack lockRoot
                    )
              else do
                TIO.writeFile ebuildPath donorContent
                cgpOnPycargoStart progress
                tool <-
                  coPycargoebuild
                    ops
                    ebuildPath
                    pycargoDir
                    outPath
                    distDir
                case tool of
                  Left err -> pure (Left err)
                  Right () -> do
                    cgpOnPycargoDone progress
                    cgpOnPackStart progress
                    packed <-
                      coPackCrates
                        ops
                        lockRoot
                        distDir
                        stageDir
                        outPath
                    case packed of
                      Left err -> pure (Left err)
                      Right () -> do
                        cgpOnPackDone progress
                        hasTar <- doesFileExist outPath
                        if not hasTar
                          then
                            pure $
                              Left
                                ( "cargo crates pack failed: tarball missing at "
                                    <> T.pack outPath
                                )
                          else do
                            ebuildBody <- TIO.readFile ebuildPath
                            rootToml <- readOptionalToml (pkgDir </> "Cargo.toml")
                            let mRoot = parseRustVersionField =<< rootToml
                            mDeps <- maxRustVersionInTree lockRoot
                            let mDonor = parseRustMinVerFromEbuild donorContent
                            case combineMsrv mRoot mDeps mDonor of
                              Nothing ->
                                pure $
                                  Left
                                    "could not determine RUST_MIN_VER (no package.rust-version, \
                                    \dependency rust-version, or donor RUST_MIN_VER)"
                              Just msrv ->
                                pure $
                                  Right
                                    CargoResult
                                      { crTarballPath = outPath,
                                        crMsrv = msrv,
                                        crEbuildBody = ebuildBody
                                      }

readOptionalToml :: FilePath -> IO (Maybe Text)
readOptionalToml path = do
  exists <- doesFileExist path
  if exists then Just <$> TIO.readFile path else pure Nothing

-- | Max declared @package.rust-version@ under a lock/workspace tree.
maxRustVersionInTree :: FilePath -> IO (Maybe Text)
maxRustVersionInTree root = do
  tomls <- findCargoTomls root
  vers <- mapM readVer tomls
  pure $
    case catMaybes vers of
      [] -> Nothing
      (x : xs) -> foldl' merge (Just x) xs
  where
    readVer path = do
      body <- TIO.readFile path
      pure (parseRustVersionField body)
    merge acc y = case acc of
      Nothing -> Just y
      Just a -> maxRustVersion a y

findCargoTomls :: FilePath -> IO [FilePath]
findCargoTomls root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else go root
  where
    go dir = do
      names <- listDirectory dir
      let here =
            [ dir </> n
            | n <- names,
              n == "Cargo.toml"
            ]
          skip =
            [ "target",
              ".git",
              "node_modules",
              "cargo_home"
            ]
      subs <-
        concat
          <$> mapM
            ( \n -> do
                let p = dir </> n
                isDir <- doesDirectoryExist p
                if isDir && n `notElem` skip
                  then go p
                  else pure []
            )
            names
      pure (here <> subs)

------------------------------------------------------------------------
-- pycargoebuild (fetch / license / ebuild; no archive write)
------------------------------------------------------------------------

runPycargoebuild :: CommandRunner -> FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
runPycargoebuild run ebuildPath lockRoot tarballPath distDir = do
  let args =
        [ "-c",
          "-i",
          ebuildPath,
          "-M",
          "-f",
          "--crate-tarball-path",
          tarballPath,
          "--crate-tarball-prefix",
          T.unpack crateTarballPrefix,
          "--no-write-crate-tarball",
          "-d",
          distDir,
          lockRoot
        ]
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "pycargoebuild" args,
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( "pycargoebuild failed: "
              <> T.strip (T.pack (prStderr res))
              <> ( if T.null (T.strip (T.pack (prStdout res)))
                     then ""
                     else "\n" <> T.strip (T.pack (prStdout res))
                 )
          )

------------------------------------------------------------------------
-- Manager-owned crates tarball pack
------------------------------------------------------------------------

-- | @.cargo-checksum.json@ body for a registry package (lock checksum, empty files).
cargoChecksumJson :: Text -> Text
cargoChecksumJson packageChecksum =
  "{\"package\":\"" <> packageChecksum <> "\",\"files\":{}}"

-- | Stage distdir registry crates under @cargo_home/gentoo/@, write checksum JSON,
-- and create @{pn}-{pv}-crates.tar.xz@ via system @tar@ with @XZ_OPT=-T1 -9e@.
-- Writes atomically (temp path then rename). Errors use a pack-specific prefix.
packCratesTarball ::
  CommandRunner ->
  FilePath ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
packCratesTarball run lockRoot distDir stageDir outPath = do
  let lockPath = lockRoot </> "Cargo.lock"
  hasLock <- doesFileExist lockPath
  if not hasLock
    then pure $ Left ("cargo crates pack failed: Cargo.lock not found at " <> T.pack lockPath)
    else do
      body <- TIO.readFile lockPath
      case parseRegistryPackages body of
        Left err -> pure $ Left ("cargo crates pack failed: " <> err)
        Right pkgs -> stageAndArchive run pkgs distDir stageDir outPath

stageAndArchive ::
  CommandRunner ->
  [RegistryPackage] ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
stageAndArchive run pkgs distDir stageDir outPath = do
  let gentooDir = stageDir </> "cargo_home" </> "gentoo"
  createDirectoryIfMissing True gentooDir
  staged <- stageAll pkgs
  case staged of
    Left err -> pure (Left err)
    Right () -> createArchiveAtomic run stageDir outPath
  where
    stageAll [] = pure (Right ())
    stageAll (p : rest) = do
      r <- stageOne p
      case r of
        Left err -> pure (Left err)
        Right () -> stageAll rest

    stageOne p = do
      let cratePath = distDir </> crateFilename p
          destDir = stageDir </> "cargo_home" </> "gentoo"
      exists <- doesFileExist cratePath
      if not exists
        then
          pure $
            Left
              ( "cargo crates pack failed: missing registry crate "
                  <> T.pack (crateFilename p)
                  <> " in distdir "
                  <> T.pack distDir
              )
        else do
          extracted <- extractCrate run cratePath destDir
          case extracted of
            Left err -> pure (Left err)
            Right () -> do
              let pkgDir = destDir </> crateDirName p
                  checksumPath = pkgDir </> ".cargo-checksum.json"
              pkgExists <- doesDirectoryExist pkgDir
              if not pkgExists
                then
                  pure $
                    Left
                      ( "cargo crates pack failed: extract of "
                          <> T.pack (crateFilename p)
                          <> " did not produce "
                          <> T.pack (crateDirName p)
                      )
                else do
                  TIO.writeFile checksumPath (cargoChecksumJson (rpChecksum p))
                  pure (Right ())

extractCrate :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
extractCrate run cratePath destDir = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "tar" ["-xzf", cratePath, "-C", destDir],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( "cargo crates pack failed: tar extract "
              <> T.pack cratePath
              <> ": "
              <> T.strip (T.pack (prStderr res))
          )

createArchiveAtomic :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
createArchiveAtomic run stageDir =
  packTarXzAtomic
    run
    "cargo crates pack failed"
    Nothing
    (Just stageDir)
    ["cargo_home"]

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
