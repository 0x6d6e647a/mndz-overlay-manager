{-# LANGUAGE OverloadedStrings #-}

module Update.Git
  ( isGitWorkTree,
    pathsDirty,
    gitAddAndSignedCommit,
    gitPush,
    gitRevParseHead,
    relativeOverlayPath,
    GitOps (..),
    productionGitOps,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Metrics.Core (Metrics)
import Metrics.Process (timedRunner)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, normalise)
import Update.GpgAgent
  ( GpgHandle,
    ensureGpgReady,
    signingChildEnv,
  )
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Injectable git operations for tests.
data GitOps = GitOps
  { goIsWorkTree :: FilePath -> IO Bool,
    goPathsDirty :: FilePath -> [FilePath] -> IO (Either Text Bool),
    goAddAndCommit :: FilePath -> [FilePath] -> Text -> IO (Either Text ()),
    goPush :: FilePath -> IO (Either Text ()),
    -- | @git rev-parse HEAD@ in @dir@ (sidecar commit SHA for target_commitish).
    goRevParseHead :: FilePath -> IO (Either Text Text)
  }

-- | Production git ops: GPG readiness before every signed commit, TTY pinentry
-- environment for @git commit -S@. Each git call is a measured @proc@ span.
productionGitOps :: Metrics -> GpgHandle -> GitOps
productionGitOps m gpg =
  GitOps
    { goIsWorkTree = isGitWorkTree run,
      goPathsDirty = pathsDirty run,
      goAddAndCommit = gitAddAndSignedCommit run gpg,
      goPush = gitPush run,
      goRevParseHead = gitRevParseHead run
    }
  where
    run = timedRunner m productionCommandRunner

-- | @git args@ with captured output.
gitRead :: CommandRunner -> [String] -> IO (ExitCode, String, String)
gitRead run = gitReadWith run Timed Nothing

-- | @git args@ with the given measure and optional child environment.
gitReadWith ::
  CommandRunner ->
  Measure ->
  Maybe [(String, String)] ->
  [String] ->
  IO (ExitCode, String, String)
gitReadWith run measure env args = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "git" args,
          prCwd = Nothing,
          prEnv = env,
          prStdin = "",
          prMeasure = measure
        }
  pure (prExitCode res, prStdout res, prStderr res)

-- | True if @dir@ is inside a git work tree.
isGitWorkTree :: CommandRunner -> FilePath -> IO Bool
isGitWorkTree run dir = do
  (code, out, _) <-
    gitRead run ["-C", dir, "rev-parse", "--is-inside-work-tree"]
  pure $ code == ExitSuccess && "true" `T.isInfixOf` T.strip (T.pack out)

-- | Whether any of the given paths (relative to overlay or absolute under it)
-- are dirty (staged or unstaged) relative to HEAD.
pathsDirty :: CommandRunner -> FilePath -> [FilePath] -> IO (Either Text Bool)
pathsDirty run overlayRoot relPaths = do
  rootAbs <- makeAbsolute overlayRoot
  (code, out, err) <-
    gitRead run (["-C", rootAbs, "status", "--porcelain", "--"] <> relPaths)
  pure $
    if code /= ExitSuccess
      then Left ("git status failed: " <> T.pack err)
      else Right (not (null (lines out)))

-- | Stage only the given pathspecs and create a signed commit after GPG readiness.
gitAddAndSignedCommit ::
  CommandRunner ->
  GpgHandle ->
  FilePath ->
  [FilePath] ->
  Text ->
  IO (Either Text ())
gitAddAndSignedCommit run gpg overlayRoot relPaths message = do
  rootAbs <- makeAbsolute overlayRoot
  ready <- ensureGpgReady gpg rootAbs
  case ready of
    Left err -> pure (Left err)
    Right () -> do
      (codeAdd, _, errAdd) <-
        gitRead run (["-C", rootAbs, "add", "--"] <> relPaths)
      if codeAdd /= ExitSuccess
        then pure $ Left ("git add failed: " <> T.pack errAdd)
        else do
          env1 <- signingChildEnv gpg
          let commitArgs = ["-C", rootAbs, "commit", "-S", "-m", T.unpack message]
          -- Signing may prompt for a passphrase.
          (codeC, _, errC) <-
            gitReadWith run TimedInteractive (Just env1) commitArgs
          pure $
            if codeC == ExitSuccess
              then Right ()
              else Left ("git commit -S failed: " <> T.pack errC)

-- | @git rev-parse HEAD@ for the work tree at @dir@.
gitRevParseHead :: CommandRunner -> FilePath -> IO (Either Text Text)
gitRevParseHead run dir = do
  rootAbs <- makeAbsolute dir
  (code, out, err) <-
    gitRead run ["-C", rootAbs, "rev-parse", "HEAD"]
  pure $
    if code == ExitSuccess
      then Right (T.strip (T.pack out))
      else Left ("git rev-parse HEAD failed: " <> T.pack err)

-- | Push the current branch to its configured remote.
gitPush :: CommandRunner -> FilePath -> IO (Either Text ())
gitPush run root = do
  rootAbs <- makeAbsolute root
  -- SSH may prompt (agent confirm or key passphrase).
  (code, _, err) <-
    gitReadWith run TimedInteractive Nothing ["-C", rootAbs, "push"]
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("git push failed: " <> T.pack err)

-- | Path of @file@ relative to @overlayRoot@ (both absolute preferred).
relativeOverlayPath :: FilePath -> FilePath -> IO FilePath
relativeOverlayPath overlayRoot file = do
  rootAbs <- makeAbsolute overlayRoot
  fileAbs <- makeAbsolute file
  pure $ normalise (makeRelative rootAbs fileAbs)
