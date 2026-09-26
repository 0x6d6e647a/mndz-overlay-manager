{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Update.GpgAgent
  ( Keygrip (..),
    GpgAgentOps (..),
    GpgHandle,
    Supervisor (..),
    noopSupervisor,
    productionGpgAgentOps,
    mkGpgAgentOps,
    newGpgHandle,
    ensureGpgReady,
    teardownGpgHandle,
    prepareSigningSession,
    armGpgSession,
    lookupGpgSessionHome,
    signingChildEnv,
    pinentryChildEnv,
    lookupControllingTty,
    parseSignCapableKeygrip,
    parseKeyinfoCached,
    buildGpgSessionHome,
    removeGpgSessionHome,
    gpgHomeUnder,
    takeGpgSessionSupervisor,
    spawnGpgSessionSupervisor,
    spawnGpgSessionSupervisorIn,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar
  ( MVar,
    modifyMVar_,
    newEmptyMVar,
    newMVar,
    readMVar,
    takeMVar,
    tryPutMVar,
    withMVar,
  )
import Control.Exception (IOException, bracket_, try)
import Control.Monad (void, when)
import Data.Containers.ListUtils (nubOrd)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Foreign.C.Types (CInt (..), CLong (..))
import System.Directory
  ( copyFile,
    createDirectoryIfMissing,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
    listDirectory,
    makeAbsolute,
    removeDirectory,
    removeFile,
    removePathForcibly,
  )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, unsetEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO
  ( BufferMode (LineBuffering),
    Handle,
    IOMode (ReadWriteMode),
    hClose,
    hFlush,
    hGetLine,
    hPutStr,
    hSetBuffering,
    stderr,
    stdout,
    withFile,
  )
import System.Posix.Files (setFileMode)
import System.Posix.Process (getParentProcessID)
import System.Posix.Signals (installHandler, sigTERM)
import System.Posix.Signals qualified as Signals
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe, NoStream),
    createProcess,
    proc,
    readProcessWithExitCode,
    terminateProcess,
    waitForProcess,
  )
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Env var set only on the supervisor child. The child unsets it before waiting.
gpgSupervisorEnv :: String
gpgSupervisorEnv = "MNDZ_OVERLAY_MANAGER_GPG_SUPERVISOR"

-- | Directory name of the session home under a product run root.
gpgSessionDirName :: String
gpgSessionDirName = "gpg-home"

-- | @\<run-root\>/gpg-home@.
gpgHomeUnder :: FilePath -> FilePath
gpgHomeUnder runRoot = runRoot </> gpgSessionDirName

-- | Linux @PR_SET_PDEATHSIG@.
prSetPdeathsig :: CInt
prSetPdeathsig = 1

foreign import ccall unsafe "prctl"
  c_prctl :: CInt -> CLong -> CLong -> CLong -> CLong -> IO CInt

-- | GPG keygrip (hex string).
newtype Keygrip = Keygrip {unKeygrip :: Text}
  deriving (Eq, Ord, Show)

-- | Parent-death supervisor for one session agent.
newtype Supervisor = Supervisor
  { -- | Signal the supervisor and wait until it exits.
    supReap :: IO ()
  }

-- | Supervisor stand-in for tests that do not spawn a process.
noopSupervisor :: Supervisor
noopSupervisor = Supervisor {supReap = pure ()}

-- | Per-worktree readiness bookkeeping.
data WorktreeState = WorktreeState
  { wsSigningKey :: Text,
    wsKeygrip :: Keygrip
  }
  deriving (Eq, Show)

-- | One private GnuPG home and the supervisor that kills its agent.
data GpgSession = GpgSession
  { gsHome :: FilePath,
    gsSupervisor :: Supervisor
  }

-- | Process-lifetime GPG readiness handle.
data GpgHandle = GpgHandle
  { ghOps :: GpgAgentOps,
    ghLock :: MVar (),
    ghByRoot :: MVar (Map FilePath WorktreeState),
    ghSession :: MVar (Maybe GpgSession)
  }

-- | Injectable GPG agent operations (unit tests without live pinentry).
data GpgAgentOps = GpgAgentOps
  { -- | @git -C <repo> config --get user.signingkey@
    gaoGetSigningKey :: FilePath -> IO (Either Text Text),
    -- | Map signing key id to a sign-capable secret keygrip.
    gaoResolveKeygrip :: Text -> IO (Either Text Keygrip),
    -- | KEYINFO against the session home. @Nothing@ must not query the desktop agent.
    gaoKeyinfoCached :: Maybe FilePath -> Keygrip -> IO (Either Text Bool),
    -- | Ready-prompt on controlling TTY (Enter to continue).
    gaoReadyPrompt :: IO (Either Text ()),
    -- | Dummy warm (clearsign). Home and controlling tty are passed in.
    gaoWarmKey :: Maybe FilePath -> Maybe FilePath -> Text -> IO (Either Text ()),
    -- | Controlling tty path if available (e.g. @\/dev\/tty@).
    gaoControllingTty :: IO (Maybe FilePath),
    -- | Pause activity indicators (clear panel) before interactive unlock.
    gaoPauseUi :: IO (),
    -- | Resume activity indicators after interactive unlock.
    gaoResumeUi :: IO (),
    -- | Populate a session home from the source GnuPG home for these key ids.
    gaoBuildSessionHome :: FilePath -> FilePath -> [Text] -> IO (Either Text ()),
    -- | @gpgconf --homedir <session> --kill gpg-agent@.
    gaoKillSessionAgent :: FilePath -> IO (),
    -- | Parent-death supervisor. @Left@ fails the run before unlock.
    gaoStartSupervisor :: FilePath -> IO (Either Text Supervisor),
    -- | Reap a supervisor started by 'gaoStartSupervisor'.
    gaoReapSupervisor :: Supervisor -> IO (),
    -- | Remove the session home. Must not follow a secret-key symlink.
    gaoRemoveSessionHome :: FilePath -> IO ()
  }

-- | Build GPG agent ops over an injectable command runner (Unit heat surface).
--
-- Process-oriented helpers (git config, gpg list/clearsign, gpg-connect-agent)
-- go through the runner. TTY ready-prompt and controlling-tty discovery stay
-- host-local (not CommandRunner).
mkGpgAgentOps :: CommandRunner -> IO () -> IO () -> GpgAgentOps
mkGpgAgentOps run pauseUi resumeUi =
  GpgAgentOps
    { gaoGetSigningKey = gitGetSigningKey run,
      gaoResolveKeygrip = resolveKeygripViaGpg run,
      gaoKeyinfoCached = keyinfoCached run,
      gaoReadyPrompt = readyPromptOnTty,
      gaoWarmKey = warmKeyDummy run,
      gaoControllingTty = controllingTtyPath,
      gaoPauseUi = pauseUi,
      gaoResumeUi = resumeUi,
      gaoBuildSessionHome = buildGpgSessionHome,
      gaoKillSessionAgent = killSessionAgent run,
      gaoStartSupervisor = spawnGpgSessionSupervisor,
      gaoReapSupervisor = supReap,
      gaoRemoveSessionHome = removeGpgSessionHome
    }

-- | Production ops. Pass pause\/resume from 'CLI.Progress' panel controls.
productionGpgAgentOps :: IO () -> IO () -> GpgAgentOps
productionGpgAgentOps = mkGpgAgentOps productionCommandRunner

-- | Create a process-lifetime handle.
newGpgHandle :: GpgAgentOps -> IO GpgHandle
newGpgHandle ops = do
  lock <- newMVar ()
  byRoot <- newMVar Map.empty
  session <- newMVar Nothing
  pure $
    GpgHandle
      { ghOps = ops,
        ghLock = lock,
        ghByRoot = byRoot,
        ghSession = session
      }

-- | Record a session that is already supervised. Tests use 'noopSupervisor'.
armGpgSession :: GpgHandle -> FilePath -> Supervisor -> IO ()
armGpgSession handle home sup =
  modifyMVar_ (ghSession handle) $ \_ ->
    pure (Just GpgSession {gsHome = home, gsSupervisor = sup})

-- | Session home, once 'prepareSigningSession' or 'armGpgSession' has run.
lookupGpgSessionHome :: GpgHandle -> IO (Maybe FilePath)
lookupGpgSessionHome handle = fmap gsHome <$> readMVar (ghSession handle)

-- | Ensure the worktree’s signing key is ready for @git commit -S@.
--
-- Cold session cache: ready-prompt then dummy warm. Warm session cache: no
-- prompt. A warm desktop agent is not a session-cache hit. Missing
-- @user.signingkey@ \/ no TTY when unlock is required: hard failure.
ensureGpgReady :: GpgHandle -> FilePath -> IO (Either Text ())
ensureGpgReady handle repoRoot =
  withMVar (ghLock handle) $ \() -> do
    rootAbs <- makeAbsolute repoRoot
    let ops = ghOps handle
    resolved <- resolveWorktree ops handle rootAbs
    case resolved of
      Left err -> pure (Left err)
      Right st -> unlockCold handle st

-- | Build the session home, start the supervisor, and unlock each distinct key.
--
-- Supervisor start failure returns before any warm-up and does not use the
-- desktop agent. The home is @\<runRoot\>/gpg-home@.
prepareSigningSession :: GpgHandle -> FilePath -> [FilePath] -> IO (Either Text ())
prepareSigningSession handle runRoot worktrees =
  withMVar (ghLock handle) $ \() -> do
    let ops = ghOps handle
        home = gpgHomeUnder runRoot
    roots <- mapM makeAbsolute worktrees
    resolved <- mapM (resolveWorktree ops handle) roots
    case sequence resolved of
      Left err -> pure (Left err)
      Right sts -> do
        source <- sourceGnuPGHome
        let keyIds = nubOrd (map wsSigningKey sts)
        writeGpgSessionSkeleton home
        started <- gaoStartSupervisor ops home
        case started of
          Left err -> do
            gaoRemoveSessionHome ops home
            pure (Left ("GPG session supervisor failed to start: " <> err))
          Right sup -> do
            armGpgSession handle home sup
            built <- gaoBuildSessionHome ops source home keyIds
            case built of
              Left err -> pure (Left err)
              Right () -> unlockMany handle sts

-- | Kill the session agent, reap the supervisor, and remove the session home.
-- Does not send @CLEAR_PASSPHRASE@ to the desktop agent. A second call is a no-op.
teardownGpgHandle :: GpgHandle -> IO ()
teardownGpgHandle handle = do
  mSess <- readMVar (ghSession handle)
  case mSess of
    Nothing -> pure ()
    Just sess -> do
      let ops = ghOps handle
      gaoKillSessionAgent ops (gsHome sess)
      gaoReapSupervisor ops (gsSupervisor sess)
      gaoRemoveSessionHome ops (gsHome sess)
      modifyMVar_ (ghSession handle) $ \_ -> pure Nothing

-- | Child environment for GPG unlock \/ @git commit -S@.
--
-- Sets @GPG_TTY@ when a controlling tty exists, sets @GNUPGHOME@ when a session
-- home exists, and clears @DISPLAY@ so pinentry prefers TTY over GUI. The
-- parent process environment is left unchanged.
pinentryChildEnv ::
  Maybe FilePath ->
  Maybe FilePath ->
  [(String, String)] ->
  [(String, String)]
pinentryChildEnv mTty mHome parentEnv =
  let stripped =
        filter
          (\(k, _) -> k /= "DISPLAY" && k /= "GPG_TTY" && k /= "GNUPGHOME")
          parentEnv
      withHome = case mHome of
        Just home | not (null home) -> ("GNUPGHOME", home) : stripped
        _ -> stripped
   in case mTty of
        Just tty | not (null tty) -> ("GPG_TTY", tty) : withHome
        _ -> withHome

-- | Child environment for the warm-up @gpg@ and for @git commit -S@.
signingChildEnv :: GpgHandle -> IO [(String, String)]
signingChildEnv handle = do
  mTty <- lookupControllingTty handle
  mHome <- lookupGpgSessionHome handle
  pinentryChildEnv mTty mHome <$> getEnvironment

-- | Controlling tty path from a handle’s ops (for signed-commit child env).
lookupControllingTty :: GpgHandle -> IO (Maybe FilePath)
lookupControllingTty handle = gaoControllingTty (ghOps handle)

------------------------------------------------------------------------
-- Session home
------------------------------------------------------------------------

gpgAgentConfText :: Text
gpgAgentConfText =
  T.unlines
    [ "default-cache-ttl 28800",
      "max-cache-ttl 28800",
      "pinentry-program /usr/bin/pinentry-tty"
    ]

-- | Mode-700 directory and @gpg-agent.conf@. Does not start an agent.
writeGpgSessionSkeleton :: FilePath -> IO ()
writeGpgSessionSkeleton dest = do
  createDirectoryIfMissing True dest
  setFileMode dest 0o700
  TIO.writeFile (dest </> "gpg-agent.conf") gpgAgentConfText

-- | Operator GnuPG home: @$GNUPGHOME@ when set, otherwise @~\/.gnupg@.
sourceGnuPGHome :: IO FilePath
sourceGnuPGHome = do
  m <- lookupEnv "GNUPGHOME"
  case m of
    Just p | not (null p) -> makeAbsolute p
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".gnupg")

-- | Create a session home that can sign with the requested keys only.
--
-- Public keys are exported from @source@. Only each sign-capable secret key
-- file is linked, or copied when this GnuPG will not list the linked key.
-- @use-keyboxd@ is left off.
buildGpgSessionHome :: FilePath -> FilePath -> [Text] -> IO (Either Text ())
buildGpgSessionHome source dest keyIds = do
  writeGpgSessionSkeleton dest
  go (nubOrd keyIds)
  where
    go [] = pure (Right ())
    go (keyId : rest) = do
      installed <- installSigningKey source dest keyId
      case installed of
        Left err -> pure (Left err)
        Right () -> go rest

installSigningKey :: FilePath -> FilePath -> Text -> IO (Either Text ())
installSigningKey source dest keyId = do
  exported <-
    runGpg
      source
      ["--export", "--output", dest </> "session-pub.gpg", T.unpack keyId]
  case exported of
    Left err ->
      pure (Left ("could not export public key " <> keyId <> ": " <> err))
    Right _ -> do
      imported <- runGpg dest ["--import", dest </> "session-pub.gpg"]
      _ <- try @IOException (removeFile (dest </> "session-pub.gpg"))
      case imported of
        Left err ->
          pure (Left ("could not import public key " <> keyId <> ": " <> err))
        Right _ -> do
          listed <-
            runGpg
              source
              [ "--list-secret-keys",
                "--with-colons",
                "--with-keygrip",
                T.unpack keyId
              ]
          case listed >>= parseSignCapableKeygrip of
            Left err -> pure (Left err)
            Right (Keygrip grip) -> linkOrCopySecret source dest grip

linkOrCopySecret :: FilePath -> FilePath -> Text -> IO (Either Text ())
linkOrCopySecret source dest grip = do
  let src = source </> "private-keys-v1.d" </> T.unpack grip <> ".key"
      dstDir = dest </> "private-keys-v1.d"
      dst = dstDir </> T.unpack grip <> ".key"
  srcOk <- doesFileExist src
  if not srcOk
    then
      pure
        ( Left
            ("sign-capable secret key file is missing for keygrip " <> grip)
        )
    else do
      createDirectoryIfMissing True dstDir
      setFileMode dstDir 0o700
      linked <- try @IOException (createFileLink src dst)
      case linked of
        Left e ->
          pure (Left ("could not link secret key " <> grip <> ": " <> T.pack (show e)))
        Right () -> do
          visible <- sessionListsGrip dest grip
          if visible
            then pure (Right ())
            else do
              -- A symlink GnuPG will not use is replaced by that one file.
              removeFile dst
              copied <- try @IOException (copyFile src dst)
              case copied of
                Left e ->
                  pure
                    ( Left
                        ( "could not copy secret key "
                            <> grip
                            <> ": "
                            <> T.pack (show e)
                        )
                    )
                Right () -> do
                  setFileMode dst 0o600
                  visible' <- sessionListsGrip dest grip
                  pure $
                    if visible'
                      then Right ()
                      else
                        Left
                          ("session home cannot see secret keygrip " <> grip)

sessionListsGrip :: FilePath -> Text -> IO Bool
sessionListsGrip dest grip = do
  listed <-
    runGpg
      dest
      ["--list-secret-keys", "--with-colons", "--with-keygrip"]
  pure $ case listed of
    Right out -> grip `T.isInfixOf` T.pack out
    Left _ -> False

-- | @gpg --homedir@ so a caller @GNUPGHOME@ cannot redirect the command.
runGpg :: FilePath -> [String] -> IO (Either Text String)
runGpg home args = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "gpg"
        (["--homedir", home, "--batch", "--pinentry-mode", "cancel"] <> args)
        ""
  pure $ case result of
    Left e -> Left (T.pack (show e))
    Right (code, out, err) ->
      if code == ExitSuccess
        then Right out
        else Left (T.strip (T.pack err))

-- | Remove @gpg-home@. Refuses any other path. Does not follow key symlinks,
-- and drops an empty parent run root after the home is gone.
removeGpgSessionHome :: FilePath -> IO ()
removeGpgSessionHome home
  | takeFileName home /= gpgSessionDirName = pure ()
  | otherwise = do
      removePathForcibly home
      let parent = takeDirectory home
      exists <- doesDirectoryExist parent
      when exists $ do
        entries <- listDirectory parent
        when (null entries) $
          void (try @IOException (removeDirectory parent))

------------------------------------------------------------------------
-- Supervisor
------------------------------------------------------------------------

-- | If this process was spawned as the session supervisor, run it and return
-- @True@. The normal program returns @False@ without starting a supervisor.
takeGpgSessionSupervisor :: IO Bool
takeGpgSessionSupervisor = do
  mHome <- lookupEnv gpgSupervisorEnv
  case mHome of
    Nothing -> pure False
    Just home -> do
      unsetEnv gpgSupervisorEnv
      runGpgSessionSupervisor home
      pure True

-- | Spawn a child that kills the session agent when its parent dies.
-- The child inherits the current process environment.
spawnGpgSessionSupervisor :: FilePath -> IO (Either Text Supervisor)
spawnGpgSessionSupervisor home = do
  env0 <- getEnvironment
  spawnGpgSessionSupervisorIn env0 home

-- | Like 'spawnGpgSessionSupervisor' with an explicit environment.
-- @GNUPGHOME@ is not added. The supervisor variable is set to @home@.
spawnGpgSessionSupervisorIn ::
  [(String, String)] ->
  FilePath ->
  IO (Either Text Supervisor)
spawnGpgSessionSupervisorIn env0 home = do
  exe <- getExecutablePath
  let env1 =
        (gpgSupervisorEnv, home)
          : filter (\(k, _) -> k /= gpgSupervisorEnv) env0
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
      pure (Left (T.pack (show e)))
    Right (Nothing, Just outH, Nothing, ph) ->
      waitReady outH ph
    Right _ ->
      pure (Left "GPG session supervisor did not return a stdout pipe")
  where
    waitReady outH ph = do
      ready <- race (threadDelay 60_000_000) (try @IOException (hGetLine outH))
      case ready of
        Left () -> do
          terminateProcess ph
          void (waitForProcess ph)
          hClose outH
          pure (Left "GPG session supervisor did not become ready")
        Right (Left _) -> do
          ec <- waitForProcess ph
          hClose outH
          pure
            ( Left
                ( "GPG session supervisor exited before ready: "
                    <> T.pack (show ec)
                )
            )
        Right (Right "ready") -> do
          hClose outH
          pure (Right (Supervisor {supReap = reap ph}))
        Right (Right other) -> do
          terminateProcess ph
          void (waitForProcess ph)
          hClose outH
          pure (Left ("GPG session supervisor sent " <> T.pack (show other)))
    reap ph = do
      terminateProcess ph
      void (waitForProcess ph)

-- | Set the parent-death signal, recheck the parent, then wait for @SIGTERM@.
runGpgSessionSupervisor :: FilePath -> IO ()
runGpgSessionSupervisor home = do
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
    then killSessionAgentDirect home
    else do
      hSetBuffering stdout LineBuffering
      putStrLn "ready"
      hFlush stdout
      void (takeMVar done)
      killSessionAgentDirect home

killSessionAgentDirect :: FilePath -> IO ()
killSessionAgentDirect home =
  void $
    try @IOException $
      readProcessWithExitCode
        "gpgconf"
        ["--homedir", home, "--kill", "gpg-agent"]
        ""

------------------------------------------------------------------------
-- Unlock
------------------------------------------------------------------------

unlockMany :: GpgHandle -> [WorktreeState] -> IO (Either Text ())
unlockMany handle = go Set.empty
  where
    go _ [] = pure (Right ())
    go seen (st : rest)
      | Set.member (wsKeygrip st) seen = go seen rest
      | otherwise = do
          unlocked <- unlockCold handle st
          case unlocked of
            Left err -> pure (Left err)
            Right () -> go (Set.insert (wsKeygrip st) seen) rest

unlockCold :: GpgHandle -> WorktreeState -> IO (Either Text ())
unlockCold handle st = do
  let ops = ghOps handle
  mHome <- lookupGpgSessionHome handle
  cached <- gaoKeyinfoCached ops mHome (wsKeygrip st)
  case cached of
    Left err -> pure (Left err)
    Right True -> pure (Right ())
    Right False -> do
      mTty <- gaoControllingTty ops
      case mTty of
        Nothing ->
          pure $
            Left
              ( "GPG signing key is locked and no controlling TTY is available "
                  <> "for interactive unlock (worktree key "
                  <> wsSigningKey st
                  <> "). Run from a terminal."
              )
        Just _ ->
          bracket_ (gaoPauseUi ops) (gaoResumeUi ops) $ do
            prompted <- gaoReadyPrompt ops
            case prompted of
              Left err -> pure (Left err)
              Right () -> gaoWarmKey ops mHome mTty (wsSigningKey st)

------------------------------------------------------------------------
-- Resolve worktree state
------------------------------------------------------------------------

resolveWorktree ::
  GpgAgentOps ->
  GpgHandle ->
  FilePath ->
  IO (Either Text WorktreeState)
resolveWorktree ops handle rootAbs = do
  byRoot <- readMVar (ghByRoot handle)
  case Map.lookup rootAbs byRoot of
    Just st -> pure (Right st)
    Nothing -> do
      mKey <- gaoGetSigningKey ops rootAbs
      case mKey of
        Left err -> pure (Left err)
        Right signingKey -> do
          mGrip <- gaoResolveKeygrip ops signingKey
          case mGrip of
            Left err -> pure (Left err)
            Right grip -> do
              let st =
                    WorktreeState
                      { wsSigningKey = signingKey,
                        wsKeygrip = grip
                      }
              modifyMVar_ (ghByRoot handle) $ pure . Map.insert rootAbs st
              pure (Right st)

------------------------------------------------------------------------
-- Production ops
------------------------------------------------------------------------

gitGetSigningKey :: CommandRunner -> FilePath -> IO (Either Text Text)
gitGetSigningKey run repoRoot = do
  rootAbs <- makeAbsolute repoRoot
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "git"
              ["-C", rootAbs, "config", "--get", "user.signingkey"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then
        Left
          ( "git config user.signingkey is unset for worktree "
              <> T.pack rootAbs
              <> "; set it for GPG-signed commits (no default-key fallback)."
              <> nullSuffix (prStderr res)
          )
      else
        let key = T.strip (T.pack (prStdout res))
         in if T.null key
              then
                Left
                  ( "git config user.signingkey is empty for worktree "
                      <> T.pack rootAbs
                  )
              else Right key

resolveKeygripViaGpg :: CommandRunner -> Text -> IO (Either Text Keygrip)
resolveKeygripViaGpg run signingKey = do
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "gpg"
              [ "--list-secret-keys",
                "--with-colons",
                "--with-keygrip",
                T.unpack signingKey
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res /= ExitSuccess
      then
        Left
          ( "could not list secret key for user.signingkey="
              <> signingKey
              <> nullSuffix (prStderr res)
          )
      else parseSignCapableKeygrip (prStdout res)

-- | From @gpg --list-secret-keys --with-colons --with-keygrip@ output, pick the
-- first secret key (sec\/ssb) whose capabilities include @s@ and return its
-- keygrip (@grp:@ line that follows the key record).
parseSignCapableKeygrip :: String -> Either Text Keygrip
parseSignCapableKeygrip out =
  case go (lines out) of
    Just g -> Right (Keygrip (T.pack g))
    Nothing ->
      Left
        "no sign-capable secret keygrip found for user.signingkey"
  where
    go [] = Nothing
    go (line : rest) =
      case colonFields line of
        ("sec" : fields) | hasSign fields -> takeGrip rest
        ("ssb" : fields) | hasSign fields -> takeGrip rest
        _ -> go rest
    hasSign fields =
      -- capabilities are field 12 in colon format (index 11 after type).
      case drop 10 fields of
        (caps : _) -> 's' `elem` caps
        [] -> False
    takeGrip [] = Nothing
    takeGrip (line : rest) =
      case colonFields line of
        ("grp" : fields) ->
          case drop 8 fields of
            (g : _) | not (null g) -> Just g
            _ -> takeGrip rest
        ("sec" : _) -> Nothing
        ("ssb" : _) -> Nothing
        _ -> takeGrip rest

colonFields :: String -> [String]
colonFields = splitOn ':'
  where
    splitOn _ [] = [""]
    splitOn c s =
      case break (== c) s of
        (a, []) -> [a]
        (a, _ : b) -> a : splitOn c b

keyinfoCached :: CommandRunner -> Maybe FilePath -> Keygrip -> IO (Either Text Bool)
keyinfoCached _ Nothing _ =
  pure (Left "GPG session home is not active")
keyinfoCached run (Just home) (Keygrip grip) = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "gpg-connect-agent" ["--homedir", home],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "KEYINFO " <> T.unpack grip <> "\n"
        }
  pure $
    if prExitCode res /= ExitSuccess
      then
        Left
          ( "gpg-connect-agent KEYINFO failed for keygrip "
              <> grip
              <> nullSuffix (prStderr res)
          )
      else parseKeyinfoCached (prStdout res) grip

-- | Parse @S KEYINFO <grip> <type> <serial> <idstr> <cached> …@ lines.
-- @cached@ is @1@ (warm) or @-@ (cold).
parseKeyinfoCached :: String -> Text -> Either Text Bool
parseKeyinfoCached out grip =
  case mapMaybe match (lines out) of
    (b : _) -> Right b
    [] ->
      Left
        ( "could not parse KEYINFO for keygrip "
            <> grip
            <> ": "
            <> T.pack (take 200 out)
        )
  where
    match line =
      case words line of
        ("S" : "KEYINFO" : g : _type : _serial : _idstr : cached : _)
          | T.pack g == grip ->
              case cached of
                "1" -> Just True
                "-" -> Just False
                _ -> Nothing
        _ -> Nothing

readyPromptOnTty :: IO (Either Text ())
readyPromptOnTty = do
  mTty <- controllingTtyPath
  case mTty of
    Nothing ->
      pure $
        Left
          "no controlling TTY for GPG ready-prompt; run from a terminal"
    Just tty -> do
      result <-
        try $
          withFile tty ReadWriteMode $ \h -> do
            hPutStr
              h
              "Press Enter when ready to unlock GPG for signed commits…\n"
            hFlush h
            _ <- hGetLine h
            pure ()
      pure $ case result of
        Left (e :: IOException) ->
          Left
            ( "failed to prompt on controlling TTY: "
                <> T.pack (show e)
            )
        Right () -> Right ()

warmKeyDummy ::
  CommandRunner ->
  Maybe FilePath ->
  Maybe FilePath ->
  Text ->
  IO (Either Text ())
warmKeyDummy run mHome mTty signingKey = do
  env0 <- getEnvironment
  let env1 = pinentryChildEnv mTty mHome env0
      homeArgs = case mHome of
        Just home | not (null home) -> ["--homedir", home]
        _ -> []
  hPutStr stderr "Unlocking GPG signing key (TTY pinentry)…\n"
  hFlush stderr
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "gpg"
              ( homeArgs
                  <> [ "--local-user",
                       T.unpack signingKey,
                       "--clearsign",
                       "--output",
                       "-",
                       "--yes"
                     ]
              ),
          prCwd = Nothing,
          prEnv = Just env1,
          prStdin = "mndz-overlay-manager gpg readiness warm\n"
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( "GPG unlock (clearsign warm) failed for user.signingkey="
              <> signingKey
              <> nullSuffix (prStderr res)
          )

killSessionAgent :: CommandRunner -> FilePath -> IO ()
killSessionAgent run home = do
  _ <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "gpgconf"
              ["--homedir", home, "--kill", "gpg-agent"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure ()

controllingTtyPath :: IO (Maybe FilePath)
controllingTtyPath = do
  ok <- doesFileExist "/dev/tty"
  if not ok
    then pure Nothing
    else do
      opened <- try openOk
      pure $ case opened of
        Left (_ :: IOException) -> Nothing
        Right () -> Just "/dev/tty"
  where
    openOk = withFile "/dev/tty" ReadWriteMode $ \(_ :: Handle) -> pure ()

nullSuffix :: String -> Text
nullSuffix err =
  let t = T.strip (T.pack err)
   in if T.null t then "" else ": " <> t
