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

main :: IO ()
main =
  defaultMain $
    testGroup
      "mndz-overlay-manager"
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
        Lanes.tests,
        Progress.tests,
        Apply.tests,
        Md5Cache.tests,
        Properties.tests
      ]
