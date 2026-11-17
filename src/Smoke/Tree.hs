{-# LANGUAGE OverloadedStrings #-}

-- | Per-command snapshot of the managed Gentoo tree as an imported Docker
-- image, mounted read-only into every smoke container of the command.
--
-- @tar@ runs in a container from the smoke image (the host needs no @tar@)
-- and pipes into @docker import@. The image carries the product, run, and
-- pid labels so a later command can remove leftovers of a dead one.
module Smoke.Tree
  ( dockerSafe,
    snapshotTag,
    snapshotRepository,
    SnapshotCfg (..),
    snapshotTarName,
    snapshotPipeline,
    createSnapshot,
    removeSnapshot,
    withSnapshot,
    sweepStaleSnapshots,
    shellQuote,
  )
where

import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker
  ( materializePidLabelKey,
    materializeProductLabel,
    materializeProductLabelKey,
    materializeRunLabelKey,
  )

-- | Replace characters Docker rejects in names and tags (a run id may carry
-- a @+@ time zone offset).
dockerSafe :: String -> String
dockerSafe = map (\c -> if c `elem` ("+/:" :: String) then '_' else c)

snapshotRepository :: String
snapshotRepository = "mndz-overlay-manager/smoke-tree"

-- | @mndz-overlay-manager/smoke-tree:\<run-id\>@.
snapshotTag :: String -> String
snapshotTag runId = snapshotRepository <> ":" <> dockerSafe runId

data SnapshotCfg = SnapshotCfg
  { scRunId :: String,
    scCliPid :: String,
    -- | Image whose @tar@ writes the archive (the smoke image).
    scImage :: String,
    -- | Managed tree root.
    scTree :: FilePath
  }
  deriving (Eq, Show)

-- | Name of the short-lived @tar@ container.
snapshotTarName :: SnapshotCfg -> String
snapshotTarName cfg = "mndz-smoke-" <> dockerSafe (scRunId cfg) <> "-snapshot"

labels :: SnapshotCfg -> [String]
labels cfg =
  [ materializeProductLabel,
    materializeRunLabelKey <> "=" <> scRunId cfg,
    materializePidLabelKey <> "=" <> scCliPid cfg
  ]

-- | Host shell pipeline: @docker run … tar … | docker import … -@.
snapshotPipeline :: SnapshotCfg -> String
snapshotPipeline cfg =
  unwords (map shellQuote tarArgv) <> " | " <> unwords (map shellQuote importArgv)
  where
    tarArgv =
      ["docker", "run", "--name", snapshotTarName cfg]
        <> concat [["--label", l] | l <- labels cfg]
        <> [ "--network",
             "none",
             "--mount",
             "type=bind,src=" <> scTree cfg <> ",dst=/t,readonly",
             scImage cfg,
             "tar",
             "-C",
             "/t",
             "--exclude=./.git",
             "--exclude=./.dockerignore",
             "--owner=0",
             "--group=0",
             "-c",
             "."
           ]
    importArgv =
      ["docker", "import"]
        <> concat [["--change", "LABEL " <> l] | l <- labels cfg]
        <> ["-", snapshotTag (scRunId cfg)]

-- | POSIX single-quote a word.
shellQuote :: String -> String
shellQuote s = "'" <> concatMap (\c -> if c == '\'' then "'\\''" else [c]) s <> "'"

-- | Create the snapshot image; 'Right' its tag. The @tar@ container's own
-- exit code is checked, since the pipeline reports only @docker import@'s.
createSnapshot :: CommandRunner -> SnapshotCfg -> IO (Either Text String)
createSnapshot run cfg = do
  let tag = snapshotTag (scRunId cfg)
      name = snapshotTarName cfg
  piped <-
    run
      ProcessRequest
        { prMode = ShellCmd (snapshotPipeline cfg),
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  tarExit <- docker run ["inspect", "--format", "{{.State.ExitCode}}", name]
  _ <- docker run ["rm", "-f", name]
  let tarOk = case tarExit of
        Right out -> T.strip (T.pack out) == "0"
        Left _ -> False
  if prExitCode piped == ExitSuccess && tarOk
    then pure (Right tag)
    else do
      removeSnapshot run tag
      pure $
        Left $
          "could not snapshot the Gentoo tree into "
            <> T.pack tag
            <> ": "
            <> T.strip (T.pack (prStderr piped))
            <> either (\e -> " (tar container: " <> e <> ")") (const "") tarExit

removeSnapshot :: CommandRunner -> String -> IO ()
removeSnapshot run tag = do
  _ <- try @SomeException (docker run ["rmi", tag])
  pure ()

-- | Snapshot, run the continuation with the tag, and remove the snapshot on
-- return or exception.
withSnapshot :: CommandRunner -> SnapshotCfg -> (String -> IO a) -> IO (Either Text a)
withSnapshot run cfg k = do
  created <- createSnapshot run cfg
  case created of
    Left err -> pure (Left err)
    Right tag -> Right <$> (k tag `finally` removeSnapshot run tag)

-- | Remove snapshot images whose labeled pid is not a live overlay-manager.
-- Best effort; never throws.
sweepStaleSnapshots :: CommandRunner -> (String -> IO Bool) -> IO ()
sweepStaleSnapshots run isLive = do
  listed <-
    try @SomeException $
      docker
        run
        [ "images",
          "--filter",
          "label=" <> materializeProductLabelKey,
          "--filter",
          "reference=" <> snapshotRepository <> ":*",
          "--format",
          "{{.Repository}}:{{.Tag}}"
        ]
  case listed of
    Right (Right out) ->
      forM_ (filter (not . null) (lines out)) $ \ref -> do
        pidOut <-
          docker
            run
            ["image", "inspect", "--format", "{{index .Config.Labels \"" <> materializePidLabelKey <> "\"}}", ref]
        keep <- case pidOut of
          Right p | not (null (trim p)) -> isLive (trim p)
          _ -> pure False
        if keep then pure () else removeSnapshot run ref
    _ -> pure ()
  where
    trim = T.unpack . T.strip . T.pack

docker :: CommandRunner -> [String] -> IO (Either Text String)
docker run args = do
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
      then Right (prStdout res)
      else Left (T.strip (T.pack (prStderr res)))
