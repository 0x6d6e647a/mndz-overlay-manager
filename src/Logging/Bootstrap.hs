module Logging.Bootstrap
  ( bootstrapLogger
  , runWithLogger
  ) where

import Colog (LogAction, Message, cmap, fmtMessage, logTextStderr, usingLoggerT)
import Control.Monad.IO.Class (liftIO)

bootstrapLogger :: LogAction IO Message
bootstrapLogger = cmap fmtMessage logTextStderr

runWithLogger :: LogAction IO Message -> IO a -> IO a
runWithLogger logger action = usingLoggerT logger (liftIO action)
