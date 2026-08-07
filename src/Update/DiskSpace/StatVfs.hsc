-- | Portable @statvfs@ free-space binding via hsc2hs.
--
-- Layout of @struct statvfs@ is taken from the build sysroot headers so free-byte
-- math does not depend on hardcoded glibc x86_64 offsets.
module Update.DiskSpace.StatVfs
  ( freeBytesStatvfs,
  )
where

import Foreign (Ptr, allocaBytes, peekByteOff)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CULong (..))

#include <sys/statvfs.h>

foreign import ccall unsafe "statvfs"
  c_statvfs :: CString -> Ptr () -> IO CInt

-- | Free bytes available to non-root on the filesystem backing @path@
-- (@f_bavail * f_frsize@). Throws 'IOError' on @statvfs@ failure.
freeBytesStatvfs :: FilePath -> IO Integer
freeBytesStatvfs path =
  withCString path $ \cpath ->
    allocaBytes #{size struct statvfs} $ \pst -> do
      rc <- c_statvfs cpath pst
      if rc /= 0
        then ioError (userError ("statvfs failed for " <> path))
        else do
          frsize <- #{peek struct statvfs, f_frsize} pst :: IO CULong
          bavail <- #{peek struct statvfs, f_bavail} pst :: IO CULong
          pure (toInteger bavail * toInteger frsize)
