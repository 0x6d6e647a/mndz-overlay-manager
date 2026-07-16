module CLI.Jobs
  ( mapConcurrentlyN,
  )
where

import Control.Concurrent (QSem, newQSem, signalQSem, waitQSem)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket_)

-- | Like 'mapConcurrently', but at most @n@ actions run at once.
--
-- @n <= 0@ is treated as 1.
mapConcurrentlyN :: Int -> (a -> IO b) -> [a] -> IO [b]
mapConcurrentlyN n f xs = do
  let limit = max 1 n
  sem <- newQSem limit
  mapConcurrently (withSlot sem . f) xs

withSlot :: QSem -> IO a -> IO a
withSlot sem = bracket_ (waitQSem sem) (signalQSem sem)
