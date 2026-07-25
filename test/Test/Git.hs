{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for Update.Git production helpers via controlled temp repos
-- and injectable GpgHandle (no live pinentry).
module Test.Git (tests) where

import Control.Monad (void)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Git
  ( gitAddAndSignedCommit,
    gitPush,
    isGitWorkTree,
    pathsDirty,
    productionGitOps,
    relativeOverlayPath,
  )
import Update.Git qualified as Git
import Update.GpgAgent
  ( GpgAgentOps (..),
    Keygrip (..),
    ensureGpgReady,
    newGpgHandle,
    teardownGpgHandle,
  )

tests :: TestTree
tests =
  testGroup
    "Git"
    [ testCase "Is Git Work Tree" testIsGitWorkTree,
      testCase "Paths Dirty Clean And Dirty" testPathsDirty,
      testCase "Paths Dirty Git Status Failure" testPathsDirtyStatusFailure,
      testCase "Relative Overlay Path" testRelativeOverlayPath,
      testCase "Git Push No Remote Fails" testGitPushNoRemote,
      testCase "Git Add Commit Gpg Not Ready" testGitAddCommitGpgNotReady,
      testCase "Git Add Commit Commit Failure" testGitAddCommitCommitFails,
      testCase "Production GitOps Wiring" testProductionGitOpsWiring
    ]

initRepo :: FilePath -> IO ()
initRepo root = do
  callProcess "git" ["-C", root, "init"]
  callProcess "git" ["-C", root, "config", "user.email", "test@example.com"]
  callProcess "git" ["-C", root, "config", "user.name", "Test User"]
  -- Avoid signing for baseline commits used to establish HEAD.
  callProcess "git" ["-C", root, "config", "commit.gpgsign", "false"]
  writeFile (root </> "README") "hello\n"
  callProcess "git" ["-C", root, "add", "README"]
  callProcess "git" ["-C", root, "commit", "-m", "init"]

testIsGitWorkTree :: IO ()
testIsGitWorkTree =
  withSystemTempDirectory "git-wt" $ \tmp -> do
    createDirectoryIfMissing True (tmp </> "plain")
    plain <- isGitWorkTree (tmp </> "plain")
    assertEq "non-git" False plain
    createDirectoryIfMissing True (tmp </> "repo")
    initRepo (tmp </> "repo")
    inside <- isGitWorkTree (tmp </> "repo")
    assertEq "git worktree" True inside

testPathsDirty :: IO ()
testPathsDirty =
  withSystemTempDirectory "git-dirty" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    clean <- assertRight "clean" =<< pathsDirty root ["README"]
    assertEq "clean false" False clean
    writeFile (root </> "README") "dirty\n"
    dirty <- assertRight "dirty" =<< pathsDirty root ["README"]
    assertEq "dirty true" True dirty
    -- missing pathspec is still a successful status (not dirty)
    missing <- assertRight "missing path" =<< pathsDirty root ["no-such-file"]
    assertEq "missing not dirty" False missing

testPathsDirtyStatusFailure :: IO ()
testPathsDirtyStatusFailure =
  withSystemTempDirectory "git-status-fail" $ \tmp -> do
    -- Not a git repo → git status fails
    createDirectoryIfMissing True (tmp </> "plain")
    err <- assertLeft "status fail" =<< pathsDirty (tmp </> "plain") ["x"]
    assertTrue "mentions status" ("git status failed" `T.isInfixOf` err)

testRelativeOverlayPath :: IO ()
testRelativeOverlayPath =
  withSystemTempDirectory "git-rel" $ \tmp -> do
    let root = tmp </> "overlay"
        file = root </> "cat" </> "pkg" </> "pkg-1.ebuild"
    createDirectoryIfMissing True (takeDirectory file)
    writeFile file "EAPI=8\n"
    rel <- relativeOverlayPath root file
    assertEq "relative" ("cat" </> "pkg" </> "pkg-1.ebuild") rel

testGitPushNoRemote :: IO ()
testGitPushNoRemote =
  withSystemTempDirectory "git-push" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    err <- assertLeft "push fail" =<< gitPush root
    assertTrue "push failed msg" ("git push failed" `T.isInfixOf` err)

fakeGpgOps :: GpgAgentOps
fakeGpgOps =
  GpgAgentOps
    { gaoGetSigningKey = \_ -> pure (Right "TESTKEY"),
      gaoResolveKeygrip = \_ -> pure (Right (Keygrip "GRIP")),
      gaoKeyinfoCached = \_ -> pure (Right True),
      gaoReadyPrompt = pure (Right ()),
      gaoWarmKey = \_ -> pure (Right ()),
      gaoClearPassphrase = \_ -> pure (),
      gaoControllingTty = pure Nothing,
      gaoPauseUi = pure (),
      gaoResumeUi = pure ()
    }

testGitAddCommitGpgNotReady :: IO ()
testGitAddCommitGpgNotReady =
  withSystemTempDirectory "git-commit-gpg" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    writeFile (root </> "extra") "x\n"
    let ops =
          fakeGpgOps
            { gaoGetSigningKey = \_ -> pure (Left "signingkey unset")
            }
    h <- newGpgHandle ops
    err <-
      assertLeft "gpg gate" =<< gitAddAndSignedCommit h root ["extra"] "msg"
    assertTrue "signingkey" ("signingkey" `T.isInfixOf` err)
    teardownGpgHandle h

testGitAddCommitCommitFails :: IO ()
testGitAddCommitCommitFails =
  withSystemTempDirectory "git-commit-fail" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    writeFile (root </> "extra") "x\n"
    -- GPG "ready" but no real key → commit -S fails after git add.
    h <- newGpgHandle fakeGpgOps
    void $ assertRight "gpg ready" =<< ensureGpgReady h root
    err <-
      assertLeft "commit -S" =<< gitAddAndSignedCommit h root ["extra"] "signed"
    assertTrue "commit failed" ("git commit -S failed" `T.isInfixOf` err)
    teardownGpgHandle h

testProductionGitOpsWiring :: IO ()
testProductionGitOpsWiring =
  withSystemTempDirectory "git-ops" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    h <- newGpgHandle fakeGpgOps
    let ops = productionGitOps h
    assertTrue "worktree via ops" =<< Git.goIsWorkTree ops root
    dirty <- assertRight "paths" =<< Git.goPathsDirty ops root ["README"]
    assertEq "clean" False dirty
    -- push still fails without remote
    err <- assertLeft "push ops" =<< Git.goPush ops root
    assertTrue "push" ("git push failed" `T.isInfixOf` err)
    teardownGpgHandle h
