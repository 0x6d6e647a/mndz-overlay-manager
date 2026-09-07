{-# LANGUAGE OverloadedStrings #-}

module Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    productionCargoOps,
    mkCargoOps,
    buildCargoCratesTarball,
    crateTarballPrefix,
    cratesIoDownloadEndpoint,
    fetchAndUnpackCrate,
    harvestCloneFloor,
    harvestRegistryPackageRoots,
    -- Pack helpers (unit-tested)
    RegistryPackage (..),
    parseRegistryPackages,
    parseV8RegistryPin,
    rustyV8SnapshotBasename,
    rustyV8ReleaseTag,
    harvestRustyV8Snapshot,
    cargoChecksumJson,
    packCratesTarball,
    packCratesTarballWith,
  )
where

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
    cratePackageName,
    parseRegistryPackages,
    parseV8RegistryPin,
  )
import Update.Cargo.Msrv
  ( TagFloorResult (..),
    applyRustToolchainFloor,
    fetchCargoTomlFromDir,
    fetchRustToolchainFromDir,
    maxMaybeRustVersions,
    parseDirectRustVersion,
    parseRustMinVerFromEbuild,
    probePolicyTagFloor,
  )
import Update.DiskSpace
  ( MaterializeClass (FullCargo),
    checkPostCloneForClass,
  )
import Update.EbuildEdit (stripWindowsOnlyGitCrates)
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Pack.XzTar (packTarXzAtomic)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Types (CargoSource (..))

-- | Internal tarball path prefix expected by cargo.eclass.
crateTarballPrefix :: Text
crateTarballPrefix = "cargo_home/gentoo"

-- | rusty_v8+submodules snapshot basename keyed by crates.io @v8@ version.
rustyV8SnapshotBasename :: Text -> FilePath
rustyV8SnapshotBasename ver =
  T.unpack ("rusty-v8-" <> ver <> "-with-submodules.tar.xz")

-- | Assets release tag for a rusty_v8 snapshot (crate version, not overlay PV).
rustyV8ReleaseTag :: Text -> Text
rustyV8ReleaseTag ver = "rusty-v8-" <> ver

-- | Canonical crates.io download endpoint for a published crate.
cratesIoDownloadEndpoint :: Text -> Text -> Text
cratesIoDownloadEndpoint crate pv =
  "https://crates.io/api/v1/crates/" <> crate <> "/" <> pv <> "/download"

data CargoResult = CargoResult
  { crTarballPath :: FilePath,
    -- | Combined MSRV written as RUST_MIN_VER.
    crMsrv :: Text,
    -- | Ebuild body after pycargoebuild inplace update (before manager SRC_URI patches).
    crEbuildBody :: Text,
    -- | @max(Hsource, Hregistry)@ after pack; 'Nothing' if both absent.
    crHarvestFloor :: Maybe Text
  }

data CargoOps = CargoOps
  { coClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    -- | Fetch the published @crate@ @.crate@ at @pv@ from the canonical crates.io
    -- endpoint with in-container @aria2c@ (default User-Agent) into @distDir@,
    -- then unpack it under @srcDir@ as @{crate}-{pv}\/@. Hard-fails on fetch
    -- failure (naming endpoint and PV), package-name divergence from @pn@, or
    -- a missing unpacked @Cargo.lock@.
    coFetchUnpackCrate ::
      -- \| Overlay package name (also the expected published crate name).
      Text ->
      -- \| PV without revision.
      Text ->
      -- \| Unit distdir for the fetched @.crate@.
      FilePath ->
      -- \| Unit work source area receiving @{crate}-{pv}\/@.
      FilePath ->
      IO (Either Text ()),
    -- | Run pycargoebuild: ebuild path, lock root / pkg dir, tarball out path, temp distdir.
    coPycargoebuild :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ()),
    -- | Pack registry crates: staging callback @k N@, archive-start, lock
    -- root, distdir, stage dir, final tarball path.
    coPackCrates ::
      (Int -> Int -> IO ()) ->
      IO () ->
      FilePath ->
      FilePath ->
      FilePath ->
      FilePath ->
      IO (Either Text ())
  }

data CargoProgress = CargoProgress
  { cgpOnCloneStart :: IO (),
    cgpOnCloneDone :: IO (),
    cgpOnPycargoStart :: IO (),
    cgpOnPycargoDone :: IO (),
    -- | Called as @k N@ while extracting each registry crate (1-based @k@).
    cgpOnStageCrate :: Int -> Int -> IO (),
    cgpOnPackStart :: IO (),
    cgpOnPackDone :: IO ()
  }

-- | Build cargo ops over an injectable command runner (Unit heat surface).
mkCargoOps :: CommandRunner -> CargoOps
mkCargoOps run =
  CargoOps
    { coClone = gitCloneTag run,
      coFetchUnpackCrate = fetchAndUnpackCrate run,
      coPycargoebuild = runPycargoebuild run,
      coPackCrates = packCratesTarballWith run
    }

productionCargoOps :: CargoOps
productionCargoOps = mkCargoOps productionCommandRunner

-- | Clone-or-fetch @tag@/@published crate@, run pycargoebuild with no-write
-- crate tarball, pack crates, return tarball + MSRV + ebuild body.
-- Source, distdir, and stage live under unit @workDir@; tarball under @outDir@.
-- Provenance selects how @workDir/src@ is populated: 'CargoGitTag' clones the
-- GitHub tag (byte-for-byte legacy flow); 'CargoCratesIo' fetches and unpacks
-- the published crates.io @.crate@ for @pn@ at the target PV.
buildCargoCratesTarball ::
  CargoOps ->
  CargoProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  CargoSource ->
  -- | Donor ebuild content (from overlay template).
  Text ->
  -- | Planned direct tag floor (authoritative; not re-fetched).
  Maybe Text ->
  -- | Include canonical same-PV donor floor (same-PV rewrite only).
  Bool ->
  -- | Overlay package name (for ebuild filename in work dir).
  Text ->
  -- | Unit @work/@ (source tree, distdir, stage, donor ebuild).
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
  cargoSrc
  donorContent
  tagFloor
  useDonorFloor
  pn
  workDir
  outDir
  tarballName = do
    createDirectoryIfMissing True outDir
    createDirectoryIfMissing True workDir
    let tag = versionTag prefix pv
        url = githubCloneUrl owner repo
        outPath = outDir </> tarballName
        srcDir = workDir </> "src"
        distDir = workDir </> "distdir"
        stageDir = workDir </> "stage"
        ebuildName = T.unpack pn <> "-" <> T.unpack pv <> ".ebuild"
        ebuildPath = workDir </> ebuildName
    createDirectoryIfMissing True distDir
    populated <- case cargoSrc of
      CargoGitTag -> do
        cgpOnCloneStart progress
        cloned <- coClone ops url tag srcDir
        case cloned of
          Left err -> pure (Left err)
          Right () -> do
            cgpOnCloneDone progress
            pure (Right ())
      CargoCratesIo -> do
        cgpOnCloneStart progress
        fetched <- coFetchUnpackCrate ops pn pv distDir srcDir
        case fetched of
          Left err -> pure (Left err)
          Right () -> do
            cgpOnCloneDone progress
            pure (Right ())
    case populated of
      Left err -> pure (Left err)
      Right () -> do
        -- The source root is the clone (GitTag) or the unpacked crate tree
        -- (CratesIo); the unpack itself lands as srcDir/<p>/ in both cases.
        spaceOk <- checkPostCloneForClass FullCargo srcDir
        case spaceOk of
          Left err -> pure (Left err)
          Right () -> do
            let unpackedCrateRoot = srcDir </> (T.unpack pn <> "-" <> T.unpack pv)
                lockRoot = case (cargoSrc, mLockSub) of
                  (CargoCratesIo, _) -> unpackedCrateRoot
                  (CargoGitTag, Just sub) -> srcDir </> sub
                  (CargoGitTag, Nothing) -> srcDir
                -- pycargoebuild rejects workspace roots; run in the package member
                -- when set (e.g. usage's cli/). Cargo.lock is still resolved upward.
                -- CratesIo: the published crate root is the package.
                pycargoDir = case (cargoSrc, mPkgSub) of
                  (CargoGitTag, Just sub) -> srcDir </> sub
                  (CargoCratesIo, _) -> unpackedCrateRoot
                  (CargoGitTag, Nothing) -> lockRoot
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
                    packed <-
                      coPackCrates
                        ops
                        (cgpOnStageCrate progress)
                        (cgpOnPackStart progress)
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
                            ebuildBody0 <- TIO.readFile ebuildPath
                            lockBody <- TIO.readFile (lockRoot </> "Cargo.lock")
                            tomlBodies <- collectCargoTomlBodies lockRoot
                            let ebuildBody =
                                  stripWindowsOnlyGitCrates lockBody tomlBodies ebuildBody0
                            srcH <- case cargoSrc of
                              -- GitTag: active-set clone harvest (policy closure).
                              CargoGitTag -> harvestCloneFloor srcDir mPkgSub mLockSub
                              -- CratesIo: published crate manifests declare no
                              -- in-tree path deps; walk the unpacked crate root.
                              CargoCratesIo -> harvestCloneFloor unpackedCrateRoot Nothing Nothing
                            regH <-
                              harvestRegistryPackageRoots
                                (stageDir </> "cargo_home" </> "gentoo")
                            let mDonor =
                                  if useDonorFloor
                                    then parseRustMinVerFromEbuild donorContent
                                    else Nothing
                            pure $
                              case (srcH, regH) of
                                (Left err, _) -> Left err
                                (_, Left err) -> Left err
                                (Right mSrcH, Right mReg) ->
                                  let harvest = maxMaybeRustVersions [mSrcH, mReg]
                                   in case maxMaybeRustVersions [tagFloor, mSrcH, mReg, mDonor] of
                                        Nothing ->
                                          Left
                                            "could not determine RUST_MIN_VER (no direct tag \
                                            \rust-version, source/registry harvest, or same-PV \
                                            \donor RUST_MIN_VER)"
                                        Just msrv ->
                                          Right
                                            CargoResult
                                              { crTarballPath = outPath,
                                                crMsrv = msrv,
                                                crEbuildBody = ebuildBody,
                                                crHarvestFloor = harvest
                                              }

collectCargoTomlBodies :: FilePath -> IO [Text]
collectCargoTomlBodies root = do
  paths <- findCargoTomls root
  mapM TIO.readFile paths

findCargoTomls :: FilePath -> IO [FilePath]
findCargoTomls = go
  where
    go dir = do
      names <- listDirectory dir
      concat
        <$> mapM
          ( \n -> do
              let p = dir </> n
              isDir <- doesDirectoryExist p
              if isDir
                then
                  if n == ".git" || n == "target" || n == "vendor"
                    then pure []
                    else go p
                else
                  pure [p | n == "Cargo.toml"]
          )
          names

-- | Active-set clone harvest: same policy-package path closure as tag floor.
harvestCloneFloor ::
  FilePath ->
  Maybe FilePath ->
  Maybe FilePath ->
  IO (Either Text (Maybe Text))
harvestCloneFloor cloneDir mPkg mLock = do
  result <-
    probePolicyTagFloor
      mPkg
      mLock
      (Just cloneDir)
      (fetchCargoTomlFromDir cloneDir)
  case result of
    TagFloorIncomplete reasons _ ->
      pure $
        Left
          ( "incomplete clone Cargo.toml path closure: "
              <> T.intercalate "; " reasons
          )
    TagFloorFailed err -> pure (Left err)
    TagFloorComplete mFloor _ ->
      applyRustToolchainFloor mLock (fetchRustToolchainFromDir cloneDir) mFloor

-- | Direct rust-version from immediate extracted registry package roots only
-- (@cargo_home/gentoo/{name}-{version}/Cargo.toml@). Nested examples are ignored.
harvestRegistryPackageRoots :: FilePath -> IO (Either Text (Maybe Text))
harvestRegistryPackageRoots gentooDir = do
  exists <- doesDirectoryExist gentooDir
  if not exists
    then pure (Right Nothing)
    else do
      names <- listDirectory gentooDir
      paths <-
        concat
          <$> mapM
            ( \n -> do
                let dir = gentooDir </> n
                    toml = dir </> "Cargo.toml"
                isDir <- doesDirectoryExist dir
                hasToml <- doesFileExist toml
                pure [toml | isDir && hasToml]
            )
            names
      maxDirectRustFromFiles paths

maxDirectRustFromFiles :: [FilePath] -> IO (Either Text (Maybe Text))
maxDirectRustFromFiles paths = do
  parsed <- mapM readOne paths
  pure $
    case sequence parsed of
      Left err -> Left err
      Right ms -> Right (maxMaybeRustVersions ms)
  where
    readOne path = do
      body <- TIO.readFile path
      pure (parseDirectRustVersion body)

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
packCratesTarball run =
  packCratesTarballWith run (\_ _ -> pure ()) (pure ())

-- | Like 'packCratesTarball' with staging (@k@ of @N@) and archive-start hooks.
packCratesTarballWith ::
  CommandRunner ->
  (Int -> Int -> IO ()) ->
  IO () ->
  FilePath ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
packCratesTarballWith run onStage onArchiveStart lockRoot distDir stageDir outPath = do
  let lockPath = lockRoot </> "Cargo.lock"
  hasLock <- doesFileExist lockPath
  if not hasLock
    then pure $ Left ("cargo crates pack failed: Cargo.lock not found at " <> T.pack lockPath)
    else do
      body <- TIO.readFile lockPath
      case parseRegistryPackages body of
        Left err -> pure $ Left ("cargo crates pack failed: " <> err)
        Right pkgs ->
          stageAndArchive run onStage onArchiveStart pkgs distDir stageDir outPath

stageAndArchive ::
  CommandRunner ->
  (Int -> Int -> IO ()) ->
  IO () ->
  [RegistryPackage] ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
stageAndArchive run onStage onArchiveStart pkgs distDir stageDir outPath = do
  let gentooDir = stageDir </> "cargo_home" </> "gentoo"
  createDirectoryIfMissing True gentooDir
  staged <- stageAll 1 pkgs
  case staged of
    Left err -> pure (Left err)
    Right () -> do
      onArchiveStart
      createArchiveAtomic run stageDir outPath
  where
    n = length pkgs
    stageAll _ [] = pure (Right ())
    stageAll k (p : rest) = do
      onStage k n
      r <- stageOne p
      case r of
        Left err -> pure (Left err)
        Right () -> stageAll (k + 1) rest

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

-- | Reuse a verified rusty_v8 snapshot or clone @denoland/rusty_v8@ @v${ver}@
-- with recursive submodules and pack a hermetic tar/xz.
harvestRustyV8Snapshot ::
  (Text -> Text -> FilePath -> IO (Either Text ())) ->
  (FilePath -> FilePath -> IO (Either Text ())) ->
  Maybe FilePath ->
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
harvestRustyV8Snapshot cloneFn packFn mReuse ver workDir outDir =
  let outPath = outDir </> rustyV8SnapshotBasename ver
      tag = "v" <> ver
      src = workDir </> "rusty_v8"
      url = "https://github.com/denoland/rusty_v8" :: Text
   in case mReuse of
        Just p -> pure (Right p)
        Nothing -> do
          createDirectoryIfMissing True workDir
          createDirectoryIfMissing True outDir
          cloned <- cloneFn url tag src
          case cloned of
            Left err -> pure (Left err)
            Right () -> do
              packed <- packFn src outPath
              pure $ case packed of
                Left err -> Left err
                Right () -> Right outPath

------------------------------------------------------------------------
-- CratesIo fetch-and-unpack (published crate provenance)
------------------------------------------------------------------------

-- | Fetch the published @crate@ @.crate@ at @pv@ from the canonical crates.io
-- download endpoint with @aria2c@ (its default User-Agent, matching
-- pycargoebuild's in-container fetch posture) into @distDir@, then unpack the
-- tarball under @srcDir@. Hard-fails on fetch failure (naming the endpoint and
-- PV), when the unpacked tree does not contain the expected @{crate}-{pv}\/@
-- directory, when the published manifest's package name diverges from the
-- overlay package name @pn@ (naming both), or when the unpacked crate lacks
-- @Cargo.lock@.
fetchAndUnpackCrate ::
  CommandRunner ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
fetchAndUnpackCrate run pn pv distDir srcDir = do
  createDirectoryIfMissing True distDir
  createDirectoryIfMissing True srcDir
  let endpoint = cratesIoDownloadEndpoint pn pv
      crateFile = T.unpack pn <> "-" <> T.unpack pv <> ".crate"
      cratePath = distDir </> crateFile
      expectedDirName = T.unpack pn <> "-" <> T.unpack pv
      crateDir = srcDir </> expectedDirName
  fetchRes <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "aria2c"
              [ "--dir",
                distDir,
                "--out",
                crateFile,
                "--allow-overwrite=true",
                T.unpack endpoint
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  case prExitCode fetchRes of
    ExitFailure _ ->
      pure $
        Left
          ( "crates.io fetch failed for published crate "
              <> pn
              <> "-"
              <> pv
              <> " from "
              <> endpoint
              <> ": "
              <> T.strip (T.pack (prStderr fetchRes))
          )
    ExitSuccess -> do
      unpacked <-
        run
          ProcessRequest
            { prMode = ExecCmd "tar" ["-xzf", cratePath, "-C", srcDir],
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = ""
            }
      case prExitCode unpacked of
        ExitFailure _ ->
          pure $
            Left
              ( "crates.io crate unpack failed for "
                  <> pn
                  <> "-"
                  <> pv
                  <> ": "
                  <> T.strip (T.pack (prStderr unpacked))
              )
        ExitSuccess -> do
          dirOk <- doesDirectoryExist crateDir
          if not dirOk
            then
              pure $
                Left
                  ( "crates.io crate unpack did not produce "
                      <> pn
                      <> "-"
                      <> pv
                      <> "/ under "
                      <> T.pack srcDir
                      <> " (expected published crate directory "
                      <> T.pack expectedDirName
                      <> ")"
                  )
            else do
              mBody <- readOptionalFile (crateDir </> "Cargo.toml")
              case mBody >>= cratePackageName of
                Nothing ->
                  pure $
                    Left
                      ( "published crate "
                          <> pn
                          <> "-"
                          <> pv
                          <> " has no [package].name in Cargo.toml"
                      )
                Just name
                  | name /= pn ->
                      pure $
                        Left
                          ( "published crate package name "
                              <> name
                              <> " differs from overlay package name "
                              <> pn
                              <> " (crates.io provenance requires them to match)"
                          )
                  | otherwise -> do
                      hasLock <- doesFileExist (crateDir </> "Cargo.lock")
                      if not hasLock
                        then
                          pure $
                            Left
                              ( "published crate "
                                  <> pn
                                  <> "-"
                                  <> pv
                                  <> " has no Cargo.lock; pack requires the \
                                     \published crate's lockfile"
                              )
                        else pure (Right ())
  where
    readOptionalFile path = do
      exists <- doesFileExist path
      if exists then Just <$> TIO.readFile path else pure Nothing
