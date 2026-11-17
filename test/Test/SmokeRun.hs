{-# LANGUAGE OverloadedStrings #-}

-- | Integration coverage for the smoke pipeline over fakes: result lines,
-- summary, exit decision, lock release, logs, and worktree state.
module Test.SmokeRun (tests) where

import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (addUTCTime, getCurrentTime)
import Overlay.Types (Ebuild (..))
import Overlay.Version (parseEbuildVersion)
import Smoke.Check (SmokeDef)
import Smoke.CompileCache (CacheReport (..), CacheUse (..), TrimCheck (..))
import Smoke.Container (FailStage (..), RunOutcome (..), RunResult (..))
import Smoke.Definitions (lookupSmokeDef, smokeDefinitions)
import Smoke.Plan (HostCeilings (..), LaneRuntime (..), PackageInput (..), PlannedItem (..), RuntimeCap (..), SmokeRun (..), planSmokeRuns)
import Smoke.Run
  ( SmokeOps (..),
    SmokeSummary (..),
    keptRunLogs,
    missingDefinitions,
    pruneRunLogs,
    runSmoke,
    summaryLines,
    uncommittedPackages,
  )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, setModificationTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import System.Timeout (timeout)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.FileLock (LockMode (..), acquireFileLock, releaseFileLock)
import Update.Process (productionCommandRunner)
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Types (EcosystemSpec (..), PackageKey (..), UpdateTechnique (..), mkPackageKey)

tests :: TestTree
tests =
  testGroup
    "SmokeRun"
    [ testCase "mixed results: lines, summary, failure exit, continuation" testMixed,
      testCase "tree lock is released before the first run" testLockRelease,
      testCase "compile cache report is logged, stdout unchanged" testCacheReportLogged,
      testCase "probe failure stops before any run" testProbeFails,
      testCase "missing definitions are named" testMissingDefinitions,
      testCase "eleventh earlier log directory is pruned" testPrune,
      testCase "modified, staged, and untracked files are reported" testUncommitted
    ]

eb :: Text -> Text -> Text -> Ebuild
eb cat pn ver = Ebuild cat pn ver ("/ov/" <> T.unpack cat <> "/" <> T.unpack pn <> "/" <> T.unpack pn <> "-" <> T.unpack ver <> ".ebuild")

-- | beads (two lanes), deno-bin (unlabeled), and kiro-cli-bin keyworded
-- for arm64 only (skipped on amd64).
items :: [PlannedItem]
items =
  planSmokeRuns
    "amd64"
    (Map.singleton RuntimeGo (HostCeilings (Just (parseEbuildVersion "1.26.11")) (Just (parseEbuildVersion "1.27.4"))))
    [ PackageInput (mkPackageKey "dev-util" "beads") (DepsAndAssets (Go Nothing)) [(eb "dev-util" "beads" "1.3.4", "BDEPEND=\">=dev-lang/go-1.26.5:=\"\nKEYWORDS=\"~amd64\"\n")],
      PackageInput (mkPackageKey "dev-lang" "deno-bin") GitMvAndManifest [(eb "dev-lang" "deno-bin" "2.9.8", "KEYWORDS=\"-* ~amd64\"\n")],
      PackageInput (mkPackageKey "dev-util" "kiro-cli-bin") GitMvAndManifest [(eb "dev-util" "kiro-cli-bin" "3.3.0", "KEYWORDS=\"-* ~arm64\"\n")]
    ]

data Trace = Trace
  { tEvents :: IORef [Text],
    tLines :: IORef [Text],
    tErrors :: IORef [Text]
  }

newTrace :: IO Trace
newTrace = Trace <$> newIORef [] <*> newIORef [] <*> newIORef []

note :: Trace -> Text -> IO ()
note t e = modifyIORef' (tEvents t) (++ [e])

fakeOps :: Trace -> (SmokeRun -> IO RunResult) -> SmokeOps
fakeOps t runOne =
  SmokeOps
    { soSweep = note t "sweep",
      soEnsureImage = note t "image" >> pure (Right ()),
      soWithSnapshot = \k -> do
        note t "snapshot"
        r <- k
        note t "snapshot removed"
        pure (Right r),
      soReleaseTree = note t "release",
      soProbe = note t "probe" >> pure (Right ()),
      soPrepareCache = note t "compile cache" >> pure CacheOff,
      soRun = \_ run _ _ -> do
        note t ("run " <> ebuildVersion (srEbuild run))
        (`RunOutcome` Nothing) <$> runOne run,
      soEmit = \l -> modifyIORef' (tLines t) (++ [l]),
      soLogFailure = \e -> modifyIORef' (tErrors t) (++ [e]),
      soLogWarning = \e -> modifyIORef' (tErrors t) (++ ["warning: " <> e]),
      soLogInfo = \e -> modifyIORef' (tErrors t) (++ ["info: " <> e]),
      soProgress = \_ _ _ -> pure ()
    }

defFor :: PackageKey -> SmokeDef
defFor k = case lookupSmokeDef k of
  Just d -> d
  Nothing -> error "fixture key without definition"

testMixed :: IO ()
testMixed = withSystemTempDirectory "om-smoke-mixed" $ \tmp -> do
  t <- newTrace
  let runOne run = pure $ case (ebuildPackage (srEbuild run), srCap run) of
        ("beads", Just _) | "1.3.4" == ebuildVersion (srEbuild run), isPlain run -> RunFail FailBuild "Fetch failed" "/logs/beads/build.log"
        _ -> RunPass
      isPlain run = fmap capTier (srCap run) == Just Plain
  got <- runSmoke (fakeOps t runOne) defFor (tmp </> "r1") items
  outLines <- readIORef (tLines t)
  assertEq
    "lines"
    [ "dev-lang/deno-bin-2.9.8: pass",
      "dev-util/beads-1.3.4 (dev-lang/go amd64): fail: build",
      "dev-util/beads-1.3.4 (dev-lang/go ~amd64): pass",
      "dev-util/kiro-cli-bin-3.3.0: skip: KEYWORDS has neither amd64 nor ~amd64"
    ]
    outLines
  assertEq "summary" (Right (SmokeSummary 2 1 1)) got
  errs <- readIORef (tErrors t)
  assertTrue "failure names its log" (any ("/logs/beads/build.log" `T.isInfixOf`) errs)
  case got of
    Right s -> do
      assertTrue "exit 1 when any failure" (ssFailed s > 0)
      let ls = summaryLines s "/logs/r1" [PackageKey "dev-util/hk"]
      assertTrue "counts" (any ("2 passed, 1 failed, 1 skipped" `T.isInfixOf`) ls)
      assertTrue "log dir" (any ("/logs/r1" `T.isInfixOf`) ls)
      assertTrue "uncommitted" ("dev-util/hk was tested with uncommitted changes" `elem` ls)
    Left err -> assertFailure (T.unpack err)

testCacheReportLogged :: IO ()
testCacheReportLogged = withSystemTempDirectory "om-smoke-report" $ \tmp -> do
  t <- newTrace
  used <- newIORef []
  let report run = case srCap run of
        Just cap | capTier cap == Plain -> CacheReport 3 4 12 (Just ("go1.27.3", TrimFail))
        _ -> CacheReport 0 1 0 Nothing
      ops =
        (fakeOps t (\_ -> pure RunPass))
          { soPrepareCache = pure (CacheOn 1024),
            soRun = \cache run _ _ -> do
              modifyIORef' used (++ [cache])
              pure (RunOutcome RunPass (Just (report run)))
          }
  _ <- runSmoke ops defFor (tmp </> "r1") items
  outLines <- readIORef (tLines t)
  assertEq
    "stdout result lines unchanged"
    [ "dev-lang/deno-bin-2.9.8: pass",
      "dev-util/beads-1.3.4 (dev-lang/go amd64): pass",
      "dev-util/beads-1.3.4 (dev-lang/go ~amd64): pass",
      "dev-util/kiro-cli-bin-3.3.0: skip: KEYWORDS has neither amd64 nor ~amd64"
    ]
    outLines
  logs <- readIORef (tErrors t)
  assertTrue
    "report names atom and lane"
    ( "info: dev-util/beads-1.3.4 (dev-lang/go amd64): compile cache: ccache 3 hits, 4 misses; go cache +12 entries; go trim check fail (go1.27.3)"
        `elem` logs
    )
  assertEq "one report per run" 3 (length (filter ("info: " `T.isPrefixOf`) logs))
  assertTrue "failed trim check warns" (any (\l -> "warning: " `T.isPrefixOf` l && "go1.27.3" `T.isInfixOf` l) logs)
  seen <- readIORef used
  assertEq "every run gets the prepared cache" (replicate 3 (CacheOn 1024)) seen

testLockRelease :: IO ()
testLockRelease =
  withSystemTempDirectory "om-smoke-lock" $ \tmp -> do
    let lockPath = tmp </> "gentoo.lock"
    shared <- acquireFileLock SharedLock lockPath
    t <- newTrace
    exclusiveSeen <- newIORef []
    let ops =
          (fakeOps t (\_ -> pure RunPass))
            { soReleaseTree = note t "release" >> releaseFileLock shared,
              soRun = \_ run _ _ -> do
                note t ("run " <> ebuildVersion (srEbuild run))
                -- Blocking with a limit: a process forked by a parallel test
                -- holds the released lock's description until it execs.
                ex <- timeout 5000000 (acquireFileLock ExclusiveLock lockPath)
                modifyIORef' exclusiveSeen (++ [isJust ex])
                mapM_ releaseFileLock ex
                pure (RunOutcome RunPass Nothing)
            }
    _ <- runSmoke ops defFor (tmp </> "logs") items
    events <- readIORef (tEvents t)
    assertEq
      "order"
      ["sweep", "image", "snapshot", "release", "probe", "compile cache", "run 2.9.8", "run 1.3.4", "run 1.3.4", "snapshot removed"]
      events
    seen <- readIORef exclusiveSeen
    assertTrue "a second resolver can take the exclusive lock during runs" (not (null seen) && and seen)

testProbeFails :: IO ()
testProbeFails = do
  t <- newTrace
  let ops = (fakeOps t (\_ -> pure RunPass)) {soProbe = pure (Left "sandboxes cannot be enforced")}
  got <- runSmoke ops defFor "/logs/r1" items
  assertEq "hard failure" (Left "sandboxes cannot be enforced") got
  events <- readIORef (tEvents t)
  assertTrue "no run" (not (any ("run " `T.isPrefixOf`) events))
  assertTrue "snapshot still removed" ("snapshot removed" `elem` events)

testMissingDefinitions :: IO ()
testMissingDefinitions = do
  let keys = [PackageKey "dev-util/crush", PackageKey "dev-util/newpkg", PackageKey "dev-util/other"]
  assertEq "named" [PackageKey "dev-util/newpkg", PackageKey "dev-util/other"] (missingDefinitions (`Map.lookup` smokeDefinitions) keys)

testPrune :: IO ()
testPrune =
  withSystemTempDirectory "om-smoke-logs" $ \root -> do
    now <- getCurrentTime
    let mk i = do
          let d = root </> ("run-" <> show (i :: Int))
          createDirectoryIfMissing True d
          setModificationTime d (addUTCTime (fromIntegral i) now)
    forM_ [1 .. 10] mk
    pruneRunLogs root
    mk 11
    pruneRunLogs root
    after1 <- sort <$> listDirectory root
    assertEq "ten earlier kept" keptRunLogs (length after1)
    assertTrue "oldest gone" ("run-1" `notElem` after1)
    mk 12
    pruneRunLogs root
    after2 <- listDirectory root
    assertTrue "next oldest gone" ("run-2" `notElem` after2)
    stillThere <- doesDirectoryExist (root </> "run-12")
    assertTrue "newest kept" stillThere

testUncommitted :: IO ()
testUncommitted =
  withSystemTempDirectory "om-smoke-git" $ \repo -> do
    let git args = callProcess "git" (["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"] <> args)
        write p body = do
          createDirectoryIfMissing True (repo </> takeDir p)
          TIO.writeFile (repo </> p) body
        takeDir = reverse . drop 1 . dropWhile (/= '/') . reverse
    git ["init", "-q"]
    forM_ ["dev-util/a", "dev-util/b", "dev-util/c", "dev-util/d"] $ \p -> write (p <> "/x.ebuild") "EAPI=8\n"
    git ["add", "."]
    git ["commit", "-q", "-m", "seed"]
    write "dev-util/a/x.ebuild" "EAPI=8\n# modified\n"
    write "dev-util/b/y.ebuild" "EAPI=8\n"
    git ["add", "dev-util/b/y.ebuild"]
    write "dev-util/c/files/new.patch" "x\n"
    got <- uncommittedPackages productionCommandRunner repo (map (PackageKey . ("dev-util/" <>)) ["a", "b", "c", "d"])
    assertEq "modified, staged, untracked" (map (PackageKey . ("dev-util/" <>)) ["a", "b", "c"]) got
