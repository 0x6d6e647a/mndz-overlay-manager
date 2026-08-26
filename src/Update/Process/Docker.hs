{-# LANGUAGE OverloadedStrings #-}

-- | Docker session for full-path DepsAndAssets materialize child processes.
--
-- Production builders keep their @CommandRunner@ bodies; this module creates
-- one container per unit, then prefixes language / @tar@ / @git@ /
-- @pycargoebuild@ invocations with @docker exec@. Unit tests inject a fake
-- inner runner so no live daemon is required.
module Update.Process.Docker
  ( defaultMaterializeImage,
    materializeImageEnvVar,
    materializeBuilderHome,
    secretMaterializeEnvKeys,
    materializeProductLabelKey,
    materializeProductLabel,
    materializeRunLabelKey,
    materializePidLabelKey,
    MaterializeDockerCfg (..),
    MaterializeUnitRef (..),
    resolveMaterializeImage,
    resolveMaterializeDockerCfg,
    materializeSessionName,
    materializeCreateArgs,
    materializeExecArgs,
    wrapMaterializeExecRequest,
    withUnitMaterializeSession,
    sweepStaleMaterializeSessions,
    isLiveOverlayManagerPid,
    inspectMaterializeImage,
    missingImageMessage,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, finally, try)
import Control.Monad (forM_)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, getSymbolicLinkTarget)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.User (getRealGroupID, getRealUserID)
import Text.Read (readMaybe)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.TempWorkspace (UnitDirs (..))

-- | Default image tag used when @MNDZ_MATERIALIZE_IMAGE@ is unset.
defaultMaterializeImage :: String
defaultMaterializeImage = "mndz-overlay-manager/materialize:local"

-- | Environment override for the materialize image tag.
materializeImageEnvVar :: String
materializeImageEnvVar = "MNDZ_MATERIALIZE_IMAGE"

-- | Generic @HOME@ inside the materialize container (not the operator home).
materializeBuilderHome :: FilePath
materializeBuilderHome = "/home/builder"

-- | Host secrets that must never be passed into the materialize container.
secretMaterializeEnvKeys :: [String]
secretMaterializeEnvKeys =
  [ "GITHUB_TOKEN",
    "GH_TOKEN",
    "GNUPGHOME",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID"
  ]

-- | Product label key used to find leftover materialize sessions.
materializeProductLabelKey :: String
materializeProductLabelKey = "mndz.overlay-manager"

-- | @mndz.overlay-manager=1@ filter value for @docker ps@.
materializeProductLabel :: String
materializeProductLabel = materializeProductLabelKey <> "=1"

-- | Label key recording the run id that owns a session.
materializeRunLabelKey :: String
materializeRunLabelKey = "mndz.overlay-manager.run"

-- | Label key recording the host CLI pid that owns a session.
materializePidLabelKey :: String
materializePidLabelKey = "mndz.overlay-manager.pid"

forcedEnvKeys :: [String]
forcedEnvKeys =
  [ "HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "PATH",
    "SBCL_HOME",
    "SBCL_SOURCE_ROOT",
    "npm_config_nodedir",
    "npm_config_python",
    "PYTHON"
  ]

-- | Image + identity for one materialize session (binds come from the unit).
data MaterializeDockerCfg = MaterializeDockerCfg
  { -- | Image tag (@mndz-overlay-manager/materialize:local@ or override).
    mdcImage :: String,
    -- | @uid:gid@ passed to @docker create@/@exec --user@.
    mdcUser :: String,
    -- | Run-id segment used in the container name and run label.
    mdcRunId :: String,
    -- | Host CLI pid recorded on the pid label (not parsed from run-id).
    mdcCliPid :: String
  }
  deriving (Eq, Show)

-- | Category / package / PV used in the session name.
data MaterializeUnitRef = MaterializeUnitRef
  { murCategory :: Text,
    murPackage :: Text,
    murPV :: Text
  }
  deriving (Eq, Show)

resolveMaterializeImage :: IO String
resolveMaterializeImage = do
  m <- lookupEnv materializeImageEnvVar
  pure (fromMaybe defaultMaterializeImage (nonEmpty m))
  where
    nonEmpty (Just s) | not (null s) = Just s
    nonEmpty _ = Nothing

-- | Resolve image, host uid:gid, and this CLI pid for a run.
resolveMaterializeDockerCfg :: String -> IO MaterializeDockerCfg
resolveMaterializeDockerCfg runId = do
  image <- resolveMaterializeImage
  uid <- getRealUserID
  gid <- getRealGroupID
  pid <- getProcessID
  pure
    MaterializeDockerCfg
      { mdcImage = image,
        mdcUser = show uid <> ":" <> show gid,
        mdcRunId = runId,
        mdcCliPid = show pid
      }

-- | @mndz-mat-\<runId\>-\<cat\>-\<pn\>-\<pv\>@ with @/@ replaced by @-@.
materializeSessionName :: MaterializeDockerCfg -> MaterializeUnitRef -> String
materializeSessionName cfg unit =
  sanitizeDockerName $
    "mndz-mat-"
      <> mdcRunId cfg
      <> "-"
      <> T.unpack (murCategory unit)
      <> "-"
      <> T.unpack (murPackage unit)
      <> "-"
      <> T.unpack (murPV unit)

sanitizeDockerName :: String -> String
sanitizeDockerName = map (\c -> if c == '/' then '-' else c)

-- | @docker create@ argv (no @docker@ binary): @--rm@, name, labels, user,
-- forced env, unit @work/@ and @out/@ binds, image, @sleep infinity@.
materializeCreateArgs ::
  MaterializeDockerCfg ->
  MaterializeUnitRef ->
  UnitDirs ->
  [String]
materializeCreateArgs cfg unit dirs =
  [ "create",
    "--rm",
    "--user",
    mdcUser cfg,
    "--name",
    materializeSessionName cfg unit,
    "--label",
    materializeProductLabel,
    "--label",
    materializeRunLabelKey <> "=" <> mdcRunId cfg,
    "--label",
    materializePidLabelKey <> "=" <> mdcCliPid cfg,
    "--env",
    "HOME=" <> materializeBuilderHome,
    "--env",
    "XDG_CONFIG_HOME=" <> materializeBuilderHome <> "/.config",
    "--env",
    "XDG_CACHE_HOME=/tmp/builder-cache",
    "--env",
    "npm_config_nodedir=/usr",
    "--env",
    "npm_config_python=/usr/bin/python3",
    "--env",
    "PYTHON=/usr/bin/python3",
    "--mount",
    bindMount (udWork dirs),
    "--mount",
    bindMount (udOut dirs),
    mdcImage cfg,
    "sleep",
    "infinity"
  ]
  where
    bindMount p = "type=bind,src=" <> p <> ",dst=" <> p

-- | @docker exec@ argv for one builder request.
materializeExecArgs :: MaterializeDockerCfg -> String -> ProcessRequest -> [String]
materializeExecArgs cfg name req =
  ["exec"]
    ++ ["--user", mdcUser cfg]
    ++ workdirFlags
    ++ concatMap envFlag (execEnv req)
    ++ stdinFlags
    ++ [name]
    ++ innerCmd
  where
    workdirFlags = case prCwd req of
      Just d -> ["--workdir", d]
      Nothing -> []
    stdinFlags
      | null (prStdin req) = []
      | otherwise = ["-i"]
    innerCmd = case prMode req of
      ExecCmd cmd args -> cmd : args
      ShellCmd sh -> ["sh", "-c", sh]

-- | Rewrite a host process request into @docker exec … name cmd@.
wrapMaterializeExecRequest ::
  MaterializeDockerCfg ->
  String ->
  ProcessRequest ->
  ProcessRequest
wrapMaterializeExecRequest cfg name req =
  ProcessRequest
    { prMode = ExecCmd "docker" (materializeExecArgs cfg name req),
      prCwd = Nothing,
      prEnv = Nothing,
      prStdin = prStdin req
    }

envFlag :: (String, String) -> [String]
envFlag (k, v) = ["--env", k <> "=" <> v]

execEnv :: ProcessRequest -> [(String, String)]
execEnv req =
  [ (k, v)
  | (k, v) <- fromMaybe [] (prEnv req),
    not (dropKey k)
  ]
  where
    dropKey k =
      k `elem` secretMaterializeEnvKeys
        || k `elem` forcedEnvKeys
        || "SSH_" `isPrefixOf` k

-- | Create/start one unit session, run the continuation with an exec runner,
-- and @docker rm -f@ on success, @Left@, or exception.
--
-- Create/start failure is @Left@ (unit hard-fail). Exec into a session that is
-- not running is a hard-fail; a replacement session is not opened.
withUnitMaterializeSession ::
  CommandRunner ->
  MaterializeDockerCfg ->
  MaterializeUnitRef ->
  UnitDirs ->
  (CommandRunner -> IO (Either Text a)) ->
  IO (Either Text a)
withUnitMaterializeSession inner cfg unit dirs k = do
  let name = materializeSessionName cfg unit
  created <- dockerCreate inner cfg unit dirs
  case created of
    Left err -> pure (Left err)
    Right () ->
      ( do
          started <- dockerStart inner name
          case started of
            Left err -> pure (Left err)
            Right () -> do
              ready <- waitUntilRunning inner name
              case ready of
                Left err -> pure (Left err)
                Right () -> k (sessionExecRunner inner cfg name)
      )
        `finally` dockerRm inner name

sessionExecRunner ::
  CommandRunner ->
  MaterializeDockerCfg ->
  String ->
  CommandRunner
sessionExecRunner inner cfg name req = do
  res <- inner (wrapMaterializeExecRequest cfg name req)
  if prExitCode res == ExitSuccess
    then pure res
    else do
      running <- inspectRunning inner name
      case running of
        Right True -> pure res
        _ ->
          pure
            res
              { prExitCode = ExitFailure 1,
                prStderr = T.unpack deadSessionMessage
              }

deadSessionMessage :: Text
deadSessionMessage = "materialize session is not running"

dockerCreate ::
  CommandRunner ->
  MaterializeDockerCfg ->
  MaterializeUnitRef ->
  UnitDirs ->
  IO (Either Text ())
dockerCreate run cfg unit dirs = do
  res <-
    runDocker
      run
      (materializeCreateArgs cfg unit dirs)
      ""
  pure $
    either
      (Left . ("could not create materialize session: " <>))
      (const (Right ()))
      res

dockerStart :: CommandRunner -> String -> IO (Either Text ())
dockerStart run name = do
  res <- runDocker run ["start", name] ""
  pure $
    either
      (Left . ("could not start materialize session: " <>))
      (const (Right ()))
      res

dockerRm :: CommandRunner -> String -> IO ()
dockerRm run name = do
  _ <- runDocker run ["rm", "-f", name] ""
  pure ()

waitUntilRunning :: CommandRunner -> String -> IO (Either Text ())
waitUntilRunning run name = go (50 :: Int)
  where
    go 0 =
      pure $
        Left $
          "materialize session did not become running: " <> T.pack name
    go n = do
      running <- inspectRunning run name
      case running of
        Left err -> pure (Left err)
        Right True -> pure (Right ())
        Right False -> do
          threadDelay 100_000
          go (n - 1)

inspectRunning :: CommandRunner -> String -> IO (Either Text Bool)
inspectRunning run name = do
  res <-
    runDocker
      run
      ["inspect", "--format", "{{.State.Running}}", name]
      ""
  pure $ case res of
    Left err ->
      Left ("could not inspect materialize session: " <> err)
    Right out ->
      case T.toLower (T.strip (T.pack out)) of
        "true" -> Right True
        "false" -> Right False
        _ ->
          Left $
            "could not parse materialize session state from: "
              <> T.strip (T.pack out)

runDocker :: CommandRunner -> [String] -> String -> IO (Either Text String)
runDocker run args stdin = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "docker" args,
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = stdin
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right (prStdout res)
      else Left (T.strip (T.pack (prStderr res)))

-- | Best-effort leftover sweep. Never throws; never removes a container whose
-- labeled pid is a live overlay-manager process.
sweepStaleMaterializeSessions ::
  CommandRunner ->
  -- | @True@ when the labeled pid is a live overlay-manager.
  (String -> IO Bool) ->
  IO ()
sweepStaleMaterializeSessions run isLive = do
  listed <-
    try @SomeException $
      run
        ProcessRequest
          { prMode =
              ExecCmd
                "docker"
                ["ps", "-aq", "--filter", "label=" <> materializeProductLabel],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
  case listed of
    Left _ -> pure ()
    Right res
      | prExitCode res /= ExitSuccess -> pure ()
      | otherwise ->
          forM_ (filter (not . null) (lines (prStdout res))) $
            sweepOne run isLive

sweepOne :: CommandRunner -> (String -> IO Bool) -> String -> IO ()
sweepOne run isLive cid = do
  _ <- try @SomeException $ do
    pidRes <-
      run
        ProcessRequest
          { prMode =
              ExecCmd
                "docker"
                [ "inspect",
                  "--format",
                  "{{index .Config.Labels \"" <> materializePidLabelKey <> "\"}}",
                  cid
                ],
            prCwd = Nothing,
            prEnv = Nothing,
            prStdin = ""
          }
    let pid = trim (prStdout pidRes)
    keep <-
      if prExitCode pidRes /= ExitSuccess || null pid
        then pure False
        else isLive pid
    if keep
      then pure ()
      else do
        _ <-
          run
            ProcessRequest
              { prMode = ExecCmd "docker" ["rm", "-f", cid],
                prCwd = Nothing,
                prEnv = Nothing,
                prStdin = ""
              }
        pure ()
  pure ()

-- | @True@ when @\/proc\/\<pid\>@ exists and its @exe@ is this CLI (or exe is
-- unreadable while the pid is still live — do not sweep a concurrent run).
isLiveOverlayManagerPid :: String -> IO Bool
isLiveOverlayManagerPid pidStr =
  case readMaybe pidStr :: Maybe Int of
    Just pid | pid > 0 -> do
      let procDir = "/proc" </> pidStr
      exists <- doesDirectoryExist procDir
      if not exists
        then pure False
        else do
          self <- getExecutablePath
          mExe <- try @IOException (getSymbolicLinkTarget (procDir </> "exe"))
          pure $ case mExe of
            Left _ -> True
            Right target ->
              let cleaned = takeWhile (not . isSpace) target
               in cleaned == self || target == self
    _ -> pure False

inspectMaterializeImage :: CommandRunner -> String -> IO (Either Text ())
inspectMaterializeImage run image = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "docker" ["image", "inspect", image],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (missingImageMessage image)

missingImageMessage :: String -> Text
missingImageMessage image =
  "materialize image is not usable: "
    <> T.pack image
    <> " (update ensures the default tag "
    <> T.pack defaultMaterializeImage
    <> " when full-path work needs it; set "
    <> T.pack materializeImageEnvVar
    <> " only to an existing inspect-only override; see README)"

trim :: String -> String
trim = T.unpack . T.strip . T.pack
