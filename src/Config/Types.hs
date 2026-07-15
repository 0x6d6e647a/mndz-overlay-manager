{-# LANGUAGE OverloadedStrings #-}

module Config.Types
  ( OverlayConfig (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)
import Toml.Schema (FromValue (..), optKey, parseTableFromValue, reqKey)

data OverlayConfig = OverlayConfig
  { mndzOverlayPath :: FilePath,
    mndzOverlayAssetsPath :: Maybe FilePath,
    githubToken :: Maybe Text
  }
  deriving (Eq, Show, Generic)

instance FromValue OverlayConfig where
  fromValue =
    parseTableFromValue $
      OverlayConfig
        <$> reqKey "mndz-overlay-path"
        <*> optKey "mndz-overlay-assets-path"
        <*> optKey "github-token"
