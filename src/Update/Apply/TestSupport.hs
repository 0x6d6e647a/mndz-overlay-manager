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
    fullPathMaterializeSteps,
    reusePathMaterializeSteps,
    materializeStepTotalUpper,
    reviseMaterializeStepTotal,
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
    markSuccessLinesReused,
    materializePlan,
    materializeStepTotalUpper,
    reusePathMaterializeSteps,
    reviseMaterializeStepTotal,
  )
