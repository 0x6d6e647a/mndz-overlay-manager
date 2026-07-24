{-# LANGUAGE OverloadedStrings #-}

module Update.SshAgent
  ( SshSession (..),
    AgentIdentities (..),
    ensureSshAgent,
    teardownSshSession,
    SshAgentOps (..),
    productionSshAgentOps,
    discoverIdentityFiles,
    defaultIdentityCandidates,
    parseIdentityFiles,
  )
where

import Control.Monad (filterM, unless)
import Data.Char (isAsciiUpper, isSpace)
import Data.Containers.ListUtils (nubOrd)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( doesFileExist,
    getHomeDirectory,
  )
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
  ( IOMode (ReadWriteMode),
    hFlush,
    hPutStrLn,
    stderr,
    stdout,
    withFile,
  )
import System.Process
  ( CreateProcess (..),
    StdStream (Inherit, UseHandle),
    proc,
    readProcessWithExitCode,
    waitForProcess,
    withCreateProcess,
  )

-- | SSH agent session for the process lifetime.
data SshSession
  = -- | Reused existing agent; do not kill on exit.
    SshSessionReused
  | -- | Agent we started; kill on exit.
    SshSessionOwned
      { ssAgentPid :: String
      }
  deriving (Eq, Show)

-- | Result of querying identities in the agent.
data AgentIdentities
  = -- | @ssh-add -l@ exit 0
    HasIdentities
  | -- | @ssh-add -l@ exit 1 (reachable, empty)
    NoIdentities
  | -- | @ssh-add -l@ exit 2 or other (unreachable)
    AgentUnreachable Text
  deriving (Eq, Show)

-- | Injectable SSH agent operations.
data SshAgentOps = SshAgentOps
  { saoLookupEnv :: String -> IO (Maybe String),
    saoSetEnv :: String -> String -> IO (),
    saoUnsetEnv :: String -> IO (),
    saoRunAgent :: IO (Either Text (String, String)), -- sock, pid

    -- | Interactive @ssh-add@ of discovered keys (TTY / askpass).
    saoSshAdd :: IO (Either Text ()),
    saoListIdentities :: IO AgentIdentities,
    saoKillAgent :: String -> IO ()
  }

productionSshAgentOps :: SshAgentOps
productionSshAgentOps =
  SshAgentOps
    { saoLookupEnv = lookupEnv,
      saoSetEnv = setEnv,
      saoUnsetEnv = unsetEnv,
      saoRunAgent = runSshAgent,
      saoSshAdd = runSshAddInteractive,
      saoListIdentities = listIdentities,
      saoKillAgent = killSshAgent
    }

-- | Ensure an SSH agent is available for git push.
--
-- The program starts @ssh-agent@ when needed and tears it down if we own it.
-- Keys are discovered from @~\/.ssh\/config@ @IdentityFile@ lines and default
-- paths (not only bare @ssh-add@ defaults).
ensureSshAgent :: SshAgentOps -> IO (Either Text SshSession)
ensureSshAgent ops = do
  mSock <- saoLookupEnv ops "SSH_AUTH_SOCK"
  case mSock of
    Just sock | not (null sock) -> ensureWithExistingSocket ops
    _ -> startFreshAgent ops

ensureWithExistingSocket :: SshAgentOps -> IO (Either Text SshSession)
ensureWithExistingSocket ops = do
  ids <- saoListIdentities ops
  case ids of
    HasIdentities -> pure (Right SshSessionReused)
    NoIdentities -> do
      hPutStrLn stderr "SSH agent has no identities; adding keys (passphrase prompt if needed)…"
      hFlush stderr
      added <- saoSshAdd ops
      case added of
        Left err -> pure (Left err)
        Right () -> confirmIdentities ops SshSessionReused
    AgentUnreachable err -> do
      hPutStrLn
        stderr
        ( "existing SSH agent unreachable ("
            <> T.unpack err
            <> "); starting a new one…"
        )
      hFlush stderr
      startFreshAgent ops

startFreshAgent :: SshAgentOps -> IO (Either Text SshSession)
startFreshAgent ops = do
  hPutStrLn stderr "Starting ssh-agent…"
  hFlush stderr
  started <- saoRunAgent ops
  case started of
    Left err -> pure (Left err)
    Right (sock, pid) -> do
      saoSetEnv ops "SSH_AUTH_SOCK" sock
      saoSetEnv ops "SSH_AGENT_PID" pid
      hPutStrLn
        stderr
        ( "ssh-agent ready (SSH_AUTH_SOCK="
            <> sock
            <> "); adding SSH keys…"
        )
      hFlush stderr
      added <- saoSshAdd ops
      case added of
        Left err -> do
          saoKillAgent ops pid
          saoUnsetEnv ops "SSH_AUTH_SOCK"
          saoUnsetEnv ops "SSH_AGENT_PID"
          pure (Left err)
        Right () -> confirmIdentities ops (SshSessionOwned pid)

confirmIdentities :: SshAgentOps -> SshSession -> IO (Either Text SshSession)
confirmIdentities ops session = do
  ids <- saoListIdentities ops
  pure $ case ids of
    HasIdentities -> Right session
    NoIdentities ->
      Left
        "ssh-add finished but the agent still has no identities"
    AgentUnreachable err ->
      Left ("SSH agent not usable after ssh-add: " <> err)

teardownSshSession :: SshAgentOps -> SshSession -> IO ()
teardownSshSession _ SshSessionReused = pure ()
teardownSshSession ops (SshSessionOwned pid) = do
  saoKillAgent ops pid
  saoUnsetEnv ops "SSH_AUTH_SOCK"
  saoUnsetEnv ops "SSH_AGENT_PID"

runSshAgent :: IO (Either Text (String, String))
runSshAgent = do
  (code, out, err) <- readProcessWithExitCode "ssh-agent" ["-s"] ""
  if code /= ExitSuccess
    then pure $ Left ("ssh-agent failed: " <> T.pack (nullToDash err out))
    else pure $ parseAgentEnv out

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

------------------------------------------------------------------------
-- Key discovery
------------------------------------------------------------------------

-- | OpenSSH default private key paths (relative to home @.ssh@).
defaultIdentityCandidates :: FilePath -> [FilePath]
defaultIdentityCandidates sshDir =
  map
    (sshDir </>)
    [ "id_rsa",
      "id_ecdsa",
      "id_ecdsa_sk",
      "id_ed25519",
      "id_ed25519_sk",
      "id_xmss",
      "id_dsa"
    ]

-- | Discover private key paths: @IdentityFile@ from @~\/.ssh\/config@ plus
-- default identity names that exist on disk.
discoverIdentityFiles :: IO [FilePath]
discoverIdentityFiles = do
  home <- getHomeDirectory
  let sshDir = home </> ".ssh"
      configPath = sshDir </> "config"
  configExists <- doesFileExist configPath
  fromConfig <-
    if configExists
      then parseIdentityFiles home <$> readFile configPath
      else pure []
  let defaults = defaultIdentityCandidates sshDir
  filterM doesFileExist (nubOrd (fromConfig <> defaults))

-- | Collect @IdentityFile@ values from an OpenSSH config body.
parseIdentityFiles :: FilePath -> String -> [FilePath]
parseIdentityFiles home =
  mapMaybe (parseIdentityLine home) . lines

parseIdentityLine :: FilePath -> String -> Maybe FilePath
parseIdentityLine home raw =
  let line = trim (takeWhile (/= '#') raw)
      ws = words line
   in case ws of
        (kw : path : _)
          | map toLower kw == "identityfile" ->
              Just (expandTilde home path)
        _ -> Nothing
  where
    toLower c
      | isAsciiUpper c = toEnum (fromEnum c + 32)
      | otherwise = c
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

expandTilde :: FilePath -> FilePath -> FilePath
expandTilde home path =
  case path of
    '~' : '/' : rest -> home </> rest
    "~" -> home
    _ -> path

------------------------------------------------------------------------
-- Interactive ssh-add
------------------------------------------------------------------------

-- | Add discovered keys. Prefer @\/dev\/tty@ for passphrase prompts; fall back
-- to @SSH_ASKPASS@ (e.g. ksshaskpass) when no controlling TTY is available.
runSshAddInteractive :: IO (Either Text ())
runSshAddInteractive = do
  keys <- discoverIdentityFiles
  case keys of
    [] ->
      pure $
        Left
          ( "no SSH private keys found. Expected IdentityFile entries in "
              <> "~/.ssh/config and/or default keys under ~/.ssh/id_*. "
              <> "Your GitHub key may live under ~/.ssh/keys/ — ensure it is "
              <> "listed as IdentityFile for github.com."
          )
    _ -> do
      hPutStrLn stderr ("Adding keys: " <> unwords keys)
      hFlush stderr
      addKeysWithPrompt keys

addKeysWithPrompt :: [FilePath] -> IO (Either Text ())
addKeysWithPrompt keys = do
  ttyOk <- canUseDevTty
  if ttyOk
    then sshAddWithDevTty keys
    else sshAddWithAskPass keys

canUseDevTty :: IO Bool
canUseDevTty = doesFileExist "/dev/tty"

-- | Open @\/dev\/tty@ so ssh-add can prompt even when stdio is not a TTY.
sshAddWithDevTty :: [FilePath] -> IO (Either Text ())
sshAddWithDevTty keys =
  withFile "/dev/tty" ReadWriteMode $ \tty -> do
    hPutStrLn
      stderr
      "Using /dev/tty for ssh-add passphrase prompt…"
    hFlush stderr
    env0 <- getEnvironment
    let cp =
          (proc "ssh-add" keys)
            { std_in = UseHandle tty,
              std_out = Inherit,
              std_err = Inherit,
              env = Just env0
            }
    runSshAddProcess cp keys "tty"

-- | Force GUI/CLI askpass when there is no usable controlling terminal.
sshAddWithAskPass :: [FilePath] -> IO (Either Text ())
sshAddWithAskPass keys = do
  askPass <- findAskPass
  case askPass of
    Nothing ->
      pure $
        Left
          ( "cannot prompt for SSH key passphrase: no controlling TTY and no "
              <> "ssh-askpass helper (install ksshaskpass or ssh-askpass, or run "
              <> "from a real terminal). Keys: "
              <> T.pack (unwords keys)
          )
    Just askPath -> do
      display <- lookupEnv "DISPLAY"
      wayland <- lookupEnv "WAYLAND_DISPLAY"
      unless (maybe False (not . null) display || maybe False (not . null) wayland) $
        hPutStrLn
          stderr
          "warning: DISPLAY/WAYLAND_DISPLAY unset; askpass may fail"
      hPutStrLn
        stderr
        ("Using SSH_ASKPASS=" <> askPath <> " for passphrase prompt…")
      hFlush stderr
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
            (proc "ssh-add" keys)
              { std_in = Inherit,
                std_out = Inherit,
                std_err = Inherit,
                env = Just env1
              }
      runSshAddProcess cp keys "askpass"

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

runSshAddProcess :: CreateProcess -> [FilePath] -> String -> IO (Either Text ())
runSshAddProcess cp keys mode = do
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
                <> ") for keys: "
                <> T.pack (unwords keys)
                <> ". Unlock manually with: ssh-add "
                <> T.pack (unwords keys)
            )

listIdentities :: IO AgentIdentities
listIdentities = do
  (code, out, err) <- readProcessWithExitCode "ssh-add" ["-l"] ""
  pure $ case code of
    ExitSuccess -> HasIdentities
    ExitFailure 1 -> NoIdentities
    ExitFailure n ->
      AgentUnreachable $
        "ssh-add -l exit "
          <> T.pack (show n)
          <> ": "
          <> T.pack (nullToDash err out)

killSshAgent :: String -> IO ()
killSshAgent pid = do
  _ <- readProcessWithExitCode "kill" [pid] ""
  pure ()

nullToDash :: String -> String -> String
nullToDash primary fallback =
  case (primary, fallback) of
    ("", "") -> "(no output)"
    ("", fb) -> fb
    (p, _) -> p
