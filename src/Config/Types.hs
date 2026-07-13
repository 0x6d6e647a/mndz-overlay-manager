{-# LANGUAGE OverloadedStrings #-}

module Config.Types
  ( OverlayConfig (..),
  )
where

import GHC.Generics (Generic)
import Toml.Schema (FromValue (..), parseTableFromValue, reqKey)

newtype OverlayConfig = OverlayConfig
  { mndzOverlayPath :: FilePath
  }
  deriving (Eq, Show, Generic)

instance FromValue OverlayConfig where
  fromValue =
    parseTableFromValue $
      OverlayConfig <$> reqKey "mndz-overlay-path"
