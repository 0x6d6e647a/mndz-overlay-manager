module CLI.Jobs
  ( mapConcurrentlyN,
    WorkBudget,
    newWorkBudget,
    withWorkSlot,
    workBudgetCapacity,
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

-- | Separate from package job admission: nested Go planning work units
-- (ceilings discovery, list-versions, go.mod probes).
newtype WorkBudget = WorkBudget QSem

-- | Capacity is @2 * max(1, jobs)@.
workBudgetCapacity :: Int -> Int
workBudgetCapacity jobs = 2 * max 1 jobs

-- | Create a work budget for one command run from the resolved package jobs limit.
newWorkBudget :: Int -> IO WorkBudget
newWorkBudget jobs = WorkBudget <$> newQSem (workBudgetCapacity jobs)

-- | Acquire one work-budget slot for the duration of @action@.
withWorkSlot :: WorkBudget -> IO a -> IO a
withWorkSlot (WorkBudget sem) = withSlot sem
