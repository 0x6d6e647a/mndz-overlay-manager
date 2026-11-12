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
    gitCloneRecursiveSubmodules,
    parseV8DepsGcsLinux,
    extractV8DepsFromSnapshot,
    V8GcsLinuxDists (..),
    cargoChecksumJson,
    packCratesTarball,
    packCratesTarballWith,
  )
where

import CLI.Jobs (PackSlot)
import Control.Exception (IOException, try)
import Data.List (intercalate)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    makeAbsolute,
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Update.Assets.Layout
  ( rustyV8ReleaseTag,
    rustyV8SnapshotBasename,
  )
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
import Update.Cargo.V8Deps
  ( V8GcsLinuxDists (..),
    extractV8DepsFromSnapshot,
    parseV8DepsGcsLinux,
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
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Types (CargoSource (..))

-- | Internal tarball path prefix expected by cargo.eclass.
crateTarballPrefix :: Text
crateTarballPrefix = "cargo_home/gentoo"

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
    -- | Run @cargo generate-lockfile@ in the lock root. Used only when
    -- provenance is 'CargoGitTagGenerateLock' and @Cargo.lock@ is absent.
    -- A non-zero exit is 'Left' and does not include the lock-root prefix;
    -- the caller adds that path.
    coGenerateLockfile :: FilePath -> IO (Either Text ()),
    -- | Run pycargoebuild: ebuild path, lock root / pkg dir, tarball out path, temp distdir.
    coPycargoebuild :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ()),
    -- | Pack registry crates: staging callback (registry crate count),
    -- archive-start, lock root, distdir, stage dir, final tarball path.
    coPackCrates ::
      (Int -> IO ()) ->
      IO () ->
      FilePath ->
      FilePath ->
      FilePath ->
      FilePath ->
      IO (Either Text ()),
    -- | @git clone --recurse-submodules --depth 1 --branch@ (rusty_v8 harvest).
    coCloneRecursiveSubmodules :: Text -> Text -> FilePath -> IO (Either Text ()),
    -- | Hermetic tar/xz of a source tree to a dest path (rusty_v8 snapshot).
    coPackTree :: FilePath -> FilePath -> IO (Either Text ())
  }

data CargoProgress = CargoProgress
  { cgpOnCloneStart :: IO (),
    cgpOnCloneDone :: IO (),
    cgpOnPycargoStart :: IO (),
    cgpOnPycargoDone :: IO (),
    -- | Called once with the registry crate count before extraction.
    -- Skipped when that count is zero.
    cgpOnStageCrate :: Int -> IO (),
    cgpOnPackStart :: IO (),
    cgpOnPackDone :: IO ()
  }

-- | Build cargo ops over an injectable command runner (Unit heat surface).
--
-- @threads@ is the xz thread count @N@ for crates and rusty_v8 packs
-- (@xzOptValue@: block size when @N > 1@). @slot@ is the update's shared
-- compress lock.
-- Crate staging is one @xargs -P N@ invocation and does not take it.
-- @N@ is @threads@ (values below 1 become 1, matching @xzOptValue@).
mkCargoOps :: Int -> PackSlot -> CommandRunner -> CargoOps
mkCargoOps threads slot run =
  CargoOps
    { coClone = gitCloneTag run,
      coFetchUnpackCrate = fetchAndUnpackCrate run,
      coGenerateLockfile = runGenerateLockfile run,
      coPycargoebuild = runPycargoebuild run,
      coPackCrates = packCratesTarballWith threads slot run,
      coCloneRecursiveSubmodules = gitCloneRecursiveSubmodules run,
      coPackTree = packRustyV8Tree threads slot run
    }

-- | Fallback ops. An update passes the resolved @--jobs@ count and its slot.
productionCargoOps :: PackSlot -> CargoOps
productionCargoOps slot = mkCargoOps 1 slot productionCommandRunner

-- | Clone-or-fetch @tag@/@published crate@, run pycargoebuild with
-- @--use-crate-tarball@, pack crates, return tarball + MSRV + ebuild body.
-- Source, distdir, and stage live under unit @workDir@; tarball under @outDir@.
-- Provenance selects how @workDir/src@ is populated: 'CargoGitTag' and
-- 'CargoGitTagGenerateLock' clone the GitHub tag; 'CargoCratesIo' fetches and
-- unpacks the published crates.io @.crate@ for @pn@ at the target PV.
-- 'CargoGitTagGenerateLock' runs @cargo generate-lockfile@ in the lock root
-- when that clone has no @Cargo.lock@. 'CargoGitTag' still hard-fails then.
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
    let cloneTag = do
          cgpOnCloneStart progress
          cloned <- coClone ops url tag srcDir
          case cloned of
            Left err -> pure (Left err)
            Right () -> do
              cgpOnCloneDone progress
              pure (Right ())
    populated <- case cargoSrc of
      CargoGitTag -> cloneTag
      CargoGitTagGenerateLock -> cloneTag
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
                gitLockRoot = maybe srcDir (srcDir </>) mLockSub
                lockRoot = case cargoSrc of
                  CargoCratesIo -> unpackedCrateRoot
                  CargoGitTag -> gitLockRoot
                  CargoGitTagGenerateLock -> gitLockRoot
                -- pycargoebuild rejects workspace roots; run in the package member
                -- when set (e.g. usage's cli/). Cargo.lock is still resolved upward.
                -- CratesIo: the published crate root is the package.
                gitPkgDir = maybe lockRoot (srcDir </>) mPkgSub
                pycargoDir = case cargoSrc of
                  CargoCratesIo -> unpackedCrateRoot
                  CargoGitTag -> gitPkgDir
                  CargoGitTagGenerateLock -> gitPkgDir
            lockReady <- requireOrGenerateLock ops cargoSrc lockRoot
            case lockReady of
              Left err -> pure (Left err)
              Right () -> do
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
                                  stripWindowsOnlyGitCrates pn lockBody tomlBodies ebuildBody0
                            srcH <- case cargoSrc of
                              -- Git tag clones: active-set harvest (policy closure).
                              CargoGitTag -> harvestCloneFloor srcDir mPkgSub mLockSub
                              CargoGitTagGenerateLock -> harvestCloneFloor srcDir mPkgSub mLockSub
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

-- | Keep an existing @Cargo.lock@. For 'CargoGitTagGenerateLock' only, create
-- a missing lock with @cargo generate-lockfile@. Other provenances hard-fail
-- and do not generate. A failed generate names the lock root and does not
-- continue to @pycargoebuild@.
requireOrGenerateLock :: CargoOps -> CargoSource -> FilePath -> IO (Either Text ())
requireOrGenerateLock ops cargoSrc lockRoot = do
  let lockPath = lockRoot </> "Cargo.lock"
  hasLock <- doesFileExist lockPath
  let missing = Left ("Cargo.lock not found at " <> T.pack lockRoot)
  case (cargoSrc, hasLock) of
    (_, True) -> pure (Right ())
    (CargoGitTagGenerateLock, False) -> do
      generated <- coGenerateLockfile ops lockRoot
      case generated of
        Left err ->
          pure $
            Left
              ( "cargo generate-lockfile failed at "
                  <> T.pack lockRoot
                  <> ": "
                  <> err
              )
        Right () -> do
          wrote <- doesFileExist lockPath
          pure $
            if wrote
              then Right ()
              else missing
    (CargoGitTag, False) -> pure missing
    (CargoCratesIo, False) -> pure missing

-- | @cargo generate-lockfile@ in @lockRoot@. The caller's error adds the path.
runGenerateLockfile :: CommandRunner -> FilePath -> IO (Either Text ())
runGenerateLockfile run lockRoot = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "cargo" ["generate-lockfile"],
          prCwd = Just lockRoot,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  pure $ case prExitCode res of
    ExitSuccess -> Right ()
    ExitFailure code ->
      Left
        ( "exit "
            <> T.pack (show code)
            <> ": "
            <> T.strip (T.pack (prStderr res))
        )

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
        [ "--use-crate-tarball",
          "-i",
          ebuildPath,
          "-M",
          "-f",
          "--crate-tarball-path",
          tarballPath,
          "--crate-tarball-prefix",
          T.unpack crateTarballPrefix,
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
          prStdin = "",
          prMeasure = Timed
        }
  case prExitCode res of
    ExitSuccess -> pure (Right ())
    ExitFailure code ->
      summarizePycargoFailure distDir code (prStderr res) (prStdout res)

-- | @distDir@ is @<unit>/work/distdir@. The transcript is written on the host
-- in @<unit>@, beside @work/@ and @out/@, which are the only container mounts.
summarizePycargoFailure :: FilePath -> Int -> String -> String -> IO (Either Text ())
summarizePycargoFailure distDir code err out = do
  let logPath = takeDirectory (takeDirectory distDir) </> "pycargoebuild.log"
  logPathAbs <- makeAbsolute logPath
  written <-
    try @IOException $
      TIO.writeFile logPathAbs (pycargoTranscript code err out)
  pure (Left (pycargoFailureMessage code logPathAbs err out written))

pycargoFailureMessage :: Int -> FilePath -> String -> String -> Either IOException () -> Text
pycargoFailureMessage code logPath err out written =
  T.intercalate "\n" $
    ("pycargoebuild failed (exit " <> T.pack (show code) <> ")")
      : quotedErrorLines err out
      ++ [logLine]
  where
    logLine = case written of
      Right () -> "log: " <> T.pack logPath
      Left ex ->
        "log: "
          <> T.pack logPath
          <> " was not written: "
          <> T.pack (show ex)

-- | Stderr matches first, then stdout matches. A line matches when its
-- case-folded text contains @error@.
quotedErrorLines :: String -> String -> [Text]
quotedErrorLines err out =
  quoteStream err <> quoteStream out
  where
    quoteStream stream =
      [ "    " <> line
      | line <- T.lines (T.pack stream),
        "error" `T.isInfixOf` T.toCaseFold line
      ]

pycargoTranscript :: Int -> String -> String -> Text
pycargoTranscript code err out =
  "exit: "
    <> T.pack (show code)
    <> "\nstderr:\n"
    <> streamBlock err
    <> "stdout:\n"
    <> streamBlock out
  where
    streamBlock stream =
      case T.pack stream of
        t
          | T.null t -> "\n"
          | "\n" `T.isSuffixOf` t -> t
          | otherwise -> t <> "\n"

------------------------------------------------------------------------
-- Manager-owned crates tarball pack
------------------------------------------------------------------------

-- | @.cargo-checksum.json@ body for a registry package (lock checksum, empty files).
cargoChecksumJson :: Text -> Text
cargoChecksumJson packageChecksum =
  "{\"package\":\"" <> packageChecksum <> "\",\"files\":{}}"

-- | Stage distdir registry crates under @cargo_home/gentoo/@, write checksum JSON,
-- and create @{pn}-{pv}-crates.tar.xz@ via system @tar@ with @xzOptValue@
-- (@N@ threads, block size when @N > 1@).
-- Writes atomically (temp path then rename). Errors use a pack-specific prefix.
-- @threads@ is that @N@ (values below 1 become 1).
packCratesTarball ::
  Int ->
  PackSlot ->
  CommandRunner ->
  FilePath ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
packCratesTarball threads slot run =
  packCratesTarballWith threads slot run (\_ -> pure ()) (pure ())

-- | Like 'packCratesTarball' with a staging-count hook and an archive-start hook.
-- The staging hook runs once, with the registry crate count, and only when
-- that count is at least 1.
packCratesTarballWith ::
  Int ->
  PackSlot ->
  CommandRunner ->
  (Int -> IO ()) ->
  IO () ->
  FilePath ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
packCratesTarballWith threads slot run onStage onArchiveStart lockRoot distDir stageDir outPath = do
  let lockPath = lockRoot </> "Cargo.lock"
  hasLock <- doesFileExist lockPath
  if not hasLock
    then pure $ Left ("cargo crates pack failed: Cargo.lock not found at " <> T.pack lockPath)
    else do
      body <- TIO.readFile lockPath
      case parseRegistryPackages body of
        Left err -> pure $ Left ("cargo crates pack failed: " <> err)
        Right pkgs ->
          stageAndArchive threads slot run onStage onArchiveStart pkgs distDir stageDir outPath

stageAndArchive ::
  Int ->
  PackSlot ->
  CommandRunner ->
  (Int -> IO ()) ->
  IO () ->
  [RegistryPackage] ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
stageAndArchive threads slot run onStage onArchiveStart pkgs distDir stageDir outPath = do
  let gentooDir = stageDir </> "cargo_home" </> "gentoo"
      errDir = takeDirectory stageDir </> "crate-errors"
      unitDir = takeDirectory (takeDirectory stageDir)
  createDirectoryIfMissing True gentooDir
  missing <- traverse (missingCrate distDir) pkgs
  case catMaybes missing of
    records@(first : _) ->
      stagingHardFail unitDir records (missingSummary distDir (length records) first)
    []
      | null pkgs -> archiveStaged
      | otherwise -> do
          onStage (length pkgs)
          createDirectoryIfMissing True errDir
          cratePaths <-
            traverse (\pkg -> makeAbsolute (distDir </> crateFilename pkg)) pkgs
          res <- runCrateExtract run threads gentooDir errDir cratePaths
          scanned <- traverse (scanStaged gentooDir errDir) pkgs
          -- No @.err@ file means the invocation never reported a crate
          -- (xargs or the container failed). A zero exit with a missing
          -- directory is still a per-crate failure.
          let anyExtract = any scanExtract scanned
          case prExitCode res of
            ExitFailure code
              | not anyExtract ->
                  pure (Left (invocationFailure code (prStderr res)))
            _ -> do
              settled <- traverse (settleStaged gentooDir) (zip pkgs scanned)
              case catMaybes settled of
                records@(first : _) ->
                  stagingHardFail unitDir records (stageSummary (length records) first)
                [] -> archiveStaged
  where
    archiveStaged = do
      onArchiveStart
      createArchiveAtomic threads slot run stageDir outPath

-- | One lock-listed crate that is not in the distdir. Lock order is the
-- traversal order of 'stageAndArchive'.
missingCrate :: FilePath -> RegistryPackage -> IO (Maybe CrateStageFailure)
missingCrate distDir pkg = do
  let file = crateFilename pkg
  exists <- doesFileExist (distDir </> file)
  pure $
    if exists
      then Nothing
      else Just (CrateStageFailure file CrateMissing "")

-- | What the batched extract left for one lock entry, before checksums.
data CrateScan = ScanExtract Text | ScanNoDirectory | ScanOk

scanExtract :: CrateScan -> Bool
scanExtract (ScanExtract _) = True
scanExtract _ = False

-- | An @.err@ file is an extract failure. Otherwise a missing crate directory
-- is noted; the caller decides whether that is a no-directory failure or part
-- of an invocation failure.
scanStaged :: FilePath -> FilePath -> RegistryPackage -> IO CrateScan
scanStaged gentooDir errDir pkg = do
  let file = crateFilename pkg
      errPath = errDir </> (file <> ".err")
      pkgDir = gentooDir </> crateDirName pkg
  hasErr <- doesFileExist errPath
  if hasErr
    then ScanExtract <$> TIO.readFile errPath
    else do
      hasDir <- doesDirectoryExist pkgDir
      pure $ if hasDir then ScanOk else ScanNoDirectory

-- | Turn a scan into a failure, or write @.cargo-checksum.json@ for a crate
-- that staged cleanly.
settleStaged ::
  FilePath ->
  (RegistryPackage, CrateScan) ->
  IO (Maybe CrateStageFailure)
settleStaged gentooDir (pkg, scan) = do
  let file = crateFilename pkg
      pkgDir = gentooDir </> crateDirName pkg
  case scan of
    ScanExtract body ->
      pure (Just (CrateStageFailure file CrateExtract body))
    ScanNoDirectory ->
      pure (Just (CrateStageFailure file CrateNoDirectory ""))
    ScanOk -> do
      TIO.writeFile
        (pkgDir </> ".cargo-checksum.json")
        (cargoChecksumJson (rpChecksum pkg))
      pure Nothing

-- | One @xargs -0 -P W@ invocation. Paths stay on stdin, in lock order.
-- @W@ is @threads@ clamped to at least 1 (@xargs -P 0@ would mean unlimited).
runCrateExtract ::
  CommandRunner ->
  Int ->
  FilePath ->
  FilePath ->
  [FilePath] ->
  IO ProcessResult
runCrateExtract run threads gentooDir errDir cratePaths =
  run
    ProcessRequest
      { prMode =
          ExecCmd
            "xargs"
            [ "-0",
              "-P",
              show (max 1 threads),
              "-n",
              "1",
              "sh",
              "-c",
              crateExtractScript,
              "sh",
              gentooDir,
              errDir
            ],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = intercalate "\0" cratePaths,
        prMeasure = Timed
      }

-- | @$1@ is the gentoo directory, @$2@ is the error directory, @$3@ is the
-- crate path @xargs@ appends. A failing @tar@ leaves @<filename>.err@ and
-- exits 1 (never 255, so @xargs@ keeps going). Success removes that file.
crateExtractScript :: String
crateExtractScript =
  unlines
    [ "f=$3; e=$2/${f##*/}.err",
      "tar -xzf \"$f\" -C \"$1\" 2>\"$e\" || exit 1",
      "rm -f \"$e\""
    ]

data CrateStageKind = CrateMissing | CrateExtract | CrateNoDirectory
  deriving (Eq)

data CrateStageFailure = CrateStageFailure
  { csfFile :: FilePath,
    csfKind :: CrateStageKind,
    csfStderr :: Text
  }

stagingHardFail ::
  FilePath ->
  [CrateStageFailure] ->
  (Text -> Text) ->
  IO (Either Text ())
stagingHardFail unitDir records summary = do
  let logPath = unitDir </> "crate-staging.log"
  absLog <- makeAbsolute logPath
  written <-
    try @IOException $
      TIO.writeFile absLog (renderCrateStagingLog records)
  pure (Left (summary (stagingLogNote absLog written)))

stagingLogNote :: FilePath -> Either IOException () -> Text
stagingLogNote absLog written =
  case written of
    Right () -> "see " <> T.pack absLog
    Left ex -> T.pack absLog <> " was not written: " <> T.pack (show ex)

missingSummary :: FilePath -> Int -> CrateStageFailure -> Text -> Text
missingSummary distDir n first note =
  "cargo crates pack failed: "
    <> T.pack (show n)
    <> " registry "
    <> crateWord n
    <> " missing from distdir "
    <> T.pack distDir
    <> "; first: "
    <> T.pack (csfFile first)
    <> "; "
    <> note

stageSummary :: Int -> CrateStageFailure -> Text -> Text
stageSummary n first note =
  let detail = case csfKind first of
        CrateExtract ->
          case firstStderrLine (csfStderr first) of
            Just line -> ": " <> line
            Nothing -> ""
        _ -> ""
   in "cargo crates pack failed: "
        <> T.pack (show n)
        <> " "
        <> crateWord n
        <> " failed to stage; first: "
        <> T.pack (csfFile first)
        <> detail
        <> "; "
        <> note

crateWord :: Int -> Text
crateWord 1 = "crate"
crateWord _ = "crates"

firstStderrLine :: Text -> Maybe Text
firstStderrLine body =
  case T.lines body of
    (line : _) | not (T.null line) -> Just line
    _ -> Nothing

invocationFailure :: Int -> String -> Text
invocationFailure code err =
  "cargo crates pack failed: crate extraction invocation exited "
    <> T.pack (show code)
    <> ": "
    <> T.strip (T.pack err)

renderCrateStagingLog :: [CrateStageFailure] -> Text
renderCrateStagingLog records =
  T.intercalate "\n" (map renderBlock records) <> "\n"
  where
    renderBlock record =
      T.pack (csfFile record)
        <> ": "
        <> kindLabel (csfKind record)
        <> stderrBlock record
    kindLabel CrateMissing = "missing"
    kindLabel CrateExtract = "extract"
    kindLabel CrateNoDirectory = "no directory"
    stderrBlock record
      | csfKind record == CrateExtract =
          case T.lines (csfStderr record) of
            [] -> ""
            lines_ ->
              "\n" <> T.intercalate "\n" ["    " <> line | line <- lines_]
      | otherwise = ""

createArchiveAtomic :: Int -> PackSlot -> CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
createArchiveAtomic threads slot run stageDir =
  packTarXzAtomic
    run
    slot
    threads
    "cargo crates pack failed"
    Nothing
    (Just stageDir)
    ["cargo_home"]

gitCloneTag :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag run url tag dest =
  gitCloneWithArgs
    run
    [ "--depth",
      "1",
      "--branch",
      T.unpack tag,
      T.unpack url,
      dest
    ]

-- | Shallow clone of @url@ at @tag@ with recursive submodules (rusty_v8).
gitCloneRecursiveSubmodules ::
  CommandRunner ->
  Text ->
  Text ->
  FilePath ->
  IO (Either Text ())
gitCloneRecursiveSubmodules run url tag dest =
  gitCloneWithArgs
    run
    [ "--recurse-submodules",
      "--depth",
      "1",
      "--branch",
      T.unpack tag,
      T.unpack url,
      dest
    ]

gitCloneWithArgs :: CommandRunner -> [String] -> IO (Either Text ())
gitCloneWithArgs run args = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "git" ("clone" : args),
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("git clone failed: " <> T.pack (prStderr res))

packRustyV8Tree :: Int -> PackSlot -> CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
packRustyV8Tree threads slot run src =
  packTarXzAtomic
    run
    slot
    threads
    "rusty_v8 snapshot pack failed"
    Nothing
    (Just src)
    ["."]

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
          prStdin = "",
          prMeasure = Timed
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
              prStdin = "",
              prMeasure = Timed
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
