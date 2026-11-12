{-# LANGUAGE OverloadedStrings #-}

module CLI.Jobs
  ( mapConcurrentlyN,
    WorkBudget,
    newWorkBudget,
    workBudgetWithMetrics,
    withWorkSlot,
    workBudgetCapacity,
    withMeasuredSlot,
    PackSlot,
    newPackSlot,
    packSlotWithMetrics,
    packSlotMetrics,
    withPackSlot,
  )
where

import Control.Concurrent (QSem, newQSem, signalQSem, waitQSem)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket_)
import Data.Aeson ((.=))
import Data.Text (Text)
import Metrics.Core (Metrics, captureSpanContext, noopMetrics, withSpan)

-- | Like 'mapConcurrently', but at most @n@ actions run at once.
--
-- @n <= 0@ is treated as 1. Each child inherits the caller's metrics span,
-- and waiting for a job slot is a @slot.wait@ span of kind @jobs@.
mapConcurrentlyN :: Metrics -> Int -> (a -> IO b) -> [a] -> IO [b]
mapConcurrentlyN m n f xs = do
  let limit = max 1 n
  sem <- newQSem limit
  inherit <- captureSpanContext m
  mapConcurrently (inherit . withMeasuredSlot m "jobs" limit sem . f) xs

-- | Hold one unit of @sem@ for @action@; time spent waiting for it is a
-- @slot.wait@ span with the slot kind and capacity.
withMeasuredSlot :: Metrics -> Text -> Int -> QSem -> IO a -> IO a
withMeasuredSlot m kind capacity sem =
  bracket_
    ( withSpan
        m
        "slot.wait"
        ["kind" .= kind, "capacity" .= capacity]
        (waitQSem sem)
    )
    (signalQSem sem)

-- | Separate from package job admission: nested Go planning work units
-- (ceilings discovery, list-versions, go.mod probes).
data WorkBudget = WorkBudget
  { wbSem :: QSem,
    wbCapacity :: Int,
    wbMetrics :: Metrics
  }

-- | Capacity is @2 * max(1, jobs)@.
workBudgetCapacity :: Int -> Int
workBudgetCapacity jobs = 2 * max 1 jobs

-- | Create a work budget for one command run from the resolved package jobs limit.
newWorkBudget :: Int -> IO WorkBudget
newWorkBudget jobs = do
  let cap = workBudgetCapacity jobs
  sem <- newQSem cap
  pure WorkBudget {wbSem = sem, wbCapacity = cap, wbMetrics = noopMetrics}

-- | Record @slot.wait@ spans (kind @work@) for this budget's slots.
workBudgetWithMetrics :: Metrics -> WorkBudget -> WorkBudget
workBudgetWithMetrics m wb = wb {wbMetrics = m}

-- | Acquire one work-budget slot for the duration of @action@.
withWorkSlot :: WorkBudget -> IO a -> IO a
withWorkSlot wb = withMeasuredSlot (wbMetrics wb) "work" (wbCapacity wb) (wbSem wb)

-- | The update's shared capacity-1 compression slot. Waiting for it is a
-- @slot.wait@ span of kind @pack@.
data PackSlot = PackSlot
  { packSem :: QSem,
    packMetrics :: Metrics
  }

newPackSlot :: IO PackSlot
newPackSlot = do
  sem <- newQSem 1
  pure PackSlot {packSem = sem, packMetrics = noopMetrics}

-- | Recorder for spans and counters of work under this slot.
packSlotMetrics :: PackSlot -> Metrics
packSlotMetrics = packMetrics

-- | Record @slot.wait@ spans (kind @pack@) for this slot.
packSlotWithMetrics :: Metrics -> PackSlot -> PackSlot
packSlotWithMetrics m slot = slot {packMetrics = m}

-- | Hold the pack slot for the duration of @action@.
withPackSlot :: PackSlot -> IO a -> IO a
withPackSlot slot = withMeasuredSlot (packMetrics slot) "pack" 1 (packSem slot)
