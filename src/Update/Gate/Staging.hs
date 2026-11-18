{-# LANGUAGE OverloadedStrings #-}

-- | The per-unit directory of distfiles a gated smoke run may fetch before
-- they are published. It holds exactly the unit's built distfiles, so the
-- manager @DISTDIR@ itself is never mounted into a container.
module Update.Gate.Staging
  ( buildStagingDir,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeFileName, (</>))
import System.Posix.Files (createLink)

-- | Create @dir@ holding each built distfile by its basename: a hard link,
-- or a copy when linking fails (for example across filesystems). Two
-- distfiles with the same basename are an error.
buildStagingDir :: FilePath -> [FilePath] -> IO (Either Text ())
buildStagingDir dir files
  | length (nub names) /= length names =
      pure (Left ("distfiles with the same name cannot be staged together: " <> T.intercalate ", " (map T.pack files)))
  | otherwise = do
      made <- try @IOException (createDirectoryIfMissing True dir)
      case made of
        Left err -> pure (Left ("could not create the staging directory " <> T.pack dir <> ": " <> T.pack (show err)))
        Right () -> do
          results <- forM files $ \src -> do
            let dst = dir </> takeFileName src
            already <- doesFileExist dst
            _ <- if already then try @IOException (removeFile dst) else pure (Right ())
            linked <- try @IOException (createLink src dst)
            case linked of
              Right () -> pure (Right ())
              Left _ -> do
                copied <- try @IOException (copyFile src dst)
                pure $ case copied of
                  Right () -> Right ()
                  Left err -> Left ("could not stage " <> T.pack src <> ": " <> T.pack (show err))
          pure (sequence_ results)
  where
    names = map takeFileName files
