{-# LANGUAGE OverloadedStrings #-}

module Config.Types
  ( OverlayConfig (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)
import Toml.Schema (FromValue (..), optKey, parseTableFromValue, reqKey)

data OverlayConfig = OverlayConfig
  { overlayPath :: FilePath,
    assetsPath :: Maybe FilePath,
    githubToken :: Maybe Text
  }
  deriving (Eq, Show, Generic)

instance FromValue OverlayConfig where
  fromValue =
    parseTableFromValue $
      OverlayConfig
        <$> reqKey "overlay-path"
        <*> optKey "assets-path"
        <*> optKey "github-token"
