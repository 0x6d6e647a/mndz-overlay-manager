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
import Update.Md5Cache (PackageCacheIssue (..), packageCacheGateError)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey,
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
