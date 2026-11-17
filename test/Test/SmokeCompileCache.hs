{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for the smoke compile cache: the Go trim check script
-- (and the same script against the host @go@), inspection parsing, the
-- cleanup planner, and the helper container over scripted Docker fakes.
module Test.SmokeCompileCache (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Smoke.CompileCache
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, testCaseInfo)
import Update.FileLock (LockMode (..), acquireFileLock, releaseFileLock)
import Update.Process (ProcessMode (..), ProcessRequest (..), ProcessResult (..))

tests :: TestTree
tests =
  testGroup
    "SmokeCompileCache"
    [ testGroup
        "go trim check"
        [ testCase "script: treatment, control, and verdicts" testTrimScript,
          testCaseInfo "script against the host go" testTrimHostGo
        ],
      testGroup
        "inspection"
        [ testCase "packages, missing last-used, filesystem" testInspectParse,
          testCase "malformed output is an error" testInspectMalformed
        ],
      testGroup
        "cleanup plan"
        [ testCase "package removed from the overlay" testPlanNotInInventory,
          testCase "caches unused for 30 days" testPlanIdle,
          testCase "over budget: least recently used first" testPlanOverBudget,
          testCase "concurrent command's cache is kept" testPlanConcurrent,
          testCase "little free space" testPlanLittleSpace,
          testCase "default budget" testPlanDefaultBudget,
          testCase "reset one package" testPlanReset,
          testCase "directories to create and stamp" testPlanCreate
        ],
      testGroup
        "helper"
        [ testCase "helper argv" testHelperArgs,
          testCase "apply script" testApplyScript,
          testCase "prepare: inspect, plan, apply" testPrepare,
          testCase "helper failure turns the cache off" testPrepareFails,
          testCase "held lock delays a second cleanup" testPrepareLock,
          testCase "opt-out runs no helper" testOptOut,
          testCase "reset with no compile cache" testResetNoCache
        ],
      testGroup
        "report"
        [ testCase "parse and line" testReport,
          testCase "trim check warning names the version" testReportWarning
        ]
    ]

------------------------------------------------------------------------
-- Go trim check

testTrimScript :: IO ()
testTrimScript = do
  let s = goTrimCheckScript
  mapM_
    (\needle -> assertTrue ("script has " <> T.unpack needle) (needle `T.isInfixOf` s))
    [ "GOENV=off GOTOOLCHAIN=local GOPROXY=off GOFLAGS=",
      "\"encoding/json\"",
      "touch -d \"@$((now - 10 * 86400))\"",
      "cp -Rp \"$work/treat\" \"$work/control\"",
      "echo \"$now\" > \"$work/treat/trim.txt\"",
      "echo \"$((now - 2 * 86400))\" > \"$work/control/trim.txt\"",
      "if [ \"$control\" -gt 0 ]; then echo inconclusive",
      "elif [ \"$kept\" -gt 0 ]; then echo ok",
      "else echo fail"
    ]
  assertEq "ok" TrimOk (parseTrimCheck "noise\nok\n")
  assertEq "fail" TrimFail (parseTrimCheck "fail\n")
  assertEq "inconclusive" TrimInconclusive (parseTrimCheck "inconclusive\n")
  assertEq "garbage" TrimInconclusive (parseTrimCheck "go: command not found\n")

-- | The same script the container runs, against the development machine's
-- @go@; skipped (with a visible note) when @go@ is not installed.
testTrimHostGo :: IO String
testTrimHostGo = do
  found <- findExecutable "go"
  case found of
    Nothing -> pure "skipped: go is not on PATH"
    Just _ -> withSystemTempDirectory "om-go-trim" $ \tmp -> do
      let script = tmp </> "check.sh"
      TIO.writeFile script goTrimCheckScript
      inherited <- getEnvironment
      (_, out, err) <-
        readCreateProcessWithExitCode
          (proc "sh" [script]) {env = Just (("TMPDIR", tmp) : filter ((/= "TMPDIR") . fst) inherited), cwd = Just tmp}
          ""
      case parseTrimCheck (T.pack out) of
        TrimOk -> pure (lastLine err)
        other -> assertFailure ("go trim check: " <> show other <> "\n" <> err) >> pure ""
  where
    lastLine = maybe "" T.unpack . lastMay . filter (not . T.null) . map T.strip . T.lines . T.pack
    lastMay xs = if null xs then Nothing else Just (last xs)

------------------------------------------------------------------------
-- Inspection

gib :: Integer
gib = 1024 * 1024 * 1024

testInspectParse :: IO ()
testInspectParse = do
  insp <-
    assertRight "parses" $
      parseInspection "pkg 1024 1794900000 dev-util/crush\npkg 2048 - dev-util/beads\n\nfs 4000 8000\n"
  assertEq
    "entries"
    [CacheEntry "dev-util/crush" 1024 (Just 1794900000), CacheEntry "dev-util/beads" 2048 Nothing]
    (inEntries insp)
  assertEq "available" 4000 (inAvailable insp)
  assertEq "total" 8000 (inTotal insp)
  empty <- assertRight "empty volume" (parseInspection "fs 1 2\n")
  assertEq "no entries" [] (inEntries empty)

testInspectMalformed :: IO ()
testInspectMalformed = do
  _ <- assertLeft "garbage line" (parseInspection "pkg 12 - dev-util/crush\ndu: cannot read\nfs 1 2\n")
  _ <- assertLeft "bad size" (parseInspection "pkg big - dev-util/crush\nfs 1 2\n")
  _ <- assertLeft "key without category" (parseInspection "pkg 1 - crush\nfs 1 2\n")
  _ <- assertLeft "no filesystem line" (parseInspection "pkg 1 - dev-util/crush\n")
  pure ()

------------------------------------------------------------------------
-- Cleanup plan

now :: Integer
now = 1794900000

hour, day :: Integer
hour = 60 * 60
day = 24 * hour

entry :: Text -> Integer -> Maybe Integer -> CacheEntry
entry key size age = CacheEntry key size (fmap (now -) age)

input :: [CacheEntry] -> CleanupInput
input es =
  CleanupInput
    { ciInventory = ["dev-util/crush", "dev-util/beads", "dev-util/hk", "dev-lang/deno-bin", "dev-build/node-gyp"],
      ciSelected = [],
      ciReset = [],
      ciNow = now,
      ciMaxSize = 3 * gib,
      ciInspection = Inspection es (100 * gib) (200 * gib)
    }

testPlanNotInInventory :: IO ()
testPlanNotInInventory = do
  let plan = planCleanup (input [entry "dev-util/old" 10 (Just hour), entry "dev-util/crush" 10 (Just hour)])
  assertEq "removed" [("dev-util/old", RemovedNotInInventory)] (cpRemoved plan)
  assertEq "applied" ["dev-util/old"] (apRemove (cpApply plan))
  assertTrue "prunes kept caches" (apPrune (cpApply plan))

testPlanIdle :: IO ()
testPlanIdle = do
  let plan =
        planCleanup
          (input [entry "dev-util/crush" 10 (Just (31 * day)), entry "dev-util/beads" 10 Nothing, entry "dev-util/hk" 10 (Just (29 * day))])
  assertEq "idle and never used" [("dev-util/crush", RemovedIdle), ("dev-util/beads", RemovedIdle)] (cpRemoved plan)

testPlanOverBudget :: IO ()
testPlanOverBudget = do
  let plan =
        planCleanup
          ( input
              [ entry "dev-util/crush" gib (Just (2 * day)),
                entry "dev-util/beads" gib (Just (5 * day)),
                entry "dev-util/hk" gib (Just (3 * day)),
                entry "dev-lang/deno-bin" gib (Just (4 * day))
              ]
          )
  assertEq "oldest first until it fits" [("dev-util/beads", RemovedOverBudget)] (cpRemoved plan)
  assertEq "before" (4 * gib) (cpSizeBefore plan)
  assertEq "after" (3 * gib) (cpSizeAfter plan)
  assertEq "no warning" Nothing (cpWarning plan)

testPlanConcurrent :: IO ()
testPlanConcurrent = do
  let plan =
        planCleanup
          ( input
              [ entry "dev-util/crush" (2 * gib) (Just hour),
                entry "dev-util/beads" (2 * gib) (Just (2 * day))
              ]
          )
  assertEq "only the older cache goes" [("dev-util/beads", RemovedOverBudget)] (cpRemoved plan)
  let busy =
        planCleanup
          ( input
              [ entry "dev-util/crush" (2 * gib) (Just hour),
                entry "dev-util/beads" (2 * gib) (Just (2 * hour))
              ]
          )
  assertEq "caches used within 24 hours are kept" [] (cpRemoved busy)
  assertTrue "over-budget warning" (maybe False ("24 hours" `T.isInfixOf`) (cpWarning busy))

testPlanLittleSpace :: IO ()
testPlanLittleSpace = do
  let half = gib `div` 2
      es = [entry "dev-util/crush" (gib - gib `div` 10 * 4) (Just (5 * day)), entry "dev-util/beads" (gib `div` 10 * 4) (Just (3 * day))]
      plan = planCleanup (input es) {ciInspection = Inspection es (gib + half) (8 * gib)}
  assertEq "budget is total + available - 2 GiB" half (cpBudget plan)
  assertEq "least recently used removed" [("dev-util/crush", RemovedOverBudget)] (cpRemoved plan)
  assertTrue "at least 2 GiB free after" (gib + half + (cpSizeBefore plan - cpSizeAfter plan) >= 2 * gib)
  assertEq "floored at zero" 0 (effectiveBudget (3 * gib) 0 gib)

testPlanDefaultBudget :: IO ()
testPlanDefaultBudget = do
  assertEq "max size when space allows" (3 * gib) (cpBudget (planCleanup (input [])))
  assertEq "ccache per package capped at 1 GiB" gib (packageCcacheSize (3 * gib))
  assertEq "ccache per package within a small budget" (gib `div` 2) (packageCcacheSize (gib `div` 2))

testPlanReset :: IO ()
testPlanReset = do
  let plan =
        planCleanup
          (input [entry "dev-util/crush" 10 (Just hour), entry "dev-util/beads" 10 (Just hour)])
            { ciSelected = ["dev-util/crush"],
              ciReset = ["dev-util/crush"]
            }
  assertEq "only the reset package" [("dev-util/crush", RemovedReset)] (cpRemoved plan)
  assertEq "recreated empty" ["dev-util/crush"] (apCreate (cpApply plan))

testPlanCreate :: IO ()
testPlanCreate = do
  let plan =
        planCleanup
          (input [entry "dev-util/crush" 10 (Just hour)])
            { ciSelected = ["dev-util/crush", "dev-util/beads"]
            }
  assertEq "missing directory created" ["dev-util/beads"] (apCreate (cpApply plan))
  assertEq "every selected cache marked used" ["dev-util/crush", "dev-util/beads"] (apStamp (cpApply plan))

------------------------------------------------------------------------
-- Helper

helperCfg :: HelperCfg
helperCfg = HelperCfg {hcImage = "mndz-overlay-manager/smoke:local", hcRunId = "r1", hcCliPid = "4242"}

testHelperArgs :: IO ()
testHelperArgs = do
  let args = helperArgs helperCfg "true"
  assertEq "run --rm" ["run", "--rm"] (take 2 args)
  assertTrue "no network" (isSub ["--network", "none"] args)
  assertTrue "product label" (isSub ["--label", "mndz.overlay-manager=1"] args)
  assertTrue "pid label" (isSub ["--label", "mndz.overlay-manager.pid=4242"] args)
  assertTrue "whole volume at /cache" (isSub ["--mount", "type=volume,src=mndz-smoke-compile-cache,dst=/cache"] args)
  assertTrue "no capability" ("--cap-add" `notElem` args)
  assertEq "image and script last" ["mndz-overlay-manager/smoke:local", "sh", "-c", "true"] (drop (length args - 4) args)

testApplyScript :: IO ()
testApplyScript = do
  let s = applyScript (Apply ["dev-util/old"] ["dev-util/crush"] ["dev-util/crush"] True)
  mapM_
    (\needle -> assertTrue ("apply has " <> T.unpack needle) (needle `T.isInfixOf` s))
    [ "rm -rf -- 'dev-util/old'",
      "install -d -o root -g root -m 0755 -- 'dev-util' 'dev-util/crush'",
      "for s in ccache go autoconf zig; do install -d -o root -g portage -m 2775 -- 'dev-util/crush'/$s; done",
      "date +%s > 'dev-util/crush/.last-used'",
      "find /cache -path '/cache/*/*/go/??/*' -type f -name '*-[ad]' -mmin +43200 -delete",
      "find /cache -path '/cache/*/*/zig/*' -type f -mmin +43200 -delete"
    ]
  let resetOnly = applyScript (Apply ["dev-util/crush"] [] [] False)
  assertTrue "reset removes" ("rm -rf -- 'dev-util/crush'" `T.isInfixOf` resetOnly)
  assertTrue "reset does not prune" (not ("find " `T.isInfixOf` resetOnly))
  assertTrue "reset creates nothing" (not ("install " `T.isInfixOf` resetOnly))

data Fake = Fake
  { fCalls :: IORef [[String]],
    fRespond :: [String] -> ProcessResult
  }

newFake :: ([String] -> ProcessResult) -> IO Fake
newFake respond = Fake <$> newIORef [] <*> pure respond

runFake :: Fake -> ProcessRequest -> IO ProcessResult
runFake fake req = do
  let args = case prMode req of
        ExecCmd c as -> c : as
        ShellCmd s -> ["sh", "-c", s]
  modifyIORef' (fCalls fake) (++ [args])
  pure (fRespond fake args)

ok :: String -> ProcessResult
ok out = ProcessResult ExitSuccess out ""

-- | Inspect prints the given output; apply succeeds.
helperFake :: String -> [String] -> ProcessResult
helperFake inspected args
  | any ("du -sb" `isInfixOf`) args = ok inspected
  | otherwise = ok ""

prepareCfg :: Fake -> FilePath -> PrepareCfg
prepareCfg fake lockPath =
  PrepareCfg
    { pcRun = runFake fake,
      pcHelper = helperCfg,
      pcLockPath = lockPath,
      pcNow = pure now,
      pcMaxSize = 3 * gib,
      pcInventory = ["dev-util/crush", "dev-util/beads"],
      pcSelected = ["dev-util/crush"],
      pcReset = [],
      pcEnabled = True
    }

scriptOf :: [String] -> String
scriptOf = last

testPrepare :: IO ()
testPrepare =
  withSystemTempDirectory "om-cc-prepare" $ \tmp -> do
    fake <- newFake (helperFake "pkg 100 1794899000 dev-util/crush\npkg 50 - dev-util/old\nfs 107374182400 214748364800\n")
    r <- prepareCompileCache (prepareCfg fake (tmp </> "compile-cache.lock"))
    assertEq "cache on with 1 GiB ccache" (CacheOn gib) (prUse r)
    assertEq "no warnings" [] (prWarnings r)
    assertEq "old package removed" (Just [("dev-util/old", RemovedNotInInventory)]) (cpRemoved <$> prPlan r)
    calls <- readIORef (fCalls fake)
    case calls of
      [inspect, apply] -> do
        assertEq "docker" ["docker"] (take 1 inspect)
        assertTrue "inspect lists packages and free space" ("df -B1" `isInfixOf` scriptOf inspect)
        assertTrue "apply removes the old package" ("rm -rf -- 'dev-util/old'" `isInfixOf` scriptOf apply)
        assertTrue "apply keeps crush" (not ("rm -rf -- 'dev-util/crush'" `isInfixOf` scriptOf apply))
        assertTrue "apply marks crush used" ("date +%s > 'dev-util/crush/.last-used'" `isInfixOf` scriptOf apply)
      other -> assertFailure ("expected inspect and apply, got " <> show (length other))

testPrepareFails :: IO ()
testPrepareFails =
  withSystemTempDirectory "om-cc-fail" $ \tmp -> do
    fake <- newFake (const (ProcessResult (ExitFailure 125) "" "docker: Error response from daemon: no such image\n"))
    r <- prepareCompileCache (prepareCfg fake (tmp </> "compile-cache.lock"))
    assertEq "cache off" CacheOff (prUse r)
    case prWarnings r of
      [w] -> assertTrue "warning names the cause" ("no such image" `T.isInfixOf` w && "without the compile cache" `T.isInfixOf` w)
      other -> assertFailure ("expected one warning, got " <> show other)
    calls <- readIORef (fCalls fake)
    assertEq "no apply after a failed inspect" 1 (length calls)
    malformed <- newFake (helperFake "garbage\n")
    r2 <- prepareCompileCache (prepareCfg malformed (tmp </> "compile-cache.lock"))
    assertEq "malformed inspection turns the cache off" CacheOff (prUse r2)

testPrepareLock :: IO ()
testPrepareLock =
  withSystemTempDirectory "om-cc-lock" $ \tmp -> do
    let lockPath = tmp </> "compile-cache.lock"
    held <- acquireFileLock ExclusiveLock lockPath
    fake <- newFake (helperFake "fs 107374182400 214748364800\n")
    done <- newEmptyMVar
    _ <- forkIO (prepareCompileCache (prepareCfg fake lockPath) >>= putMVar done)
    threadDelay 200000
    waiting <- readIORef (fCalls fake)
    assertEq "no helper while another cleanup holds the lock" 0 (length waiting)
    releaseFileLock held
    r <- takeMVar done
    assertEq "cache on after the lock is released" (CacheOn gib) (prUse r)
    calls <- readIORef (fCalls fake)
    assertEq "inspect and apply ran" 2 (length calls)

testOptOut :: IO ()
testOptOut =
  withSystemTempDirectory "om-cc-off" $ \tmp -> do
    fake <- newFake (const (ok ""))
    r <- prepareCompileCache (prepareCfg fake (tmp </> "l")) {pcEnabled = False}
    assertEq "off" (PrepareResult CacheOff Nothing []) r
    calls <- readIORef (fCalls fake)
    assertEq "no helper container" [] calls

testResetNoCache :: IO ()
testResetNoCache =
  withSystemTempDirectory "om-cc-reset" $ \tmp -> do
    fake <- newFake (const (ok ""))
    r <- prepareCompileCache (prepareCfg fake (tmp </> "l")) {pcEnabled = False, pcReset = ["dev-util/crush"]}
    assertEq "runs use no cache" CacheOff (prUse r)
    calls <- readIORef (fCalls fake)
    case calls of
      [apply] -> do
        assertTrue "deletes crush" ("rm -rf -- 'dev-util/crush'" `isInfixOf` scriptOf apply)
        assertTrue "keeps other packages" (not ("dev-util/beads" `isInfixOf` scriptOf apply))
        assertTrue "no cleanup" (not ("find " `isInfixOf` scriptOf apply))
      other -> assertFailure ("expected one apply, got " <> show (length other))

------------------------------------------------------------------------
-- Report

testReport :: IO ()
testReport = do
  let out =
        "ccache cache_miss\t73\nccache direct_cache_hit\t17\nccache preprocessed_cache_hit\t16\n\
        \ccache local_storage_hit\t33\ngo-before 839\ngo-after 851\n"
      r = parseReport out (Just ("go1.27.3", TrimOk))
  assertEq "report" (CacheReport 33 73 12 (Just ("go1.27.3", TrimOk))) r
  assertEq
    "line"
    "compile cache: ccache 33 hits, 73 misses; go cache +12 entries; go trim check ok (go1.27.3)"
    (reportLine r)
  assertEq "missing counters are zero" (CacheReport 0 0 0 Nothing) (parseReport "" Nothing)

testReportWarning :: IO ()
testReportWarning = do
  assertEq "ok has no warning" Nothing (reportWarning (CacheReport 0 0 0 (Just ("go1.27.3", TrimOk))))
  assertEq "inconclusive has no warning" Nothing (reportWarning (CacheReport 0 0 0 (Just ("go1.27.3", TrimInconclusive))))
  case reportWarning (CacheReport 0 0 0 (Just ("go1.28.0", TrimFail))) of
    Just w -> assertTrue "names the version" ("not suppressed for go1.28.0" `T.isInfixOf` w)
    Nothing -> assertFailure "expected a warning"

isSub :: (Eq a) => [a] -> [a] -> Bool
isSub needle hay = any (\t -> take (length needle) t == needle) (tailsOf hay)
  where
    tailsOf [] = [[]]
    tailsOf xs@(_ : rest) = xs : tailsOf rest
