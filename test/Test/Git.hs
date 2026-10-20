{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for Update.Git production helpers via controlled temp repos
-- and injectable GpgHandle (no live pinentry).
module Test.Git (clearGitLocalEnv, tests) where

import Control.Monad (forM_, unless, void, when)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (env),
    callProcess,
    createProcess,
    proc,
    readProcessWithExitCode,
    waitForProcess,
  )
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Git
  ( gitAddAndSignedCommit,
    gitPush,
    gitRevParseHead,
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
    noopSupervisor,
    teardownGpgHandle,
  )

tests :: TestTree
tests =
  testGroup
    "Git"
    [ testCase "Is Git Work Tree" testIsGitWorkTree,
      testCase "Launch clears linked worktree git env" testLaunchClearsLinkedWorktreeEnv,
      testCase "Cleared env temporary init" testClearedEnvTemporaryInit,
      testCase "Paths Dirty Clean And Dirty" testPathsDirty,
      testCase "Paths Dirty Treats Deleted And Untracked" testPathsDirtyDeletedUntracked,
      testCase "Paths Dirty Git Status Failure" testPathsDirtyStatusFailure,
      testCase "Relative Overlay Path" testRelativeOverlayPath,
      testCase "Git Push No Remote Fails" testGitPushNoRemote,
      testCase "Git Add Commit Gpg Not Ready" testGitAddCommitGpgNotReady,
      testCase "Git Add Commit Commit Failure" testGitAddCommitCommitFails,
      testCase "Production GitOps Wiring" testProductionGitOpsWiring,
      testCase "Rev-parse HEAD" testGitRevParseHead
    ]

-- | Drop Git's repository-location variables so later git commands target the
-- directory they are given. A missing @git@ leaves the environment unchanged.
clearGitLocalEnv :: IO ()
clearGitLocalEnv = do
  (code, out, _) <-
    readProcessWithExitCode "git" ["rev-parse", "--local-env-vars"] ""
  when (code == ExitSuccess) $
    forM_ (lines out) $ \name ->
      unless (null name) (unsetEnv name)

-- | Passed to the child suite. Not a Git local variable, so the clear keeps it.
probeRootEnv :: String
probeRootEnv = "MNDZ_GIT_ENV_PROBE_ROOT"

-- | Start this executable with a linked worktree's repository environment.
-- @main@ clears that environment before the child initializes a repository.
testLaunchClearsLinkedWorktreeEnv :: IO ()
testLaunchClearsLinkedWorktreeEnv =
  withSystemTempDirectory "git-clear-env-" $ \tmp -> do
    let mainRepo = tmp </> "main"
        linked = tmp </> "linked"
    createDirectoryIfMissing True mainRepo
    initRepo mainRepo
    callProcess "git" ["-C", mainRepo, "worktree", "add", "-q", "-b", "clear-env", linked]
    gitDir <- gitPath linked ["rev-parse", "--absolute-git-dir"]
    commonDir <- gitPath linked ["rev-parse", "--git-common-dir"]
    exe <- getExecutablePath
    env0 <- getEnvironment
    let dropped =
          [ "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_COMMON_DIR",
            "GIT_INDEX_FILE",
            probeRootEnv
          ]
        -- A private tix path so this child does not rewrite the suite's .tix.
        env1 =
          (probeRootEnv, mainRepo)
            : ("GIT_DIR", gitDir)
            : ("GIT_WORK_TREE", linked)
            : ("GIT_COMMON_DIR", commonDir)
            : ("HPCTIXFILE", tmp </> "child.tix")
            : filter
              (\(k, _) -> k `notElem` dropped && k /= "HPCTIXFILE")
              env0
    (_, _, _, ph) <-
      createProcess
        (proc exe ["-p", "Cleared env temporary init"])
          { env = Just env1
          }
    code <- waitForProcess ph
    assertEq "child suite cleared the hook environment" ExitSuccess code

-- | Initialize a temporary repository after @main@ has cleared Git's environment.
testClearedEnvTemporaryInit :: IO ()
testClearedEnvTemporaryInit =
  withSystemTempDirectory "git-cleared-init-" $ \tmp -> do
    let other = tmp </> "other"
    createDirectoryIfMissing True other
    callProcess "git" ["-C", other, "init", "-q"]
    inside <- isGitWorkTree other
    assertEq "temporary directory is a work tree" True inside
    mRoot <- lookupEnv probeRootEnv
    forM_ mRoot assertCommonConfigOmitsWorktree

assertCommonConfigOmitsWorktree :: FilePath -> IO ()
assertCommonConfigOmitsWorktree root = do
  (code, out, _) <-
    readProcessWithExitCode "git" ["-C", root, "config", "--get", "core.worktree"] ""
  assertEq "common config omits core.worktree" (ExitFailure 1) code
  assertEq "core.worktree empty" "" (T.unpack (T.strip (T.pack out)))

-- | Absolute path printed by @git -C dir args@.
gitPath :: FilePath -> [String] -> IO FilePath
gitPath dir args = do
  (code, out, err) <-
    readProcessWithExitCode "git" (["-C", dir] <> args) ""
  assertEq (unwords ("git" : args) <> ": " <> err) ExitSuccess code
  let path = T.unpack (T.strip (T.pack out))
  pure $ if isAbsolute path then path else dir </> path

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

testPathsDirtyDeletedUntracked :: IO ()
testPathsDirtyDeletedUntracked =
  withSystemTempDirectory "git-dirty-du" $ \tmp -> do
    let root = tmp </> "repo"
        pkg = root </> "dev-lang" </> "bun-bin"
    createDirectoryIfMissing True pkg
    initRepo root
    writeFile (pkg </> "bun-bin-1.3.14.ebuild") "EAPI=8\n"
    callProcess "git" ["-C", root, "add", "dev-lang/bun-bin"]
    callProcess "git" ["-C", root, "commit", "-m", "bun-bin"]
    callProcess
      "git"
      ["-C", root, "rm", "-q", "dev-lang/bun-bin/bun-bin-1.3.14.ebuild"]
    createDirectoryIfMissing True pkg
    writeFile (pkg </> "bun-bin-1.4.0.ebuild") "EAPI=8\n"
    dirty <-
      assertRight "D and ??" =<< pathsDirty root ["dev-lang/bun-bin"]
    assertEq "untracked and deleted count as dirty" True dirty

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
      gaoKeyinfoCached = \_ _ -> pure (Right True),
      gaoReadyPrompt = pure (Right ()),
      gaoWarmKey = \_ _ _ -> pure (Right ()),
      gaoControllingTty = pure Nothing,
      gaoPauseUi = pure (),
      gaoResumeUi = pure (),
      gaoBuildSessionHome = \_ _ _ -> pure (Right ()),
      gaoKillSessionAgent = \_ -> pure (),
      gaoStartSupervisor = \_ -> pure (Right noopSupervisor),
      gaoReapSupervisor = \_ -> pure (),
      gaoRemoveSessionHome = \_ -> pure ()
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

testGitRevParseHead :: IO ()
testGitRevParseHead =
  withSystemTempDirectory "git-rev-parse" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    sha <- assertRight "HEAD" =<< gitRevParseHead root
    assertTrue "sha nonempty" (T.length sha >= 7)
    missing <-
      assertLeft "missing repo"
        =<< gitRevParseHead (tmp </> "not-a-repo")
    assertTrue "rev-parse fail" ("git rev-parse HEAD failed" `T.isInfixOf` missing)
