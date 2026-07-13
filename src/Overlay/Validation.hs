module Overlay.Validation
  ( OverlayError (..),
    validateOverlay,
  )
where

import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))

data OverlayError
  = NotADirectory FilePath
  | MissingDirectory FilePath
  | MissingFile FilePath
  | RepoNameMismatch FilePath String
  deriving (Eq, Show)

requiredDirectories :: [FilePath]
requiredDirectories =
  [ "profiles",
    "metadata"
  ]

requiredFiles :: [FilePath]
requiredFiles =
  [ "profiles" </> "repo_name",
    "metadata" </> "layout.conf"
  ]

expectedRepoName :: String
expectedRepoName = "mndz"

validateOverlay :: FilePath -> IO (Either OverlayError ())
validateOverlay path = do
  isDir <- doesDirectoryExist path
  if not isDir
    then pure (Left (NotADirectory path))
    else checkDirectories path

checkDirectories :: FilePath -> IO (Either OverlayError ())
checkDirectories root = go requiredDirectories
  where
    go [] = checkFiles root
    go (entry : rest) = do
      let full = root </> entry
      exists <- doesDirectoryExist full
      if exists
        then go rest
        else pure (Left (MissingDirectory full))

checkFiles :: FilePath -> IO (Either OverlayError ())
checkFiles root = go requiredFiles
  where
    go [] = checkRepoName root
    go (entry : rest) = do
      let full = root </> entry
      exists <- doesFileExist full
      if exists
        then go rest
        else pure (Left (MissingFile full))

checkRepoName :: FilePath -> IO (Either OverlayError ())
checkRepoName root = do
  let repoNameFile = root </> "profiles" </> "repo_name"
  content <- readFile repoNameFile
  let trimmed = filter (/= '\n') content
  if trimmed == expectedRepoName
    then pure (Right ())
    else pure (Left (RepoNameMismatch repoNameFile trimmed))
