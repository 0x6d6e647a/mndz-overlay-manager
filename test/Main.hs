module Main (main) where

import Test.Apply qualified as Apply
import Test.Assets qualified as Assets
import Test.CLI qualified as CLI
import Test.Config qualified as Config
import Test.EbuildEdit qualified as EbuildEdit
import Test.Gpg qualified as Gpg
import Test.Lanes qualified as Lanes
import Test.Md5Cache qualified as Md5Cache
import Test.Overlay qualified as Overlay
import Test.Policy qualified as Policy
import Test.Preflight qualified as Preflight
import Test.Progress qualified as Progress
import Test.Properties qualified as Properties
import Test.Ssh qualified as Ssh
import Test.Targets qualified as Targets
import Test.Tasty (defaultMain, testGroup)

-- Test taxonomy (Unit vs Integration) — design D3 / CONTRIBUTING.
--
-- Unit: single library concern; no multi-step product pipeline
-- (apply/plan/commit spine); I/O limited to reading small committed fixtures
-- or pure in-memory behavior. Property tests (QuickCheck) are a technique
-- under Unit, not a separate isolation level.
--
-- Integration: multi-module workflow; temporary overlay mutation;
-- ApplyEnv / PlanOps / runners / multi-phase apply-plan behavior.
--
-- Top-level tasty groups are named Unit and Integration so coverage
-- attribution can run: cabal test all --test-options='-p Unit'
-- (and likewise for Integration / full suite for Overall).

main :: IO ()
main =
  defaultMain $
    testGroup
      "mndz-overlay-manager"
      [ testGroup
          "Unit"
          [ Overlay.tests,
            Config.tests,
            Policy.tests,
            Targets.tests,
            Preflight.tests,
            Assets.tests,
            EbuildEdit.tests,
            Ssh.tests,
            Gpg.tests,
            CLI.tests,
            Lanes.unitTests,
            Progress.unitTests,
            Apply.unitTests,
            Md5Cache.unitTests,
            Properties.tests
          ],
        testGroup
          "Integration"
          [ Lanes.integrationTests,
            Progress.integrationTests,
            Apply.integrationTests,
            Md5Cache.integrationTests
          ]
      ]
