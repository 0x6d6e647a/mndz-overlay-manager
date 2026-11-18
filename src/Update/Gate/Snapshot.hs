{-# LANGUAGE OverloadedStrings #-}

-- | The overlay a gated smoke run sees: the overlay's @HEAD@ commit, with
-- the gated unit's package directory and that package's md5-cache entries
-- taken from the worktree. Other units' uncommitted work is never visible.
module Update.Gate.Snapshot
  ( buildUnitSnapshot,
    isCacheEntryOf,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_, when)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Discovery (parseEbuildFileName)
import System.Directory
  ( copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (addTrailingPathSeparator, (</>))
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Types (PackageKey, packageKeyText, splitPackageKey)

-- | Whether an md5-cache file name (@\<pn\>-\<pvr\>@) belongs to package
-- @pn@. A prefix match is not enough: @codex-acp-2.7.0@ is not a @codex@
-- entry.
isCacheEntryOf :: Text -> FilePath -> Bool
isCacheEntryOf pn name = case parseEbuildFileName (name <> ".ebuild") of
  Just (n, _) -> n == T.unpack pn
  Nothing -> False

-- | Fill @dest@ with the overlay at @HEAD@, then replace the unit's package
-- directory and its md5-cache entries with the worktree's. @HEAD@ is
-- written through a private index file next to @dest@, so the overlay's own
-- index is never touched.
buildUnitSnapshot :: CommandRunner -> FilePath -> PackageKey -> FilePath -> IO (Either Text ())
buildUnitSnapshot run overlay key dest = case splitPackageKey key of
  Nothing -> pure (Left ("invalid package key " <> packageKeyText key))
  Just (cat, pn) -> do
    createDirectoryIfMissing True dest
    base <- getEnvironment
    let index = dest <> ".index"
        env = Just (("GIT_INDEX_FILE", index) : filter ((/= "GIT_INDEX_FILE") . fst) base)
        git args = do
          res <-
            run
              ProcessRequest
                { prMode = ExecCmd "git" (["-C", overlay] <> args),
                  prCwd = Nothing,
                  prEnv = env,
                  prStdin = "",
                  prMeasure = Timed
                }
          pure $
            if prExitCode res == ExitSuccess
              then Right ()
              else Left (T.strip (T.pack (prStderr res)))
    readTree <- git ["read-tree", "HEAD"]
    checkout <- either (pure . Left) (const (git ["checkout-index", "--all", "--force", "--prefix=" <> addTrailingPathSeparator dest])) readTree
    _ <- try @IOException (removeFile index)
    case checkout of
      Left err -> pure (Left ("could not write the overlay at HEAD into " <> T.pack dest <> ": " <> err))
      Right () -> do
        copied <- try @IOException $ do
          let rel = T.unpack cat </> T.unpack pn
          replaceDir (overlay </> rel) (dest </> rel)
          let cacheRel = "metadata" </> "md5-cache" </> T.unpack cat
          createDirectoryIfMissing True (dest </> cacheRel)
          stale <- filter (isCacheEntryOf pn) <$> listDirectory (dest </> cacheRel)
          forM_ stale (\name -> removeFile (dest </> cacheRel </> name))
          hasCache <- doesDirectoryExist (overlay </> cacheRel)
          when hasCache $ do
            fresh <- filter (isCacheEntryOf pn) <$> listDirectory (overlay </> cacheRel)
            forM_ fresh $ \name -> copyFile (overlay </> cacheRel </> name) (dest </> cacheRel </> name)
        pure $ case copied of
          Left err -> Left ("could not copy " <> packageKeyText key <> " into the gate snapshot: " <> T.pack (show err))
          Right () -> Right ()

-- | Make @dst@ a copy of @src@ (removed when @src@ does not exist).
replaceDir :: FilePath -> FilePath -> IO ()
replaceDir src dst = do
  had <- doesDirectoryExist dst
  when had (removeDirectoryRecursive dst)
  exists <- doesDirectoryExist src
  when exists (copyTree src dst)

copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
  createDirectoryIfMissing True dst
  names <- listDirectory src
  forM_ names $ \name -> do
    let s = src </> name
        d = dst </> name
    isDir <- doesDirectoryExist s
    if isDir
      then copyTree s d
      else do
        isFile <- doesFileExist s
        when isFile (copyFile s d)
