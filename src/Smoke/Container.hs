{-# LANGUAGE OverloadedStrings #-}

-- | The container of one smoke run: create and remove, Portage
-- configuration and the check user, the sandbox probe, the emerge steps,
-- network attach and detach, and the checks.
--
-- Every Docker call goes through the injected 'CommandRunner'.
module Smoke.Container
  ( -- * Configuration
    SmokeContainerCfg (..),
    smokeBinpkgsVolume,
    smokeDistfilesVolume,
    smokeDistDir,
    checkUser,
    checkHome,
    checkUidFor,
    smokeContainerName,
    smokeCreateArgs,

    -- * Portage configuration
    portageConfigFiles,
    makeConfLines,
    setupScript,

    -- * Sandbox probe
    sandboxProbeArgs,
    sandboxProbeMessage,
    runSandboxProbe,

    -- * Emerge steps
    dependenciesArgv,
    packageArgv,
    extrasArgv,

    -- * Session
    ExecUser (..),
    SmokeSession (..),
    smokeExecArgs,
    withSmokeContainer,

    -- * One run
    FailStage (..),
    RunResult (..),
    RunOutcome (..),
    renderFailStage,
    runLogDir,
    performRun,
  )
where

import Control.Exception (finally)
import Control.Monad (void, when)
import Data.Aeson ((.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Metrics.Container (CgroupRoots)
import Metrics.Core (Metrics (..), withSpan)
import Metrics.Process (timeWrapArgs)
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Version (renderPVNoRev)
import Smoke.Check
  ( CheckCtx (..),
    CheckIO (..),
    CheckResult (..),
    Command (..),
    Outcome (..),
    SmokeDef (..),
    failedCheckNames,
    runChecks,
  )
import Smoke.CompileCache
  ( CacheReport,
    CacheUse (..),
    GoChecks,
    TrimCheck,
    cacheMakeConfLines,
    cacheSetupLines,
    ccacheConf,
    ccacheConfPath,
    claimGoCheck,
    compileCacheMount,
    confcacheMarkerScript,
    configureCacheNote,
    goTrimCheckScript,
    goVersionScript,
    parseReport,
    parseTrimCheck,
    portageBashrc,
    reportScript,
  )
import Smoke.Plan
  ( RuntimeCap (..),
    SmokeRun (..),
    runtimeCapPackages,
  )
import Smoke.Tree (dockerSafe, shellQuote)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker
  ( materializePidLabelKey,
    materializeProductLabel,
    materializeRunLabelKey,
    measuredContainerExec,
    registerContainerCgroup,
    snapshotContainer,
    waitUntilRunning,
  )
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Types (PackageKey)

data SmokeContainerCfg = SmokeContainerCfg
  { sccRunId :: String,
    sccCliPid :: String,
    -- | Smoke image tag.
    sccImage :: String,
    -- | Tree snapshot image tag.
    sccSnapshot :: String,
    -- | Absolute effective overlay path.
    sccOverlay :: FilePath,
    -- | Run metrics @time/@ directory when recording.
    sccTimeDir :: Maybe FilePath,
    -- | Operator uid (the check user's uid, unless 0).
    sccOperatorUid :: Int,
    -- | Resolved @--jobs@.
    sccJobs :: Int,
    -- | Every overlay @category/package@, excluded from binary packages.
    sccOverlayNames :: [Text],
    -- | Compile cache use for this command's runs.
    sccCache :: CacheUse
  }
  deriving (Eq, Show)

smokeBinpkgsVolume :: String
smokeBinpkgsVolume = "mndz-smoke-binpkgs"

smokeDistfilesVolume :: String
smokeDistfilesVolume = "mndz-smoke-distfiles"

-- | Empty, container-local @DISTDIR@ of the package step.
smokeDistDir :: FilePath
smokeDistDir = "/var/tmp/smoke-distfiles"

checkUser :: String
checkUser = "smoke"

checkHome :: FilePath
checkHome = "/home/smoke"

-- | The operator's uid, or 1000 when the operator is root.
checkUidFor :: Int -> Int
checkUidFor 0 = 1000
checkUidFor uid = uid

-- | @mndz-smoke-\<run-id\>-\<cat\>-\<pn\>-\<pvr\>[-plain|-tilde]@.
smokeContainerName :: SmokeContainerCfg -> SmokeRun -> String
smokeContainerName cfg run =
  dockerSafe ("mndz-smoke-" <> sccRunId cfg <> "-" <> runSlug run)

runSlug :: SmokeRun -> String
runSlug run =
  let e = srEbuild run
   in T.unpack (ebuildCategory e <> "-" <> ebuildPackage e <> "-" <> ebuildVersion e)
        <> maybe "" (("-" <>) . tierSlug . capTier) (srCap run)

tierSlug :: KeywordTier -> String
tierSlug = \case
  Plain -> "plain"
  Tilde -> "tilde"

-- | @docker create@ argv (no @docker@ binary). @SYS_ADMIN@ is the only added
-- capability; no token, GPG, or SSH variable is passed. With the compile
-- cache on, the package's part of the cache volume is mounted.
smokeCreateArgs :: SmokeContainerCfg -> SmokeRun -> [String]
smokeCreateArgs cfg run =
  [ "create",
    "--name",
    smokeContainerName cfg run,
    "--label",
    materializeProductLabel,
    "--label",
    materializeRunLabelKey <> "=" <> sccRunId cfg,
    "--label",
    materializePidLabelKey <> "=" <> sccCliPid cfg,
    "--cap-add",
    "SYS_ADMIN",
    "--mount",
    "type=image,source=" <> sccSnapshot cfg <> ",target=/var/db/repos/gentoo",
    "--mount",
    "type=bind,src=" <> sccOverlay cfg <> ",dst=/var/db/repos/mndz,readonly",
    "--mount",
    "type=volume,src=" <> smokeBinpkgsVolume <> ",dst=/var/cache/binpkgs",
    "--mount",
    "type=volume,src=" <> smokeDistfilesVolume <> ",dst=/var/cache/distfiles"
  ]
    <> concat [["--mount", compileCacheMount (srKey run)] | CacheOn _ <- [sccCache cfg]]
    <> concat [["--mount", "type=bind,src=" <> d <> ",dst=" <> d] | Just d <- [sccTimeDir cfg]]
    <> [sccImage cfg, "sleep", "infinity"]

------------------------------------------------------------------------
-- Portage configuration

-- | Lines appended to @/etc/portage/make.conf@. With the compile cache on,
-- @FEATURES@ gains @ccache@ and the cache settings follow.
makeConfLines :: Int -> CacheUse -> SmokeRun -> [Text]
makeConfLines jobs cache run =
  [ "MAKEOPTS=\"-j" <> tshow jobs <> " -l" <> tshow (jobs + 1) <> "\"",
    "FEATURES=\"getbinpkg buildpkg" <> (case cache of CacheOn _ -> " ccache"; CacheOff -> "") <> "\"",
    "ACCEPT_LICENSE=\"*\""
  ]
    <> case cache of
      CacheOn size -> cacheMakeConfLines size (capTier <$> srCap run)
      CacheOff -> []

-- | Files written under @/etc/portage@ for a run: the @mndz@ repository, the
-- overlay and runtime-cap keyword accepts, the Python slot and definition
-- accepts, the runtime mask above the cap, and the definition's USE lines.
portageConfigFiles :: SmokeRun -> [Text] -> [Text] -> [(FilePath, Text)]
portageConfigFiles run extraAccepts uses =
  [ ( "/etc/portage/repos.conf/mndz.conf",
      T.unlines ["[mndz]", "location = /var/db/repos/mndz", "masters = gentoo", "auto-sync = no"]
    ),
    ("/etc/portage/package.accept_keywords/smoke", T.unlines accepts)
  ]
    <> [("/etc/portage/package.mask/smoke", T.unlines masks) | not (null masks)]
    <> [("/etc/portage/package.use/smoke", T.unlines uses) | not (null uses)]
  where
    kw = "~" <> srArch run
    accepts =
      ["*/*::mndz " <> kw]
        <> [ "<=" <> pkg <> "-" <> renderPVNoRev (capCeiling cap) <> " " <> kw
           | Just cap <- [srCap run],
             pkg <- runtimeCapPackages (capRuntime cap)
           ]
        <> ["dev-lang/python:" <> slot <> " " <> kw | Just slot <- [srPythonSlot run]]
        <> [a <> " " <> kw | a <- extraAccepts]
    masks =
      [ ">" <> pkg <> "-" <> renderPVNoRev (capCeiling cap)
      | Just cap <- [srCap run],
        pkg <- runtimeCapPackages (capRuntime cap)
      ]

-- | Root script: write the configuration, append to @make.conf@, and create
-- the check user with @uid@. With the compile cache on, it also writes the
-- ccache configuration and the bashrc hooks, and marks the cache used.
setupScript :: Int -> Int -> CacheUse -> SmokeRun -> [Text] -> [Text] -> Text
setupScript uid jobs cache run extraAccepts uses =
  T.unlines $
    ["set -eu"]
      <> concatMap writeFile' (portageConfigFiles run extraAccepts uses <> cacheFiles)
      <> ["printf '%s\\n' " <> T.unwords (map q (makeConfLines jobs cache run)) <> " >> /etc/portage/make.conf"]
      <> (case cache of CacheOn _ -> cacheSetupLines; CacheOff -> [])
      <> ["useradd --create-home --uid " <> tshow uid <> " --user-group " <> T.pack checkUser]
  where
    writeFile' (path, body) =
      [ "mkdir -p " <> q (T.pack (takeDirectory path)),
        "printf '%s' " <> q body <> " > " <> q (T.pack path)
      ]
    q = T.pack . shellQuote . T.unpack
    cacheFiles = case cache of
      CacheOn size -> [(T.unpack ccacheConfPath, ccacheConf size), ("/etc/portage/bashrc", portageBashrc)]
      CacheOff -> []

------------------------------------------------------------------------
-- Sandbox probe

-- | @docker run@ argv of the probe: same privileges as a run container.
sandboxProbeArgs :: SmokeContainerCfg -> [String]
sandboxProbeArgs cfg =
  [ "run",
    "--rm",
    "--label",
    materializeProductLabel,
    "--label",
    materializeRunLabelKey <> "=" <> sccRunId cfg,
    "--label",
    materializePidLabelKey <> "=" <> sccCliPid cfg,
    "--cap-add",
    "SYS_ADMIN",
    "--network",
    "none",
    sccImage cfg,
    "sh",
    "-c",
    "unshare --net true && unshare --ipc true && unshare --pid --fork true"
  ]

sandboxProbeMessage :: Text -> Text
sandboxProbeMessage detail =
  "Portage's network, IPC, and PID sandboxes cannot be enforced on this host: \
  \a container with SYS_ADMIN could not create the namespaces ("
    <> detail
    <> ")"

runSandboxProbe :: CommandRunner -> SmokeContainerCfg -> IO (Either Text ())
runSandboxProbe run cfg = do
  res <- run (dockerReq Timed (sandboxProbeArgs cfg) "")
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (sandboxProbeMessage (T.strip (T.pack (prStderr res <> prStdout res))))

------------------------------------------------------------------------
-- Emerge steps

atomFor :: SmokeRun -> String
atomFor run = T.unpack ("=" <> ebuildAtom (srEbuild run) <> "::mndz")

excludeFlags :: [Text] -> [String]
excludeFlags [] = []
excludeFlags names =
  let joined = T.unpack (T.unwords names)
   in ["--usepkg-exclude", joined, "--buildpkg-exclude", joined]

-- | Dependencies of the package under test, binary packages allowed except
-- for overlay packages.
dependenciesArgv :: [Text] -> SmokeRun -> [String]
dependenciesArgv names run =
  ["emerge", "--oneshot", "--onlydeps", "--jobs=1", "--quiet-build=n", "--usepkg"]
    <> excludeFlags names
    <> [atomFor run]

-- | The package under test, from source, no binary package written. Runs
-- with @DISTDIR=@'smokeDistDir'.
packageArgv :: SmokeRun -> [String]
packageArgv run =
  ["emerge", "--oneshot", "--jobs=1", "--quiet-build=n", "--usepkg=n", "--buildpkg=n", atomFor run]

-- | @usermod@ arguments adding the check user to @groups@.
groupsArgs :: [Text] -> [String]
groupsArgs gs = ["--append", "--groups", T.unpack (T.intercalate "," gs), checkUser]

extrasArgv :: [Text] -> [String]
extrasArgv atoms = ["emerge", "--oneshot", "--jobs=1", "--usepkg"] <> map T.unpack atoms

------------------------------------------------------------------------
-- Session

data ExecUser = AsRoot | AsCheckUser
  deriving (Eq, Show)

data SmokeSession = SmokeSession
  { ssName :: String,
    -- | Run a request in the container.
    ssExec :: ExecUser -> ProcessRequest -> IO ProcessResult,
    -- | Attach ('True') to or detach from the default bridge.
    ssNetwork :: Bool -> IO (Either Text ())
  }

-- | @docker exec@ argv for an in-container request. With @innerTime@, the
-- command runs under GNU time writing that @.inner@ file.
smokeExecArgs :: String -> ExecUser -> Maybe FilePath -> ProcessRequest -> [String]
smokeExecArgs name user innerTime req =
  ["exec"]
    <> userFlags
    <> concat [["--env", k <> "=" <> v] | (k, v) <- fromMaybe [] (prEnv req)]
    <> ["-i" | not (null (prStdin req))]
    <> [name]
    <> inner
  where
    userFlags = case user of
      AsRoot -> []
      AsCheckUser -> ["--user", checkUser, "--workdir", checkHome]
    cmdline = case prMode req of
      ExecCmd c as -> c : as
      ShellCmd s -> ["sh", "-c", s]
    inner = case innerTime of
      Nothing -> cmdline
      Just file -> let (t, ts) = timeWrapArgs file cmdline in t : ts

-- | Create and start the run's container, run the continuation, and remove
-- the container on return or exception. When recording, the session is a
-- @container.session@ span and the container's cgroup totals are written as
-- a @container@ event before removal.
withSmokeContainer ::
  Metrics ->
  CgroupRoots ->
  CommandRunner ->
  SmokeContainerCfg ->
  SmokeRun ->
  (SmokeSession -> IO a) ->
  IO (Either Text a)
withSmokeContainer m roots run cfg smokeRun k = do
  let name = smokeContainerName cfg smokeRun
      recording = mEnabled m && isJust (sccTimeDir cfg)
  withSpan m "container.session" ["container" .= name, "image" .= sccImage cfg] $ do
    created <- dockerE Lifecycle run (smokeCreateArgs cfg smokeRun)
    case created of
      Left err -> pure (Left ("could not create smoke container: " <> err))
      Right _ ->
        ( do
            started <- dockerE Timed run ["start", name]
            ready <- either (pure . Left) (const (waitUntilRunning run name)) started
            case ready of
              Left err -> pure (Left ("could not start smoke container: " <> err))
              Right () -> do
                mCgroup <-
                  if recording
                    then registerContainerCgroup m roots run name
                    else pure Nothing
                let session =
                      SmokeSession
                        { ssName = name,
                          ssExec = execIn name,
                          ssNetwork = network name
                        }
                (Right <$> k session) `finally` snapshotContainer m roots name mCgroup
        )
          `finally` dockerE Timed run ["rm", "-f", name]
  where
    execIn name user req =
      case (mEnabled m, sccTimeDir cfg) of
        (True, Just dir) ->
          measuredContainerExec m run name dir (\f -> wrap name user f req) req
        _ -> run (wrap name user Nothing req)
    wrap name user innerTime req =
      ProcessRequest
        { prMode = ExecCmd "docker" (smokeExecArgs name user innerTime req),
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = prStdin req,
          prMeasure = maybe Timed (const TimedContainerExec) innerTime
        }
    network name up =
      void <$> dockerE Timed run ["network", if up then "connect" else "disconnect", "bridge", name]

------------------------------------------------------------------------
-- One run

data FailStage
  = FailDependencies
  | FailBuild
  | -- | Names of the failed checks (or the extra atoms that did not install).
    FailCheck [Text]
  deriving (Eq, Show)

-- | @dependencies@, @build@, or @check <names>@.
renderFailStage :: FailStage -> Text
renderFailStage = \case
  FailDependencies -> "dependencies"
  FailBuild -> "build"
  FailCheck names -> T.unwords ("check" : names)

data RunResult
  = RunPass
  | -- | Stage, a one-line reason, and the log file holding the details.
    RunFail FailStage Text FilePath
  deriving (Eq, Show)

-- | A run's result and, with the compile cache on, its cache statistics.
data RunOutcome = RunOutcome
  { roResult :: RunResult,
    roCache :: Maybe CacheReport
  }
  deriving (Eq, Show)

-- | @\<logs\>/\<cat\>-\<pn\>-\<pvr\>[-plain|-tilde]@.
runLogDir :: FilePath -> SmokeRun -> FilePath
runLogDir logsRoot run = logsRoot </> runSlug run

-- | Configure the container, run the three emerge steps, detach the
-- network, and run the checks. Each step's output goes to its own log file
-- under @logDir@. @progress@ receives the stage name as each begins.
--
-- With the compile cache on, the Go trim check runs after the dependencies
-- step for a Go version not yet checked in this command (its result never
-- changes the run's), a failure in a configure phase that used the
-- configure cache says so, and the run's cache statistics are collected at
-- the end.
performRun ::
  SmokeSession ->
  SmokeContainerCfg ->
  GoChecks ->
  PackageKey ->
  SmokeDef ->
  SmokeRun ->
  FilePath ->
  (Text -> IO ()) ->
  IO RunOutcome
performRun session cfg goChecks key def run logDir progress = do
  createDirectoryIfMissing True logDir
  progress "dependencies"
  setup <-
    step
      "setup"
      AsRoot
      (ExecCmd "sh" ["-s"])
      Nothing
      (T.unpack (setupScript (checkUidFor (sccOperatorUid cfg)) (sccJobs cfg) (sccCache cfg) run (sdAcceptKeywords def) (sdPackageUse def)))
  case setup of
    Left (why, file) -> pure (RunOutcome (RunFail FailDependencies ("container setup failed: " <> why) file) Nothing)
    Right () -> do
      trimRef <- newIORef Nothing
      result <- afterSetup trimRef
      report <- case sccCache cfg of
        CacheOff -> pure Nothing
        CacheOn _ -> do
          res <- rootSh reportScript
          Just . parseReport (T.pack (prStdout res)) <$> readIORef trimRef
      pure (RunOutcome result report)
  where
    afterSetup trimRef = do
      deps <- emerge "dependencies" (dependenciesArgv (sccOverlayNames cfg) run) Nothing
      case deps of
        Left (why, file) -> pure (RunFail FailDependencies why file)
        Right () -> do
          goTrimCheck trimRef
          progress "build"
          pkg <- emerge "build" (packageArgv run) (Just [("DISTDIR", smokeDistDir)])
          case pkg of
            Left (why, file) -> pure (RunFail FailBuild why file)
            Right () -> do
              extras <- case sdExtraAtoms def of
                [] -> pure (Right ())
                atoms -> do
                  progress "extras"
                  r <- emerge "extras" (extrasArgv atoms) Nothing
                  pure (either (\(why, file) -> Left (FailCheck ("install" : atoms), why, file)) Right r)
              groups <- case sdCheckGroups def of
                [] -> pure extras
                gs -> case extras of
                  Left e -> pure (Left e)
                  Right () ->
                    either (\(why, file) -> Left (FailCheck ["groups"], why, file)) Right
                      <$> step "groups" AsRoot (ExecCmd "usermod" (groupsArgs gs)) Nothing ""
              case groups of
                Left (stage, why, file) -> pure (RunFail stage why file)
                Right () -> do
                  detached <- ssNetwork session False
                  case detached of
                    Left err -> do
                      let file = logDir </> "network.log"
                      TIO.writeFile file err
                      pure (RunFail (FailCheck ["network"]) ("could not detach the network: " <> err) file)
                    Right () -> checks
    ctx =
      CheckCtx
        { ccKey = key,
          ccVersion = srVersion run,
          ccPv = renderPVNoRev (srVersion run)
        }
    step label user mode env stdin = do
      let file = logDir </> (label <> ".log")
      res <-
        ssExec
          session
          user
          ProcessRequest {prMode = mode, prCwd = Nothing, prEnv = env, prStdin = stdin, prMeasure = Timed}
      TIO.writeFile file (T.pack (prStdout res) <> T.pack (prStderr res))
      pure $
        if prExitCode res == ExitSuccess
          then Right ()
          else Left (exitText (prExitCode res) <> tailNote res, file)
    emerge label args env = case args of
      c : as -> step label AsRoot (ExecCmd c as) env "" >>= either (fmap Left . configureNote) (pure . Right)
      [] -> pure (Right ())
    rootSh :: Text -> IO ProcessResult
    rootSh script =
      ssExec
        session
        AsRoot
        ProcessRequest {prMode = ExecCmd "sh" ["-c", T.unpack script], prCwd = Nothing, prEnv = Nothing, prStdin = "", prMeasure = Timed}
    -- A failure in a configure phase that loaded a configure cache names it.
    configureNote (why, file) = case sccCache cfg of
      CacheOff -> pure (why, file)
      CacheOn _ -> do
        body <- TIO.readFile file
        if "failed (configure phase)" `T.isInfixOf` body
          then do
            markers <- rootSh (T.pack confcacheMarkerScript)
            pure $
              if T.null (T.strip (T.pack (prStdout markers)))
                then (why, file)
                else (why <> "; " <> configureCacheNote, file)
          else pure (why, file)
    goTrimCheck :: IORef (Maybe (Text, TrimCheck)) -> IO ()
    goTrimCheck ref = case sccCache cfg of
      CacheOff -> pure ()
      CacheOn _ -> do
        found <- rootSh (T.pack goVersionScript)
        let version = T.strip (T.pack (prStdout found))
        when (prExitCode found == ExitSuccess && not (T.null version)) $ do
          first <- claimGoCheck goChecks version
          when first $ do
            progress "go trim check"
            res <-
              ssExec
                session
                AsRoot
                ProcessRequest
                  { prMode = ExecCmd "sh" ["-s"],
                    prCwd = Nothing,
                    prEnv = Just [("TMPDIR", "/var/tmp")],
                    prStdin = T.unpack goTrimCheckScript,
                    prMeasure = Timed
                  }
            TIO.writeFile (logDir </> "go-trim-check.log") (T.pack (prStdout res) <> T.pack (prStderr res))
            writeIORef ref (Just (version, parseTrimCheck (T.pack (prStdout res))))
    checks = do
      results <- runChecks checkIO ctx (sdChecks def)
      mapM_ writeCheckLog results
      pure $ case [r | r@CheckResult {crFailure = Just _} <- results] of
        [] -> RunPass
        failedResults@(first : _) ->
          RunFail
            (FailCheck (failedCheckNames results))
            (T.intercalate "; " [crName r <> ": " <> why | r@CheckResult {crFailure = Just why} <- failedResults])
            (checkLogPath (crName first))
    checkLogPath name = logDir </> ("check-" <> T.unpack name <> ".log")
    writeCheckLog r =
      TIO.writeFile (checkLogPath (crName r)) (crLog r <> maybe "" ("FAILED: " <>) (crFailure r))
    checkIO =
      CheckIO
        { cioExec = \limit cmd -> do
            progress "check"
            res <-
              ssExec
                session
                AsCheckUser
                ProcessRequest
                  { prMode =
                      ExecCmd
                        "timeout"
                        (["--kill-after=5", show limit] <> loginEnvArgv <> map T.unpack (cmdArgv cmd)),
                    prCwd = Nothing,
                    prEnv = if null (cmdEnv cmd) then Nothing else Just [(T.unpack k, T.unpack v) | (k, v) <- cmdEnv cmd],
                    prStdin = T.unpack (cmdStdin cmd),
                    prMeasure = Timed
                  }
            pure
              Outcome
                { oExit = case prExitCode res of
                    ExitSuccess -> 0
                    ExitFailure n -> n,
                  oStdout = T.pack (prStdout res),
                  oStderr = T.pack (prStderr res)
                },
          cioNetwork = ssNetwork session
        }

-- | @docker exec@ does not read @/etc/profile@, so variables a user's login
-- shell gets from @/etc/env.d@ (such as @SBCL_HOME@) would be missing. Each
-- check command runs after sourcing it.
loginEnvArgv :: [String]
loginEnvArgv = ["sh", "-c", ". /etc/profile && exec \"$@\"", "sh"]

exitText :: ExitCode -> Text
exitText = \case
  ExitSuccess -> "exit 0"
  ExitFailure n -> "exit " <> tshow n

-- | Portage's last @ERROR:@ line and the line after it, else the last three
-- non-empty lines of output, without terminal colour codes.
tailNote :: ProcessResult -> Text
tailNote res =
  case (errorLines, reverse ls) of
    (_ : _, _) -> ": " <> T.intercalate " | " errorLines
    ([], []) -> ""
    ([], rs) -> ": " <> T.intercalate " | " (reverse (take 3 rs))
  where
    ls = filter (not . T.null) (map (T.strip . stripAnsi) (T.lines (T.pack (prStdout res <> "\n" <> prStderr res))))
    errorLines = case [rest | rest@(l : _) <- suffixes ls, "ERROR:" `T.isInfixOf` l] of
      [] -> []
      found -> take 2 (last found)
    suffixes xs = case xs of
      [] -> []
      _ : t -> xs : suffixes t

-- | Drop @ESC [ … letter@ sequences.
stripAnsi :: Text -> Text
stripAnsi t = case T.breakOn "\ESC[" t of
  (before, rest)
    | T.null rest -> before
    | otherwise ->
        let afterCsi = T.drop 2 rest
         in before <> stripAnsi (T.drop 1 (T.dropWhile (not . isCsiFinal) afterCsi))
  where
    isCsiFinal c = c >= '@' && c <= '~' && c /= '[' && not (c >= '0' && c <= '?')

dockerReq :: Measure -> [String] -> String -> ProcessRequest
dockerReq measure args stdin =
  ProcessRequest
    { prMode = ExecCmd "docker" args,
      prCwd = Nothing,
      prEnv = Nothing,
      prStdin = stdin,
      prMeasure = measure
    }

dockerE :: Measure -> CommandRunner -> [String] -> IO (Either Text String)
dockerE measure run args = do
  res <- run (dockerReq measure args "")
  pure $
    if prExitCode res == ExitSuccess
      then Right (prStdout res)
      else Left (T.strip (T.pack (prStderr res)))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
