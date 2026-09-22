{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Overlay ebuild names and bodies. Syscalls run only while the caller holds
-- 'InTree' from 'withOverlayTree'. The constructor is not exported.
module Update.OverlayTree
  ( InTree,
    TreeLock,
    ObserveOverlay,
    ReentrantTreeLock (..),
    newTreeLock,
    withNewTreeLock,
    withOverlayTree,
    withOverlayTreeChecked,
    readEbuild,
    readEbuildBytes,
    readEbuildEither,
    writeEbuild,
    renameEbuild,
    removeEbuild,
    listEbuildNames,
    tryEbuild,
    ioExceptionMessage,
    ebuildExceptionMessage,
  )
where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Exception
  ( Exception,
    IOException,
    mask,
    onException,
    throwIO,
    try,
    uninterruptibleMask_,
  )
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (UnicodeException)
import GHC.IO.Exception (IOErrorType (..))
import System.Directory (listDirectory, removeFile, renameFile)
import System.IO.Error (ioeGetFileName, mkIOError)

-- | Witness that 'withOverlayTree' holds the lock on this thread.
data InTree = InTree

-- | Apply-wide or per-observation exclusion for overlay ebuild IO.
data TreeLock = TreeLock (MVar ()) (IORef (Maybe ThreadId))

-- | Open one observation. Check, plan, and @gencache@ pass 'withNewTreeLock'.
-- Apply passes @withOverlayTree aeTreeLock@.
type ObserveOverlay = forall a. (InTree -> IO a) -> IO a

-- | Same-thread reentry. A programming error, not an operator hard-fail.
data ReentrantTreeLock = ReentrantTreeLock
  deriving (Eq, Show)

instance Exception ReentrantTreeLock

newTreeLock :: IO TreeLock
newTreeLock = TreeLock <$> newMVar () <*> newIORef Nothing

-- | One observation on a fresh lock. Not the apply lock.
withNewTreeLock :: ObserveOverlay
withNewTreeLock action = do
  lock <- newTreeLock
  withOverlayTree lock action

-- | Hold @lock@ for @action@. Same-thread reentry throws 'ReentrantTreeLock'
-- before 'takeMVar'. The lock is released on success and on exception.
withOverlayTree :: TreeLock -> (InTree -> IO a) -> IO a
withOverlayTree (TreeLock mv ownerRef) action = do
  self <- myThreadId
  owner <- readIORef ownerRef
  when (owner == Just self) $ throwIO ReentrantTreeLock
  mask $ \restore -> do
    takeMVar mv
    writeIORef ownerRef (Just self)
    result <- restore (action InTree) `onException` release
    release
    pure result
  where
    release =
      uninterruptibleMask_ $ do
        writeIORef ownerRef Nothing
        putMVar mv ()

-- | 'withOverlayTree', mapping 'IOException' to a message that names the path.
-- 'ReentrantTreeLock' still propagates.
withOverlayTreeChecked :: TreeLock -> (InTree -> IO a) -> IO (Either Text a)
withOverlayTreeChecked lock action = do
  result <- try (withOverlayTree lock action)
  pure $ case result of
    Left err -> Left (ioExceptionMessage err)
    Right a -> Right a

readEbuild :: InTree -> FilePath -> IO Text
readEbuild tree path = do
  bytes <- readEbuildBytes tree path
  case TE.decodeUtf8' bytes of
    Right txt -> pure txt
    Left err -> ioError (unicodeFailure path err)

readEbuildBytes :: InTree -> FilePath -> IO ByteString
readEbuildBytes InTree = BS.readFile

readEbuildEither :: InTree -> FilePath -> IO (Either Text Text)
readEbuildEither tree path = tryEbuild path (readEbuild tree path)

writeEbuild :: InTree -> FilePath -> Text -> IO ()
writeEbuild InTree path body = BS.writeFile path (TE.encodeUtf8 body)

renameEbuild :: InTree -> FilePath -> FilePath -> IO ()
renameEbuild InTree = renameFile

removeEbuild :: InTree -> FilePath -> IO ()
removeEbuild InTree = removeFile

-- | Directory entry names (basenames), not full paths.
listEbuildNames :: InTree -> FilePath -> IO [FilePath]
listEbuildNames InTree = listDirectory

tryEbuild :: FilePath -> IO a -> IO (Either Text a)
tryEbuild path action = do
  result <- try action
  pure $ case result of
    Left err -> Left (ebuildExceptionMessage path err)
    Right a -> Right a

ebuildExceptionMessage :: FilePath -> IOException -> Text
ebuildExceptionMessage path err =
  T.pack path <> ": " <> T.pack (show err)

ioExceptionMessage :: IOException -> Text
ioExceptionMessage err =
  case ioeGetFileName err of
    Just path -> ebuildExceptionMessage path err
    Nothing -> T.pack (show err)

unicodeFailure :: FilePath -> UnicodeException -> IOError
unicodeFailure path err =
  mkIOError
    InvalidArgument
    (show err)
    Nothing
    (Just path)
