{-# LANGUAGE OverloadedStrings #-}

-- | Host checks @smoke@ runs before any tree, image, or container work:
-- @git@, @gpg@, and @docker@ on @PATH@, an overlay git work tree, Docker
-- Engine 28.0 or newer, and the containerd image store (image mounts need
-- both).
module Smoke.Preflight
  ( smokeRequiredTools,
    minimumDockerVersion,
    checkDockerVersion,
    checkImageStore,
    smokePreflight,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)
import Update.Git (isGitWorkTree)
import Update.Materialize.ImageLayout (DockerInfoFacts (..), parseDockerInfoJson)
import Update.Preflight (checkToolsOnPath)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )

smokeRequiredTools :: [String]
smokeRequiredTools = ["git", "gpg", "docker"]

minimumDockerVersion :: [Int]
minimumDockerVersion = [28, 0]

-- | @docker version --format '{{.Server.Version}}'@ output must be 28.0 or
-- newer.
checkDockerVersion :: Text -> Either Text ()
checkDockerVersion raw =
  case traverse (readMaybe . T.unpack) (T.splitOn "." (T.takeWhile (`notElem` ("-+" :: String)) (T.strip raw))) of
    Just parts@(_ : _)
      | parts >= minimumDockerVersion -> Right ()
      | otherwise -> Left (tooOld (T.strip raw))
    _ -> Left ("could not read the Docker Engine version from " <> T.pack (show (T.strip raw)) <> "; smoke needs Docker Engine 28.0 or newer")
  where
    tooOld v = "smoke needs Docker Engine 28.0 or newer (image mounts); this engine is " <> v

-- | The engine must use the containerd image store.
checkImageStore :: DockerInfoFacts -> Either Text ()
checkImageStore facts
  | difUsesSnapshotter facts = Right ()
  | otherwise =
      Left
        "smoke needs Docker's containerd image store (image mounts are not available \
        \on the classic storage drivers); enable it in the Docker daemon configuration"

smokePreflight :: (String -> IO (Maybe FilePath)) -> CommandRunner -> FilePath -> IO (Either Text ())
smokePreflight findTool run overlay = do
  missing <- checkToolsOnPath findTool smokeRequiredTools
  if not (null missing)
    then pure (Left ("smoke requires the following tools on PATH: " <> T.intercalate ", " (map T.pack missing)))
    else do
      isGit <- isGitWorkTree run overlay
      if not isGit
        then pure (Left ("overlay path is not a git work tree: " <> T.pack overlay))
        else do
          ver <- docker ["version", "--format", "{{.Server.Version}}"]
          case ver of
            Left err -> pure (Left ("could not query the Docker Engine version: " <> err))
            Right v -> case checkDockerVersion v of
              Left err -> pure (Left err)
              Right () -> do
                infoOut <- docker ["info", "--format", "{{json .}}"]
                pure $ case infoOut of
                  Left err -> Left ("docker info failed: " <> err)
                  Right raw -> parseDockerInfoJson raw >>= checkImageStore
  where
    docker args = do
      res <-
        run
          ProcessRequest
            { prMode = ExecCmd "docker" args,
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = "",
              prMeasure = Timed
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right (T.pack (prStdout res))
          else Left (T.strip (T.pack (prStderr res)))
