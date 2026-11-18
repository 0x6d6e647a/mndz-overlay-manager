{-# LANGUAGE OverloadedStrings #-}

-- | Structured hard-fail reasons for known apply unit failure classes.
-- Convert to operator 'Text' via 'applyUnitErrorMessage' when constructing
-- 'ApplyHardFail' (exit-code / soft-skip policy is unchanged).
module Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitErrorMessage,
    applyUnitHardFail,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Update.Md5Cache (PackageCacheIssue (..), packageCacheGateError)
import Update.OverlayWaves
  ( overlayFailClosedMessage,
    overlayProviderCascadeMessage,
    overlayRefuseMessage,
  )
import Update.Types
  ( ApplyOutcome (..),
    PackageKey,
    packageKeyText,
  )

-- | Known apply-unit hard-fail classes (dirty paths, md5 gate, assets config, keys).
data ApplyUnitError
  = -- | Involved ebuild and/or Manifest paths are dirty in git.
    ApplyDirtyInvolvedPaths
  | -- | Package md5-cache incomplete or mismatched.
    ApplyMd5CacheGate PackageKey PackageCacheIssue
  | -- | DepsAndAssets requires assets-path configuration.
    ApplyMissingAssetsPath
  | -- | DepsAndAssets release publish requires a GitHub token.
    ApplyMissingGitHubToken
  | -- | Package key is not @category/package@ (optional detail for message).
    ApplyInvalidPackageKey (Maybe Text)
  | -- | Donor/template ebuild path missing when a unit must read it.
    -- Args: package key, planned PV (rendered), path that does not exist.
    ApplyMissingDonorTemplate PackageKey Text FilePath
  | -- | Unselected overlay ceiling provider with plan-delta.
    ApplyOverlayRefuse PackageKey
  | -- | Overlay ceiling provider latest could not be fetched.
    ApplyOverlayFailClosed PackageKey
  | -- | Withheld consumer fails because the overlay provider hard-failed.
    ApplyOverlayProviderCascade PackageKey
  | -- | Overlay-internal atom-closure refuse, parse fail, cycle, or rename-away.
    ApplyAtomClosure Text
  | -- | Smoke gate failure: the failed run's description (atom, lane,
    -- @fail: \<stage\>@ or skip reason, and log).
    ApplyGateFailed Text
  | -- | Published asset verification: the URL and the mismatch.
    ApplyVerifyFailed Text Text
  | -- | Overlay push failed after the commit: overlay root and git's error.
    ApplyOverlayPushFailed FilePath Text
  | -- | Publishing halted before this unit; names the failed push.
    ApplyPublishingHalted Text
  deriving (Eq, Show)

applyUnitErrorMessage :: ApplyUnitError -> Text
applyUnitErrorMessage = \case
  ApplyDirtyInvolvedPaths ->
    "involved paths are dirty (newest ebuild and/or Manifest)"
  ApplyMd5CacheGate key issue -> packageCacheGateError key issue
  ApplyMissingAssetsPath ->
    "assets-path is required for DepsAndAssets packages"
  ApplyMissingGitHubToken ->
    "GitHub token is required to publish assets releases"
  ApplyInvalidPackageKey Nothing -> "invalid package key"
  ApplyInvalidPackageKey (Just detail) ->
    "invalid package key: " <> detail
  ApplyMissingDonorTemplate key pv path ->
    "missing donor/template ebuild for "
      <> packageKeyText key
      <> " planned PV "
      <> pv
      <> " at "
      <> T.pack path
  ApplyOverlayRefuse provider -> overlayRefuseMessage provider
  ApplyOverlayFailClosed provider -> overlayFailClosedMessage provider
  ApplyOverlayProviderCascade provider -> overlayProviderCascadeMessage provider
  ApplyAtomClosure msg -> msg
  ApplyGateFailed detail -> "smoke gate failed: " <> detail
  ApplyVerifyFailed url why ->
    "published asset verification failed for " <> url <> ": " <> why
  ApplyOverlayPushFailed overlay err ->
    "overlay push failed (the commit is kept; publishing halted for this run): "
      <> err
      <> "; push it with: git -C "
      <> T.pack overlay
      <> " push"
  ApplyPublishingHalted cause ->
    "publishing halted because " <> cause <> "; this unit was not published or committed"

-- | Build 'ApplyHardFail' with stable operator wording for a known unit error.
-- Remaining args are half-applied (overlay mutated) and assets-published flags.
applyUnitHardFail ::
  PackageKey ->
  ApplyUnitError ->
  Bool ->
  Bool ->
  ApplyOutcome
applyUnitHardFail key err =
  ApplyHardFail key (applyUnitErrorMessage err)
