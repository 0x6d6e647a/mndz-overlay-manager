module Main (main) where

import Test.Apply qualified as Apply
import Test.Assets qualified as Assets
import Test.CLI qualified as CLI
import Test.CheckPlan qualified as CheckPlan
import Test.Config qualified as Config
import Test.DiskSpace qualified as DiskSpace
import Test.Distfiles qualified as Distfiles
import Test.EbuildEdit qualified as EbuildEdit
import Test.Ecosystems qualified as Ecosystems
import Test.Git qualified as Git
import Test.Gpg qualified as Gpg
import Test.Lanes qualified as Lanes
import Test.Materialize qualified as Materialize
import Test.Md5Cache qualified as Md5Cache
import Test.Overlay qualified as Overlay
import Test.Policy qualified as Policy
import Test.Preflight qualified as Preflight
import Test.Progress qualified as Progress
import Test.Properties qualified as Properties
import Test.Ssh qualified as Ssh
import Test.Targets qualified as Targets
import Test.Tasty (defaultMain, testGroup)
import Test.TempWorkspace qualified as TempWorkspace

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
            Distfiles.tests,
            DiskSpace.tests,
            TempWorkspace.tests,
            Policy.tests,
            Targets.tests,
            Preflight.tests,
            Assets.tests,
            EbuildEdit.tests,
            Ssh.tests,
            Gpg.tests,
            Git.tests,
            CLI.tests,
            Lanes.unitTests,
            Progress.unitTests,
            Apply.unitTests,
            Materialize.unitTests,
            Md5Cache.unitTests,
            Ecosystems.unitTests,
            CheckPlan.unitTests,
            Properties.tests
          ],
        testGroup
          "Integration"
          [ Lanes.integrationTests,
            Progress.integrationTests,
            Apply.integrationTests,
            Materialize.integrationTests,
            Md5Cache.integrationTests,
            Ecosystems.integrationTests,
            CheckPlan.integrationTests
          ]
      ]
