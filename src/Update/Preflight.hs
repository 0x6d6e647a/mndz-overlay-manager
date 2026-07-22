{-# LANGUAGE OverloadedStrings #-}

module Update.Preflight
  ( updateRequiredTools,
    assetsRequiredTools,
    goRequiredTools,
    npmRequiredTools,
    bunRequiredTools,
    goAssetsRequiredTools,
    checkToolsOnPath,
    preflightUpdate,
    preflightUpdateWith,
    preflightUpdateTools,
    validateAssetsPath,
    AssetsPreflight (..),
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

-- | Tools always required when any DepsAndAssets assets work is in scope.
assetsRequiredTools :: [String]
assetsRequiredTools = ["xz"]

goRequiredTools :: [String]
goRequiredTools = ["go"]

npmRequiredTools :: [String]
npmRequiredTools = ["npm"]

bunRequiredTools :: [String]
bunRequiredTools = ["bun"]

-- | Legacy combined Go + xz tools (full-path Go materialize).
goAssetsRequiredTools :: [String]
goAssetsRequiredTools = goRequiredTools <> assetsRequiredTools

-- | Which language tools and assets extras to require.
data AssetsPreflight = AssetsPreflight
  { apNeedAssets :: Bool,
    apNeedGo :: Bool,
    apNeedNpm :: Bool,
    apNeedBun :: Bool
  }
  deriving (Eq, Show)

-- | Check that each tool name is findable on PATH.
-- Returns missing tool names (empty list means success).
checkToolsOnPath :: (String -> IO (Maybe FilePath)) -> [String] -> IO [String]
checkToolsOnPath findTool tools = do
  results <- mapM (\t -> (t,) <$> findTool t) tools
  pure [name | (name, path) <- results, isNothing path]

-- | Production preflight for @update@ without assets extras.
preflightUpdate :: IO (Either Text ())
preflightUpdate = preflightUpdateWith False

-- | Preflight with optional combined Go/assets tool requirements (legacy Bool).
preflightUpdateWith :: Bool -> IO (Either Text ())
preflightUpdateWith needGoAssets =
  preflightUpdateTools
    AssetsPreflight
      { apNeedAssets = needGoAssets,
        apNeedGo = needGoAssets,
        apNeedNpm = False,
        apNeedBun = False
      }

-- | Preflight with per-ecosystem tool requirements.
preflightUpdateTools :: AssetsPreflight -> IO (Either Text ())
preflightUpdateTools ap = do
  let tools =
        updateRequiredTools
          <> [t | apNeedAssets ap, t <- assetsRequiredTools]
          <> [t | apNeedGo ap, t <- goRequiredTools]
          <> [t | apNeedNpm ap, t <- npmRequiredTools]
          <> [t | apNeedBun ap, t <- bunRequiredTools]
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
