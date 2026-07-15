{-# LANGUAGE OverloadedStrings #-}

module Update.Types
  ( UpdateSource (..),
    PackageKey (..),
    packageKeyText,
    mkPackageKey,
    splitPackageKey,
    UpdateStatus (..),
    UpdateReport (..),
    Fetcher,
    UpdateTechnique (..),
    PackagePolicy (..),
    ApplyOutcome (..),
    outcomeIsHardFail,
    outcomeIsSuccess,
    techniqueNeedsAssets,
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

data UpdateStatus
  = -- | local, remote
    Outdated EbuildVersion EbuildVersion
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

-- | Injectable fetch function for tests and production.
type Fetcher = UpdateSource -> IO (Either Text EbuildVersion)

-- | How (or whether) to apply a version bump in the overlay.
data UpdateTechnique
  = GitMvAndManifest
  | -- | Optional subdirectory containing go.mod relative to repo root.
    GoVendorAndAssets (Maybe FilePath)
  | Unsupported Text
  deriving (Eq, Show)

-- | True when the technique publishes to mndz-overlay-assets.
techniqueNeedsAssets :: UpdateTechnique -> Bool
techniqueNeedsAssets (GoVendorAndAssets _) = True
techniqueNeedsAssets _ = False

-- | Hardcoded per-package source and apply technique.
data PackagePolicy = PackagePolicy
  { policySource :: UpdateSource,
    policyTechnique :: UpdateTechnique
  }
  deriving (Eq, Show)

-- | Result of attempting to update one package.
data ApplyOutcome
  = -- | local, remote, paths relative to overlay root for git add
    ApplySuccess PackageKey EbuildVersion EbuildVersion [FilePath]
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
