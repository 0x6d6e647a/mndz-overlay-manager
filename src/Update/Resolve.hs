module Update.Resolve
  ( resolveSource,
    resolvePolicy,
  )
where

import Update.Hardcoded (lookupHardcoded, lookupPolicy)
import Update.Types (PackageKey, PackagePolicy, UpdateSource)

-- | Resolve update source from the hardcoded policy map only.
resolveSource :: PackageKey -> Maybe UpdateSource
resolveSource = lookupHardcoded

-- | Full package policy (source + technique).
resolvePolicy :: PackageKey -> Maybe PackagePolicy
resolvePolicy = lookupPolicy
