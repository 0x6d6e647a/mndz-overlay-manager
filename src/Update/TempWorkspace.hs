{-# LANGUAGE OverloadedStrings #-}

-- | Project-wide temporary workspace under the effective temp root.
--
-- Layout: @\<tempRoot\>/mndz/overlay-manager/\<run-id\>/\<cat\>/\<pn\>/\<pv\>-{full|reuse}/{out,work}@
module Update.TempWorkspace
  ( UnitKind (..),
    RunRoot (..),
    UnitDirs (..),
    unitKindSuffix,
    formatRunId,
    runRootPath,
    unitDirPath,
    openRunRoot,
    openRunRootAt,
    ensureUnit,
    deleteUnit,
    cleanupRunSuccess,
    retainUnitError,
  )
where

import Control.Exception (try)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.LocalTime (ZonedTime, getZonedTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
    removeDirectory,
    removePathForcibly,
  )
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Process (getProcessID)
import System.Posix.Types (CPid)
import Text.Printf (printf)
import Update.DiskSpace (resolveTempRoot)

-- | Materialize path kind under a package version unit.
data UnitKind
  = -- | Full-path materialize (clone/build/pack).
    UnitFull
  | -- | Reuse-path download/verify.
    UnitReuse
  deriving (Eq, Show)

-- | Open product temp workspace for one command run.
data RunRoot = RunRoot
  { -- | Effective temp root (@TMPDIR@ or process default).
    rrTempRoot :: FilePath,
    -- | Run id segment (timestamp-pid.random).
    rrRunId :: String,
    -- | Absolute path to @…/mndz/overlay-manager/\<run-id\>@.
    rrPath :: FilePath
  }
  deriving (Eq, Show)

-- | Per-unit @out/@ and @work/@ directories under a unit root.
data UnitDirs = UnitDirs
  { -- | Absolute unit directory (@…/\<pv\>-full|reuse@).
    udPath :: FilePath,
    -- | Staged distfiles / downloaded assets.
    udOut :: FilePath,
    -- | Clones, language caches, pack stages.
    udWork :: FilePath
  }
  deriving (Eq, Show)

unitKindSuffix :: UnitKind -> String
unitKindSuffix UnitFull = "full"
unitKindSuffix UnitReuse = "reuse"

-- | Pure run-id format: local ISO-8601 with offset, pid, random hex.
--
-- Example: @2026-08-10T15:42:07-07:00-4242.a8f3@
formatRunId :: ZonedTime -> CPid -> String -> String
formatRunId zt pid rand =
  formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Ez" zt
    <> "-"
    <> show pid
    <> "."
    <> rand

-- | @\<tempRoot\>/mndz/overlay-manager/\<run-id\>@
runRootPath :: FilePath -> String -> FilePath
runRootPath tempRoot runId =
  tempRoot </> "mndz" </> "overlay-manager" </> runId

-- | @\<runRoot\>/\<category\>/\<package\>/\<pv\>-\<kind\>@
unitDirPath :: FilePath -> Text -> Text -> Text -> UnitKind -> FilePath
unitDirPath runPath category package pv kind =
  runPath
    </> T.unpack category
    </> T.unpack package
    </> (T.unpack pv <> "-" <> unitKindSuffix kind)

-- | Open a new run root under the effective temp root.
openRunRoot :: IO RunRoot
openRunRoot = do
  tempRoot <- resolveTempRoot
  openRunRootAt tempRoot

-- | Open a new run root under an explicit temp root (tests / injection).
openRunRootAt :: FilePath -> IO RunRoot
openRunRootAt tempRoot = do
  zt <- getZonedTime
  pid <- getProcessID
  rand <- randomHex 4
  let runId = formatRunId zt pid rand
      path = runRootPath tempRoot runId
  createDirectoryIfMissing True path
  pure
    RunRoot
      { rrTempRoot = tempRoot,
        rrRunId = runId,
        rrPath = path
      }

-- | Ensure unit directory and @out@/@work@ subdirs exist.
ensureUnit ::
  RunRoot ->
  Text ->
  Text ->
  Text ->
  UnitKind ->
  IO UnitDirs
ensureUnit run category package pv kind = do
  let unitPath = unitDirPath (rrPath run) category package pv kind
      outDir = unitPath </> "out"
      workDir = unitPath </> "work"
  createDirectoryIfMissing True outDir
  createDirectoryIfMissing True workDir
  pure
    UnitDirs
      { udPath = unitPath,
        udOut = outDir,
        udWork = workDir
      }

-- | Delete a unit tree and prune empty package/category parents under the run root.
deleteUnit :: UnitDirs -> IO ()
deleteUnit unit = do
  removePathForcibly (udPath unit)
  let pkgDir = takeDirectory (udPath unit)
      catDir = takeDirectory pkgDir
  removeDirIfEmpty pkgDir
  removeDirIfEmpty catDir

-- | Full-run success: delete run root; upward-prune empty brand dirs.
cleanupRunSuccess :: RunRoot -> IO ()
cleanupRunSuccess run = do
  removePathForcibly (rrPath run)
  let overlayMgr = rrTempRoot run </> "mndz" </> "overlay-manager"
      mndzBrand = rrTempRoot run </> "mndz"
  removeDirIfEmpty overlayMgr
  removeDirIfEmpty mndzBrand

-- | Append retained unit path to a hard-fail message.
retainUnitError :: UnitDirs -> Text -> Text
retainUnitError unit err =
  err <> "\nretained temp unit: " <> T.pack (udPath unit)

------------------------------------------------------------------------
-- Internals
------------------------------------------------------------------------

removeDirIfEmpty :: FilePath -> IO ()
removeDirIfEmpty path = do
  exists <- doesDirectoryExist path
  when exists $ do
    entries <- listDirectory path
    when (null entries) $ do
      -- Benign races under --jobs: ignore failure if another job filled/removed it.
      _ <- try @IOError (removeDirectory path)
      pure ()

-- | Short non-cryptographic hex from @/dev/urandom@ (4–8 chars typical).
randomHex :: Int -> IO String
randomHex n = do
  let nbytes = (n + 1) `div` 2
  bs <-
    withBinaryFile "/dev/urandom" ReadMode $ \h ->
      BS.hGet h nbytes
  pure $ take n $ concatMap (printf "%02x") (BS.unpack bs)
