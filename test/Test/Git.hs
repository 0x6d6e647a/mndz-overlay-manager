{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for Update.Git production helpers via controlled temp repos
-- and injectable GpgHandle (no live pinentry).
module Test.Git (clearGitLocalEnv, tests) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Metrics.Core (noopMetrics)
import Metrics.Process (timedRunner)
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
import Test.Metrics (spanStarts, withRecorded)
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
import Update.GitHub (gitRemoteOriginUrl, gitRemotePushUrl)
import Update.GpgAgent
  ( GpgAgentOps (..),
    GpgHandle,
    Keygrip (..),
    ensureGpgReady,
    newGpgHandle,
    noopSupervisor,
    teardownGpgHandle,
  )
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
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
      testCase "Rev-parse HEAD" testGitRevParseHead,
      testGroup
        "Scripted runner"
        [ testCase "isGitWorkTree argv, measure, stdout" testFakeWorkTree,
          testCase "pathsDirty argv, measure, mapping" testFakePathsDirty,
          testCase "gitRevParseHead argv, trim, mapping" testFakeRevParse,
          testCase "gitPush is interactive and maps failure" testFakePush,
          testCase "signed commit: add then interactive commit with env" testFakeSignedCommit,
          testCase "signed commit: add failure stops before commit" testFakeAddFails,
          testCase "signed commit: commit failure maps stderr" testFakeCommitFails,
          testCase "signed commit: gpg not ready runs no git" testFakeGpgNotReady,
          testCase "remote URL argv and mapping" testFakeRemoteUrl,
          testCase "missing git raises the same IOException with metrics" testMissingGit,
          testCase "signing environment is not recorded" testSigningEnvNotRecorded
        ]
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
    inside <- isGitWorkTree productionCommandRunner other
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
    plain <- isGitWorkTree productionCommandRunner (tmp </> "plain")
    assertEq "non-git" False plain
    createDirectoryIfMissing True (tmp </> "repo")
    initRepo (tmp </> "repo")
    inside <- isGitWorkTree productionCommandRunner (tmp </> "repo")
    assertEq "git worktree" True inside

testPathsDirty :: IO ()
testPathsDirty =
  withSystemTempDirectory "git-dirty" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    clean <- assertRight "clean" =<< pathsDirty productionCommandRunner root ["README"]
    assertEq "clean false" False clean
    writeFile (root </> "README") "dirty\n"
    dirty <- assertRight "dirty" =<< pathsDirty productionCommandRunner root ["README"]
    assertEq "dirty true" True dirty
    -- missing pathspec is still a successful status (not dirty)
    missing <- assertRight "missing path" =<< pathsDirty productionCommandRunner root ["no-such-file"]
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
      assertRight "D and ??" =<< pathsDirty productionCommandRunner root ["dev-lang/bun-bin"]
    assertEq "untracked and deleted count as dirty" True dirty

testPathsDirtyStatusFailure :: IO ()
testPathsDirtyStatusFailure =
  withSystemTempDirectory "git-status-fail" $ \tmp -> do
    -- Not a git repo → git status fails
    createDirectoryIfMissing True (tmp </> "plain")
    err <- assertLeft "status fail" =<< pathsDirty productionCommandRunner (tmp </> "plain") ["x"]
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
    err <- assertLeft "push fail" =<< gitPush productionCommandRunner root
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
      assertLeft "gpg gate" =<< gitAddAndSignedCommit productionCommandRunner h root ["extra"] "msg"
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
      assertLeft "commit -S" =<< gitAddAndSignedCommit productionCommandRunner h root ["extra"] "signed"
    assertTrue "commit failed" ("git commit -S failed" `T.isInfixOf` err)
    teardownGpgHandle h

testProductionGitOpsWiring :: IO ()
testProductionGitOpsWiring =
  withSystemTempDirectory "git-ops" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    h <- newGpgHandle fakeGpgOps
    let ops = productionGitOps noopMetrics h
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
    sha <- assertRight "HEAD" =<< gitRevParseHead productionCommandRunner root
    assertTrue "sha nonempty" (T.length sha >= 7)
    missing <-
      assertLeft "missing repo"
        =<< gitRevParseHead productionCommandRunner (tmp </> "not-a-repo")
    assertTrue "rev-parse fail" ("git rev-parse HEAD failed" `T.isInfixOf` missing)

------------------------------------------------------------------------
-- Scripted runner
------------------------------------------------------------------------

okOut :: String -> ProcessResult
okOut out = ProcessResult {prExitCode = ExitSuccess, prStdout = out, prStderr = ""}

failErr :: String -> ProcessResult
failErr err = ProcessResult {prExitCode = ExitFailure 1, prStdout = "", prStderr = err}

-- | Runner that records requests and answers each from @answer@.
recordingRunner ::
  (ProcessRequest -> ProcessResult) ->
  IO (CommandRunner, IO [ProcessRequest])
recordingRunner answer = do
  seen <- newIORef []
  let run req = do
        modifyIORef' seen (<> [req])
        pure (answer req)
  pure (run, readIORef seen)

-- | Single-answer 'recordingRunner'.
constRunner :: ProcessResult -> IO (CommandRunner, IO [ProcessRequest])
constRunner = recordingRunner . const

gitArgs :: ProcessRequest -> [String]
gitArgs req = case prMode req of
  ExecCmd "git" args -> args
  other -> error ("not a git exec: " <> show other)

testFakeWorkTree :: IO ()
testFakeWorkTree = do
  (run, seen) <- constRunner (okOut " true\n")
  yes <- isGitWorkTree run "/some/dir"
  assertTrue "trimmed true" yes
  reqs <- seen
  assertEq "argv" [["-C", "/some/dir", "rev-parse", "--is-inside-work-tree"]] (map gitArgs reqs)
  assertEq "measure" [Timed] (map prMeasure reqs)
  assertEq "no env" [Nothing] (map prEnv reqs)
  (runF, _) <- constRunner (okOut "false\n")
  no <- isGitWorkTree runF "/x"
  assertTrue "false stdout" (not no)
  (runE, _) <- constRunner (failErr "fatal: not a git repository")
  err <- isGitWorkTree runE "/x"
  assertTrue "non-zero exit" (not err)

testFakePathsDirty :: IO ()
testFakePathsDirty = do
  (run, seen) <- constRunner (okOut " M cat/pkg/Manifest\n")
  dirty <- assertRight "dirty" =<< pathsDirty run "/overlay" ["cat/pkg", "other"]
  assertTrue "dirty from output" dirty
  reqs <- seen
  assertEq
    "argv"
    [["-C", "/overlay", "status", "--porcelain", "--", "cat/pkg", "other"]]
    (map gitArgs reqs)
  assertEq "measure" [Timed] (map prMeasure reqs)
  (runC, _) <- constRunner (okOut "")
  clean <- assertRight "clean" =<< pathsDirty runC "/overlay" ["x"]
  assertTrue "empty output is clean" (not clean)
  (runE, _) <- constRunner (failErr "boom")
  err <- assertLeft "status failure" =<< pathsDirty runE "/overlay" ["x"]
  assertEq "message" "git status failed: boom" err

testFakeRevParse :: IO ()
testFakeRevParse = do
  (run, seen) <- constRunner (okOut "abc1234\n")
  sha <- assertRight "HEAD" =<< gitRevParseHead run "/repo"
  assertEq "trimmed" "abc1234" sha
  reqs <- seen
  assertEq "argv" [["-C", "/repo", "rev-parse", "HEAD"]] (map gitArgs reqs)
  assertEq "measure" [Timed] (map prMeasure reqs)
  (runE, _) <- constRunner (failErr "bad revision")
  err <- assertLeft "failure" =<< gitRevParseHead runE "/repo"
  assertEq "message" "git rev-parse HEAD failed: bad revision" err

testFakePush :: IO ()
testFakePush = do
  (run, seen) <- constRunner (okOut "")
  assertRight "push" =<< gitPush run "/repo"
  reqs <- seen
  assertEq "argv" [["-C", "/repo", "push"]] (map gitArgs reqs)
  assertEq "measure" [TimedInteractive] (map prMeasure reqs)
  (runE, _) <- constRunner (failErr "rejected")
  err <- assertLeft "failure" =<< gitPush runE "/repo"
  assertEq "message" "git push failed: rejected" err

-- | Fake GPG ops whose child environment carries a recognizable GPG_TTY.
ttyGpgOps :: GpgAgentOps
ttyGpgOps = fakeGpgOps {gaoControllingTty = pure (Just "/dev/pts/mndz-test-tty")}

withReadyHandle :: (FilePath -> GpgHandle -> IO a) -> IO a
withReadyHandle act =
  withSystemTempDirectory "git-fake-commit" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    h <- newGpgHandle ttyGpgOps
    r <- act root h
    teardownGpgHandle h
    pure r

testFakeSignedCommit :: IO ()
testFakeSignedCommit = withReadyHandle $ \root h -> do
  (run, seen) <- constRunner (okOut "")
  assertRight "commit" =<< gitAddAndSignedCommit run h root ["a", "b"] "the message"
  reqs <- seen
  assertEq
    "argv"
    [ ["-C", root, "add", "--", "a", "b"],
      ["-C", root, "commit", "-S", "-m", "the message"]
    ]
    (map gitArgs reqs)
  assertEq "measures" [Timed, TimedInteractive] (map prMeasure reqs)
  case map prEnv reqs of
    [Nothing, Just env1] ->
      assertEq "signing tty" (Just "/dev/pts/mndz-test-tty") (lookup "GPG_TTY" env1)
    other -> assertTrue ("unexpected envs: " <> show other) False

testFakeAddFails :: IO ()
testFakeAddFails = withReadyHandle $ \root h -> do
  (run, seen) <- constRunner (failErr "pathspec 'a' did not match")
  err <- assertLeft "add" =<< gitAddAndSignedCommit run h root ["a"] "m"
  assertEq "message" "git add failed: pathspec 'a' did not match" err
  reqs <- seen
  assertEq "only add ran" 1 (length reqs)

testFakeCommitFails :: IO ()
testFakeCommitFails = withReadyHandle $ \root h -> do
  (run, seen) <-
    recordingRunner $ \req ->
      if "commit" `elem` gitArgs req then failErr "no secret key" else okOut ""
  err <- assertLeft "commit" =<< gitAddAndSignedCommit run h root ["a"] "m"
  assertEq "message" "git commit -S failed: no secret key" err
  reqs <- seen
  assertEq "add then commit" 2 (length reqs)

testFakeGpgNotReady :: IO ()
testFakeGpgNotReady =
  withSystemTempDirectory "git-fake-gpg" $ \tmp -> do
    let root = tmp </> "repo"
    createDirectoryIfMissing True root
    initRepo root
    h <- newGpgHandle fakeGpgOps {gaoGetSigningKey = \_ -> pure (Left "signingkey unset")}
    (run, seen) <- constRunner (okOut "")
    err <- assertLeft "gpg gate" =<< gitAddAndSignedCommit run h root ["a"] "m"
    assertTrue "signingkey" ("signingkey" `T.isInfixOf` err)
    reqs <- seen
    assertEq "no git ran" [] (map gitArgs reqs)
    teardownGpgHandle h

testFakeRemoteUrl :: IO ()
testFakeRemoteUrl = do
  (run, seen) <- constRunner (okOut " git@github.com:o/r.git\n")
  origin <- assertRight "origin" =<< gitRemoteOriginUrl run "/assets"
  assertEq "trimmed" "git@github.com:o/r.git" origin
  pushUrl <- assertRight "push url" =<< gitRemotePushUrl run "/assets"
  assertEq "trimmed push" "git@github.com:o/r.git" pushUrl
  reqs <- seen
  assertEq
    "argv"
    [ ["-C", "/assets", "remote", "get-url", "origin"],
      ["-C", "/assets", "remote", "get-url", "--push", "origin"]
    ]
    (map gitArgs reqs)
  assertEq "measure" [Timed, Timed] (map prMeasure reqs)
  (runE, _) <- constRunner (failErr "")
  noErr <- assertLeft "no stderr" =<< gitRemoteOriginUrl runE "/assets"
  assertEq "bare message" "assets-path origin remote is missing or unreadable" noErr
  (runS, _) <- constRunner (failErr "fatal: No such remote 'origin'\n")
  withErr <- assertLeft "stderr" =<< gitRemoteOriginUrl runS "/assets"
  assertEq
    "message with stderr"
    "assets-path origin remote is missing or unreadable: fatal: No such remote 'origin'"
    withErr
  pushErr <- assertLeft "push stderr" =<< gitRemotePushUrl runS "/assets"
  assertEq
    "push message"
    "assets-path origin push URL is missing or unreadable: fatal: No such remote 'origin'"
    pushErr
  (runB, _) <- constRunner (okOut "  \n")
  empty <- assertLeft "empty" =<< gitRemoteOriginUrl runB "/assets"
  assertEq "empty message" "assets-path origin remote URL is empty" empty
  emptyPush <- assertLeft "empty push" =<< gitRemotePushUrl runB "/assets"
  assertEq "empty push message" "assets-path origin push URL is empty" emptyPush

-- | Point @git@ requests at an executable that does not exist, so GNU time
-- cannot be asked to exec it.
missingGit :: CommandRunner -> CommandRunner
missingGit run req = run req {prMode = mode}
  where
    mode = case prMode req of
      ExecCmd "git" args -> ExecCmd "mndz-no-such-git" args
      other -> other

testMissingGit :: IO ()
testMissingGit = do
  plain <- try @IOException (isGitWorkTree (missingGit productionCommandRunner) "/x")
  (timed, _) <- withRecorded $ \m ->
    try @IOException (isGitWorkTree (missingGit (timedRunner m productionCommandRunner)) "/x")
  case (plain, timed) of
    (Left a, Left b) -> assertEq "same failure" (show a) (show b)
    _ -> assertTrue "expected IOException from both runners" False

testSigningEnvNotRecorded :: IO ()
testSigningEnvNotRecorded = withReadyHandle $ \root h -> do
  seenEnv <- newIORef []
  let inner req = do
        modifyIORef' seenEnv (<> [prEnv req])
        case prMode req of
          ExecCmd "/usr/bin/time" ("-o" : file : _) -> BS.writeFile file "{}"
          _ -> pure ()
        pure (okOut "")
  (res, evs) <- withRecorded $ \m ->
    gitAddAndSignedCommit (timedRunner m inner) h root ["a"] "m"
  assertRight "commit" res
  envs <- readIORef seenEnv
  assertTrue
    "the commit really carried the tty"
    (any (maybe False (elem ("GPG_TTY", "/dev/pts/mndz-test-tty"))) envs)
  assertTrue
    "git commit span recorded"
    (length [() | (_, _, "proc", _) <- spanStarts evs] == 2)
  assertTrue "tty value absent from every event" (not ("mndz-test-tty" `T.isInfixOf` T.pack (show evs)))
