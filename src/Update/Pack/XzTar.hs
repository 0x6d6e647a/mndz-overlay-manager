{-# LANGUAGE OverloadedStrings #-}

-- | Shared DepsAndAssets @tar@ + xz pack helpers.
--
-- Sets @XZ_OPT=-T1 -9e@ (single-thread extreme, bit-stable across core
-- counts), forces xz compression with @-J@ (so a temporary basename cannot
-- disable @tar -a@ auto-compress), records numeric root owners and a clamped
-- epoch mtime, and verifies the final file begins with the xz stream magic.
module Update.Pack.XzTar
  ( xzOptValue,
    withXzOpt,
    hermeticTarArgs,
    xzMagicPrefix,
    isXzMagic,
    verifyXzFile,
    packTarXz,
    packTarXzAtomic,
  )
where

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    removeFile,
    renameFile,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (IOMode (ReadMode), withBinaryFile)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )

-- | Uniform extreme single-thread xz settings for DepsAndAssets packs.
xzOptValue :: String
xzOptValue = "-T1 -9e"

-- | GNU tar flags that strip builder identity from ustar\/PAX headers.
--
-- Owners are numeric @0\/0@, names are sorted, mtimes are clamped to the
-- Unix epoch, and PAX atime\/ctime extended headers are dropped.
hermeticTarArgs :: [String]
hermeticTarArgs =
  [ "--owner=0",
    "--group=0",
    "--numeric-owner",
    "--sort=name",
    "--mtime=@0",
    "--clamp-mtime",
    "--pax-option=delete=atime,delete=ctime"
  ]

-- | Install @XZ_OPT@ into an environment list (replacing any prior value).
withXzOpt :: [(String, String)] -> [(String, String)]
withXzOpt env0 =
  ("XZ_OPT", xzOptValue) : filter ((/= "XZ_OPT") . fst) env0

-- | XZ stream header: @FD 37 7A 58 5A 00@ (\"\\xFD7zXZ\\0\").
xzMagicPrefix :: BS.ByteString
xzMagicPrefix = BS.pack [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]

-- | True when @bs@ begins with the xz stream magic.
isXzMagic :: BS.ByteString -> Bool
isXzMagic bs = xzMagicPrefix `BS.isPrefixOf` bs

-- | Hard-fail if @path@ is missing or is not an xz-compressed stream.
-- Messages mention plain tar / non-xz so pack regressions are obvious.
verifyXzFile :: FilePath -> IO (Either Text ())
verifyXzFile path = do
  exists <- doesFileExist path
  if not exists
    then
      pure $
        Left
          ( "archive is not xz-compressed (file missing after pack): "
              <> T.pack path
          )
    else withBinaryFile path ReadMode $ \h -> do
      header <- BS.hGet h (BS.length xzMagicPrefix)
      pure $
        if isXzMagic header
          then Right ()
          else
            Left
              ( "archive is not xz-compressed (plain tar or other non-xz data): "
                  <> T.pack path
              )

-- | Pack @entries@ to @finalPath@ with forced xz (@-cJf@), hermetic tar
-- flags, and @XZ_OPT=-T1 -9e@, then verify xz magic. Non-atomic: writes
-- @finalPath@ directly.
--
-- @cwd@ is the process working directory; @changeDir@ is an optional @tar -C@
-- directory (applied before create). @errPrefix@ prefixes failure messages.
packTarXz ::
  CommandRunner ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  [FilePath] ->
  FilePath ->
  IO (Either Text ())
packTarXz run errPrefix cwd changeDir entries finalPath = do
  createDirectoryIfMissing True (takeDirectory finalPath)
  r <- runTarXz run errPrefix cwd changeDir entries finalPath
  case r of
    Left err -> pure (Left err)
    Right () -> mapLeft errPrefix <$> verifyXzFile finalPath

-- | Like 'packTarXz', but writes to @finalPath <> \".partial\"@ then renames.
-- Temp stays in the same directory as the final path. Explicit @-J@ keeps
-- compression on even when the temp basename does not end in @.xz@.
packTarXzAtomic ::
  CommandRunner ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  [FilePath] ->
  FilePath ->
  IO (Either Text ())
packTarXzAtomic run errPrefix cwd changeDir entries finalPath = do
  createDirectoryIfMissing True (takeDirectory finalPath)
  let tmpPath = finalPath <> ".partial"
  tmpExists <- doesFileExist tmpPath
  when tmpExists (removeFile tmpPath)
  r <- runTarXz run errPrefix cwd changeDir entries tmpPath
  case r of
    Left err -> do
      tryRemove tmpPath
      pure (Left err)
    Right () -> do
      finalExists <- doesFileExist finalPath
      when finalExists (removeFile finalPath)
      renameFile tmpPath finalPath
      mapLeft errPrefix <$> verifyXzFile finalPath
  where
    tryRemove p = do
      e <- doesFileExist p
      when e (removeFile p)

runTarXz ::
  CommandRunner ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  [FilePath] ->
  FilePath ->
  IO (Either Text ())
runTarXz run errPrefix cwd changeDir entries archivePath = do
  env0 <- getEnvironment
  let env' = withXzOpt env0
      cArgs = case changeDir of
        Nothing -> []
        Just d -> ["-C", d]
      -- Force xz with -J so auto-compress suffix cannot skip compression.
      tarArgs = hermeticTarArgs ++ cArgs ++ ["-cJf", archivePath] ++ entries
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "tar" tarArgs,
          prCwd = cwd,
          prEnv = Just env',
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( errPrefix
              <> ": tar archive: "
              <> T.strip (T.pack (prStderr res))
          )

mapLeft :: Text -> Either Text a -> Either Text a
mapLeft prefix e = case e of
  Left err
    | prefix `T.isPrefixOf` err -> Left err
    | otherwise -> Left (prefix <> ": " <> err)
  Right x -> Right x
