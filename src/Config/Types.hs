module Config.Types
  ( OverlayConfig(..)
  ) where

import GHC.Generics (Generic)

data OverlayConfig = OverlayConfig
  { mndzOverlayPath :: FilePath
  }
  deriving (Eq, Show, Generic)
