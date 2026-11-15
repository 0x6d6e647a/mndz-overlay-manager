{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | Advisory whole-file @flock@ locks on a lock path, shared or exclusive.
--
-- Each acquire opens its own descriptor, so two holders in one process
-- contend exactly like two processes do. The check cache flush and the
-- managed Gentoo tree both lock through this module.
module Update.FileLock
  ( LockMode (..),
    FileLock,
    acquireFileLock,
    tryAcquireFileLock,
    downgradeFileLock,
    releaseFileLock,
    withFileLock,
  )
where

import Control.Exception (bracket, onException)
import Foreign.C.Error (eINTR, eWOULDBLOCK, getErrno, throwErrno, throwErrnoIfMinus1Retry_)
import Foreign.C.Types (CInt (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.Posix.IO
  ( OpenFileFlags (..),
    OpenMode (ReadWrite),
    closeFd,
    defaultFileFlags,
    openFd,
  )
import System.Posix.Types (Fd (..))

foreign import ccall interruptible "sys/file.h flock"
  c_flock :: CInt -> CInt -> IO CInt

-- | Shared (readers) or exclusive (writer).
data LockMode = SharedLock | ExclusiveLock
  deriving (Eq, Show)

-- | A held lock on its own descriptor. Release with 'releaseFileLock'.
newtype FileLock = FileLock Fd

lockSh, lockEx, lockNb :: CInt
lockSh = 1
lockEx = 2
lockNb = 4

modeFlag :: LockMode -> CInt
modeFlag SharedLock = lockSh
modeFlag ExclusiveLock = lockEx

openLockFd :: FilePath -> IO Fd
openLockFd lockPath = do
  createDirectoryIfMissing True (takeDirectory lockPath)
  openFd lockPath ReadWrite defaultFileFlags {creat = Just 0o600, cloexec = True}

flockWait :: Fd -> LockMode -> IO ()
flockWait (Fd fd) mode =
  throwErrnoIfMinus1Retry_ "flock" (c_flock fd (modeFlag mode))

-- | Take @mode@ on @lockPath@, creating it (mode 0600) when missing. Waits.
acquireFileLock :: LockMode -> FilePath -> IO FileLock
acquireFileLock mode lockPath = do
  fd <- openLockFd lockPath
  flockWait fd mode `onException` closeFd fd
  pure (FileLock fd)

-- | Like 'acquireFileLock' without waiting: 'Nothing' when another holder
-- conflicts.
tryAcquireFileLock :: LockMode -> FilePath -> IO (Maybe FileLock)
tryAcquireFileLock mode lockPath = do
  fd@(Fd raw) <- openLockFd lockPath
  let attempt = do
        rc <- c_flock raw (modeFlag mode + lockNb)
        if rc == 0
          then pure True
          else do
            errno <- getErrno
            if
              | errno == eWOULDBLOCK -> pure False
              | errno == eINTR -> attempt
              | otherwise -> throwErrno "flock"
  ok <- attempt `onException` closeFd fd
  if ok
    then pure (Just (FileLock fd))
    else Nothing <$ closeFd fd

-- | Convert a held exclusive lock to shared on the same descriptor.
downgradeFileLock :: FileLock -> IO ()
downgradeFileLock (FileLock fd) = flockWait fd SharedLock

-- | Drop the lock and close its descriptor.
releaseFileLock :: FileLock -> IO ()
releaseFileLock (FileLock fd) = closeFd fd

-- | Run @action@ while holding @mode@ on @lockPath@.
withFileLock :: LockMode -> FilePath -> IO a -> IO a
withFileLock mode lockPath action =
  bracket (acquireFileLock mode lockPath) releaseFileLock (const action)
