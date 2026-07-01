module Overlay.Validation
  ( OverlayError(..)
  , validateOverlay
  ) where

import Data.List (isPrefixOf)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))

data OverlayError
  = NotADirectory FilePath
  | MissingDirectory FilePath
  | MissingFile FilePath
  | RepoNameMismatch FilePath String
  deriving (Eq, Show)

requiredEntries :: [FilePath]
requiredEntries =
  [ "profiles"
  , "metadata"
  , "profiles" </> "repo_name"
  , "metadata" </> "layout.conf"
  ]

expectedRepoName :: String
expectedRepoName = "mndz"

validateOverlay :: FilePath -> IO (Either OverlayError ())
validateOverlay path = do
  isDir <- doesDirectoryExist path
  if not isDir
    then pure (Left (NotADirectory path))
    else checkEntries path

checkEntries :: FilePath -> IO (Either OverlayError ())
checkEntries root = go requiredEntries
  where
    go [] = checkRepoName root
    go (entry : rest) = do
      let full = root </> entry
      exists <- if "repo_name" `isPrefixOf` entry || "layout.conf" `isPrefixOf` entry
                then doesFileExist full
                else doesDirectoryExist full
      if exists
        then go rest
        else pure (Left (if "repo_name" `isPrefixOf` entry || "layout.conf" `isPrefixOf` entry
                         then MissingFile full
                         else MissingDirectory full))

checkRepoName :: FilePath -> IO (Either OverlayError ())
checkRepoName root = do
  let repoNameFile = root </> "profiles" </> "repo_name"
  content <- readFile repoNameFile
  let trimmed = filter (/= '\n') content
  if trimmed == expectedRepoName
    then pure (Right ())
    else pure (Left (RepoNameMismatch repoNameFile trimmed))
