{-# LANGUAGE OverloadedStrings #-}

-- | Portage tools container: create/exec argv, one lazy container per run,
-- removal at exit, start failures, and @ebuild … manifest@ / @egencache@
-- through it. A scripted fake stands in for the @docker@ CLI.
module Test.ToolsContainer (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply (productionEbuildRunner)
import Update.Md5Cache
  ( EgencacheRequest (..),
    preflightGencacheWith,
    productionEgencacheRunner,
  )
import Update.Process (CommandRunner, Measure (..), ProcessMode (..), ProcessRequest (..), ProcessResult (..))
import Update.Process.Docker
  ( ToolsContainerCfg (..),
    closeToolsSession,
    materializeProductLabel,
    newToolsSession,
    toolsContainerName,
    toolsCreateArgs,
    toolsExecArgs,
    toolsGentooTreeDir,
    toolsSessionRunner,
    withToolsSession,
  )

tests :: TestTree
tests =
  testGroup
    "ToolsContainer"
    [ testCase "Create argv mounts and identity" testCreateArgs,
      testCase "Exec argv keeps cwd and env, drops secrets" testExecArgs,
      testCase "Created lazily, shared, removed at exit" testLazySharedRemoved,
      testCase "No container when no tool runs" testNoUseNoContainer,
      testCase "Container cannot start" testStartFailure,
      testCase "Manifest runs in the tools container" testEbuildInContainer,
      testCase "Eclass checksums come from the managed tree" testEgencacheInContainer,
      testCase "gencache preflight requires git gpg docker" testGencachePreflight
    ]

cfg :: ToolsContainerCfg
cfg =
  ToolsContainerCfg
    { tccUser = "1000:1000",
      tccRunId = "run42",
      tccJobs = 4,
      tccCliPid = "4242",
      tccGentooTree = "/home/op/.cache/mndz/overlay-manager/gentoo",
      tccOverlay = "/home/op/overlay",
      tccDistDir = Just "/home/op/.cache/mndz/overlay-manager/distfiles"
    }

-- | Records every @docker@ argv. @create@ fails when @failCreate@.
data FakeDocker = FakeDocker
  { fdCalls :: IORef [[String]],
    fdImageCalls :: IORef Int
  }

newFake :: IO FakeDocker
newFake = FakeDocker <$> newIORef [] <*> newIORef 0

fakeRunner :: Bool -> FakeDocker -> CommandRunner
fakeRunner failCreate fake req = case prMode req of
  ExecCmd "docker" args -> do
    modifyIORef' (fdCalls fake) (<> [args])
    pure $ case args of
      ("create" : _)
        | failCreate -> ProcessResult (ExitFailure 125) "" "Error response from daemon: no such image"
        | otherwise -> ProcessResult ExitSuccess "cid\n" ""
      ["inspect", "--format", "{{.State.Running}}", _] -> ProcessResult ExitSuccess "true\n" ""
      _ -> ProcessResult ExitSuccess "" ""
  other -> pure (ProcessResult (ExitFailure 1) "" ("unexpected " <> show other))

imageResolver :: FakeDocker -> IO (Either Text String)
imageResolver fake = do
  modifyIORef' (fdImageCalls fake) (+ 1)
  pure (Right "sha256:abc")

verbs :: FakeDocker -> IO [String]
verbs fake = concatMap (take 1) <$> readIORef (fdCalls fake)

argPairs :: [String] -> [(String, String)]
argPairs (a : b : rest) = (a, b) : argPairs (b : rest)
argPairs _ = []

testCreateArgs :: IO ()
testCreateArgs = do
  let args = toolsCreateArgs cfg "sha256:abc"
      pairs = argPairs args
  assertEq "name" "mndz-tools-run42" (toolsContainerName cfg)
  assertTrue "removed with --rm" ("--rm" `elem` args)
  assertTrue "operator user" (("--user", "1000:1000") `elem` pairs)
  assertTrue "product label" (("--label", materializeProductLabel) `elem` pairs)
  assertTrue "run label" (("--label", "mndz.overlay-manager.run=run42") `elem` pairs)
  assertTrue "pid label" (("--label", "mndz.overlay-manager.pid=4242") `elem` pairs)
  assertTrue
    "tree read-only at /var/db/repos/gentoo"
    (("--mount", "type=bind,src=" <> tccGentooTree cfg <> ",dst=/var/db/repos/gentoo,readonly") `elem` pairs)
  assertTrue "overlay at its host path" (("--mount", "type=bind,src=/home/op/overlay,dst=/home/op/overlay") `elem` pairs)
  assertTrue
    "distfiles at its host path"
    (("--mount", "type=bind,src=/home/op/.cache/mndz/overlay-manager/distfiles,dst=/home/op/.cache/mndz/overlay-manager/distfiles") `elem` pairs)
  assertTrue "writable home" (any (\(k, v) -> k == "--env" && "HOME=/" `isPrefixOf` v) pairs)
  assertTrue "writable scratch tmpfs" (("--tmpfs", "/tmp/mndz-tools:rw,exec,mode=1777") `elem` pairs)
  assertTrue "writable egencache cache tmpfs" (any (\(k, v) -> k == "--tmpfs" && "/tmp/mndz-egencache" `isPrefixOf` v) pairs)
  let repos = [v | ("--env", v) <- pairs, "PORTAGE_REPOSITORIES=" `isPrefixOf` v]
  case repos of
    [r] -> do
      assertTrue "gentoo at container tree" ("[gentoo]\nlocation = /var/db/repos/gentoo" `isInfixOf` r)
      assertTrue "mndz at overlay path" ("[mndz]\nlocation = /home/op/overlay\nmasters = gentoo" `isInfixOf` r)
    _ -> assertTrue "one PORTAGE_REPOSITORIES" False
  assertTrue "no secrets" (not (any (\a -> any (`isInfixOf` a) ["GITHUB_TOKEN", "GNUPGHOME", "SSH_AUTH_SOCK"]) args))
  assertEq "image then idle command" ["sha256:abc", "sleep", "infinity"] (drop (length args - 3) args)

testExecArgs :: IO ()
testExecArgs = do
  let req =
        ProcessRequest
          { prMode = ShellCmd "ebuild ./foo-1.ebuild manifest",
            prCwd = Just "/home/op/overlay/dev-util/foo",
            prEnv = Just [("DISTDIR", "/d"), ("GENTOO_MIRRORS", ""), ("GNUPGHOME", "/g"), ("SSH_AUTH_SOCK", "/s"), ("HOME", "/h")],
            prStdin = "",
            prMeasure = Timed
          }
      args = toolsExecArgs cfg req
  assertEq
    "exec argv"
    [ "exec",
      "--user",
      "1000:1000",
      "--workdir",
      "/home/op/overlay/dev-util/foo",
      "--env",
      "DISTDIR=/d",
      "--env",
      "GENTOO_MIRRORS=",
      "mndz-tools-run42",
      "sh",
      "-c",
      "ebuild ./foo-1.ebuild manifest"
    ]
    args

dummyReq :: String -> ProcessRequest
dummyReq cmd =
  ProcessRequest
    { prMode = ExecCmd cmd [],
      prCwd = Nothing,
      prEnv = Nothing,
      prStdin = "",
      prMeasure = Timed
    }

testLazySharedRemoved :: IO ()
testLazySharedRemoved = do
  fake <- newFake
  outs <-
    withToolsSession (fakeRunner False fake) cfg (imageResolver fake) $ \ts -> do
      created0 <- verbs fake
      assertEq "nothing created before first use" [] created0
      mapM (\n -> toolsSessionRunner ts (dummyReq ("tool" <> show n))) [1 :: Int, 2, 3]
  assertTrue "all ran" (all ((== ExitSuccess) . prExitCode) outs)
  vs <- verbs fake
  assertEq "one create" 1 (length (filter (== "create") vs))
  assertEq "setup and three workloads" 4 (length (filter (== "exec") vs))
  assertEq "image resolved once" 1 =<< readIORef (fdImageCalls fake)
  calls <- readIORef (fdCalls fake)
  case [c | c@("exec" : _) <- calls] of
    (["exec", "--user", "0:0", "mndz-tools-run42", "sh", "-c", script] : workloads) -> do
      assertTrue "setup uses four jobs" ("(jobs=4;" `isPrefixOf` script)
      assertTrue "workloads use operator identity" (all (isPrefixOf ["exec", "--user", "1000:1000"]) workloads)
    _ -> fail "expected privileged setup before the workloads"
  assertEq "removed at exit" ["rm", "-f", "mndz-tools-run42"] (last calls)

testNoUseNoContainer :: IO ()
testNoUseNoContainer = do
  fake <- newFake
  withToolsSession (fakeRunner False fake) cfg (imageResolver fake) (\_ -> pure ())
  assertEq "no docker calls" [] =<< readIORef (fdCalls fake)
  assertEq "no image ensure" 0 =<< readIORef (fdImageCalls fake)

testStartFailure :: IO ()
testStartFailure = do
  fake <- newFake
  ts <- newToolsSession (fakeRunner True fake) cfg (imageResolver fake)
  r1 <- toolsSessionRunner ts (dummyReq "ebuild")
  r2 <- toolsSessionRunner ts (dummyReq "egencache")
  assertTrue "first fails" (prExitCode r1 /= ExitSuccess)
  assertTrue "names the container failure" ("Portage tools container" `isInfixOf` prStderr r1)
  assertEq "later requests fail the same way" (prStderr r1) (prStderr r2)
  vs <- verbs fake
  assertEq "create attempted once" 1 (length (filter (== "create") vs))
  assertEq "no exec" 0 (length (filter (== "exec") vs))
  let failSetup req = case prMode req of
        ExecCmd "docker" ("exec" : "--user" : "0:0" : _) -> do
          _ <- fakeRunner False fake req
          pure (ProcessResult (ExitFailure 1) "" "read-only file system")
        _ -> fakeRunner False fake req
  writeIORef (fdCalls fake) []
  withToolsSession failSetup cfg (pure (Right "example/override:local")) $ \session -> do
    failed <- toolsSessionRunner session (dummyReq "egencache")
    assertTrue "configuration error names file" ("/etc/portage/make.conf" `isInfixOf` prStderr failed)
  setupCalls <- readIORef (fdCalls fake)
  assertTrue "uses override image" (any (elem "example/override:local") setupCalls)
  assertTrue "no workload exec" (not (any (isPrefixOf ["exec", "--user", "1000:1000"]) setupCalls))
  assertEq "removes failed setup" ["rm", "-f", "mndz-tools-run42"] (last setupCalls)
  -- An image failure is a container failure too.
  fake2 <- newFake
  ts2 <- newToolsSession (fakeRunner False fake2) cfg (pure (Left "failed to ensure materialize image: boom"))
  r3 <- toolsSessionRunner ts2 (dummyReq "ebuild")
  assertTrue "image failure named" ("boom" `isInfixOf` prStderr r3)
  closeToolsSession ts
  closeToolsSession ts2

execOf :: FakeDocker -> IO [String]
execOf fake = do
  calls <- readIORef (fdCalls fake)
  case [c | c@("exec" : "--user" : "1000:1000" : _) <- calls] of
    (c : _) -> pure c
    [] -> pure []

testEbuildInContainer :: IO ()
testEbuildInContainer = do
  fake <- newFake
  res <-
    withToolsSession (fakeRunner False fake) cfg (imageResolver fake) $ \ts ->
      productionEbuildRunner ts "/home/op/.cache/mndz/overlay-manager/distfiles" "/home/op/overlay/dev-util/foo" "foo-1.0.ebuild"
  _ <- assertRight "manifest ok" res
  ex <- execOf fake
  let pairs = argPairs ex
  assertTrue "workdir is the package dir" (("--workdir", "/home/op/overlay/dev-util/foo") `elem` pairs)
  assertTrue "DISTDIR is manager distfiles" (("--env", "DISTDIR=/home/op/.cache/mndz/overlay-manager/distfiles") `elem` pairs)
  assertTrue "GENTOO_MIRRORS empty" (("--env", "GENTOO_MIRRORS=") `elem` pairs)
  assertTrue "no host GPG home" (not (any ("GNUPGHOME" `isInfixOf`) ex))
  assertEq "manifest command" ["mndz-tools-run42", "sh", "-c", "ebuild ./foo-1.0.ebuild manifest"] (drop (length ex - 4) ex)

testEgencacheInContainer :: IO ()
testEgencacheInContainer = do
  fake <- newFake
  res <-
    withToolsSession (fakeRunner False fake) cfg (imageResolver fake) $ \ts ->
      productionEgencacheRunner
        ts
        EgencacheRequest
          { erOverlayRoot = "/home/op/overlay",
            erAtoms = ["dev-util/foo"],
            erJobs = Nothing
          }
  _ <- assertRight "egencache ok" res
  calls <- readIORef (fdCalls fake)
  let creates = [c | c@("create" : _) <- calls]
  assertTrue
    "managed tree bound at the gentoo location"
    (any (elem ("type=bind,src=" <> tccGentooTree cfg <> ",dst=" <> toolsGentooTreeDir <> ",readonly")) creates)
  ex <- execOf fake
  let egen = dropWhile (/= "egencache") ex
      pairs = argPairs egen
  assertTrue "egencache in container" (take 1 egen == ["egencache"])
  case [v | ("--repositories-configuration", v) <- pairs] of
    [conf] -> do
      assertTrue "gentoo at the bound tree" ("[gentoo]\nlocation = /var/db/repos/gentoo" `isInfixOf` conf)
      assertTrue "mndz at the overlay" ("[mndz]\nlocation = /home/op/overlay" `isInfixOf` conf)
    _ -> assertTrue "one repositories-configuration" False
  assertTrue "writable cache dir" (("--cache-dir", "/tmp/mndz-egencache") `elem` pairs)
  assertTrue "atom" ("dev-util/foo" `elem` egen)

testGencachePreflight :: IO ()
testGencachePreflight = do
  let present missing name = pure (if name `elem` missing then Nothing else Just ("/bin/" <> name))
  assertEq "host egencache not required" (Right ()) =<< preflightGencacheWith (present ["egencache", "ebuild"])
  err <- assertLeft "missing docker" =<< preflightGencacheWith (present ["docker"])
  assertTrue "names docker" ("docker" `T.isInfixOf` err)
