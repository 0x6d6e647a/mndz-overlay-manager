{-# LANGUAGE OverloadedStrings #-}

module Update.Git
  ( isGitWorkTree,
    pathsDirty,
    gitAddAndSignedCommit,
    relativeOverlayPath,
    GitOps (..),
    productionGitOps,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, normalise)
import System.Process (readProcessWithExitCode)

-- | Injectable git operations for tests.
data GitOps = GitOps
  { goIsWorkTree :: FilePath -> IO Bool,
    goPathsDirty :: FilePath -> [FilePath] -> IO (Either Text Bool),
    goAddAndCommit :: FilePath -> [FilePath] -> Text -> IO (Either Text ())
  }

productionGitOps :: GitOps
productionGitOps =
  GitOps
    { goIsWorkTree = isGitWorkTree,
      goPathsDirty = pathsDirty,
      goAddAndCommit = gitAddAndSignedCommit
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

-- | Stage only the given pathspecs and create a signed commit.
gitAddAndSignedCommit :: FilePath -> [FilePath] -> Text -> IO (Either Text ())
gitAddAndSignedCommit overlayRoot relPaths message = do
  rootAbs <- makeAbsolute overlayRoot
  (codeAdd, _, errAdd) <-
    readProcessWithExitCode
      "git"
      (["-C", rootAbs, "add", "--"] <> relPaths)
      ""
  if codeAdd /= ExitSuccess
    then pure $ Left ("git add failed: " <> T.pack errAdd)
    else do
      (codeC, _, errC) <-
        readProcessWithExitCode
          "git"
          [ "-C",
            rootAbs,
            "commit",
            "-S",
            "-m",
            T.unpack message
          ]
          ""
      pure $
        if codeC == ExitSuccess
          then Right ()
          else Left ("git commit -S failed: " <> T.pack errC)

-- | Path of @file@ relative to @overlayRoot@ (both absolute preferred).
relativeOverlayPath :: FilePath -> FilePath -> IO FilePath
relativeOverlayPath overlayRoot file = do
  rootAbs <- makeAbsolute overlayRoot
  fileAbs <- makeAbsolute file
  pure $ normalise (makeRelative rootAbs fileAbs)
