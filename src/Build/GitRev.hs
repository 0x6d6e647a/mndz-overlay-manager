{-# LANGUAGE TemplateHaskellQuotes #-}

-- | Compile-time git revision for build identity (run metrics headers).
--
-- 'gitRevisionQ' is spliced only by "Build.Info". It runs @git@ while the
-- module compiles and registers @.git/HEAD@, the resolved ref, and
-- @.git/index@ as dependent files so a new commit recompiles the splice.
-- The label can still be stale when Cabal reports the build up to date;
-- the executable SHA-256 in run headers is the ground truth.
module Build.GitRev
  ( gitRevisionQ,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, stripPrefix)
import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | Splice producing @(revision, dirty) :: (String, Bool)@.
--
-- Without @git@ or a @.git@ directory the result is @("unknown", False)@.
gitRevisionQ :: Q Exp
gitRevisionQ = do
  deps <- runIO gitDependentFiles
  mapM_ addDependentFile deps
  (rev, dirty) <- runIO readGitRevision
  [|(rev, dirty)|]

-- | Existing git metadata files whose change means a new revision or index.
gitDependentFiles :: IO [FilePath]
gitDependentFiles = do
  isDir <- doesDirectoryExist ".git"
  if not isDir
    then pure []
    else do
      headTxt <- readFileMaybe (".git" </> "HEAD")
      let refFiles = case headTxt >>= stripPrefix "ref: " . trim of
            Just ref -> [".git" </> ref, ".git" </> "packed-refs"]
            Nothing -> []
          candidates = [".git" </> "HEAD", ".git" </> "index"] <> refFiles
      existing <- filterM doesFileExist candidates
      mapM makeAbsolute existing

readGitRevision :: IO (String, Bool)
readGitRevision = do
  isDir <- doesDirectoryExist ".git"
  if not isDir
    then pure unknown
    else do
      mRev <- gitOutput ["rev-parse", "HEAD"]
      mStatus <- gitOutput ["status", "--porcelain", "--untracked-files=no"]
      pure $ case mRev of
        Just rev | not (null rev) -> (rev, maybe False (not . null) mStatus)
        _ -> unknown
  where
    unknown = ("unknown", False)

gitOutput :: [String] -> IO (Maybe String)
gitOutput args = do
  r <- try @IOException (readProcessWithExitCode "git" args "")
  pure $ case r of
    Right (ExitSuccess, out, _) -> Just (trim out)
    _ -> Nothing

readFileMaybe :: FilePath -> IO (Maybe String)
readFileMaybe path = do
  r <- try @IOException (readFile path >>= \s -> length s `seq` pure s)
  pure (either (const Nothing) Just r)

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
