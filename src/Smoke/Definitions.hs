{-# LANGUAGE OverloadedStrings #-}

-- | Smoke definitions for every overlay package with a hardcoded update
-- policy. A floor definition runs the program's version or help option;
-- packages whose seed spec describes a richer smoke carry that one.
module Smoke.Definitions
  ( smokeDefinitions,
    lookupSmokeDef,
    craftAppDef,
    craftApps,
  )
where

import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Smoke.Check
  ( Check (..),
    CheckCtx (..),
    Expect,
    Outcome (..),
    SmokeDef (..),
    allOf,
    argv,
    check,
    exitsWith,
    filesExist,
    firstLineIs,
    helpCheck,
    networked,
    outputContains,
    outputContainsPv,
    outputLacks,
    shell,
    smokeDef,
    step,
    timeoutAfter,
    versionCheck,
  )
import Update.Types (PackageKey (..), mkPackageKey)

lookupSmokeDef :: PackageKey -> Maybe SmokeDef
lookupSmokeDef = (`Map.lookup` smokeDefinitions)

smokeDefinitions :: Map PackageKey SmokeDef
smokeDefinitions =
  Map.fromList $
    [ -- Floor definitions.
      floorVersion "dev-db/dolt" "dolt" ["version"],
      (PackageKey "dev-lang/bun-bin", bunBinDef),
      floorVersion "dev-lang/deno-bin" "deno" ["--version"],
      floorVersion "dev-util/beads" "bd" ["version"],
      floorVersion "dev-util/crush" "crush" ["--version"],
      floorVersion "dev-util/grok-build-bin" "grok" ["--version"],
      floorVersion "dev-util/hk" "hk" ["--version"],
      floorVersion "dev-util/mise" "mise" ["--version"],
      floorVersion "dev-util/opencode" "opencode" ["--version"],
      floorVersion "dev-util/openspec" "openspec" ["--version"],
      floorVersion "dev-util/ralph-tui" "ralph-tui" ["--version"],
      floorVersion "dev-util/usage" "usage" ["--version"],
      (PackageKey "media-fonts/craft-fonts", smokeDef (filesExist ["/usr/share/craft-fonts/fonts"]) []),
      -- Seed-spec smokes.
      (PackageKey "dev-build/node-gyp", smokeDef (versionCheck "node-gyp" ["--version"]) []),
      (PackageKey "dev-db/badger", badgerDef),
      (PackageKey "dev-lisp/qlot", qlotDef),
      (PackageKey "dev-util/biodiff", versionAndHelp "biodiff"),
      (PackageKey "dev-util/cargo-llvm-cov", cargoLlvmCovDef),
      (PackageKey "dev-util/cargo-outdated", cargoOutdatedDef),
      (PackageKey "dev-util/cargo-update", cargoUpdateDef),
      (PackageKey "dev-util/rulesync", versionAndHelp "rulesync"),
      (PackageKey "net-analyzer/caddy-analyzer", caddyAnalyzerDef),
      (PackageKey "dev-util/cmake-language-server", cmakeLanguageServerDef),
      (PackageKey "dev-util/autolith", autolithDef),
      (PackageKey "dev-util/gastown", gastownDef),
      (PackageKey "dev-util/codex", codexDef),
      (PackageKey "dev-util/codex-acp", smokeDef (exactFirstLine "codex-acp" "@agentclientprotocol/codex-acp {PV}") []),
      (PackageKey "dev-util/codex-as-mcp", smokeDef (helpCheck "/usr/bin/codex-as-mcp") []),
      ( PackageKey "dev-util/claude-agent-acp",
        -- dev-util/claude-code requires AVX and AVX2 on amd64.
        (smokeDef (exactFirstLine "claude-agent-acp" "{PV}") [])
          { sdPackageUse = ["dev-util/claude-code cpu_flags_x86_avx cpu_flags_x86_avx2"]
          }
      ),
      ( PackageKey "dev-util/grok-bot-bin",
        (smokeDef (filesExist ["/usr/bin/grok-bot", "/opt/Grok Bot/grok-bot"]) []) {sdPackageUse = pulseaudioUse}
      ),
      (PackageKey "dev-util/kiro-cli-bin", smokeDef (versionCheck "kiro-cli" ["--version"]) []),
      (PackageKey "dev-util/kiro-ide-bin", (smokeDef (exactFirstLine "kiro" "{PV}") []) {sdPackageUse = pulseaudioUse}),
      (PackageKey "net-analyzer/witen-warden-bin", wardenDef)
    ]
      <> [(mkPackageKey cat name, craftAppDef name) | (cat, name) <- craftApps]

-- | Every slot installs @bun-\<PV\>@; only slot 0 adds @bun@.
bunBinDef :: SmokeDef
bunBinDef =
  smokeDef
    (check "version" (step (\ctx -> argv ["bun-" <> ccPv ctx, "--version"]) (allOf [exitsWith 0, outputContainsPv])) [])
    []

floorVersion :: Text -> Text -> [Text] -> (PackageKey, SmokeDef)
floorVersion key prog args = (PackageKey key, smokeDef (versionCheck prog args) [])

versionAndHelp :: Text -> SmokeDef
versionAndHelp prog = smokeDef (versionCheck prog ["--version"]) [helpCheck prog]

-- | @version@: @prog --version@ exits 0 and its first line is @expected@.
exactFirstLine :: Text -> Text -> Check
exactFirstLine prog expected =
  check "version" (step (const (argv [prog, "--version"])) (allOf [exitsWith 0, firstLineIs expected])) []

-- | The 13 Storytold craft apps (category, name).
craftApps :: [(Text, Text)]
craftApps =
  [ ("app-office", "deckcraft"),
    ("app-office", "designcraft"),
    ("app-office", "gridcraft"),
    ("app-office", "wordcraft"),
    ("app-text", "pdfcraft"),
    ("media-gfx", "cadcraft"),
    ("media-gfx", "figcraft"),
    ("media-gfx", "lightcraft"),
    ("media-gfx", "photocraft"),
    ("media-gfx", "vectorcraft"),
    ("media-sound", "soundcraft"),
    ("media-video", "effectcraft"),
    ("media-video", "filmcraft")
  ]

-- | Gentoo's pulseaudio stack with the flags its @alsa-plugin@ path needs.
pulseaudioUse :: [Text]
pulseaudioUse = ["media-libs/libpulse X", "media-plugins/alsa-plugins pulseaudio"]

-- | @\<name\> --version@ and @\<name\>-cli --version@, offline, no display.
-- The apps' default @USE=X@ needs @libxkbcommon[X]@.
craftAppDef :: Text -> SmokeDef
craftAppDef name =
  ( smokeDef
      (versionCheck name ["--version"])
      [(versionCheck (name <> "-cli") ["--version"]) {ckName = "cli-version"}]
  )
    { sdPackageUse = ["x11-libs/libxkbcommon X"]
    }

badgerDef :: SmokeDef
badgerDef =
  smokeDef
    (check "help" (step (const (argv ["badger", "--help"])) (allOf [exitsWith 0, outputContains "Available Commands"])) [])
    []

-- | Upstream @qlot --version@ exits 255 after printing; that status is accepted.
qlotDef :: SmokeDef
qlotDef =
  smokeDef
    (check "version" (step (const (argv ["qlot", "--version"])) (allOf [exitsWithAny [0, 255], outputContainsPv])) [])
    []

exitsWithAny :: [Int] -> Expect
exitsWithAny codes _ o
  | oExit o `elem` codes = Right ()
  | otherwise = Left ("exited " <> T.pack (show (oExit o)) <> ", expected one of " <> T.pack (show codes))

cargoLlvmCovDef :: SmokeDef
cargoLlvmCovDef =
  smokeDef
    (versionCheck "cargo" ["llvm-cov", "--version"])
    [ timeoutAfter 600 $
        check
          "coverage"
          (step (const (argv ["cargo", "new", "--lib", "--vcs", "none", "demo"])) (exitsWith 0))
          [ step
              (const (shell "cd demo && env -u LLVM_COV -u LLVM_PROFDATA cargo llvm-cov"))
              (exitsWith 0)
          ]
    ]

cargoOutdatedDef :: SmokeDef
cargoOutdatedDef =
  smokeDef
    (versionCheck "cargo" ["outdated", "--version"])
    [ check "help" (step (const (argv ["cargo", "outdated", "--help"])) (exitsWith 0)) [],
      networked . timeoutAfter 300 $
        check
          "outdated"
          (step (const (argv ["cargo", "new", "--vcs", "none", "demo"])) (exitsWith 0))
          [ step (const (shell "printf 'libc = \"0.1\"\\n' >> demo/Cargo.toml")) (exitsWith 0),
            step
              (const (shell "cd demo && CARGO_HOME=/home/smoke/cargo-home cargo outdated"))
              (allOf [exitsWith 0, outputContains "libc"])
          ]
    ]

cargoUpdateDef :: SmokeDef
cargoUpdateDef =
  smokeDef
    (versionCheck "cargo" ["install-update", "--version"])
    [ check "help" (step (const (argv ["cargo", "install-update", "--help"])) (exitsWith 0)) [],
      check "config-help" (step (const (argv ["cargo", "install-update-config", "--help"])) (exitsWith 0)) []
    ]

caddyAnalyzerDef :: SmokeDef
caddyAnalyzerDef =
  smokeDef
    (versionCheck "caddy-analyze" ["--version"])
    [ helpCheck "caddy-analyze",
      check
        "completion"
        (step (const (argv ["caddy-analyze", "completion", "bash"])) (allOf [exitsWith 0, outputContains "caddy-analyze"]))
        [],
      check
        "analyze"
        (step (const (shell ("printf '%s\\n' " <> T.unwords (map quote syntheticLog) <> " > access.log"))) (exitsWith 0))
        [ step
            (const (argv ["caddy-analyze", "--no-auto-download", "-f", "json", "access.log"]))
            (allOf [exitsWith 0, jsonTotalRequests (length syntheticLog)])
        ]
    ]
  where
    quote t = "'" <> t <> "'"

-- | Three Caddy JSON access-log lines.
syntheticLog :: [Text]
syntheticLog =
  [ "{\"level\":\"info\",\"ts\":1763280000." <> i <> ",\"logger\":\"http.log.access\",\"msg\":\"handled request\",\"request\":{\"remote_ip\":\"192.0.2." <> i <> "\",\"client_ip\":\"192.0.2." <> i <> "\",\"proto\":\"HTTP/1.1\",\"method\":\"GET\",\"host\":\"example.test\",\"uri\":\"/page" <> i <> "\",\"headers\":{\"User-Agent\":[\"smoke\"]}},\"bytes_read\":0,\"duration\":0.0012,\"size\":512,\"status\":200,\"resp_headers\":{}}"
  | i <- ["1", "2", "3"]
  ]

-- | Standard output is a JSON object whose @total_requests@ is @n@.
jsonTotalRequests :: Int -> Expect
jsonTotalRequests n _ o =
  case decodeStrict (encodeUtf8 (oStdout o)) of
    Just (Object obj) -> case KM.lookup "total_requests" obj of
      Just (Number x) | x == fromIntegral n -> Right ()
      other -> Left ("total_requests is " <> T.pack (show other) <> ", expected " <> T.pack (show n))
    _ -> Left "output is not a JSON object"

cmakeLanguageServerDef :: SmokeDef
cmakeLanguageServerDef =
  ( smokeDef
      ( check
          "version"
          ( step
              (const (argv ["cmake-language-server", "--version"]))
              (\ctx -> allOf [exitsWith 0, outputContains ("cmake-language-server " <> ccPv ctx)] ctx)
          )
          []
      )
      []
  )
    { -- pdm and these of its dependencies are testing-only in Gentoo.
      sdAcceptKeywords =
        [ "dev-python/pdm",
          "dev-python/dep-logic",
          "dev-python/hishel",
          "dev-python/httpx2",
          "dev-python/pbs-installer",
          "dev-python/unearth"
        ]
    }

-- | @--version@ alone does not prove the relocated helper works; a session
-- start (stopped after five seconds by its own @timeout@) must not report a
-- missing helper under the Portage work directory.
autolithDef :: SmokeDef
autolithDef =
  ( smokeDef
      (versionCheck "autolith" ["--version"])
      [ timeoutAfter 30 $
          check
            "start"
            (step (const (shell "timeout 5 autolith </dev/null 2>&1; true")) (allOf [exitsWith 0, outputLacks "/var/tmp/portage"]))
            []
      ]
  )
    { sdPackageUse = ["dev-lisp/sbcl source"]
    }

gastownDef :: SmokeDef
gastownDef =
  smokeDef
    (versionCheck "gt" ["version"])
    [ timeoutAfter 300 $
        check
          "town"
          (step (const (argv ["gt", "install", "/home/smoke/town", "--name", "smoke"])) (exitsWith 0))
          [ step
              (const (shell "cd /home/smoke/town && gt status"))
              (allOf [exitsWith 0, outputContains "smoke", outputContainsCI "dolt"])
          ]
    ]

outputContainsCI :: Text -> Expect
outputContainsCI needle _ o
  | T.toLower needle `T.isInfixOf` T.toLower (oStdout o <> oStderr o) = Right ()
  | otherwise = Left ("output does not mention " <> needle)

codexDef :: SmokeDef
codexDef =
  smokeDef
    (versionCheck "codex" ["--version"])
    [ check
        "completion"
        (step (const (argv ["codex", "completion", "bash"])) (allOf [exitsWith 0, outputContains "_codex()"]))
        [],
      helpCheck "codex-code-mode-host"
    ]

-- | Safe version smoke with the daemon stopped: @validate@ may report an
-- overall failure, but the four static parts must be ok.
wardenDef :: SmokeDef
wardenDef =
  -- The configuration is readable by root and the witen-warden group only.
  ( smokeDef
      (exactFirstLine "warden" "warden {PV}")
      [ check
          "version-json"
          (step (const (argv ["warden", "version", "--json"])) (\ctx -> allOf [exitsWith 0, outputContains ("\"version\":\"" <> ccPv ctx <> "\"")] ctx))
          [],
        check
          "validate"
          (step (const (argv ["warden", "validate"])) (validatesOk ["config", "config_schema", "actuator", "firewall_nft"]))
          []
      ]
  )
    { sdCheckGroups = ["witen-warden"]
    }

-- | Each named part has a @\<name\> ok@ line, whatever the overall status.
validatesOk :: [Text] -> Expect
validatesOk parts _ o =
  case [p | p <- parts, not (any (isOk p) (T.lines (oStdout o <> "\n" <> oStderr o)))] of
    [] -> Right ()
    missing -> Left ("not ok: " <> T.intercalate ", " missing)
  where
    isOk p line = case T.words (T.dropWhile isSpace line) of
      name : status : _ -> name == p && T.toLower status == "ok"
      _ -> False
