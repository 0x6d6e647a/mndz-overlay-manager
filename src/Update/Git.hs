{-# LANGUAGE OverloadedStrings #-}

module Update.Git
  ( isGitWorkTree,
    pathsDirty,
    gitAddAndSignedCommit,
    gitPush,
    relativeOverlayPath,
    GitOps (..),
    productionGitOps,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (makeAbsolute)
import System.Environment (getEnvironment)
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
    lookupControllingTty,
    pinentryChildEnv,
  )

-- | Injectable git operations for tests.
data GitOps = GitOps
  { goIsWorkTree :: FilePath -> IO Bool,
    goPathsDirty :: FilePath -> [FilePath] -> IO (Either Text Bool),
    goAddAndCommit :: FilePath -> [FilePath] -> Text -> IO (Either Text ()),
    goPush :: FilePath -> IO (Either Text ())
  }

-- | Production git ops: GPG readiness before every signed commit, TTY pinentry
-- environment for @git commit -S@.
productionGitOps :: GpgHandle -> GitOps
productionGitOps gpg =
  GitOps
    { goIsWorkTree = isGitWorkTree,
      goPathsDirty = pathsDirty,
      goAddAndCommit = gitAddAndSignedCommit gpg,
      goPush = gitPush
    }

-- | True if @dir@ is inside a git work tree.
isGitWorkTree :: FilePath -> IO Bool
isGitWorkTree dir = do
  (code, out, _) <-
    readProcessWithExitCode
      "git"
      ["-C", dir, "rev-parse", "--is-inside-work-tree"]
      ""
  pure $ code == ExitSuccess && "true" `T.isInfixOf` T.strip (T.pack out)

-- | Whether any of the given paths (relative to overlay or absolute under it)
-- are dirty (staged or unstaged) relative to HEAD.
pathsDirty :: FilePath -> [FilePath] -> IO (Either Text Bool)
pathsDirty overlayRoot relPaths = do
  rootAbs <- makeAbsolute overlayRoot
  (code, out, err) <-
    readProcessWithExitCode
      "git"
      (["-C", rootAbs, "status", "--porcelain", "--"] <> relPaths)
      ""
  pure $
    if code /= ExitSuccess
      then Left ("git status failed: " <> T.pack err)
      else Right (not (null (lines out)))

-- | Stage only the given pathspecs and create a signed commit after GPG readiness.
gitAddAndSignedCommit ::
  GpgHandle ->
  FilePath ->
  [FilePath] ->
  Text ->
  IO (Either Text ())
gitAddAndSignedCommit gpg overlayRoot relPaths message = do
  rootAbs <- makeAbsolute overlayRoot
  ready <- ensureGpgReady gpg rootAbs
  case ready of
    Left err -> pure (Left err)
    Right () -> do
      (codeAdd, _, errAdd) <-
        readProcessWithExitCode
          "git"
          (["-C", rootAbs, "add", "--"] <> relPaths)
          ""
      if codeAdd /= ExitSuccess
        then pure $ Left ("git add failed: " <> T.pack errAdd)
        else do
          mTty <- lookupControllingTty gpg
          env0 <- getEnvironment
          let env1 = pinentryChildEnv mTty env0
              cp =
                ( proc
                    "git"
                    [ "-C",
                      rootAbs,
                      "commit",
                      "-S",
                      "-m",
                      T.unpack message
                    ]
                )
                  { env = Just env1
                  }
          (codeC, _, errC) <- readCreateProcessWithExitCode cp ""
          pure $
            if codeC == ExitSuccess
              then Right ()
              else Left ("git commit -S failed: " <> T.pack errC)

-- | Push the current branch to its configured remote.
gitPush :: FilePath -> IO (Either Text ())
gitPush root = do
  rootAbs <- makeAbsolute root
  (code, _, err) <-
    readProcessWithExitCode
      "git"
      ["-C", rootAbs, "push"]
      ""
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
