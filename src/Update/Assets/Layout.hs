{-# LANGUAGE OverloadedStrings #-}

module Update.Assets.Layout
  ( SidecarPaths (..),
    sidecarPaths,
    packageAssetsDir,
    DistfileKind (..),
    distfileKindForEcosystem,
    distfileTarballName,
    vendorTarballName,
    depsTarballName,
    releaseTag,
    releaseName,
    commitMessage,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import Update.Types (EcosystemSpec (..))

-- | Absolute (or assets-root-relative) paths for the three sidecars.
data SidecarPaths = SidecarPaths
  { spSha256 :: FilePath,
    spSha512 :: FilePath,
    spB3 :: FilePath
  }
  deriving (Eq, Show)

packageAssetsDir :: FilePath -> Text -> Text -> FilePath
packageAssetsDir assetsRoot category package =
  assetsRoot </> T.unpack category </> T.unpack package

-- | @{category}/{package}/{distfile}.{sha256,sha512,b3}@ under assets root.
sidecarPaths :: FilePath -> Text -> Text -> FilePath -> SidecarPaths
sidecarPaths assetsRoot category package distfile =
  let dir = packageAssetsDir assetsRoot category package
   in SidecarPaths
        { spSha256 = dir </> distfile <> ".sha256",
          spSha512 = dir </> distfile <> ".sha512",
          spB3 = dir </> distfile <> ".b3"
        }

-- | Distfile kind for assets release basenames.
data DistfileKind
  = VendorDist
  | DepsDist
  deriving (Eq, Show)

distfileKindForEcosystem :: EcosystemSpec -> DistfileKind
distfileKindForEcosystem (Go _) = VendorDist
distfileKindForEcosystem NpmEco = DepsDist
distfileKindForEcosystem Bun = DepsDist

-- | @{pn}-{pv}-vendor.tar.xz@ or @{pn}-{pv}-deps.tar.xz@ (overlay PN, never npm scope).
distfileTarballName :: DistfileKind -> Text -> Text -> FilePath
distfileTarballName kind pn pv =
  T.unpack pn <> "-" <> T.unpack pv <> suffix
  where
    suffix = case kind of
      VendorDist -> "-vendor.tar.xz"
      DepsDist -> "-deps.tar.xz"

-- | Go vendor distfile basename (always overlay PN).
vendorTarballName :: Text -> Text -> FilePath
vendorTarballName = distfileTarballName VendorDist

-- | npm/Bun deps distfile basename (always overlay PN).
depsTarballName :: Text -> Text -> FilePath
depsTarballName = distfileTarballName DepsDist

releaseTag :: Text -> Text -> Text
releaseTag pn pv = pn <> "-" <> pv

releaseName :: Text -> Text -> Text -> Text
releaseName category pn pv =
  category <> "/" <> pn <> "-" <> pv

commitMessage :: Text -> Text -> Text -> Text
commitMessage category pn pv =
  category <> "/" <> pn <> ": " <> pv
