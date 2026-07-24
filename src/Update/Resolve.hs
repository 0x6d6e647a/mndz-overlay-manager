module Update.Resolve
  ( resolveSource,
  )
where

import Update.Hardcoded (lookupHardcoded)
import Update.Types (PackageKey, UpdateSource)

-- | Resolve update source from the hardcoded policy map only.
resolveSource :: PackageKey -> Maybe UpdateSource
resolveSource = lookupHardcoded
