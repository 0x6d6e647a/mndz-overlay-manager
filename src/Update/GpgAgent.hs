{-# LANGUAGE OverloadedStrings #-}

module Update.GpgAgent
  ( Keygrip (..),
    GpgAgentOps (..),
    GpgHandle,
    productionGpgAgentOps,
    newGpgHandle,
    ensureGpgReady,
    teardownGpgHandle,
    pinentryChildEnv,
    lookupControllingTty,
    parseSignCapableKeygrip,
    parseKeyinfoCached,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar, withMVar)
import Control.Exception (IOException, bracket_, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO
  ( Handle,
    IOMode (ReadWriteMode),
    hFlush,
    hGetLine,
    hPutStr,
    stderr,
    withFile,
  )
import System.Process
  ( CreateProcess (..),
    proc,
    readCreateProcessWithExitCode,
    readProcessWithExitCode,
  )

-- | GPG keygrip (hex string).
newtype Keygrip = Keygrip {unKeygrip :: Text}
  deriving (Eq, Ord, Show)

-- | Per-worktree readiness bookkeeping.
data WorktreeState = WorktreeState
  { wsSigningKey :: Text,
    wsKeygrip :: Keygrip,
    wsWeWarmed :: Bool
  }
  deriving (Eq, Show)

-- | Process-lifetime GPG readiness handle.
data GpgHandle = GpgHandle
  { ghOps :: GpgAgentOps,
    ghLock :: MVar (),
    ghByRoot :: MVar (Map FilePath WorktreeState),
    ghWarmed :: MVar (Set Keygrip)
  }

-- | Injectable GPG agent operations (unit tests without live pinentry).
data GpgAgentOps = GpgAgentOps
  { -- | @git -C <repo> config --get user.signingkey@
    gaoGetSigningKey :: FilePath -> IO (Either Text Text),
    -- | Map signing key id to a sign-capable secret keygrip.
    gaoResolveKeygrip :: Text -> IO (Either Text Keygrip),
    -- | KEYINFO cached? @True@ = warm, @False@ = cold.
    gaoKeyinfoCached :: Keygrip -> IO (Either Text Bool),
    -- | Ready-prompt on controlling TTY (Enter to continue).
    gaoReadyPrompt :: IO (Either Text ()),
    -- | Dummy warm (clearsign) under TTY pinentry env for the signing key id.
    gaoWarmKey :: Text -> IO (Either Text ()),
    -- | Clear cached passphrase for a keygrip.
    gaoClearPassphrase :: Keygrip -> IO (),
    -- | Controlling tty path if available (e.g. @\/dev\/tty@).
    gaoControllingTty :: IO (Maybe FilePath),
    -- | Pause activity indicators (clear panel) before interactive unlock.
    gaoPauseUi :: IO (),
    -- | Resume activity indicators after interactive unlock.
    gaoResumeUi :: IO ()
  }

-- | Production ops. Pass pause\/resume from 'CLI.Progress' panel controls.
productionGpgAgentOps :: IO () -> IO () -> GpgAgentOps
productionGpgAgentOps pauseUi resumeUi =
  GpgAgentOps
    { gaoGetSigningKey = gitGetSigningKey,
      gaoResolveKeygrip = resolveKeygripViaGpg,
      gaoKeyinfoCached = keyinfoCached,
      gaoReadyPrompt = readyPromptOnTty,
      gaoWarmKey = warmKeyDummy,
      gaoClearPassphrase = clearPassphrase,
      gaoControllingTty = controllingTtyPath,
      gaoPauseUi = pauseUi,
      gaoResumeUi = resumeUi
    }

-- | Create a process-lifetime handle.
newGpgHandle :: GpgAgentOps -> IO GpgHandle
newGpgHandle ops = do
  lock <- newMVar ()
  byRoot <- newMVar Map.empty
  warmed <- newMVar Set.empty
  pure $
    GpgHandle
      { ghOps = ops,
        ghLock = lock,
        ghByRoot = byRoot,
        ghWarmed = warmed
      }

-- | Ensure the worktree’s signing key is ready for @git commit -S@.
--
-- Cold cache: ready-prompt then dummy warm; marks keygrip as warmed by us.
-- Warm cache: no prompt. Missing @user.signingkey@ \/ no TTY when unlock is
-- required: hard failure.
ensureGpgReady :: GpgHandle -> FilePath -> IO (Either Text ())
ensureGpgReady handle repoRoot =
  withMVar (ghLock handle) $ \() -> do
    rootAbs <- makeAbsolute repoRoot
    let ops = ghOps handle
    resolved <- resolveWorktree ops handle rootAbs
    case resolved of
      Left err -> pure (Left err)
      Right st -> do
        cached <- gaoKeyinfoCached ops (wsKeygrip st)
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
                        <> "for interactive unlock (worktree: "
                        <> T.pack rootAbs
                        <> "). Run from a terminal."
                    )
              Just _ ->
                -- Clear activity indicators so ready-prompt / pinentry own the TTY.
                bracket_ (gaoPauseUi ops) (gaoResumeUi ops) $ do
                  prompted <- gaoReadyPrompt ops
                  case prompted of
                    Left err -> pure (Left err)
                    Right () -> do
                      warmed <- gaoWarmKey ops (wsSigningKey st)
                      case warmed of
                        Left err -> pure (Left err)
                        Right () -> do
                          markWarmed handle rootAbs (wsKeygrip st)
                          pure (Right ())

-- | Clear passphrases only for keygrips this process warmed.
teardownGpgHandle :: GpgHandle -> IO ()
teardownGpgHandle handle = do
  grips <- readMVar (ghWarmed handle)
  mapM_ (gaoClearPassphrase (ghOps handle)) (Set.toList grips)

-- | Child environment for GPG unlock \/ @git commit -S@: set @GPG_TTY@ when a
-- controlling tty exists; clear @DISPLAY@ so pinentry prefers TTY over GUI.
-- Parent process environment is left unchanged.
pinentryChildEnv :: Maybe FilePath -> [(String, String)] -> [(String, String)]
pinentryChildEnv mTty parentEnv =
  let withoutDisplay =
        filter (\(k, _) -> k /= "DISPLAY" && k /= "GPG_TTY") parentEnv
   in case mTty of
        Just tty | not (null tty) -> ("GPG_TTY", tty) : withoutDisplay
        _ -> withoutDisplay

-- | Controlling tty path from a handle’s ops (for signed-commit child env).
lookupControllingTty :: GpgHandle -> IO (Maybe FilePath)
lookupControllingTty handle = gaoControllingTty (ghOps handle)

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
                        wsKeygrip = grip,
                        wsWeWarmed = False
                      }
              modifyMVar_ (ghByRoot handle) $ pure . Map.insert rootAbs st
              pure (Right st)

markWarmed :: GpgHandle -> FilePath -> Keygrip -> IO ()
markWarmed handle rootAbs grip = do
  modifyMVar_ (ghByRoot handle) $ \m ->
    pure $
      Map.adjust (\st -> st {wsWeWarmed = True}) rootAbs m
  modifyMVar_ (ghWarmed handle) $ pure . Set.insert grip

------------------------------------------------------------------------
-- Production ops
------------------------------------------------------------------------

gitGetSigningKey :: FilePath -> IO (Either Text Text)
gitGetSigningKey repoRoot = do
  rootAbs <- makeAbsolute repoRoot
  (code, out, err) <-
    readProcessWithExitCode
      "git"
      ["-C", rootAbs, "config", "--get", "user.signingkey"]
      ""
  pure $
    if code /= ExitSuccess
      then
        Left
          ( "git config user.signingkey is unset for worktree "
              <> T.pack rootAbs
              <> "; set it for GPG-signed commits (no default-key fallback)."
              <> nullSuffix err
          )
      else
        let key = T.strip (T.pack out)
         in if T.null key
              then
                Left
                  ( "git config user.signingkey is empty for worktree "
                      <> T.pack rootAbs
                  )
              else Right key

resolveKeygripViaGpg :: Text -> IO (Either Text Keygrip)
resolveKeygripViaGpg signingKey = do
  (code, out, err) <-
    readProcessWithExitCode
      "gpg"
      [ "--list-secret-keys",
        "--with-colons",
        "--with-keygrip",
        T.unpack signingKey
      ]
      ""
  pure $
    if code /= ExitSuccess
      then
        Left
          ( "could not list secret key for user.signingkey="
              <> signingKey
              <> nullSuffix err
          )
      else parseSignCapableKeygrip out

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

keyinfoCached :: Keygrip -> IO (Either Text Bool)
keyinfoCached (Keygrip grip) = do
  (code, out, err) <-
    readProcessWithExitCode
      "gpg-connect-agent"
      []
      ("KEYINFO " <> T.unpack grip <> "\n")
  pure $
    if code /= ExitSuccess
      then
        Left
          ( "gpg-connect-agent KEYINFO failed for keygrip "
              <> grip
              <> nullSuffix err
          )
      else parseKeyinfoCached out grip

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

warmKeyDummy :: Text -> IO (Either Text ())
warmKeyDummy signingKey = do
  mTty <- controllingTtyPath
  env0 <- getEnvironment
  let env1 = pinentryChildEnv mTty env0
      cp =
        ( proc
            "gpg"
            [ "--local-user",
              T.unpack signingKey,
              "--clearsign",
              "--output",
              "-",
              "--yes"
            ]
        )
          { env = Just env1
          }
  hPutStr stderr "Unlocking GPG signing key (TTY pinentry)…\n"
  hFlush stderr
  (code, _out, err) <-
    readCreateProcessWithExitCode
      cp
      "mndz-overlay-manager gpg readiness warm\n"
  pure $
    if code == ExitSuccess
      then Right ()
      else
        Left
          ( "GPG unlock (clearsign warm) failed for user.signingkey="
              <> signingKey
              <> nullSuffix err
          )

clearPassphrase :: Keygrip -> IO ()
clearPassphrase (Keygrip grip) = do
  _ <-
    readProcessWithExitCode
      "gpg-connect-agent"
      []
      ("CLEAR_PASSPHRASE --mode=normal " <> T.unpack grip <> "\n")
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
