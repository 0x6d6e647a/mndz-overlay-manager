{-# LANGUAGE OverloadedStrings #-}

module Update.Hardcoded
  ( hardcodedPolicies,
    lookupPolicy,
    lookupHardcoded,
    lookupLaneArches,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Update.Types
  ( CargoSource (..),
    EcosystemSpec (..),
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
        "dev-util/grok-bot-bin"
        ( HttpJson
            { httpJsonUrls =
                [ "https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand",
                  "https://api2.cursor.sh/updates/api/download/stable/linux-arm64/sand"
                ],
              httpJsonField = "version"
            }
        )
        GitMvAndManifest,
      policy
        "dev-util/kiro-cli-bin"
        ( HttpJson
            { httpJsonUrls =
                ["https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json"],
              httpJsonField = "version"
            }
        )
        GitMvAndManifest,
      policy
        "dev-util/kiro-ide-bin"
        ( HttpJson
            { httpJsonUrls =
                [ "https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json",
                  "https://prod.download.desktop.kiro.dev/stable/metadata-linux-arm64-stable.json"
                ],
              httpJsonField = "currentRelease"
            }
        )
        GitMvAndManifest,
      policy
        "net-analyzer/witen-warden-bin"
        ( Http
            { httpPrimary = "https://www.witenlabs.com/api/releases/warden/version",
              httpFallback = Nothing
            }
        )
        GitMvAndManifest,
      policy
        "dev-lisp/qlot"
        (GitHub "fukamachi" "qlot" "")
        GitMvAndManifest,
      policy
        "dev-build/node-gyp"
        (Npm "node-gyp")
        (DepsAndAssets NpmEco),
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
        "dev-db/badger"
        (GitHub "dgraph-io" "badger" "v")
        (DepsAndAssets (Go Nothing)),
      policy
        "dev-util/gastown"
        (GitHub "gastownhall" "gastown" "v")
        (DepsAndAssets (Go Nothing)),
      policy
        "dev-util/openspec"
        (Npm "@fission-ai/openspec")
        (DepsAndAssets NpmEco),
      policy
        "dev-util/rulesync"
        (Npm "rulesync")
        (DepsAndAssets NpmEco),
      policyArches
        "dev-util/claude-agent-acp"
        (Npm "@agentclientprotocol/claude-agent-acp")
        (DepsAndAssets NpmEco)
        ["amd64"],
      policyArches
        "dev-util/codex-acp"
        (Npm "@agentclientprotocol/codex-acp")
        (DepsAndAssets NpmEco)
        ["amd64"],
      policy
        "dev-util/ralph-tui"
        (GitHub "subsy" "ralph-tui" "v")
        (DepsAndAssets Bun),
      policy
        "dev-util/opencode"
        (GitHub "anomalyco" "opencode" "v")
        (DepsAndAssets Bun),
      policy
        "dev-util/hk"
        (GitHub "jdx" "hk" "v")
        (DepsAndAssets (Cargo Nothing Nothing CargoGitTag)),
      policy
        "dev-util/mise"
        (GitHub "jdx" "mise" "v")
        (DepsAndAssets (Cargo Nothing Nothing CargoGitTag)),
      policy
        "dev-util/usage"
        (GitHub "jdx" "usage" "v")
        (DepsAndAssets (Cargo Nothing (Just "cli") CargoGitTag)),
      policy
        "dev-util/biodiff"
        (GitHub "8051enthusiast" "biodiff" "v")
        (DepsAndAssets (Cargo Nothing Nothing CargoCratesIo)),
      policyArches
        "dev-util/codex"
        (GitHub "openai" "codex" "rust-v")
        (DepsAndAssets (Cargo (Just "codex-rs") (Just "codex-rs/cli") CargoGitTag))
        ["amd64"],
      policy
        "dev-util/autolith"
        (GitHub "luciusmagn" "autolith" "v")
        (DepsAndAssets Sbcl),
      policy
        "dev-util/codex-as-mcp"
        (GitHub "kky42" "codex-as-mcp" "v")
        (DepsAndAssets (Uv Nothing)),
      policy
        "dev-util/cmake-language-server"
        (GitHub "regen100" "cmake-language-server" "v")
        (DepsAndAssets (Pdm Nothing)),
      policyArches
        "net-analyzer/caddy-analyzer"
        (GitHub "lenny-ts" "caddy-analyzer" "v")
        (DepsAndAssets (Go Nothing))
        ["amd64", "arm", "arm64"],
      policyArches
        "media-gfx/photocraft"
        (GitHub "storytold" "photocraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/photocraft") CargoGitTag))
        ["amd64", "x86", "arm", "arm64", "ppc64", "loong", "riscv", "sparc", "s390"],
      policy
        "media-fonts/craft-fonts"
        (GitHub "storytold" "craft-fonts" "v")
        (Unsupported "storytold/craft-fonts publishes no comparable numeric tag"),
      policyArches
        "app-office/gridcraft"
        (GitHub "storytold" "gridcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/gridcraft") CargoGitTag))
        craftArches,
      policyArches
        "app-office/wordcraft"
        (GitHub "storytold" "wordcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/wordcraft") CargoGitTag))
        craftArches,
      policyArches
        "app-office/designcraft"
        (GitHub "storytold" "designcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/designcraft") CargoGitTag))
        craftArches,
      policyArches
        "app-office/deckcraft"
        (GitHub "storytold" "deckcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/deckcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-gfx/cadcraft"
        (GitHub "storytold" "cadcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/cadcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-gfx/figcraft"
        (GitHub "storytold" "figcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/figcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-gfx/vectorcraft"
        (GitHub "storytold" "vectorcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/vectorcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-gfx/lightcraft"
        (GitHub "storytold" "lightcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/lightcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-sound/soundcraft"
        (GitHub "storytold" "soundcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/soundcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-video/filmcraft"
        (GitHub "storytold" "filmcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/filmcraft") CargoGitTag))
        craftArches,
      policyArches
        "app-text/pdfcraft"
        (GitHub "storytold" "pdfcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/pdfcraft") CargoGitTag))
        craftArches,
      policyArches
        "media-video/effectcraft"
        (GitHub "storytold" "effectcraft" "v")
        (DepsAndAssets (Cargo Nothing (Just "apps/effectcraft") CargoGitTag))
        craftArches
    ]
  where
    craftArches =
      ["amd64", "x86", "arm", "arm64", "ppc64", "loong", "riscv", "sparc", "s390"]
    policy key src tech = policyArches key src tech []
    policyArches key src tech arches =
      ( PackageKey key,
        PackagePolicy
          { policySource = src,
            policyTechnique = tech,
            policyLaneArches = arches
          }
      )

lookupPolicy :: PackageKey -> Maybe PackagePolicy
lookupPolicy = (`Map.lookup` hardcodedPolicies)

-- | Source-only lookup (for outdated checks).
lookupHardcoded :: PackageKey -> Maybe UpdateSource
lookupHardcoded key = policySource <$> lookupPolicy key

-- | Runtime-lane arch allowlist; empty means every discovered runtime arch.
lookupLaneArches :: PackageKey -> [Text]
lookupLaneArches key = maybe [] policyLaneArches (lookupPolicy key)
