{-# LANGUAGE OverloadedStrings #-}
module Update.Hardcoded
  ( hardcodedSources
  , lookupHardcoded
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Update.Types (PackageKey (..), UpdateSource (..))

-- | Hardcoded package → source map. Takes precedence over inference.
hardcodedSources :: Map PackageKey UpdateSource
hardcodedSources =
  Map.fromList
    [ ( PackageKey "dev-util/grok-build-bin"
      , Http
          { httpPrimary  = "https://x.ai/cli/stable"
          , httpFallback = Just "https://storage.googleapis.com/grok-build-public-artifacts/cli/stable"
          }
      )
    ]

lookupHardcoded :: PackageKey -> Maybe UpdateSource
lookupHardcoded = (`Map.lookup` hardcodedSources)
