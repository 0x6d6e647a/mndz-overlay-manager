{-# LANGUAGE OverloadedStrings #-}

module Update.Hardcoded
  ( hardcodedPolicies,
    lookupPolicy,
    lookupHardcoded,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Update.Types
  ( EcosystemSpec (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateSource (..),
    UpdateTechnique (..),
  )

-- | Hardcoded package → source + technique policy (no inference).
hardcodedPolicies :: Map PackageKey PackagePolicy
hardcodedPolicies =
  Map.fromList
    [ policy
        "dev-lang/bun-bin"
        (GitHub "oven-sh" "bun" "bun-v")
        GitMvAndManifest,
      policy
        "dev-lang/deno-bin"
        (GitHub "denoland" "deno" "v")
        GitMvAndManifest,
      policy
        "dev-util/grok-build-bin"
        ( Http
            { httpPrimary = "https://x.ai/cli/stable",
              httpFallback =
                Just
                  "https://storage.googleapis.com/grok-build-public-artifacts/cli/stable"
            }
        )
        GitMvAndManifest,
      policy
        "dev-util/opencode-bin"
        (GitHub "anomalyco" "opencode" "v")
        GitMvAndManifest,
      policy
        "dev-db/dolt"
        (GitHub "dolthub" "dolt" "v")
        (DepsAndAssets (Go (Just "go"))),
      policy
        "dev-util/beads"
        (GitHub "gastownhall" "beads" "v")
        (DepsAndAssets (Go Nothing)),
      policy
        "dev-util/crush"
        (GitHub "charmbracelet" "crush" "v")
        (DepsAndAssets (Go Nothing)),
      policy
        "dev-util/openspec"
        (Npm "@fission-ai/openspec")
        (DepsAndAssets NpmEco),
      policy
        "dev-util/ralph-tui"
        (GitHub "subsy" "ralph-tui" "v")
        (DepsAndAssets Bun),
      policy
        "dev-util/hk"
        (GitHub "jdx" "hk" "v")
        (DepsAndAssets (Cargo Nothing Nothing)),
      policy
        "dev-util/mise"
        (GitHub "jdx" "mise" "v")
        (DepsAndAssets (Cargo Nothing Nothing)),
      policy
        "dev-util/usage"
        (GitHub "jdx" "usage" "v")
        (DepsAndAssets (Cargo Nothing (Just "cli")))
    ]
  where
    policy key src tech =
      ( PackageKey key,
        PackagePolicy {policySource = src, policyTechnique = tech}
      )

lookupPolicy :: PackageKey -> Maybe PackagePolicy
lookupPolicy = (`Map.lookup` hardcodedPolicies)

-- | Source-only lookup (for outdated checks).
lookupHardcoded :: PackageKey -> Maybe UpdateSource
lookupHardcoded key = policySource <$> lookupPolicy key
