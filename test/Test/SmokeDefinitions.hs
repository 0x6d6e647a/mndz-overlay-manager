{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for the per-package smoke definitions with a fake exec.
module Test.SmokeDefinitions (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (parseEbuildVersion)
import Smoke.Check
  ( Check (..),
    CheckCtx (..),
    CheckIO (..),
    CheckResult (..),
    Command (..),
    Outcome (..),
    SmokeDef (..),
    failedCheckNames,
    runChecks,
  )
import Smoke.Definitions (craftApps, smokeDefinitions)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Hardcoded (hardcodedPolicies)
import Update.Types (PackageKey (..))

tests :: TestTree
tests =
  testGroup
    "SmokeDefinitions"
    [ testCase "definitions cover exactly the hardcoded policies" $
        assertEq "keys" (Map.keys hardcodedPolicies) (Map.keys smokeDefinitions),
      testCase "check names are unique within each definition" $
        assertEq
          "duplicates"
          []
          [ k
          | (k, d) <- Map.toList smokeDefinitions,
            let names = map ckName (NE.toList (sdChecks d)),
            length names /= length (Map.keys (Map.fromList [(n, ()) | n <- names]))
          ],
      testCase "only cargo-outdated declares network" $
        assertEq
          "networked"
          [PackageKey "dev-util/cargo-outdated"]
          [k | (k, d) <- Map.toList smokeDefinitions, any ckNetwork (sdChecks d)],
      testCase "craft app: both commands run offline" testCraftApp,
      testCase "qlot: status 255 is accepted" testQlot,
      testCase "cargo-outdated: network check expects libc" testCargoOutdated,
      testCase "caddy-analyzer: JSON request count" testCaddyAnalyzer,
      testCase "autolith: no-argument start with its own timeout" testAutolith,
      testCase "bun-bin: runs the slotted binary" testBunBin,
      testCase "cmake-language-server: accepts testing pdm" $
        assertTrue "keywords" ("dev-python/pdm" `elem` sdAcceptKeywords (def "dev-util/cmake-language-server")),
      testCase "USE lines and check groups where Gentoo defaults fall short" testUseAndGroups,
      testCase "kiro-ide: first line is the PV" testKiroIde,
      testCase "witen-warden: validate may fail overall but parts must be ok" testWarden
    ]

def :: Text -> SmokeDef
def k = case Map.lookup (PackageKey k) smokeDefinitions of
  Just d -> d
  Nothing -> error ("no definition for " <> T.unpack k)

ctxFor :: Text -> Text -> CheckCtx
ctxFor k pv = CheckCtx {ccKey = PackageKey k, ccVersion = parseEbuildVersion pv, ccPv = pv}

-- | Run a definition against a fake exec; returns results, commands with
-- limits, and network events.
runDef :: Text -> Text -> (Command -> Outcome) -> IO ([CheckResult], [(Int, [Text])], [Text])
runDef k pv respond = do
  cmds <- newIORef []
  net <- newIORef []
  let cio =
        CheckIO
          { cioExec = \limit cmd -> do
              modifyIORef' cmds (++ [(limit, cmdArgv cmd)])
              modifyIORef' net (++ ["exec"])
              pure (respond cmd),
            cioNetwork = \up -> do
              modifyIORef' net (++ [if up then "attach" else "detach"])
              pure (Right ())
          }
  rs <- runChecks cio (ctxFor k pv) (sdChecks (def k))
  (,,) rs <$> readIORef cmds <*> readIORef net

ok :: Text -> Outcome
ok o = Outcome 0 o ""

testCraftApp :: IO ()
testCraftApp = do
  assertEq "13 apps" 13 (length craftApps)
  (rs, cmds, net) <- runDef "media-gfx/photocraft" "0.1.1" $ \cmd -> ok (T.unwords (take 1 (cmdArgv cmd)) <> " 0.1.1")
  assertEq "passes" [] (failedCheckNames rs)
  assertEq "both commands" [["photocraft", "--version"], ["photocraft-cli", "--version"]] (map snd cmds)
  assertTrue "offline" ("attach" `notElem` net)

testQlot :: IO ()
testQlot = do
  (rs, _, _) <- runDef "dev-lisp/qlot" "1.8.4" (\_ -> Outcome 255 "Qlot 1.8.4\n" "")
  assertEq "255 accepted" [] (failedCheckNames rs)
  (rs', _, _) <- runDef "dev-lisp/qlot" "1.8.4" (\_ -> Outcome 1 "Qlot 1.8.4\n" "")
  assertEq "1 rejected" ["version"] (failedCheckNames rs')

testCargoOutdated :: IO ()
testCargoOutdated = do
  let respond cmd
        | "outdated --version" `T.isInfixOf` T.unwords (cmdArgv cmd) = ok "cargo-outdated 0.19.0"
        | "cargo outdated" `T.isInfixOf` T.unwords (cmdArgv cmd) = ok "Name  Project  Compat\nlibc  0.1.12   ---"
        | otherwise = ok ""
  (rs, cmds, net) <- runDef "dev-util/cargo-outdated" "0.19.0" respond
  assertEq "passes" [] (failedCheckNames rs)
  assertTrue "throwaway crate depends on libc 0.1" (any (any ("libc = \"0.1\"" `T.isInfixOf`) . snd) cmds)
  assertTrue "temporary CARGO_HOME" (any (any ("CARGO_HOME=/home/smoke/cargo-home" `T.isInfixOf`) . snd) cmds)
  assertEq "attached around the network check only" ["exec", "exec", "attach", "exec", "exec", "exec", "detach"] net
  (rs', _, _) <- runDef "dev-util/cargo-outdated" "0.19.0" $ \cmd ->
    if "cd demo" `T.isInfixOf` T.unwords (cmdArgv cmd) then ok "All dependencies are up to date" else respond cmd
  assertEq "libc missing fails" ["outdated"] (failedCheckNames rs')

testCaddyAnalyzer :: IO ()
testCaddyAnalyzer = do
  let respond n cmd
        | cmdArgv cmd == ["caddy-analyze", "--no-auto-download", "-f", "json", "access.log"] =
            Outcome 0 ("{\"total_requests\": " <> n <> ", \"parse_errors\": 0}") "warning: geoip: no GeoIP mmdb file found"
        | otherwise = ok "caddy-analyze version 0.8.1 caddy-analyze"
  (rs, cmds, _) <- runDef "net-analyzer/caddy-analyzer" "0.8.1" (respond "3")
  assertEq "passes" [] (failedCheckNames rs)
  assertTrue "writes the synthetic log" (any (any ("> access.log" `T.isInfixOf`) . snd) cmds)
  (rs', _, _) <- runDef "net-analyzer/caddy-analyzer" "0.8.1" (respond "2")
  assertEq "wrong count fails" ["analyze"] (failedCheckNames rs')

testAutolith :: IO ()
testAutolith = do
  (rs, cmds, _) <- runDef "dev-util/autolith" "0.67.47" $ \cmd ->
    if cmdArgv cmd == ["autolith", "--version"] then ok "autolith 0.67.47" else ok "fff helper missing at /var/tmp/portage/dev-util/autolith/work"
  assertEq "start fails on the portage path" ["start"] (failedCheckNames rs)
  case [(l, a) | (l, a) <- cmds, a /= ["autolith", "--version"]] of
    [(limit, as)] -> do
      assertEq "own limit" 30 limit
      assertTrue "no arguments, empty stdin" (any ("timeout 5 autolith </dev/null" `T.isInfixOf`) as)
    other -> assertFailure ("expected one start command, got " <> show other)

testKiroIde :: IO ()
testKiroIde = do
  (rs, _, _) <- runDef "dev-util/kiro-ide-bin" "1.4.178" (\_ -> ok "1.4.178\n5cce6a0\nx64")
  assertEq "passes" [] (failedCheckNames rs)
  (rs', _, _) <- runDef "dev-util/kiro-ide-bin" "1.4.178" (\_ -> ok "Kiro 1.4.178\n")
  assertEq "first line must equal PV" ["version"] (failedCheckNames rs')

testBunBin :: IO ()
testBunBin = do
  (rs, cmds, _) <- runDef "dev-lang/bun-bin" "1.4.2" (\_ -> ok "1.4.2")
  assertEq "passes" [] (failedCheckNames rs)
  assertEq "slotted name" [["bun-1.4.2", "--version"]] (map snd cmds)

testUseAndGroups :: IO ()
testUseAndGroups = do
  let uses k = sdPackageUse (def k)
  assertTrue "craft apps" (all (\(c, n) -> "x11-libs/libxkbcommon X" `elem` uses (c <> "/" <> n)) craftApps)
  assertTrue "grok-bot pulseaudio" ("media-plugins/alsa-plugins pulseaudio" `elem` uses "dev-util/grok-bot-bin")
  assertTrue "kiro-ide pulseaudio" ("media-libs/libpulse X" `elem` uses "dev-util/kiro-ide-bin")
  assertEq "autolith" ["dev-lisp/sbcl source"] (uses "dev-util/autolith")
  assertTrue "claude-code CPU flags" (any ("cpu_flags_x86_avx2" `T.isInfixOf`) (uses "dev-util/claude-agent-acp"))
  assertEq "warden group" ["witen-warden"] (sdCheckGroups (def "net-analyzer/witen-warden-bin"))
  assertEq
    "no other package joins a group"
    [PackageKey "net-analyzer/witen-warden-bin"]
    [k | (k, d) <- Map.toList smokeDefinitions, not (null (sdCheckGroups d))]

testWarden :: IO ()
testWarden = do
  let validate =
        T.unlines
          [ "config          ok      /etc/witen/warden.toml",
            "config_schema   ok",
            "actuator        ok",
            "firewall_nft    ok",
            "admin_socket    failed  daemon not running",
            "status: failed"
          ]
      respond out cmd = case cmdArgv cmd of
        ["warden", "--version"] -> ok "warden 0.1.48"
        ["warden", "version", "--json"] -> ok "{\"name\":\"warden\",\"version\":\"0.1.48\"}"
        ["warden", "validate"] -> Outcome 1 out ""
        _ -> ok ""
  (rs, _, _) <- runDef "net-analyzer/witen-warden-bin" "0.1.48" (respond validate)
  assertEq "partial ok passes" [] (failedCheckNames rs)
  (rs', _, _) <- runDef "net-analyzer/witen-warden-bin" "0.1.48" (respond (T.replace "actuator        ok" "actuator        failed" validate))
  assertEq "actuator failure fails" ["validate"] (failedCheckNames rs')
