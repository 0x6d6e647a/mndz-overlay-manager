{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Update.SshAgent
  ( SshSession (..),
    ensureSshAgent,
    teardownSshSession,
    SshAgentOps (..),
    productionSshAgentOps,
    mkSshAgentOps,
    resolveSshIdentity,
    prepareSshIdentity,
    guardSshIdentityOffered,
    takeSshSessionSupervisor,
    spawnSshSessionSupervisorIn,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (IOException, try)
import Control.Monad (filterM, unless, void, when)
import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Types (CInt (..), CLong (..))
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment
  ( getEnvironment,
    getExecutablePath,
    lookupEnv,
    setEnv,
    unsetEnv,
  )
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (isAbsolute, takeFileName, (</>))
import System.IO
  ( BufferMode (LineBuffering),
    IOMode (ReadWriteMode),
    hClose,
    hFlush,
    hGetLine,
    hPutStrLn,
    hSetBuffering,
    stderr,
    stdout,
    withFile,
  )
import System.Posix.Process (getParentProcessID)
import System.Posix.Signals (installHandler, sigTERM)
import System.Posix.Signals qualified as Signals
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe, Inherit, NoStream, UseHandle),
    createProcess,
    proc,
    readProcessWithExitCode,
    terminateProcess,
    waitForProcess,
    withCreateProcess,
  )
import Update.GitHub (AssetsPushTransport (..), classifyAssetsPushUrl)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Env var set only on the supervisor child. The value is the agent pid.
sshSupervisorEnv :: String
sshSupervisorEnv = "MNDZ_OVERLAY_MANAGER_SSH_SUPERVISOR"

-- | Linux @PR_SET_PDEATHSIG@. Copied beside the GPG supervisor on purpose.
prSetPdeathsig :: CInt
prSetPdeathsig = 1

foreign import ccall unsafe "prctl"
  c_prctl :: CInt -> CLong -> CLong -> CLong -> CLong -> IO CInt

-- | SSH agent session for the process lifetime.
--
-- An owned session carries the reap action for its parent-death supervisor.
-- That action keeps the type from being 'Eq'.
data SshSession
  = -- | Reused existing agent. No supervisor, and no kill on exit.
    SshSessionReused
  | -- | Agent this process started. Kill the pid, then reap the supervisor.
    SshSessionOwned
      { ssAgentPid :: String,
        ssReap :: IO ()
      }

instance Show SshSession where
  show SshSessionReused = "SshSessionReused"
  show (SshSessionOwned pid _) = "SshSessionOwned " <> show pid

-- | Injectable SSH agent operations.
data SshAgentOps = SshAgentOps
  { saoLookupEnv :: String -> IO (Maybe String),
    saoSetEnv :: String -> String -> IO (),
    saoUnsetEnv :: String -> IO (),
    saoRunAgent :: IO (Either Text (String, String)),
    -- | Interactive @ssh-add@ of the one resolved private key.
    saoSshAdd :: FilePath -> IO (Either Text ()),
    -- | @ssh-keygen -lf <path> -E sha256@, as the @SHA256:@ token only.
    saoFingerprint :: FilePath -> IO (Either Text Text),
    -- | @ssh-add -E sha256 -l@. 'Left' is unreachable. 'Right' is the tokens,
    -- empty when the agent is reachable and has no identities.
    saoListTokens :: IO (Either Text [Text]),
    saoKillAgent :: String -> IO (),
    -- | Start the parent-death supervisor for an agent this process owns.
    -- 'Left' means it did not become ready. 'Right' is the reap action.
    saoStartSupervisor :: String -> IO (Either Text (IO ())),
    saoOperatorHome :: IO FilePath,
    saoFileExists :: FilePath -> IO Bool
  }

-- | Build SSH agent ops over an injectable command runner.
--
-- Captured helpers (@ssh-keygen@, @ssh-agent@, @ssh-add -l@, @kill@) go
-- through the runner. Interactive @ssh-add@ stays on the inherited-stdio path.
mkSshAgentOps :: CommandRunner -> SshAgentOps
mkSshAgentOps run =
  SshAgentOps
    { saoLookupEnv = lookupEnv,
      saoSetEnv = setEnv,
      saoUnsetEnv = unsetEnv,
      saoRunAgent = runSshAgent run,
      saoSshAdd = runSshAddInteractive,
      saoFingerprint = fingerprintOf run,
      saoListTokens = listTokens run,
      saoKillAgent = killSshAgent run,
      saoStartSupervisor = spawnSshSessionSupervisor,
      saoOperatorHome = getHomeDirectory,
      saoFileExists = doesFileExist
    }

productionSshAgentOps :: SshAgentOps
productionSshAgentOps = mkSshAgentOps productionCommandRunner

-- | Error for an omitted or empty @ssh-identity@. Names the key and no path.
sshIdentityRequired :: Text
sshIdentityRequired =
  "ssh-identity is required when an assets push will run"

-- | Expand a leading @~@ or @~/@ and require an absolute private-key path.
--
-- Does not touch the disk. @~user@ is rejected. An empty or omitted value
-- uses 'sshIdentityRequired' and does not quote a path.
resolveSshIdentity :: FilePath -> Maybe FilePath -> Either Text FilePath
resolveSshIdentity _ Nothing = Left sshIdentityRequired
resolveSshIdentity home (Just raw)
  | null raw = Left sshIdentityRequired
  | otherwise = do
      expanded <- expandLeadingHome home raw
      if not (isAbsolute expanded)
        then
          Left
            ( "ssh-identity must be an absolute path after expanding a leading ~: "
                <> T.pack raw
            )
        else
          if ".pub" `isSuffixOf` takeFileName expanded
            then
              Left
                ( "ssh-identity must name a private key, not a .pub file: "
                    <> T.pack raw
                )
            else Right expanded

expandLeadingHome :: FilePath -> FilePath -> Either Text FilePath
expandLeadingHome home raw =
  case raw of
    "~" -> Right home
    '~' : '/' : rest -> Right (home </> rest)
    '~' : _ ->
      Left ("ssh-identity does not expand ~user: " <> T.pack raw)
    _ -> Right raw

-- | Resolve @ssh-identity@ and require the file to exist.
--
-- A missing file fails here, before a passphrase prompt. The error includes
-- the resolved path.
prepareSshIdentity :: SshAgentOps -> Maybe FilePath -> IO (Either Text FilePath)
prepareSshIdentity ops raw = do
  home <- saoOperatorHome ops
  case resolveSshIdentity home raw of
    Left err -> pure (Left err)
    Right path -> do
      exists <- saoFileExists ops path
      pure $
        if exists
          then Right path
          else Left ("ssh-identity file not found: " <> T.pack path)

-- | 'GIT_SSH_COMMAND' selects a client this query does not describe.
gitSshCommandSet :: Text
gitSshCommandSet =
  "GIT_SSH_COMMAND is set and selects an SSH client this check does not describe"

-- | @core.sshCommand@ selects a client this query does not describe.
coreSshCommandSet :: Text
coreSshCommandSet =
  "core.sshCommand is set and selects an SSH client this check does not describe"

-- | Before a passphrase prompt, require that an SSH assets push can offer
-- @keyPath@ when OpenSSH restricts identity files.
--
-- A web push URL succeeds without running @ssh@. 'Left' does not start an agent.
guardSshIdentityOffered ::
  CommandRunner ->
  SshAgentOps ->
  FilePath ->
  FilePath ->
  Text ->
  IO (Either Text ())
guardSshIdentityOffered run ops root keyPath pushUrl =
  case classifyAssetsPushUrl pushUrl of
    PushWeb -> pure (Right ())
    PushUnsupported url ->
      pure
        ( Left
            ("assets push URL is not a github.com SSH or web URL: " <> url)
        )
    PushSshGitHub mUser -> do
      override <- saoLookupEnv ops "GIT_SSH_COMMAND"
      case override of
        Just cmd | not (null cmd) -> pure (Left gitSshCommandSet)
        _ -> do
          configured <- readCoreSshCommand run root
          case configured of
            Left err -> pure (Left err)
            Right True -> pure (Left coreSshCommandSet)
            Right False -> do
              queried <- runSshDashG run mUser
              case queried of
                Left err -> pure (Left err)
                Right body ->
                  let (only, files) = parseSshDashG body
                   in if only
                        then matchOffered ops keyPath files
                        else pure (Right ())

-- | Exit 0 with a non-empty value is an override. Exit 1 with empty stdout
-- is unset. The command text is not returned.
readCoreSshCommand :: CommandRunner -> FilePath -> IO (Either Text Bool)
readCoreSshCommand run root = do
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd "git" ["-C", root, "config", "--get", "core.sshCommand"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  let stdoutT = T.strip (T.pack (prStdout res))
  pure $ case prExitCode res of
    ExitSuccess
      | not (T.null stdoutT) -> Right True
      | otherwise ->
          Left
            ( "git config --get core.sshCommand failed: "
                <> T.pack (nullToDash (prStderr res) (prStdout res))
            )
    ExitFailure 1
      | T.null stdoutT -> Right False
    ExitFailure n ->
      Left
        ( "git config --get core.sshCommand failed (exit "
            <> T.pack (show n)
            <> "): "
            <> T.pack (nullToDash (prStderr res) (prStdout res))
        )

-- | @ssh -G@ for @github.com@, with @-l@ when the push URL names a user.
-- Does not open a connection. Success ignores stderr.
runSshDashG :: CommandRunner -> Maybe Text -> IO (Either Text String)
runSshDashG run mUser = do
  let args = case mUser of
        Just user -> ["-G", "-l", T.unpack user, "github.com"]
        Nothing -> ["-G", "github.com"]
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "ssh" args,
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right (prStdout res)
      else
        Left
          ( "ssh -G failed: "
              <> T.pack (nullToDash (prStderr res) (prStdout res))
          )

-- | Restricted flag, then identity files other than @none@, in print order.
parseSshDashG :: String -> (Bool, [Text])
parseSshDashG = go False [] . T.lines . T.pack
  where
    go only files [] = (only, reverse files)
    go only files (line : rest) =
      case T.break isSpace (T.strip line) of
        ("", _) -> go only files rest
        ("identitiesonly", value)
          | T.strip value == "yes" -> go True files rest
        ("identityfile", value) ->
          let path = T.strip value
           in if path == "none" || T.null path
                then go only files rest
                else go only (path : files) rest
        _ -> go only files rest

matchOffered :: SshAgentOps -> FilePath -> [Text] -> IO (Either Text ())
matchOffered ops keyPath offered = do
  home <- saoOperatorHome ops
  wanted <- saoFingerprint ops keyPath
  case wanted of
    Left err ->
      pure
        ( Left
            ( "cannot fingerprint ssh-identity "
                <> T.pack keyPath
                <> ": "
                <> err
            )
        )
    Right want -> walk home want offered []
  where
    walk _ _ [] errs =
      pure (Left (offerMismatch keyPath offered (reverse errs)))
    walk home want (raw : rest) errs =
      case prepareOffered home (T.unpack raw) of
        Left err -> walk home want rest (err : errs)
        Right path -> do
          got <- saoFingerprint ops path
          case got of
            Left err -> walk home want rest ((raw <> ": " <> err) : errs)
            Right token
              | token == want -> pure (Right ())
              | otherwise -> walk home want rest errs

prepareOffered :: FilePath -> FilePath -> Either Text FilePath
prepareOffered home raw =
  case expandLeadingHome home raw of
    Left _ ->
      Left ("offered identity path does not expand ~user: " <> T.pack raw)
    Right path
      | isAbsolute path -> Right path
      | otherwise ->
          Left ("offered identity path is not absolute: " <> T.pack raw)

offerMismatch :: FilePath -> [Text] -> [Text] -> Text
offerMismatch keyPath offered errs =
  let header =
        "IdentitiesOnly is set and ssh-identity "
          <> T.pack keyPath
          <> " does not match an offered identity file"
          <> case offered of
            [] -> ""
            _ -> ": " <> T.intercalate ", " offered
      details = T.intercalate "\n" errs
   in if T.null details then header else header <> "\n" <> details

-- | Ensure the configured private key is available for git push.
--
-- Fingerprint the key before choosing a socket. Reuse a reachable agent only
-- when that @SHA256:@ token is already loaded. Otherwise start an agent this
-- process owns, supervise it, and @ssh-add@ only @keyPath@.
ensureSshAgent :: SshAgentOps -> FilePath -> IO (Either Text SshSession)
ensureSshAgent ops keyPath = do
  fingerprinted <- saoFingerprint ops keyPath
  case fingerprinted of
    Left err -> pure (Left err)
    Right token -> do
      mSock <- saoLookupEnv ops "SSH_AUTH_SOCK"
      case mSock of
        Just sock | not (null sock) -> ensureWithExistingSocket ops keyPath token
        _ -> startOwnedAgent ops keyPath token

ensureWithExistingSocket ::
  SshAgentOps ->
  FilePath ->
  Text ->
  IO (Either Text SshSession)
ensureWithExistingSocket ops keyPath token = do
  listed <- saoListTokens ops
  case listed of
    Right tokens
      | token `elem` tokens ->
          pure (Right SshSessionReused)
    Right _ -> do
      note
        "configured SSH key is not loaded in the current agent; starting a new one…"
      startOwnedAgent ops keyPath token
    Left err -> do
      note
        ( "existing SSH agent unreachable ("
            <> T.unpack err
            <> "); starting a new one…"
        )
      startOwnedAgent ops keyPath token

startOwnedAgent ::
  SshAgentOps ->
  FilePath ->
  Text ->
  IO (Either Text SshSession)
startOwnedAgent ops keyPath token = do
  note "Starting ssh-agent…"
  started <- saoRunAgent ops
  case started of
    Left err -> pure (Left err)
    Right (sock, pid) -> do
      saoSetEnv ops "SSH_AUTH_SOCK" sock
      saoSetEnv ops "SSH_AGENT_PID" pid
      supervised <- saoStartSupervisor ops pid
      case supervised of
        Left err -> do
          abandonOwned ops pid
          pure (Left err)
        Right reap -> do
          note
            ( "ssh-agent ready (SSH_AUTH_SOCK="
                <> sock
                <> "); adding "
                <> keyPath
                <> "…"
            )
          added <- saoSshAdd ops keyPath
          case added of
            Left err -> do
              releaseOwned ops pid reap
              pure (Left err)
            Right () -> confirmToken ops token (SshSessionOwned pid reap)

confirmToken ::
  SshAgentOps ->
  Text ->
  SshSession ->
  IO (Either Text SshSession)
confirmToken ops token session = do
  listed <- saoListTokens ops
  case listed of
    Right tokens
      | token `elem` tokens ->
          pure (Right session)
    Right _ -> do
      releaseSession ops session
      pure (Left "ssh-add finished but the configured key is not loaded")
    Left err -> do
      releaseSession ops session
      pure (Left ("SSH agent not usable after ssh-add: " <> err))

releaseSession :: SshAgentOps -> SshSession -> IO ()
releaseSession _ SshSessionReused = pure ()
releaseSession ops (SshSessionOwned pid reap) = releaseOwned ops pid reap

-- | Kill an owned agent, then reap its supervisor, then drop the socket vars.
releaseOwned :: SshAgentOps -> String -> IO () -> IO ()
releaseOwned ops pid reap = do
  saoKillAgent ops pid
  reap
  clearOwnedEnv ops

-- | Supervisor never became ready. Kill the agent and drop the socket vars.
abandonOwned :: SshAgentOps -> String -> IO ()
abandonOwned ops pid = do
  saoKillAgent ops pid
  clearOwnedEnv ops

clearOwnedEnv :: SshAgentOps -> IO ()
clearOwnedEnv ops = do
  saoUnsetEnv ops "SSH_AUTH_SOCK"
  saoUnsetEnv ops "SSH_AGENT_PID"

teardownSshSession :: SshAgentOps -> SshSession -> IO ()
teardownSshSession _ SshSessionReused = pure ()
teardownSshSession ops (SshSessionOwned pid reap) = releaseOwned ops pid reap

note :: String -> IO ()
note msg = do
  hPutStrLn stderr msg
  hFlush stderr

------------------------------------------------------------------------
-- Agent process
------------------------------------------------------------------------

runSshAgent :: CommandRunner -> IO (Either Text (String, String))
runSshAgent run = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "ssh-agent" ["-s"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  if prExitCode res /= ExitSuccess
    then
      pure $
        Left ("ssh-agent failed: " <> T.pack (nullToDash (prStderr res) (prStdout res)))
    else pure $ parseAgentEnv (prStdout res)

parseAgentEnv :: String -> Either Text (String, String)
parseAgentEnv out =
  let bindings = mapMaybe parseLine (lines out)
      sock = lookup "SSH_AUTH_SOCK" bindings
      pid = lookup "SSH_AGENT_PID" bindings
   in case (sock, pid) of
        (Just s, Just p) -> Right (s, p)
        _ -> Left ("could not parse ssh-agent output: " <> T.pack out)
  where
    parseLine line =
      case break (== '=') line of
        (k, '=' : rest) ->
          let val = takeWhile (/= ';') rest
           in if null k || null val then Nothing else Just (k, val)
        _ -> Nothing

fingerprintOf :: CommandRunner -> FilePath -> IO (Either Text Text)
fingerprintOf run path = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "ssh-keygen" ["-lf", path, "-E", "sha256"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then
        Left (T.pack (nullToDash (prStderr res) (prStdout res)))
      else case sha256Tokens (prStdout res) of
        (token : _) -> Right token
        [] ->
          Left
            ( "ssh-keygen did not report a SHA256 fingerprint: "
                <> T.pack (nullToDash (prStdout res) (prStderr res))
            )

listTokens :: CommandRunner -> IO (Either Text [Text])
listTokens run = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "ssh-add" ["-E", "sha256", "-l"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $ case prExitCode res of
    ExitSuccess -> Right (sha256Tokens (prStdout res))
    ExitFailure 1 -> Right []
    ExitFailure n ->
      Left
        ( "ssh-add -l exit "
            <> T.pack (show n)
            <> ": "
            <> T.pack (nullToDash (prStderr res) (prStdout res))
        )

-- | @SHA256:@ words only. Comments around them are not part of the match.
sha256Tokens :: String -> [Text]
sha256Tokens = map T.pack . filter ("SHA256:" `isPrefixOf`) . words

killSshAgent :: CommandRunner -> String -> IO ()
killSshAgent run pid = do
  _ <-
    run
      ProcessRequest
        { prMode = ExecCmd "kill" [pid],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure ()

------------------------------------------------------------------------
-- Parent-death supervisor
--
-- Same sequence as the GPG session supervisor (re-exec, PR_SET_PDEATHSIG,
-- recheck the parent, signal ready, then kill). A second copy lives here so
-- this change does not refactor the signing supervisor.
------------------------------------------------------------------------

-- | If this process was spawned as the SSH supervisor, run it and return
-- @True@. The normal program returns @False@ without starting a supervisor.
takeSshSessionSupervisor :: IO Bool
takeSshSessionSupervisor = do
  mPid <- lookupEnv sshSupervisorEnv
  case mPid of
    Nothing -> pure False
    Just pid -> do
      unsetEnv sshSupervisorEnv
      runSshSessionSupervisor pid
      pure True

spawnSshSessionSupervisor :: String -> IO (Either Text (IO ()))
spawnSshSessionSupervisor pid = do
  env0 <- getEnvironment
  spawnSshSessionSupervisorIn env0 pid

-- | Like 'spawnSshSessionSupervisor' with an explicit environment.
-- The supervisor variable is set to the agent pid.
spawnSshSessionSupervisorIn ::
  [(String, String)] ->
  String ->
  IO (Either Text (IO ()))
spawnSshSessionSupervisorIn env0 pid = do
  exe <- getExecutablePath
  let env1 =
        (sshSupervisorEnv, pid)
          : filter (\(k, _) -> k /= sshSupervisorEnv) env0
  started <-
    try @IOException $
      createProcess
        (proc exe [])
          { env = Just env1,
            std_in = NoStream,
            std_out = CreatePipe,
            std_err = NoStream
          }
  case started of
    Left e ->
      pure (Left ("SSH supervisor failed to start: " <> T.pack (show e)))
    Right (Nothing, Just outH, Nothing, ph) ->
      waitReady outH ph
    Right _ ->
      pure (Left "SSH supervisor did not return a stdout pipe")
  where
    waitReady outH ph = do
      ready <- race (threadDelay 60_000_000) (try @IOException (hGetLine outH))
      case ready of
        Left () -> do
          terminateProcess ph
          void (waitForProcess ph)
          hClose outH
          pure (Left "SSH supervisor did not become ready")
        Right (Left _) -> do
          ec <- waitForProcess ph
          hClose outH
          pure
            ( Left
                ( "SSH supervisor exited before ready: "
                    <> T.pack (show ec)
                )
            )
        Right (Right "ready") -> do
          hClose outH
          pure (Right (reap ph))
        Right (Right other) -> do
          terminateProcess ph
          void (waitForProcess ph)
          hClose outH
          pure (Left ("SSH supervisor sent " <> T.pack (show other)))
    reap ph = do
      terminateProcess ph
      void (waitForProcess ph)

-- | Set the parent-death signal, recheck the parent, then wait for @SIGTERM@.
runSshSessionSupervisor :: String -> IO ()
runSshSessionSupervisor pid = do
  parent <- getParentProcessID
  done <- newEmptyMVar
  _ <-
    installHandler
      sigTERM
      (Signals.Catch (void (tryPutMVar done ())))
      Nothing
  rc <- c_prctl prSetPdeathsig (fromIntegral sigTERM) 0 0 0
  when (rc < 0) exitFailure
  parent2 <- getParentProcessID
  -- prctl then recheck: a parent that died in between is not signaled.
  if parent2 /= parent || parent2 == 1
    then killAgentPid pid
    else do
      hSetBuffering stdout LineBuffering
      putStrLn "ready"
      hFlush stdout
      void (takeMVar done)
      killAgentPid pid

killAgentPid :: String -> IO ()
killAgentPid pid =
  void $
    try @IOException $
      readProcessWithExitCode "kill" [pid] ""

------------------------------------------------------------------------
-- Interactive ssh-add
------------------------------------------------------------------------

-- | Add one private key. Prefer @\/dev\/tty@; fall back to @SSH_ASKPASS@.
runSshAddInteractive :: FilePath -> IO (Either Text ())
runSshAddInteractive keyPath = do
  ttyOk <- canUseDevTty
  if ttyOk
    then sshAddWithDevTty keyPath
    else sshAddWithAskPass keyPath

canUseDevTty :: IO Bool
canUseDevTty = doesFileExist "/dev/tty"

-- | Open @\/dev\/tty@ so ssh-add can prompt even when stdio is not a TTY.
sshAddWithDevTty :: FilePath -> IO (Either Text ())
sshAddWithDevTty keyPath =
  withFile "/dev/tty" ReadWriteMode $ \tty -> do
    note "Using /dev/tty for ssh-add passphrase prompt…"
    env0 <- getEnvironment
    let cp =
          (proc "ssh-add" [keyPath])
            { std_in = UseHandle tty,
              std_out = Inherit,
              std_err = Inherit,
              env = Just env0
            }
    runSshAddProcess cp keyPath "tty"

-- | Force GUI/CLI askpass when there is no usable controlling terminal.
sshAddWithAskPass :: FilePath -> IO (Either Text ())
sshAddWithAskPass keyPath = do
  askPass <- findAskPass
  case askPass of
    Nothing ->
      pure $
        Left
          ( "cannot prompt for SSH key passphrase: no controlling TTY and no "
              <> "ssh-askpass helper (install ksshaskpass or ssh-askpass, or run "
              <> "from a real terminal). Key: "
              <> T.pack keyPath
          )
    Just askPath -> do
      display <- lookupEnv "DISPLAY"
      wayland <- lookupEnv "WAYLAND_DISPLAY"
      unless (maybe False (not . null) display || maybe False (not . null) wayland) $
        note "warning: DISPLAY/WAYLAND_DISPLAY unset; askpass may fail"
      note ("Using SSH_ASKPASS=" <> askPath <> " for passphrase prompt…")
      env0 <- getEnvironment
      let env1 =
            ("SSH_ASKPASS", askPath)
              : ("SSH_ASKPASS_REQUIRE", "force")
              : filter
                ( \(k, _) ->
                    k /= "SSH_ASKPASS" && k /= "SSH_ASKPASS_REQUIRE"
                )
                env0
          cp =
            (proc "ssh-add" [keyPath])
              { std_in = Inherit,
                std_out = Inherit,
                std_err = Inherit,
                env = Just env1
              }
      runSshAddProcess cp keyPath "askpass"

findAskPass :: IO (Maybe FilePath)
findAskPass = do
  mEnv <- lookupEnv "SSH_ASKPASS"
  case mEnv of
    Just p | not (null p) -> do
      ok <- doesFileExist p
      pure $ if ok then Just p else Nothing
    _ -> do
      let candidates =
            [ "/usr/bin/ksshaskpass",
              "/usr/bin/ssh-askpass",
              "/usr/lib/ssh/ssh-askpass",
              "/usr/libexec/ssh-askpass",
              "/usr/lib/openssh/ssh-askpass"
            ]
      found <- filterM doesFileExist candidates
      pure $ case found of
        (p : _) -> Just p
        [] -> Nothing

runSshAddProcess :: CreateProcess -> FilePath -> String -> IO (Either Text ())
runSshAddProcess cp keyPath mode = do
  hFlush stdout
  hFlush stderr
  withCreateProcess cp $ \_ _ _ ph -> do
    code <- waitForProcess ph
    pure $
      if code == ExitSuccess
        then Right ()
        else
          Left
            ( "ssh-add failed via "
                <> T.pack mode
                <> " (exit "
                <> T.pack (show code)
                <> ") for key: "
                <> T.pack keyPath
                <> ". Unlock manually with: ssh-add "
                <> T.pack keyPath
            )

nullToDash :: String -> String -> String
nullToDash primary fallback =
  case (primary, fallback) of
    ("", "") -> "(no output)"
    ("", fb) -> fb
    (p, _) -> p
