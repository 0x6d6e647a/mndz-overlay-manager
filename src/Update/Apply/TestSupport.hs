-- | Test-only Apply helpers.
--
-- Not part of the product CLI surface. The executable should depend on
-- 'Update.Apply' only. Unit tests may import this module for per-package
-- apply steps, materialize budgets, and related re-exports.
module Update.Apply.TestSupport
  ( applyPackagePhase1,
    newEbuildFileName,
    renderPVNoRev,
    contentFixNeeded,
    goPublishAndOverlay,
    markSuccessLinesReused,
    signedOverlayCommit,
    materializePlan,
    orderNeedPlannedUnits,
    overlayAfterAssets,
    fullPathMaterializeSteps,
    reusePathMaterializeSteps,
    materializeStepTotalUpper,
    reviseMaterializeStepTotal,
    parseConsumerNeeds,
    prettyOverlayAtom,
    harvestVsLaneCeiling,
    atomMatchesPV,
    keepProviderPVs,
    extrasBeyondKeep,
    renameAwayUnsatisfied,
    waitCycleWithEdge,
    prettyWaitCycle,
    OverlayAtom (..),
    VersionOp (..),
    DepNeed (..),
  )
where

import Overlay.Version (renderPVNoRev)
import Update.Apply (applyPackagePhase1)
import Update.Apply.Commit (signedOverlayCommit)
import Update.Apply.GitMv (newEbuildFileName)
import Update.Apply.Materialize
  ( contentFixNeeded,
    fullPathMaterializeSteps,
    goPublishAndOverlay,
    harvestVsLaneCeiling,
    markSuccessLinesReused,
    materializePlan,
    materializeStepTotalUpper,
    orderNeedPlannedUnits,
    reusePathMaterializeSteps,
    reviseMaterializeStepTotal,
  )
import Update.Apply.OverlayWrite (overlayAfterAssets)
import Update.AtomClosure
  ( DepNeed (..),
    OverlayAtom (..),
    VersionOp (..),
    atomMatchesPV,
    extrasBeyondKeep,
    keepProviderPVs,
    parseConsumerNeeds,
    prettyOverlayAtom,
    prettyWaitCycle,
    renameAwayUnsatisfied,
    waitCycleWithEdge,
  )
