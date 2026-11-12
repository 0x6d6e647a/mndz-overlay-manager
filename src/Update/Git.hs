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

import Data.Aeson ((.=))
import Data.Text (Text)
import Data.Text qualified as T
import Metrics.Core (Attrs, Metrics)
import Metrics.Process (wallClockProc)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, normalise)
import System.Process
  ( CreateProcess (..),
    proc,
    readCreateProcessWithExitCode,
    readProcessWithExitCode,
  )
import Update.GpgAgent
  ( GpgHandle,
    ensureGpgReady,
    signingChildEnv,
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
-- environment for @git commit -S@. Each git call is a wall-clock @proc@ span.
productionGitOps :: Metrics -> GpgHandle -> GitOps
productionGitOps m gpg =
  GitOps
    { goIsWorkTree = isGitWorkTree m,
      goPathsDirty = pathsDirty m,
      goAddAndCommit = gitAddAndSignedCommit m gpg,
      goPush = gitPush m,
      goRevParseHead = gitRevParseHead m
    }

-- | @git args@ with captured output, recorded as a wall-clock @proc@ span.
gitRead :: Metrics -> Attrs -> [String] -> IO (ExitCode, String, String)
gitRead m extra args =
  wallClockProc m "git" args Nothing extra (\(c, _, _) -> Just c) $
    readProcessWithExitCode "git" args ""

-- | True if @dir@ is inside a git work tree.
isGitWorkTree :: Metrics -> FilePath -> IO Bool
isGitWorkTree m dir = do
  (code, out, _) <-
    gitRead m [] ["-C", dir, "rev-parse", "--is-inside-work-tree"]
  pure $ code == ExitSuccess && "true" `T.isInfixOf` T.strip (T.pack out)

-- | Whether any of the given paths (relative to overlay or absolute under it)
-- are dirty (staged or unstaged) relative to HEAD.
pathsDirty :: Metrics -> FilePath -> [FilePath] -> IO (Either Text Bool)
pathsDirty m overlayRoot relPaths = do
  rootAbs <- makeAbsolute overlayRoot
  (code, out, err) <-
    gitRead m [] (["-C", rootAbs, "status", "--porcelain", "--"] <> relPaths)
  pure $
    if code /= ExitSuccess
      then Left ("git status failed: " <> T.pack err)
      else Right (not (null (lines out)))

-- | Stage only the given pathspecs and create a signed commit after GPG readiness.
gitAddAndSignedCommit ::
  Metrics ->
  GpgHandle ->
  FilePath ->
  [FilePath] ->
  Text ->
  IO (Either Text ())
gitAddAndSignedCommit m gpg overlayRoot relPaths message = do
  rootAbs <- makeAbsolute overlayRoot
  ready <- ensureGpgReady gpg rootAbs
  case ready of
    Left err -> pure (Left err)
    Right () -> do
      (codeAdd, _, errAdd) <-
        gitRead m [] (["-C", rootAbs, "add", "--"] <> relPaths)
      if codeAdd /= ExitSuccess
        then pure $ Left ("git add failed: " <> T.pack errAdd)
        else do
          env1 <- signingChildEnv gpg
          let commitArgs = ["-C", rootAbs, "commit", "-S", "-m", T.unpack message]
              cp = (proc "git" commitArgs) {env = Just env1}
          -- Signing may prompt for a passphrase.
          (codeC, _, errC) <-
            wallClockProc m "git" commitArgs Nothing ["interactive" .= True] (\(c, _, _) -> Just c) $
              readCreateProcessWithExitCode cp ""
          pure $
            if codeC == ExitSuccess
              then Right ()
              else Left ("git commit -S failed: " <> T.pack errC)

-- | @git rev-parse HEAD@ for the work tree at @dir@.
gitRevParseHead :: Metrics -> FilePath -> IO (Either Text Text)
gitRevParseHead m dir = do
  rootAbs <- makeAbsolute dir
  (code, out, err) <-
    gitRead m [] ["-C", rootAbs, "rev-parse", "HEAD"]
  pure $
    if code == ExitSuccess
      then Right (T.strip (T.pack out))
      else Left ("git rev-parse HEAD failed: " <> T.pack err)

-- | Push the current branch to its configured remote.
gitPush :: Metrics -> FilePath -> IO (Either Text ())
gitPush m root = do
  rootAbs <- makeAbsolute root
  -- SSH may prompt (agent confirm or key passphrase).
  (code, _, err) <-
    gitRead m ["interactive" .= True] ["-C", rootAbs, "push"]
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
