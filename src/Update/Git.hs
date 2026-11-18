{-# LANGUAGE OverloadedStrings #-}

module Update.Git
  ( isGitWorkTree,
    pathsDirty,
    gitAddAndSignedCommit,
    gitPush,
    gitPushCurrentBranch,
    gitRevParseHead,
    UpstreamSync (..),
    checkUpstreamSync,
    upstreamSyncError,
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

-- | Push only the current branch to its configured upstream, without
-- force, whatever @push.default@ the repository sets.
gitPushCurrentBranch :: CommandRunner -> FilePath -> IO (Either Text ())
gitPushCurrentBranch run root = do
  rootAbs <- makeAbsolute root
  -- SSH may prompt (agent confirm or key passphrase).
  (code, _, err) <-
    gitReadWith run TimedInteractive Nothing ["-C", rootAbs, "-c", "push.default=upstream", "push"]
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("git push failed: " <> T.strip (T.pack err))

-- | Path of @file@ relative to @overlayRoot@ (both absolute preferred).
relativeOverlayPath :: FilePath -> FilePath -> IO FilePath
relativeOverlayPath overlayRoot file = do
  rootAbs <- makeAbsolute overlayRoot
  fileAbs <- makeAbsolute file
  pure $ normalise (makeRelative rootAbs fileAbs)

-- | Where a worktree's current branch stands against its upstream.
data UpstreamSync
  = SyncDetached
  | -- | Branch.
    SyncNoUpstream Text
  | SyncInSync
  | -- | Branch, upstream, and the commits only on the local branch (count,
    -- then up to ten as @\<short-sha\> \<subject\>@).
    SyncAhead Text Text (Int, [Text])
  | -- | Branch, upstream, and the commits only on the upstream.
    SyncBehind Text Text (Int, [Text])
  | -- | Branch, upstream, local-only commits, upstream-only commits.
    SyncDiverged Text Text (Int, [Text]) (Int, [Text])
  deriving (Eq, Show)

-- | Resolve the branch and its upstream (failing before any fetch when
-- detached or without upstream), run @beforeFetch@ (the Git Operations
-- check), fetch the upstream's remote, and compare.
checkUpstreamSync :: CommandRunner -> IO (Either Text ()) -> FilePath -> IO (Either Text UpstreamSync)
checkUpstreamSync run beforeFetch dir = do
  (codeB, outB, _) <- gitRead run ["-C", dir, "symbolic-ref", "--quiet", "--short", "HEAD"]
  let branch = T.strip (T.pack outB)
  if codeB /= ExitSuccess || T.null branch
    then pure (Right SyncDetached)
    else do
      (codeU, outU, _) <- gitRead run ["-C", dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
      let upstream = T.strip (T.pack outU)
      if codeU /= ExitSuccess || T.null upstream
        then pure (Right (SyncNoUpstream branch))
        else do
          (codeR, outR, errR) <- gitRead run ["-C", dir, "config", "--get", "branch." <> T.unpack branch <> ".remote"]
          let remote = T.strip (T.pack outR)
          if codeR /= ExitSuccess || T.null remote
            then pure (Left ("could not read the remote of branch " <> branch <> ": " <> T.strip (T.pack errR)))
            else do
              health <- beforeFetch
              case health of
                Left err -> pure (Left err)
                Right () -> do
                  -- SSH may prompt (agent confirm or key passphrase).
                  (codeF, _, errF) <- gitReadWith run TimedInteractive Nothing ["-C", dir, "fetch", "--quiet", T.unpack remote]
                  if codeF /= ExitSuccess
                    then pure (Left ("git fetch " <> remote <> " failed: " <> T.strip (T.pack errF)))
                    else compareUpstream branch upstream
  where
    compareUpstream branch upstream = do
      (codeC, outC, errC) <- gitRead run ["-C", dir, "rev-list", "--left-right", "--count", "@{u}...HEAD"]
      case map (reads @Int) (words outC) of
        [[(behind, "")], [(ahead, "")]] | codeC == ExitSuccess -> do
          local <- if ahead > 0 then commits "@{u}..HEAD" else pure []
          remoteOnly <- if behind > 0 then commits "HEAD..@{u}" else pure []
          pure . Right $ case (ahead > 0, behind > 0) of
            (False, False) -> SyncInSync
            (True, False) -> SyncAhead branch upstream (ahead, local)
            (False, True) -> SyncBehind branch upstream (behind, remoteOnly)
            (True, True) -> SyncDiverged branch upstream (ahead, local) (behind, remoteOnly)
        _ -> pure (Left ("could not compare " <> branch <> " with " <> upstream <> ": " <> T.strip (T.pack errC)))
    commits range = do
      (code, out, _) <- gitRead run ["-C", dir, "log", "--format=%h %s", "--max-count=" <> show maxNamed, range]
      pure (if code == ExitSuccess then filter (not . T.null) (map T.strip (T.lines (T.pack out))) else [])
    maxNamed = 10 :: Int

-- | The refusal for a repository (@overlay@ or @assets@ worktree) that is
-- not in sync, or 'Nothing' when it is.
upstreamSyncError :: Text -> FilePath -> UpstreamSync -> Maybe Text
upstreamSyncError label dir = \case
  SyncInSync -> Nothing
  SyncDetached ->
    Just (label <> " " <> T.pack dir <> " is on a detached HEAD; check out a branch that tracks its upstream, then run update again")
  SyncNoUpstream branch ->
    Just (label <> " branch " <> branch <> " in " <> T.pack dir <> " has no upstream; set one with git branch --set-upstream-to, then run update again")
  SyncAhead branch upstream local ->
    Just (label <> " branch " <> branch <> " is ahead of " <> upstream <> " by " <> count local <> named local <> "; push or reconcile it, then run update again")
  SyncBehind branch upstream remote ->
    Just (label <> " branch " <> branch <> " is behind " <> upstream <> " by " <> count remote <> named remote <> "; pull it, then run update again")
  SyncDiverged branch upstream local remote ->
    Just
      ( label
          <> " branch "
          <> branch
          <> " has diverged from "
          <> upstream
          <> " (local only: "
          <> count local
          <> named local
          <> "; upstream only: "
          <> count remote
          <> named remote
          <> "); reconcile it, then run update again"
      )
  where
    count (n, _) = T.pack (show n) <> (if n == 1 then " commit" else " commits")
    named (_, cs) = " (" <> T.intercalate "; " cs <> ")"
