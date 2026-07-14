{-# LANGUAGE OverloadedStrings #-}

module Update.Preflight
  ( updateRequiredTools,
    checkToolsOnPath,
    preflightUpdate,
  )
where

import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (findExecutable)

-- | External tools required on PATH for the @update@ command.
updateRequiredTools :: [String]
updateRequiredTools = ["git", "ebuild", "gpg"]

-- | Check that each tool name is findable on PATH.
-- Returns missing tool names (empty list means success).
checkToolsOnPath :: (String -> IO (Maybe FilePath)) -> [String] -> IO [String]
checkToolsOnPath findTool tools = do
  results <- mapM (\t -> (t,) <$> findTool t) tools
  pure [name | (name, path) <- results, isNothing path]

-- | Production preflight for @update@: require git, ebuild, and gpg.
preflightUpdate :: IO (Either Text ())
preflightUpdate = do
  missing <- checkToolsOnPath findExecutable updateRequiredTools
  pure $ case missing of
    [] -> Right ()
    ms ->
      Left $
        "update requires the following tools on PATH: "
          <> T.intercalate ", " (map T.pack ms)
