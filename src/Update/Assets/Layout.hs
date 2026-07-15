{-# LANGUAGE OverloadedStrings #-}

module Update.Assets.Layout
  ( SidecarPaths (..),
    sidecarPaths,
    packageAssetsDir,
    vendorTarballName,
    releaseTag,
    releaseName,
    commitMessage,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))

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

vendorTarballName :: Text -> Text -> FilePath
vendorTarballName pn pv =
  T.unpack pn <> "-" <> T.unpack pv <> "-vendor.tar.xz"

releaseTag :: Text -> Text -> Text
releaseTag pn pv = pn <> "-" <> pv

releaseName :: Text -> Text -> Text -> Text
releaseName category pn pv =
  category <> "/" <> pn <> "-" <> pv

commitMessage :: Text -> Text -> Text -> Text
commitMessage category pn pv =
  category <> "/" <> pn <> ": " <> pv
