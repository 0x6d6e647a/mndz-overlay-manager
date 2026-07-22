{-# LANGUAGE OverloadedStrings #-}

module Update.Preflight
  ( updateRequiredTools,
    goAssetsRequiredTools,
    checkToolsOnPath,
    preflightUpdate,
    preflightUpdateWith,
    validateAssetsPath,
  )
where

import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, findExecutable)
import Update.Git (isGitWorkTree)

-- | External tools required on PATH for every @update@ run.
updateRequiredTools :: [String]
updateRequiredTools = ["git", "ebuild", "egencache", "gpg"]

-- | Additional tools when a Go/assets technique will apply.
goAssetsRequiredTools :: [String]
goAssetsRequiredTools = ["go", "xz"]

-- | Check that each tool name is findable on PATH.
-- Returns missing tool names (empty list means success).
checkToolsOnPath :: (String -> IO (Maybe FilePath)) -> [String] -> IO [String]
checkToolsOnPath findTool tools = do
  results <- mapM (\t -> (t,) <$> findTool t) tools
  pure [name | (name, path) <- results, isNothing path]

-- | Production preflight for @update@ without Go assets extras.
preflightUpdate :: IO (Either Text ())
preflightUpdate = preflightUpdateWith False

-- | Preflight with optional Go/assets tool requirements.
preflightUpdateWith :: Bool -> IO (Either Text ())
preflightUpdateWith needGoAssets = do
  let tools =
        updateRequiredTools
          <> if needGoAssets then goAssetsRequiredTools else []
  missing <- checkToolsOnPath findExecutable tools
  pure $ case missing of
    [] -> Right ()
    ms ->
      Left $
        "update requires the following tools on PATH: "
          <> T.intercalate ", " (map T.pack ms)

-- | Validate assets worktree path when assets publish is required.
validateAssetsPath :: Maybe FilePath -> IO (Either Text FilePath)
validateAssetsPath = \case
  Nothing ->
    pure $
      Left
        "assets-path is required for packages that publish vendor/deps assets"
  Just path -> do
    exists <- doesDirectoryExist path
    if not exists
      then pure $ Left ("assets-path is not a directory: " <> T.pack path)
      else do
        isGit <- isGitWorkTree path
        pure $
          if isGit
            then Right path
            else Left ("assets-path is not a git work tree: " <> T.pack path)
