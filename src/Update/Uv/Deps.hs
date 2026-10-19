{-# LANGUAGE OverloadedStrings #-}

-- | Uv deps tarball materialize inside the full-path container.
--
-- Closure authority is @uv sync --frozen@. The packer does not run @uv lock@.
-- Sdists land at @sdists/\<file\>@. A Rust sdist with no @vendor/@ is vendored
-- and the generated @.cargo/config.toml@ is repacked into that sdist.
module Update.Uv.Deps
  ( UvDepsOps (..),
    UvDepsProgress (..),
    productionUvDepsOps,
    mkUvDepsOps,
    buildUvDepsTarball,
    productionProbeUvSync,
    planBackendSdists,
    backendSdistUrl,
  )
where

import Control.Exception (IOException, try)
import Data.List (find, sort)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removePathForcibly,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import Update.DiskSpace
  ( MaterializeClass (FullUv),
    checkPostCloneForClass,
  )
import Update.Go.Vendor (githubCloneUrl)
import Update.Pack.XzTar (packTarXz)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Process.Docker (secretMaterializeEnvKeys)
import Update.Uv.Lock
  ( UvLock (..),
    UvPackage (..),
    UvSource (..),
    parseUvLock,
  )
import Update.Uv.Pack
  ( SdistPack (..),
    buildRequiresOf,
    classifyPyprojectBuild,
    frozenUvSyncArgs,
    frozenUvSyncEnv,
    packSdists,
    parseDryRunSdists,
    setuptoolsFallbackRequires,
  )
import Update.Uv.Python (ProbeStep (..), classifyPythonFind, probeOrdered)

-- | Injectable container ops for Uv deps materialize.
data UvDepsOps = UvDepsOps
  { udoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    udoSync :: FilePath -> Text -> IO (Either Text ()),
    udoFreeze :: FilePath -> IO (Either Text [Text]),
    udoReadFile :: FilePath -> IO (Either Text Text),
    udoDownload :: Text -> FilePath -> IO (Either Text ()),
    udoUnpack :: FilePath -> FilePath -> IO (Either Text ()),
    udoCargoVendor :: FilePath -> IO (Either Text Text),
    udoRepackSdist :: FilePath -> FilePath -> IO (Either Text ()),
    udoPack :: FilePath -> FilePath -> IO (Either Text ()),
    udoHasVendor :: FilePath -> IO Bool,
    udoHasCargoToml :: FilePath -> IO Bool,
    -- | Resolve one build-system requirement list to sdist files.
    -- The 'FilePath' is the unit work directory the container bind-mounts.
    udoPlanBackendSdists ::
      Text ->
      [Text] ->
      FilePath ->
      IO (Either Text [(Text, Text, Text)]),
    -- | PyPI sdist URL for @name==version@, using the slot interpreter.
    -- The script is written under the unit work directory.
    udoBackendSdistUrl ::
      Text ->
      Text ->
      Text ->
      FilePath ->
      IO (Either Text Text),
    -- | Top-level @pyproject.toml@, or @Nothing@ when the sdist has none.
    udoReadSdistPyproject :: FilePath -> IO (Either Text (Maybe Text))
  }

-- | Clone and pack mark the shared materialize counter. Sync stays inside
-- the pack phase so the 7-step budget matches the other ecosystems.
data UvDepsProgress = UvDepsProgress
  { udpOnCloneStart :: IO (),
    udpOnCloneDone :: IO (),
    udpOnPackStart :: IO (),
    udpOnPackDone :: IO ()
  }

mkUvDepsOps :: CommandRunner -> UvDepsOps
mkUvDepsOps run =
  UvDepsOps
    { udoClone = gitCloneTag run,
      udoSync = uvSync run,
      udoFreeze = uvFreeze run,
      udoReadFile = readLockFile,
      udoDownload = downloadFile run,
      udoUnpack = unpackArchive run,
      udoCargoVendor = cargoVendor run,
      udoRepackSdist = repackSdist run,
      udoPack = packStage run,
      udoHasVendor = \dir -> doesDirectoryExist (dir </> "vendor"),
      udoHasCargoToml = \dir -> doesFileExist (dir </> "Cargo.toml"),
      udoPlanBackendSdists = planBackendSdists run,
      udoBackendSdistUrl = backendSdistUrl run,
      udoReadSdistPyproject = readSdistPyproject run
    }

productionUvDepsOps :: UvDepsOps
productionUvDepsOps = mkUvDepsOps productionCommandRunner

-- | Clone the raw tag, sync the frozen lock, and pack @sdists/@.
buildUvDepsTarball ::
  UvDepsOps ->
  UvDepsProgress ->
  Text ->
  Text ->
  -- | Raw git tag (not @v${PV}@).
  Text ->
  Maybe FilePath ->
  -- | Python slot passed to @uv --python@.
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildUvDepsTarball ops progress owner repo tag mSub slot workDir outDir tarballName = do
  createDirectoryIfMissing True outDir
  createDirectoryIfMissing True workDir
  let url = githubCloneUrl owner repo
      outPath = outDir </> tarballName
      cloneDir = workDir </> "src"
      stageDir = workDir </> "stage"
      projectDir = case mSub of
        Nothing -> cloneDir
        Just sub -> cloneDir </> sub
      lockPath = projectDir </> "uv.lock"
  udpOnCloneStart progress
  cloned <- udoClone ops url tag cloneDir
  case cloned of
    Left err -> pure (Left err)
    Right () -> do
      udpOnCloneDone progress
      spaceOk <- checkPostCloneForClass FullUv cloneDir
      case spaceOk of
        Left err -> pure (Left err)
        Right () -> do
          bodyE <- udoReadFile ops lockPath
          case bodyE of
            Left err -> pure (Left err)
            Right body ->
              case parseUvLock body of
                Left err -> pure (Left err)
                Right lock -> do
                  synced <- udoSync ops projectDir slot
                  case synced of
                    Left err -> pure (Left err)
                    Right () -> do
                      namesE <- udoFreeze ops projectDir
                      case namesE of
                        Left err -> pure (Left err)
                        Right names -> do
                          udpOnPackStart progress
                          packed <- packResolved ops slot lock names stageDir workDir
                          case packed of
                            Left err -> pure (Left err)
                            Right () -> do
                              tarred <- udoPack ops stageDir outPath
                              case tarred of
                                Left err -> pure (Left err)
                                Right () -> do
                                  udpOnPackDone progress
                                  hasTar <- doesFileExist outPath
                                  pure $
                                    if hasTar
                                      then Right outPath
                                      else
                                        Left
                                          ( "Uv deps pack did not produce tarball at "
                                              <> T.pack outPath
                                          )

packResolved ::
  UvDepsOps ->
  Text ->
  UvLock ->
  [Text] ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
packResolved ops slot lock names stageDir workDir = do
  let resolved = Set.fromList (map normalizeName names)
      editable = namesOf isEditable lock
      gitNames =
        namesOf isGit lock
          `Set.intersection` resolved
          `Set.difference` namesWithSdist lock
      pathNames =
        namesOf isPath lock
          `Set.intersection` resolved
          `Set.difference` namesWithSdist lock
      sdistNames =
        resolved
          `Set.difference` editable
          `Set.difference` gitNames
          `Set.difference` pathNames
  if not (Set.null pathNames)
    then
      pure
        ( Left
            ( "selected path dependency has no sdist: "
                <> T.intercalate ", " (Set.toList pathNames)
            )
        )
    else case packSdists lock sdistNames Set.empty of
      Left err -> pure (Left err)
      Right planned -> do
        createDirectoryIfMissing True (stageDir </> "sdists")
        sdistOk <- packEach ops planned stageDir workDir
        case sdistOk of
          Left err -> pure (Left err)
          Right () -> do
            expanded <- expandBuildBackends ops slot stageDir workDir
            case expanded of
              Left err -> pure (Left err)
              Right () -> packGit ops lock gitNames stageDir

packEach :: UvDepsOps -> [SdistPack] -> FilePath -> FilePath -> IO (Either Text ())
packEach ops planned stageDir workDir = go planned
  where
    go [] = pure (Right ())
    go (item : rest) = do
      let dest = stageDir </> spRelativePath item
          unpackDir = workDir </> ("unpack-" <> T.unpack (spName item))
      createDirectoryIfMissing True (takeDirectory dest)
      got <- udoDownload ops (spUrl item) dest
      case got of
        Left err -> pure (Left err)
        Right () -> do
          removePathForcibly unpackDir
          createDirectoryIfMissing True unpackDir
          unpacked <- udoUnpack ops dest unpackDir
          case unpacked of
            Left err -> pure (Left err)
            Right () -> do
              top <- unpackTop unpackDir
              hasCargo <- udoHasCargoToml ops top
              hasVendor <- udoHasVendor ops top
              vendored <-
                if hasCargo && not hasVendor
                  then vendorOne ops top dest
                  else pure (Right ())
              removePathForcibly unpackDir
              case vendored of
                Left err -> pure (Left err)
                Right () -> go rest

vendorOne :: UvDepsOps -> FilePath -> FilePath -> IO (Either Text ())
vendorOne ops top dest = do
  cfg <- udoCargoVendor ops top
  case cfg of
    Left err -> pure (Left err)
    Right body -> do
      createDirectoryIfMissing True (top </> ".cargo")
      TIO.writeFile (top </> ".cargo" </> "config.toml") body
      udoRepackSdist ops top dest

-- | Download PEP 517 build backends until no new sdist appears.
-- Each distinct requirement list is resolved on its own. Eight rounds is
-- the bound; a round with no new sdist is success.
expandBuildBackends ::
  UvDepsOps ->
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text ())
expandBuildBackends ops slot stageDir workDir = go (1 :: Int) Set.empty
  where
    sdistsDir = stageDir </> "sdists"
    go roundNo scanned
      | roundNo > 8 = pure (Left "build-backend closure did not settle")
      | otherwise = do
          names <- listDirectory sdistsDir
          let fresh =
                sort
                  [ name
                  | name <- names,
                    ".tar.gz" `T.isSuffixOf` T.pack name,
                    Set.notMember name scanned
                  ]
          if null fresh
            then pure (Right ())
            else do
              setsE <- requirementSets ops sdistsDir fresh
              case setsE of
                Left err -> pure (Left err)
                Right sets -> do
                  fetched <- fetchSets ops slot sdistsDir workDir sets
                  case fetched of
                    Left err -> pure (Left err)
                    Right () -> go (roundNo + 1) (scanned <> Set.fromList fresh)

requirementSets ::
  UvDepsOps ->
  FilePath ->
  [FilePath] ->
  IO (Either Text [[Text]])
requirementSets ops dir files = do
  listsE <- mapM (requirementList ops dir) files
  pure $
    case sequence listsE of
      Left err -> Left err
      Right lists ->
        Right
          ( Set.toList
              (Set.fromList [sort reqs | reqs <- lists, not (null reqs)])
          )

requirementList :: UvDepsOps -> FilePath -> FilePath -> IO (Either Text [Text])
requirementList ops dir file = do
  bodyE <- udoReadSdistPyproject ops (dir </> file)
  pure $
    case bodyE of
      Left err -> Left err
      Right Nothing -> Right setuptoolsFallbackRequires
      Right (Just body) ->
        case classifyPyprojectBuild body of
          Left err -> Left (T.pack file <> ": " <> err)
          Right build -> Right (buildRequiresOf build)

fetchSets ::
  UvDepsOps ->
  Text ->
  FilePath ->
  FilePath ->
  [[Text]] ->
  IO (Either Text ())
fetchSets _ _ _ _ [] = pure (Right ())
fetchSets ops slot dir work (reqs : rest) = do
  plannedE <- udoPlanBackendSdists ops slot reqs work
  case plannedE of
    Left err -> pure (Left err)
    Right planned -> do
      results <- mapM (fetchBackend ops slot dir work) planned
      case sequence results of
        Left err -> pure (Left err)
        Right _ -> fetchSets ops slot dir work rest

fetchBackend ::
  UvDepsOps ->
  Text ->
  FilePath ->
  FilePath ->
  (Text, Text, Text) ->
  IO (Either Text ())
fetchBackend ops slot dir work (distName, version, filename) = do
  let dest = dir </> takeFileName (T.unpack filename)
  exists <- doesFileExist dest
  if exists
    then pure (Right ())
    else do
      urlE <- udoBackendSdistUrl ops slot distName version work
      case urlE of
        Left err -> pure (Left err)
        Right url -> do
          got <- udoDownload ops url dest
          case got of
            Left err -> pure (Left err)
            Right () -> vendorFetched ops dest work

vendorFetched :: UvDepsOps -> FilePath -> FilePath -> IO (Either Text ())
vendorFetched ops dest workDir = do
  let unpackDir = workDir </> ("unpack-" <> takeFileName dest)
  removePathForcibly unpackDir
  createDirectoryIfMissing True unpackDir
  unpacked <- udoUnpack ops dest unpackDir
  case unpacked of
    Left err -> pure (Left err)
    Right () -> do
      top <- unpackTop unpackDir
      hasCargo <- udoHasCargoToml ops top
      hasVendor <- udoHasVendor ops top
      vendored <-
        if hasCargo && not hasVendor
          then vendorOne ops top dest
          else pure (Right ())
      removePathForcibly unpackDir
      pure vendored

-- | Dry-run one requirement list inside @workDir@.
--
-- Materialize runs this through @docker exec@. The container bind-mounts the
-- unit work directory and does not see a host-only temporary directory, so
-- the requirements file and the venv are created under @workDir@.
planBackendSdists ::
  CommandRunner ->
  Text ->
  [Text] ->
  FilePath ->
  IO (Either Text [(Text, Text, Text)])
planBackendSdists _ _ [] _ = pure (Right [])
planBackendSdists run slot reqs workDir =
  withTempDirectory workDir "uv-backend-plan-" $ \tmp -> do
    let reqPath = tmp </> "requirements.txt"
        venv = tmp </> "venv"
        python = "/usr/bin/python" <> T.unpack slot
    TIO.writeFile reqPath (T.unlines reqs)
    env <- plannerEnv
    made <-
      runChecked
        run
        "uv venv failed"
        ProcessRequest
          { prMode = ExecCmd "uv" ["venv", "--python", python, venv],
            prCwd = Nothing,
            prEnv = Just env,
            prStdin = ""
          }
    case made of
      Left err -> pure (Left err)
      Right () -> do
        res <-
          run
            ProcessRequest
              { prMode =
                  ExecCmd
                    "uv"
                    [ "pip",
                      "install",
                      "--python",
                      venv </> "bin" </> "python",
                      "--dry-run",
                      "--no-binary",
                      ":all:",
                      "--no-progress",
                      "-v",
                      "-r",
                      reqPath
                    ],
                prCwd = Nothing,
                prEnv = Just env,
                prStdin = ""
              }
        let logged = T.pack (prStdout res) <> "\n" <> T.pack (prStderr res)
        pure $
          if prExitCode res /= ExitSuccess
            then Left ("uv backend dry-run failed: " <> T.strip (T.pack (prStderr res)))
            else parseDryRunSdists logged

-- | Look up one sdist URL. The helper script is written under @workDir@ so
-- the materialize container can read it.
backendSdistUrl ::
  CommandRunner ->
  Text ->
  Text ->
  Text ->
  FilePath ->
  IO (Either Text Text)
backendSdistUrl run slot name version workDir =
  withTempDirectory workDir "uv-sdist-url-" $ \tmp -> do
    let script = tmp </> "sdist_url.py"
        python = "/usr/bin/python" <> T.unpack slot
    TIO.writeFile script pypiSdistUrlPy
    env <- plannerEnv
    res <-
      run
        ProcessRequest
          { prMode = ExecCmd python [script, T.unpack name, T.unpack version],
            prCwd = Nothing,
            prEnv = Just env,
            prStdin = ""
          }
    pure $
      if prExitCode res /= ExitSuccess
        then Left ("pypi sdist lookup failed: " <> T.strip (T.pack (prStderr res)))
        else case T.lines (T.strip (T.pack (prStdout res))) of
          [url] | "https://" `T.isPrefixOf` url -> Right url
          _ -> Left "pypi sdist lookup did not print a URL"

pypiSdistUrlPy :: Text
pypiSdistUrlPy =
  T.unlines
    [ "import json, urllib.request, sys",
      "name, version = sys.argv[1], sys.argv[2]",
      "api = \"https://pypi.org/pypi/%s/%s/json\" % (name, version)",
      "with urllib.request.urlopen(api, timeout=60) as response:",
      "    meta = json.load(response)",
      "for item in meta[\"urls\"]:",
      "    if item[\"packagetype\"] == \"sdist\":",
      "        print(item[\"url\"])",
      "        raise SystemExit(0)",
      "sys.stderr.write(\"no sdist on PyPI for %s==%s\\n\" % (name, version))",
      "raise SystemExit(1)"
    ]

readSdistPyproject :: CommandRunner -> FilePath -> IO (Either Text (Maybe Text))
readSdistPyproject run archive = do
  listed <- runCapture run "sdist list failed" "tar" ["-tzf", archive]
  case listed of
    Left err -> pure (Left err)
    Right body ->
      case topPyproject body of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right Nothing)
        Right (Just member) ->
          fmap Just <$> runCapture run "sdist pyproject read failed" "tar" ["-xOf", archive, T.unpack member]

topPyproject :: Text -> Either Text (Maybe Text)
topPyproject listing =
  case [member | member <- T.lines listing, isTopPyproject member] of
    [] -> Right Nothing
    [member] -> Right (Just member)
    _ -> Left "sdist has multiple top-level pyproject.toml files"

isTopPyproject :: Text -> Bool
isTopPyproject name =
  let cleaned =
        case T.stripPrefix "./" (T.strip name) of
          Just rest -> rest
          Nothing -> T.strip name
   in T.count "/" cleaned == 1 && "/pyproject.toml" `T.isSuffixOf` cleaned

plannerEnv :: IO [(String, String)]
plannerEnv = do
  env0 <- getEnvironment
  pure $
    ("UV_PYTHON_DOWNLOADS", "never")
      : filter
        ( \(key, _) ->
            key /= "UV_PYTHON_DOWNLOADS"
              && key /= "UV_OFFLINE"
              && key /= "CARGO_NET_OFFLINE"
              && key `notElem` secretMaterializeEnvKeys
        )
        env0

runCapture :: CommandRunner -> Text -> String -> [String] -> IO (Either Text Text)
runCapture run prefix cmd args = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd cmd args,
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right (T.pack (prStdout res))
      else Left (prefix <> ": " <> T.strip (T.pack (prStderr res)))

packGit :: UvDepsOps -> UvLock -> Set Text -> FilePath -> IO (Either Text ())
packGit _ _ gitNames _
  | Set.null gitNames = pure (Right ())
packGit ops lock gitNames stageDir = go (Set.toList gitNames)
  where
    go [] = pure (Right ())
    go (name : rest) =
      case find (\pkg -> normalizeName (upName pkg) == name) (ulPackages lock) of
        Nothing -> pure (Left ("uv.lock has no distribution named " <> name))
        Just pkg ->
          case upSource pkg of
            UvGit url rev -> do
              let dest = stageDir </> "git" </> T.unpack name
              createDirectoryIfMissing True (takeDirectory dest)
              cloned <- udoClone ops url rev dest
              case cloned of
                Left err -> pure (Left err)
                Right () -> go rest
            _ -> pure (Left ("selected git dependency has no git source: " <> name))

namesOf :: (UvPackage -> Bool) -> UvLock -> Set Text
namesOf keep lock =
  Set.fromList [normalizeName (upName pkg) | pkg <- ulPackages lock, keep pkg]

namesWithSdist :: UvLock -> Set Text
namesWithSdist lock =
  Set.fromList
    [ normalizeName (upName pkg)
    | pkg <- ulPackages lock,
      Just _ <- [upSdist pkg]
    ]

isEditable :: UvPackage -> Bool
isEditable pkg = case upSource pkg of
  UvEditable _ -> True
  _ -> False

isGit :: UvPackage -> Bool
isGit pkg = case upSource pkg of
  UvGit _ _ -> True
  _ -> False

isPath :: UvPackage -> Bool
isPath pkg = case upSource pkg of
  UvPath _ -> True
  _ -> False

normalizeName :: Text -> Text
normalizeName = T.toLower . T.replace "_" "-"

unpackTop :: FilePath -> IO FilePath
unpackTop dest = do
  kids <- listDirectory dest
  case kids of
    [name] -> do
      let path = dest </> name
      isDir <- doesDirectoryExist path
      pure (if isDir then path else dest)
    _ -> pure dest

gitCloneTag :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag run url tag dest = do
  removePathForcibly dest
  runChecked
    run
    "git clone failed"
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

uvSync :: CommandRunner -> FilePath -> Text -> IO (Either Text ())
uvSync run projectDir slot = do
  env0 <- getEnvironment
  let env =
        frozenUvSyncEnv
          ++ filter (\(key, _) -> key /= "UV_PYTHON_DOWNLOADS") env0
  runChecked
    run
    "uv sync --frozen failed"
    ProcessRequest
      { prMode = ExecCmd "uv" (map T.unpack (frozenUvSyncArgs slot)),
        prCwd = Just projectDir,
        prEnv = Just env,
        prStdin = ""
      }

uvFreeze :: CommandRunner -> FilePath -> IO (Either Text [Text])
uvFreeze run projectDir = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "uv" ["pip", "freeze"],
          prCwd = Just projectDir,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then Left ("uv pip freeze failed: " <> T.pack (prStderr res))
      else Right (freezeNames (T.pack (prStdout res)))

freezeNames :: Text -> [Text]
freezeNames body =
  [ name
  | line <- T.lines body,
    let stripped = T.strip line,
    not (T.null stripped),
    not (T.isPrefixOf "-e " stripped),
    let name = T.takeWhile (/= '=') stripped,
    not (T.null name)
  ]

readLockFile :: FilePath -> IO (Either Text Text)
readLockFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("uv.lock is missing: " <> T.pack path))
    else Right <$> TIO.readFile path

downloadFile :: CommandRunner -> Text -> FilePath -> IO (Either Text ())
downloadFile run url dest =
  runChecked
    run
    "sdist download failed"
    ProcessRequest
      { prMode = ExecCmd "wget" ["-O", dest, T.unpack url],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

unpackArchive :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
unpackArchive run archive dest =
  runChecked
    run
    "sdist unpack failed"
    ProcessRequest
      { prMode = ExecCmd "tar" ["-xzf", archive, "-C", dest],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

cargoVendor :: CommandRunner -> FilePath -> IO (Either Text Text)
cargoVendor run dir = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "cargo" ["vendor"],
          prCwd = Just dir,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then Left ("cargo vendor failed: " <> T.pack (prStderr res))
      else Right (T.pack (prStdout res))

repackSdist :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
repackSdist run srcDir dest =
  runChecked
    run
    "sdist repack failed"
    ProcessRequest
      { prMode =
          ExecCmd
            "tar"
            [ "-czf",
              dest,
              "-C",
              takeDirectory srcDir,
              takeFileName srcDir
            ],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

packStage :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
packStage run stageDir outPath = do
  hasGit <- doesDirectoryExist (stageDir </> "git")
  let entries = "sdists" : ["git" | hasGit]
  packTarXz run "tar pack failed" Nothing (Just stageDir) entries outPath

-- | Clone one tag and sync slots in probe order. Stops at the first success.
-- A missing interpreter is 'Left'. A non-zero sync rejects that slot.
productionProbeUvSync ::
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  [Text] ->
  IO (Either Text (Set Text))
productionProbeUvSync owner repo tag mSub slots
  | null slots = pure (Right Set.empty)
  | otherwise =
      withSystemTempDirectory "uv-probe-" $ \tmp -> do
        let dest = tmp </> "src"
            url = githubCloneUrl owner repo
        cloned <- gitCloneTag productionCommandRunner url tag dest
        case cloned of
          Left err -> pure (Left err)
          Right () -> do
            let project = case mSub of
                  Nothing -> dest
                  Just sub -> dest </> sub
            exists <- doesDirectoryExist project
            if not exists
              then
                pure (Left ("uv project directory is missing: " <> T.pack project))
              else probeOrdered (probeSlot productionCommandRunner project) slots

probeSlot :: CommandRunner -> FilePath -> Text -> IO ProbeStep
probeSlot run project slot = do
  found <- pythonFind run slot
  case found of
    Left msg -> pure (ProbeHardFail msg)
    Right () -> do
      synced <- uvSyncExit run project slot
      pure $ case synced of
        Left msg -> ProbeHardFail msg
        Right True -> ProbeOk
        Right False -> ProbeReject

pythonFind :: CommandRunner -> Text -> IO (Either Text ())
pythonFind run slot = do
  env <- uvProbeEnv
  eres <-
    try @IOException $
      run
        ProcessRequest
          { prMode = ExecCmd "uv" ["python", "find", T.unpack slot],
            prCwd = Nothing,
            prEnv = Just env,
            prStdin = ""
          }
  pure $ case eres of
    Left _ -> Left "uv is not installed"
    Right res ->
      classifyPythonFind
        slot
        (prExitCode res)
        (T.pack (prStdout res))
        (T.pack (prStderr res))

uvSyncExit :: CommandRunner -> FilePath -> Text -> IO (Either Text Bool)
uvSyncExit run project slot = do
  env <- uvProbeEnv
  eres <-
    try @IOException $
      run
        ProcessRequest
          { prMode = ExecCmd "uv" (map T.unpack (frozenUvSyncArgs slot)),
            prCwd = Just project,
            prEnv = Just env,
            prStdin = ""
          }
  pure $ case eres of
    Left _ -> Left "uv is not installed"
    Right res -> Right (prExitCode res == ExitSuccess)

uvProbeEnv :: IO [(String, String)]
uvProbeEnv = do
  env0 <- getEnvironment
  pure $
    frozenUvSyncEnv
      ++ filter
        ( \(key, _) ->
            key /= "UV_PYTHON_DOWNLOADS" && key `notElem` secretMaterializeEnvKeys
        )
        env0

runChecked :: CommandRunner -> Text -> ProcessRequest -> IO (Either Text ())
runChecked run prefix req = do
  res <- run req
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( prefix
              <> ": "
              <> T.strip (T.pack (prStderr res))
          )
