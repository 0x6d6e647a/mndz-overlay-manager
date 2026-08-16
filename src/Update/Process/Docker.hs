{-# LANGUAGE OverloadedStrings #-}

-- | Docker wrapper for full-path DepsAndAssets materialize child processes.
--
-- Production builders keep their @CommandRunner@ bodies; this module prefixes
-- language / @tar@ / @git@ / @pycargoebuild@ invocations with @docker run@.
-- Unit tests inject a fake inner runner so no live daemon is required.
module Update.Process.Docker
  ( defaultMaterializeImage,
    materializeImageEnvVar,
    materializeBuilderHome,
    secretMaterializeEnvKeys,
    MaterializeDockerCfg (..),
    resolveMaterializeImage,
    wrapMaterializeRequest,
    materializeDockerRunner,
    productionMaterializeRunner,
    inspectMaterializeImage,
    missingImageMessage,
  )
where

import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Posix.User (getRealGroupID, getRealUserID)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Default image tag used when @MNDZ_MATERIALIZE_IMAGE@ is unset.
defaultMaterializeImage :: String
defaultMaterializeImage = "mndz-overlay-manager/materialize:local"

-- | Environment override for the materialize image tag.
materializeImageEnvVar :: String
materializeImageEnvVar = "MNDZ_MATERIALIZE_IMAGE"

-- | Generic @HOME@ inside the materialize container (not the operator home).
materializeBuilderHome :: FilePath
materializeBuilderHome = "/home/builder"

-- | Host secrets that must never be passed into the materialize container.
secretMaterializeEnvKeys :: [String]
secretMaterializeEnvKeys =
  [ "GITHUB_TOKEN",
    "GH_TOKEN",
    "GNUPGHOME",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID"
  ]

forcedEnvKeys :: [String]
forcedEnvKeys = ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "PATH"]

-- | Bind-mount + identity settings for one @docker run@.
data MaterializeDockerCfg = MaterializeDockerCfg
  { -- | Image tag (@mndz-overlay-manager/materialize:local@ or override).
    mdcImage :: String,
    -- | @uid:gid@ passed to @docker run --user@.
    mdcUser :: String,
    -- | Host path bind-mounted at the same absolute path (unit work\/out root).
    mdcBindPath :: FilePath
  }
  deriving (Eq, Show)

resolveMaterializeImage :: IO String
resolveMaterializeImage = do
  m <- lookupEnv materializeImageEnvVar
  pure (fromMaybe defaultMaterializeImage (nonEmpty m))
  where
    nonEmpty (Just s) | not (null s) = Just s
    nonEmpty _ = Nothing

-- | Rewrite a host process request into @docker run --rm … image cmd@.
wrapMaterializeRequest :: MaterializeDockerCfg -> ProcessRequest -> ProcessRequest
wrapMaterializeRequest cfg req =
  ProcessRequest
    { prMode = ExecCmd "docker" (dockerArgs cfg req),
      prCwd = Nothing,
      prEnv = Nothing,
      prStdin = prStdin req
    }

dockerArgs :: MaterializeDockerCfg -> ProcessRequest -> [String]
dockerArgs cfg req =
  [ "run",
    "--rm",
    "--user",
    mdcUser cfg
  ]
    ++ concatMap envFlag (containerEnv req)
    ++ [ "--mount",
         "type=bind,src=" <> mdcBindPath cfg <> ",dst=" <> mdcBindPath cfg
       ]
    ++ workdirFlags
    ++ [mdcImage cfg]
    ++ innerCmd
  where
    workdirFlags = case prCwd req of
      Just d -> ["--workdir", d]
      Nothing -> []
    innerCmd = case prMode req of
      ExecCmd cmd args -> cmd : args
      ShellCmd sh -> ["sh", "-c", sh]

envFlag :: (String, String) -> [String]
envFlag (k, v) = ["--env", k <> "=" <> v]

containerEnv :: ProcessRequest -> [(String, String)]
containerEnv req =
  forced ++ kept
  where
    forced =
      [ ("HOME", materializeBuilderHome),
        ("XDG_CONFIG_HOME", materializeBuilderHome <> "/.config"),
        ("XDG_CACHE_HOME", "/tmp/builder-cache")
      ]
    incoming = fromMaybe [] (prEnv req)
    kept =
      [ (k, v)
      | (k, v) <- incoming,
        not (dropKey k)
      ]
    dropKey k =
      k `elem` secretMaterializeEnvKeys
        || k `elem` forcedEnvKeys
        || "SSH_" `isPrefixOf` k

-- | Wrap an inner runner (production or fake) with the docker argv rewrite.
materializeDockerRunner :: MaterializeDockerCfg -> CommandRunner -> CommandRunner
materializeDockerRunner cfg inner req = inner (wrapMaterializeRequest cfg req)

-- | Production runner: host uid\/gid, resolved image, bind-mount @bindPath@.
productionMaterializeRunner :: FilePath -> IO CommandRunner
productionMaterializeRunner bindPath = do
  image <- resolveMaterializeImage
  uid <- getRealUserID
  gid <- getRealGroupID
  let cfg =
        MaterializeDockerCfg
          { mdcImage = image,
            mdcUser = show uid <> ":" <> show gid,
            mdcBindPath = bindPath
          }
  pure (materializeDockerRunner cfg productionCommandRunner)

inspectMaterializeImage :: CommandRunner -> String -> IO (Either Text ())
inspectMaterializeImage run image = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "docker" ["image", "inspect", image],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left (missingImageMessage image)

missingImageMessage :: String -> Text
missingImageMessage image =
  "materialize image is not usable: "
    <> T.pack image
    <> " (build it with: docker build -t "
    <> T.pack defaultMaterializeImage
    <> " -f docker/materialize/Dockerfile . ; override the tag with "
    <> T.pack materializeImageEnvVar
    <> "; see README)"
