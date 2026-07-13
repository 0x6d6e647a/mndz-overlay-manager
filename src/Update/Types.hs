{-# LANGUAGE OverloadedStrings #-}

module Update.Types
  ( UpdateSource (..),
    PackageKey (..),
    packageKeyText,
    mkPackageKey,
    UpdateStatus (..),
    UpdateReport (..),
    Fetcher,
  )
where

import Data.Text (Text)
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
