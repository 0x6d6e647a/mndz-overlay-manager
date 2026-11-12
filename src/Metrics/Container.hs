{-# LANGUAGE OverloadedStrings #-}

-- | Materialize container cgroup snapshot (design D7): resolve the
-- container's cgroup v2 path through its init PID, then read CPU totals and
-- peak memory before the container is removed.
module Metrics.Container
  ( CgroupRoots (..),
    productionCgroupRoots,
    cgroupOfPid,
    parseCgroupV2Path,
    cgroupSnapshot,
    parseCpuStat,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson ((.=))
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Metrics.Core (Attrs)
import System.FilePath ((</>))
import Text.Read (readMaybe)

-- | Where @/proc@ and the cgroup v2 mount live (fixtures in tests).
data CgroupRoots = CgroupRoots
  { crProc :: FilePath,
    crSys :: FilePath
  }
  deriving (Eq, Show)

productionCgroupRoots :: CgroupRoots
productionCgroupRoots = CgroupRoots {crProc = "/proc", crSys = "/sys/fs/cgroup"}

-- | Unified hierarchy path from @/proc/\<pid\>/cgroup@ (the @0::@ line).
parseCgroupV2Path :: Text -> Maybe Text
parseCgroupV2Path body =
  listToMaybe [p | l <- T.lines body, Just p <- [T.stripPrefix "0::" l], not (T.null p)]

-- | cgroup v2 path of a process.
cgroupOfPid :: CgroupRoots -> Int -> IO (Either Text Text)
cgroupOfPid roots pid = do
  let path = crProc roots </> show pid </> "cgroup"
  r <- readText path
  pure $ case r of
    Left err -> Left err
    Right body -> maybe (Left ("no cgroup v2 entry in " <> T.pack path)) Right (parseCgroupV2Path body)

-- | @usage_usec@, @user_usec@, @system_usec@ from @cpu.stat@.
parseCpuStat :: Text -> [(Text, Integer)]
parseCpuStat body =
  [ (k, n)
  | l <- T.lines body,
    [k, v] <- [T.words l],
    k `elem` ["usage_usec", "user_usec", "system_usec"],
    Just n <- [readMaybe (T.unpack v)]
  ]

-- | @container@ event attributes for a cgroup: CPU microseconds and peak
-- memory bytes, or @error@ naming what could not be read.
cgroupSnapshot :: CgroupRoots -> Text -> IO Attrs
cgroupSnapshot roots cg = do
  let dir = crSys roots </> T.unpack (T.dropWhile (== '/') cg)
  cpu <- readText (dir </> "cpu.stat")
  peak <- readText (dir </> "memory.peak")
  pure $ case (cpu, peak) of
    (Right c, Right p)
      | Just bytes <- (readMaybe (T.unpack (T.strip p)) :: Maybe Integer) ->
          ["cgroup" .= cg]
            <> [k .= v | (k, v) <- map keyed (parseCpuStat c)]
            <> ["memory_peak_bytes" .= bytes]
      | otherwise -> ["cgroup" .= cg, "error" .= ("unparseable memory.peak" :: Text)]
    (Left err, _) -> ["cgroup" .= cg, "error" .= err]
    (_, Left err) -> ["cgroup" .= cg, "error" .= err]
  where
    keyed (k, v) = (cpuKey k, v)
    cpuKey = \case
      "usage_usec" -> "cpu_usage_usec"
      "user_usec" -> "cpu_user_usec"
      _ -> "cpu_system_usec"

readText :: FilePath -> IO (Either Text Text)
readText path = do
  r <- try @IOException (TIO.readFile path) -- allow-non-ebuild: proc/sysfs
  pure $ case r of
    Left e -> Left ("cannot read " <> T.pack path <> ": " <> T.pack (show e))
    Right t -> Right t
