{-# LANGUAGE OverloadedStrings #-}

module Update.Types
  ( UpdateSource (..),
    PackageKey (..),
    packageKeyText,
    mkPackageKey,
    splitPackageKey,
    OutdatedLine (..),
    UpdateStatus (..),
    UpdateReport (..),
    Fetcher,
    EcosystemSpec (..),
    UpdateTechnique (..),
    PackagePolicy (..),
    SuccessLine (..),
    ApplyOutcome (..),
    outcomeIsHardFail,
    outcomeIsSuccess,
    techniqueNeedsAssets,
    ecosystemIsGo,
    ecosystemIsNpm,
    ecosystemIsBun,
    ecosystemIsCargo,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion)

-- | Where to fetch the latest upstream version.
data UpdateSource
  = GitHub
      { ghOwner :: Text,
        ghRepo :: Text,
        ghTagPrefix :: Text
      }
  | Npm
      { npmPackage :: Text
      }
  | Http
      { httpPrimary :: Text,
        httpFallback :: Maybe Text
      }
  deriving (Eq, Show)

-- | @category/package@ key.
newtype PackageKey = PackageKey {unPackageKey :: Text}
  deriving (Eq, Ord, Show)

packageKeyText :: PackageKey -> Text
packageKeyText = unPackageKey

mkPackageKey :: Text -> Text -> PackageKey
mkPackageKey cat pkg = PackageKey (cat <> "/" <> pkg)

-- | Split @category/package@ into category and package name.
splitPackageKey :: PackageKey -> Maybe (Text, Text)
splitPackageKey (PackageKey t) =
  case T.breakOn "/" t of
    (cat, rest)
      | not (T.null cat),
        Just ('/', pkg) <- T.uncons rest,
        not (T.null pkg) ->
          Just (cat, pkg)
    _ -> Nothing

-- | One outdated report line (optional runtime-lane label).
data OutdatedLine = OutdatedLine
  { olFrom :: EbuildVersion,
    olTo :: EbuildVersion,
    -- | e.g. @Just "(dev-lang/go amd64)"@ for runtime-lane lines.
    olLabel :: Maybe Text,
    -- | Same-PV overlay/Manifest content fix (apply may reuse release assets).
    olAssetsReusable :: Bool
  }
  deriving (Eq, Show)

data UpdateStatus
  = -- | One or more outdated transitions (non-deps: single unlabeled line).
    Outdated [OutdatedLine]
  | Ok EbuildVersion
  | -- | local, remote
    Ahead EbuildVersion EbuildVersion
  | Unconfigured
  | FetchError Text
  deriving (Eq, Show)

data UpdateReport = UpdateReport
  { reportKey :: PackageKey,
    reportStatus :: UpdateStatus
  }
  deriving (Eq, Show)

-- | One success stdout line after apply/commit.
data SuccessLine = SuccessLine
  { slFrom :: EbuildVersion,
    slTo :: EbuildVersion,
    slLabel :: Maybe Text,
    -- | PV was materialized via reuse of an existing release asset.
    slAssetsReused :: Bool
  }
  deriving (Eq, Show)

-- | Injectable fetch function for tests and production.
type Fetcher = UpdateSource -> IO (Either Text EbuildVersion)

-- | Language-deps ecosystem under 'DepsAndAssets'.
data EcosystemSpec
  = -- | Optional subdirectory containing go.mod relative to repo root.
    Go (Maybe FilePath)
  | NpmEco
  | Bun
  | -- | Optional lock/workdir subdir (Cargo.lock) and package subdir (binary Cargo.toml / rust-version).
    -- 'Nothing' means repository root for that role.
    Cargo
      { cargoLockSubdir :: Maybe FilePath,
        cargoPackageSubdir :: Maybe FilePath
      }
  deriving (Eq, Show)

-- | How (or whether) to apply a version bump in the overlay.
data UpdateTechnique
  = GitMvAndManifest
  | DepsAndAssets EcosystemSpec
  | Unsupported Text
  deriving (Eq, Show)

-- | True when the technique publishes to mndz-overlay-assets.
techniqueNeedsAssets :: UpdateTechnique -> Bool
techniqueNeedsAssets (DepsAndAssets _) = True
techniqueNeedsAssets _ = False

ecosystemIsGo :: EcosystemSpec -> Bool
ecosystemIsGo (Go _) = True
ecosystemIsGo _ = False

ecosystemIsNpm :: EcosystemSpec -> Bool
ecosystemIsNpm NpmEco = True
ecosystemIsNpm _ = False

ecosystemIsBun :: EcosystemSpec -> Bool
ecosystemIsBun Bun = True
ecosystemIsBun _ = False

ecosystemIsCargo :: EcosystemSpec -> Bool
ecosystemIsCargo Cargo {} = True
ecosystemIsCargo _ = False

-- | Hardcoded per-package source and apply technique.
data PackagePolicy = PackagePolicy
  { policySource :: UpdateSource,
    policyTechnique :: UpdateTechnique
  }
  deriving (Eq, Show)

-- | Result of attempting to update one package (or one PV commit unit).
data ApplyOutcome
  = -- | Success means the unit is already signed-committed in overlay HEAD.
    -- Path list is for tests/logging only (not a deferred-commit contract).
    ApplySuccess PackageKey [SuccessLine] [FilePath]
  | ApplySoftSkip PackageKey Text
  | -- | message, half-applied (overlay mutated), assets already published
    ApplyHardFail PackageKey Text Bool Bool
  deriving (Eq, Show)

outcomeIsHardFail :: ApplyOutcome -> Bool
outcomeIsHardFail ApplyHardFail {} = True
outcomeIsHardFail _ = False

outcomeIsSuccess :: ApplyOutcome -> Bool
outcomeIsSuccess ApplySuccess {} = True
outcomeIsSuccess _ = False
