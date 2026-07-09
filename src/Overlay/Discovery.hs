module Overlay.Discovery
  ( DiscoveryError (..)
  , discoveryErrorMessage
  , collectEbuilds
  , parseEbuildFileName
  ) where

import Control.Monad (filterM)
import Data.Char (isDigit)
import Data.List (isSuffixOf, sort)
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Overlay.Types (Ebuild (..))
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>), takeFileName)

data DiscoveryError
  = MalformedEbuildName FilePath
  | PackageNameMismatch FilePath String String
  deriving (Eq, Show)

discoveryErrorMessage :: DiscoveryError -> String
discoveryErrorMessage = \case
  MalformedEbuildName path ->
    "malformed ebuild filename (expected package-version.ebuild): " <> path
  PackageNameMismatch path expected got ->
    "package name mismatch in " <> path
      <> ": directory is " <> expected
      <> " but filename has package " <> got

-- | Split @package-version.ebuild@ into package and version.
-- Version starts at the last @-@ followed by a digit.
parseEbuildFileName :: String -> Maybe (String, String)
parseEbuildFileName name = do
  base <- stripSuffix ".ebuild" name
  splitPkgVer base

stripSuffix :: String -> String -> Maybe String
stripSuffix sfx s
  | sfx `isSuffixOf` s = Just (take (length s - length sfx) s)
  | otherwise = Nothing

splitPkgVer :: String -> Maybe (String, String)
splitPkgVer s = do
  i <- listToMaybe (reverse versionHyphenIndices)
  let (pkg, rest) = splitAt i s
  case rest of
    '-' : ver | not (null pkg) && not (null ver) -> Just (pkg, ver)
    _ -> Nothing
  where
    versionHyphenIndices =
      [ i
      | (i, c) <- zip [0 ..] s
      , c == '-'
      , i + 1 < length s
      , isDigit (s !! (i + 1))
      ]

collectEbuilds :: FilePath -> IO (Either DiscoveryError [Ebuild])
collectEbuilds root = do
  entries <- listDirectory root
  categories <- filterM (isCategory root) (sort entries)
  goCategories categories []
  where
    goCategories [] acc = pure (Right (concat (reverse acc)))
    goCategories (cat : rest) acc = do
      result <- collectCategory root cat
      case result of
        Left err -> pure (Left err)
        Right es -> goCategories rest (es : acc)

isCategory :: FilePath -> FilePath -> IO Bool
isCategory root name = do
  let path = root </> name
  isDir <- doesDirectoryExist path
  if not isDir
    then pure False
    else do
      children <- listDirectory path
      anyM (packageDirHasEbuild path) children

packageDirHasEbuild :: FilePath -> FilePath -> IO Bool
packageDirHasEbuild catPath child = do
  let path = catPath </> child
  isDir <- doesDirectoryExist path
  if not isDir
    then pure False
    else do
      files <- listDirectory path
      pure (any (".ebuild" `isSuffixOf`) files)

collectCategory :: FilePath -> FilePath -> IO (Either DiscoveryError [Ebuild])
collectCategory root cat = do
  let catPath = root </> cat
  children <- sort <$> listDirectory catPath
  packageDirs <- filterM (doesDirectoryExist . (catPath </>)) children
  goPackages packageDirs []
  where
    goPackages [] acc = pure (Right (concat (reverse acc)))
    goPackages (pkg : rest) acc = do
      result <- collectPackage root cat pkg
      case result of
        Left err -> pure (Left err)
        Right es -> goPackages rest (es : acc)

collectPackage :: FilePath -> FilePath -> FilePath -> IO (Either DiscoveryError [Ebuild])
collectPackage root cat pkg = do
  let pkgPath = root </> cat </> pkg
  files <- sort <$> listDirectory pkgPath
  let ebuildFiles = filter (".ebuild" `isSuffixOf`) files
  pure $ mapM (toEbuild root cat pkg pkgPath) ebuildFiles

toEbuild :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> Either DiscoveryError Ebuild
toEbuild _root cat pkg pkgPath file =
  let full = pkgPath </> file
  in case parseEbuildFileName (takeFileName file) of
    Nothing -> Left (MalformedEbuildName full)
    Just (name, ver)
      | name /= pkg -> Left (PackageNameMismatch full pkg name)
      | otherwise ->
          Right Ebuild
            { ebuildCategory = T.pack cat
            , ebuildPackage  = T.pack pkg
            , ebuildVersion  = T.pack ver
            , ebuildPath     = full
            }

anyM :: (Monad m) => (a -> m Bool) -> [a] -> m Bool
anyM _ [] = pure False
anyM p (x : xs) = do
  b <- p x
  if b then pure True else anyM p xs
