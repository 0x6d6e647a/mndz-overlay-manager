{-# LANGUAGE OverloadedStrings #-}

-- | Integration coverage for the @update@ smoke gate's overlay snapshot.
module Test.Gate (tests) where

import Control.Concurrent (forkIO, newQSem, signalQSem, threadDelay, waitQSem)
import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Aeson (Value (..), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Metrics.Core (noopMetrics, withSpan)
import Overlay.Types (Ebuild (..))
import Overlay.Version (parseEbuildVersion)
import Smoke.CompileCache (CacheUse (..))
import Smoke.Container (OverlayMount (..), RunOutcome (..), RunResult (..), SmokeContainerCfg (..), StagedFetch (..), smokeCreateArgs)
import Smoke.Definitions (lookupSmokeDef)
import Smoke.Plan (SmokeRun (..))
import Smoke.Run (SmokeOps (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import System.Timeout (timeout)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Metrics (evKind, field, firstId, spanStarts, withRecorded)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Gate
  ( GateConfig (..),
    GateFailure (..),
    GateHandle (..),
    GateRequest (..),
    GateResult (..),
    md5CacheDependencies,
    newGateScheduler,
  )
import Update.Gate.Session (GateSessionCfg (..), UnitGateCfg (..), runUnitGate, withGateSession)
import Update.Gate.Snapshot (buildUnitSnapshot, isCacheEntryOf)
import Update.Gate.Staging (buildStagingDir)
import Update.Held (HeldReason (..))
import Update.Process (productionCommandRunner)
import Update.Types (PackageKey, UpdateTechnique (..), mkPackageKey, packageKeyText)

tests :: TestTree
tests =
  testGroup
    "Gate"
    [ testGroup
        "snapshot"
        [ testCase "HEAD plus only the unit's package and cache entries" testSnapshotIsolation,
          testCase "cache entry match is by package name, not prefix" testCacheEntryOf
        ],
      testGroup
        "staging"
        [ testCase "exactly the unit's distfiles; DISTDIR never mounted" testStaging
        ],
      testGroup
        "scheduler"
        [ testCase "a gated unit frees its job slot (jobs 1)" testSlotReleased,
          testCase "ready gates run one at a time in arrival order" testLaneFifo,
          testCase "dependent gates after its selected dependency is terminal" testDependencyWait,
          testCase "unselected dependency adds no wait" testUnselectedNoWait,
          testCase "failed dependency still lets the dependent gate" testFailedDependency,
          testCase "two-package cycle fails both; others continue" testCycle,
          testCase "unready prerequisites fail the gate" testUnready,
          testCase "waits show their status" testWaitStatuses,
          testCase "md5-cache dependency atoms" testDependencyAtoms
        ],
      testGroup
        "unit gate"
        [ testCase "runs the PV on its snapshot with the session's cache use" testUnitGateRuns,
          testCase "host keyword skip fails the gate" testUnitGateArchSkip,
          testCase "gated run span nests under the package span" testGateRunSpan
        ]
    ]

-- | A committed overlay with @dev-util/codex@, @dev-util/codex-acp@, and
-- @dev-util/hk@, each with one ebuild and one md5-cache entry.
seedOverlay :: FilePath -> IO (FilePath -> Text -> IO (), [String] -> IO ())
seedOverlay repo = do
  let git args = callProcess "git" (["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"] <> args)
      write p body = do
        createDirectoryIfMissing True (takeDirectory (repo </> p))
        TIO.writeFile (repo </> p) body
  git ["init", "-q"]
  forM_ [("codex", "0.163.0"), ("codex-acp", "2.6.0"), ("hk", "2.12.0")] $ \(pn, ver) -> do
    write ("dev-util" </> pn </> (pn <> "-" <> ver <> ".ebuild")) "EAPI=8\n"
    write ("dev-util" </> pn </> "Manifest") ("DIST " <> pnText pn <> " 1\n")
    write ("metadata/md5-cache/dev-util" </> (pn <> "-" <> ver)) "_md5_=old\n"
  write "eclass/x.eclass" "# eclass\n"
  git ["add", "."]
  git ["commit", "-q", "-m", "seed"]
  pure (write, git)
  where
    pnText = \case
      "codex" -> "codex"
      "codex-acp" -> "codex-acp"
      _ -> "hk"

testSnapshotIsolation :: IO ()
testSnapshotIsolation =
  withSystemTempDirectory "om-gate-snap" $ \tmp -> do
    let repo = tmp </> "overlay"
        dest = tmp </> "snap"
    createDirectoryIfMissing True repo
    (write, _) <- seedOverlay repo
    -- The unit (codex) renames its ebuild and regenerates its cache entry.
    renameFile (repo </> "dev-util/codex/codex-0.163.0.ebuild") (repo </> "dev-util/codex/codex-0.164.0.ebuild")
    renameFile (repo </> "metadata/md5-cache/dev-util/codex-0.163.0") (repo </> "metadata/md5-cache/dev-util/codex-0.164.0")
    write "dev-util/codex/Manifest" "DIST codex-new 1\n"
    -- Another unit (hk) has an uncommitted rename.
    renameFile (repo </> "dev-util/hk/hk-2.12.0.ebuild") (repo </> "dev-util/hk/hk-2.13.0.ebuild")
    renameFile (repo </> "metadata/md5-cache/dev-util/hk-2.12.0") (repo </> "metadata/md5-cache/dev-util/hk-2.13.0")
    -- An untracked file outside any unit.
    write "profiles/scratch" "dirt\n"
    assertRight "snapshot" =<< buildUnitSnapshot productionCommandRunner repo (mkPackageKey "dev-util" "codex") dest
    codexFiles <- listDirectory (dest </> "dev-util/codex")
    assertEq "unit rename present" ["Manifest", "codex-0.164.0.ebuild"] (sorted codexFiles)
    manifest <- TIO.readFile (dest </> "dev-util/codex/Manifest")
    assertEq "unit Manifest from worktree" "DIST codex-new 1\n" manifest
    hkFiles <- listDirectory (dest </> "dev-util/hk")
    assertEq "other unit at HEAD" ["Manifest", "hk-2.12.0.ebuild"] (sorted hkFiles)
    cache <- listDirectory (dest </> "metadata/md5-cache/dev-util")
    assertEq
      "cache: unit's new entry, others at HEAD"
      ["codex-0.164.0", "codex-acp-2.6.0", "hk-2.12.0"]
      (sorted cache)
    eclass <- doesFileExist (dest </> "eclass/x.eclass")
    assertTrue "rest of HEAD present" eclass
    scratch <- doesFileExist (dest </> "profiles/scratch")
    assertTrue "untracked non-unit file absent" (not scratch)
    index <- doesFileExist (dest <> ".index")
    assertTrue "private index removed" (not index)
  where
    sorted = foldr insert []
    insert x [] = [x]
    insert x (y : ys) = if x <= y then x : y : ys else y : insert x ys

testCacheEntryOf :: IO ()
testCacheEntryOf = do
  assertTrue "own entry" (isCacheEntryOf "codex" "codex-0.164.0")
  assertTrue "revision" (isCacheEntryOf "codex" "codex-0.164.0-r1")
  assertTrue "not codex-acp" (not (isCacheEntryOf "codex" "codex-acp-2.7.0"))
  assertTrue "codex-acp's own" (isCacheEntryOf "codex-acp" "codex-acp-2.7.0")

testStaging :: IO ()
testStaging =
  withSystemTempDirectory "om-gate-staging" $ \tmp -> do
    let distdir = tmp </> "distfiles"
        staging = tmp </> "run" </> "staged"
    createDirectoryIfMissing True distdir
    forM_ ["codex-0.164.0-crates.tar.xz", "rusty-v8-150.5.0-with-submodules.tar.xz", "other-1.0-deps.tar.xz"] $ \f ->
      TIO.writeFile (distdir </> f) "bytes"
    let unitFiles = [distdir </> "codex-0.164.0-crates.tar.xz", distdir </> "rusty-v8-150.5.0-with-submodules.tar.xz"]
    assertRight "stage" =<< buildStagingDir staging unitFiles
    staged <- listDirectory staging
    assertEq "exactly the unit's basenames" ["codex-0.164.0-crates.tar.xz", "rusty-v8-150.5.0-with-submodules.tar.xz"] (sort staged)
    body <- TIO.readFile (staging </> "codex-0.164.0-crates.tar.xz")
    assertEq "content" "bytes" body
    assertRight "restage is idempotent" =<< buildStagingDir staging unitFiles
    let run =
          SmokeRun
            { srKey = mkPackageKey "dev-util" "codex",
              srEbuild = Ebuild "dev-util" "codex" "0.164.0" "/snap/dev-util/codex/codex-0.164.0.ebuild",
              srVersion = parseEbuildVersion "0.164.0",
              srArch = "amd64",
              srCap = Nothing,
              srPythonSlot = Nothing
            }
        cfg =
          SmokeContainerCfg
            { sccRunId = "r1",
              sccCliPid = "1",
              sccImage = "img",
              sccSnapshot = "tree",
              sccOverlay = SnapshotMount (tmp </> "snap") (Just (StagedFetch staging "https://github.com/o/a/releases/download/")),
              sccTimeDir = Nothing,
              sccOperatorUid = 1000,
              sccJobs = 4,
              sccOverlayNames = [],
              sccCache = CacheOff
            }
        args = smokeCreateArgs cfg run
    assertTrue "staging mounted" (any (("src=" <> staging <> ",") `isInfixOf`) args)
    assertTrue "DISTDIR never mounted" (not (any ((distdir <> ",") `isInfixOf`) args) && not (any ((distdir <> "/") `isInfixOf`) args))

------------------------------------------------------------------------
-- Scheduler

codexKey, acpKey, hkKey :: PackageKey
codexKey = mkPackageKey "dev-util" "codex"
acpKey = mkPackageKey "dev-util" "codex-acp"
hkKey = mkPackageKey "dev-util" "hk"

req :: PackageKey -> GateRequest
req k = GateRequest {grKey = k, grPv = "1.0", grStaged = [], grAssetsPrefix = "https://github.com/o/a/releases/download/", grStatus = \_ -> pure ()}

baseCfg :: [PackageKey] -> (PackageKey -> [PackageKey]) -> (GateRequest -> IO GateResult) -> GateConfig
baseCfg selected deps run =
  GateConfig
    { gcSelected = Set.fromList selected,
      gcDependencies = pure . deps . grKey,
      gcReady = pure (Right ()),
      gcRun = run,
      gcAroundWait = \_ _ act -> act
    }

passed :: GateResult
passed = GatePassed [] []

-- | With one job slot, B takes the slot while A is in its gated run.
testSlotReleased :: IO ()
testSlotReleased = do
  sem <- newQSem 1
  bHadSlot <- newEmptyMVar
  let run _ = do
        -- A's run finishes only once B has run in the slot.
        r <- timeout 5000000 (takeMVar bHadSlot)
        pure (maybe (GateFailed (GateFailure HeldGate "slot never freed" [] [])) (const passed) r)
  h <- newGateScheduler (baseCfg [hkKey] (const []) run)
  ghWireSlots h (signalQSem sem) (waitQSem sem)
  waitQSem sem
  _ <- forkIO $ do
    waitQSem sem
    putMVar bHadSlot ()
    signalQSem sem
  got <- ghGate h (req hkKey)
  signalQSem sem
  assertEq "A passed after B used the slot" passed got

testLaneFifo :: IO ()
testLaneFifo = do
  order <- newIORef []
  active <- newIORef (0 :: Int)
  maxActive <- newIORef (0 :: Int)
  let run r = do
        modifyIORef' active (+ 1)
        readIORef active >>= \n -> modifyIORef' maxActive (max n)
        modifyIORef' order (++ [grKey r])
        threadDelay 50000
        modifyIORef' active (subtract 1)
        pure passed
  h <- newGateScheduler (baseCfg [] (const []) run)
  _ <-
    mapConcurrently
      (\(i, k) -> threadDelay (i * 10000) >> ghGate h (req k))
      (zip [0 ..] [codexKey, acpKey, hkKey])
  assertEq "arrival order" [codexKey, acpKey, hkKey] =<< readIORef order
  assertEq "one at a time" 1 =<< readIORef maxActive

testDependencyWait :: IO ()
testDependencyWait = do
  order <- newIORef []
  let deps k = if k == acpKey then [codexKey, mkPackageKey "dev-libs" "openssl"] else []
      run r = modifyIORef' order (++ [grKey r]) >> pure passed
  h <- newGateScheduler (baseCfg [codexKey, acpKey] deps run)
  done <- newEmptyMVar
  _ <- forkIO (ghGate h (req acpKey) >>= putMVar done)
  threadDelay 50000
  ranEarly <- readIORef order
  assertEq "acp waits while codex works" [] ranEarly
  _ <- ghGate h (req codexKey)
  ghTerminal h codexKey
  r <- timeout 5000000 (takeMVar done)
  assertEq "acp gated after codex is terminal" (Just passed) r
  assertEq "order" [codexKey, acpKey] =<< readIORef order

testUnselectedNoWait :: IO ()
testUnselectedNoWait = do
  h <- newGateScheduler (baseCfg [acpKey] (const [codexKey]) (const (pure passed)))
  r <- timeout 2000000 (ghGate h (req acpKey))
  assertEq "no wait on unselected codex" (Just passed) r

testFailedDependency :: IO ()
testFailedDependency = do
  h <- newGateScheduler (baseCfg [codexKey, acpKey] (\k -> [codexKey | k == acpKey]) (const (pure passed)))
  -- codex failed (held): it is terminal; acp gates against HEAD.
  ghTerminal h codexKey
  r <- timeout 2000000 (ghGate h (req acpKey))
  assertEq "dependent gates" (Just passed) r

testCycle :: IO ()
testCycle = do
  let a = mkPackageKey "dev-util" "a"
      b = mkPackageKey "dev-util" "b"
      deps k
        | k == a = [b]
        | k == b = [a]
        | otherwise = []
  h <- newGateScheduler (baseCfg [a, b, hkKey] deps (const (pure passed)))
  r <- timeout 5000000 $ concurrently (ghGate h (req a)) (threadDelay 20000 >> ghGate h (req b))
  case r of
    Just (GateFailed fa, GateFailed fb) -> do
      assertEq "a cycle" HeldCycle (gfReason fa)
      assertEq "b cycle" HeldCycle (gfReason fb)
      mapM_
        ( \f ->
            assertTrue
              "names both"
              (all (`T.isInfixOf` gfMessage f) [packageKeyText a, packageKeyText b])
        )
        [fa, fb]
    other -> assertTrue ("expected two cycle failures, got " <> show other) False
  other <- timeout 2000000 (ghGate h (req hkKey))
  assertEq "outside the cycle continues" (Just passed) other

testUnready :: IO ()
testUnready = do
  h <- newGateScheduler (baseCfg [] (const []) (const (pure passed))) {gcReady = pure (Left "sandbox probe failed")}
  r <- ghGate h (req hkKey)
  case r of
    GateFailed f -> assertTrue "names the prerequisite" ("sandbox probe failed" `T.isInfixOf` gfMessage f)
    _ -> assertTrue "unready gate must fail" False

testDependencyAtoms :: IO ()
testDependencyAtoms =
  assertEq
    "atoms"
    [ mkPackageKey "dev-util" "codex",
      mkPackageKey "dev-libs" "openssl",
      mkPackageKey "sys-libs" "zlib",
      mkPackageKey "virtual" "rust"
    ]
    ( md5CacheDependencies
        ( T.unlines
            [ "BDEPEND=>=virtual/rust-1.85 sys-libs/zlib",
              "DEPEND=dev-util/codex !dev-util/blocked >=dev-libs/openssl-3:0= || ( a/b c/d )",
              "RDEPEND=dev-util/codex",
              "SRC_URI=https://x/y-1.tar.gz",
              "KEYWORDS=~amd64"
            ]
        )
        `sortedLike` ["dev-util/codex", "dev-libs/openssl", "sys-libs/zlib", "virtual/rust"]
    )
  where
    sortedLike ks wanted = [k | w <- wanted, k <- ks, packageKeyText k == w]

------------------------------------------------------------------------
-- One unit

withDenoOverlay :: (FilePath -> FilePath -> IO a) -> IO a
withDenoOverlay k =
  withSystemTempDirectory "om-unit-gate" $ \tmp -> do
    let repo = tmp </> "overlay"
        git args = callProcess "git" (["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"] <> args)
        pkg = repo </> "dev-lang" </> "deno-bin"
    createDirectoryIfMissing True pkg
    TIO.writeFile (pkg </> "deno-bin-2.9.2.ebuild") "EAPI=8\nKEYWORDS=\"-* ~amd64\"\n"
    git ["init", "-q"]
    git ["add", "."]
    git ["commit", "-q", "-m", "seed"]
    renameFile (pkg </> "deno-bin-2.9.2.ebuild") (pkg </> "deno-bin-2.9.3.ebuild")
    k tmp repo

unitCfg :: FilePath -> FilePath -> T.Text -> IORef [(OverlayMount, CacheUse)] -> UnitGateCfg
unitCfg tmp repo arch seen =
  UnitGateCfg
    { ugRunner = productionCommandRunner,
      ugOverlay = repo,
      ugWorkDir = tmp </> "work",
      ugArch = arch,
      ugCeilings = \_ _ -> pure (Right Map.empty),
      ugTechnique = const (Just GitMvAndManifest),
      ugDefinition = lookupSmokeDef,
      ugLogsDir = tmp </> "logs",
      ugMetrics = noopMetrics,
      ugRun = \mount _ cache _ _ _ -> do
        modifyIORef' seen (++ [(mount, cache)])
        pure (RunOutcome RunPass Nothing)
    }

noOps :: SmokeOps
noOps =
  SmokeOps
    { soSweep = pure (),
      soEnsureImage = pure (Right ()),
      soWithSnapshot = fmap Right,
      soReleaseTree = pure (),
      soProbe = pure (Right ()),
      soPrepareCache = pure CacheOff,
      soRun = \_ _ _ _ -> error "replaced by ugRun",
      soEmit = \_ -> pure (),
      soLogFailure = \_ -> pure (),
      soLogWarning = \_ -> pure (),
      soLogInfo = \_ -> pure (),
      soProgress = \_ _ _ -> pure ()
    }

testUnitGateRuns :: IO ()
testUnitGateRuns = withDenoOverlay $ \tmp repo -> do
  seen <- newIORef []
  let dist = tmp </> "deno-x.tar.xz"
  TIO.writeFile dist "bytes"
  let request = (req (mkPackageKey "dev-lang" "deno-bin")) {grPv = "2.9.3", grStaged = [dist]}
  got <-
    withGateSession
      GateSessionCfg
        { gscSmokeOps = noOps,
          gscRunUnit = runUnitGate (unitCfg tmp repo "amd64" seen) noOps,
          gscDependencies = \_ -> pure [],
          gscAroundWait = \_ _ act -> act
        }
      [mkPackageKey "dev-lang" "deno-bin"]
      (\gate _ -> ghGate gate request)
  case got of
    GatePassed runs _ -> assertEq "one run" 1 (length runs)
    other -> assertTrue ("expected a pass, got " <> show other) False
  calls <- readIORef seen
  case calls of
    [(SnapshotMount dir (Just staged), cache)] -> do
      assertEq "no compile cache" CacheOff cache
      assertTrue "snapshot, not the worktree" (dir /= repo)
      assertEq "staged prefix" "https://github.com/o/a/releases/download/" (sfPrefix staged)
    other -> assertTrue ("expected one snapshot run, got " <> show other) False

testUnitGateArchSkip :: IO ()
testUnitGateArchSkip = withDenoOverlay $ \tmp repo -> do
  seen <- newIORef []
  got <- runUnitGate (unitCfg tmp repo "arm64" seen) noOps CacheOff ((req (mkPackageKey "dev-lang" "deno-bin")) {grPv = "2.9.3"})
  case got of
    GateFailed f -> assertTrue "names arm64" ("arm64" `T.isInfixOf` gfMessage f)
    other -> assertTrue ("expected a failure, got " <> show other) False
  assertEq "no container" 0 . length =<< readIORef seen

testWaitStatuses :: IO ()
testWaitStatuses = do
  seen <- newIORef []
  h <- newGateScheduler (baseCfg [codexKey, acpKey] (\k -> [codexKey | k == acpKey]) (const (pure passed)))
  let statusReq k = (req k) {grStatus = \s -> modifyIORef' seen (++ [(k, s)])}
  done <- newEmptyMVar
  _ <- forkIO (ghGate h (statusReq acpKey) >>= putMVar done)
  threadDelay 30000
  ghTerminal h codexKey
  _ <- takeMVar done
  got <- readIORef seen
  assertTrue "names the dependency" ((acpKey, "waiting at gate for dev-util/codex") `elem` got)
  assertTrue "names the lane wait" ((acpKey, "waiting for the smoke lane") `elem` got)

testGateRunSpan :: IO ()
testGateRunSpan = withDenoOverlay $ \tmp repo -> do
  seen <- newIORef []
  (got, evs) <- withRecorded $ \m ->
    withSpan m "package" ["package" .= ("dev-lang/deno-bin" :: T.Text)] $
      runUnitGate (unitCfg tmp repo "amd64" seen) {ugMetrics = m} noOps CacheOff ((req (mkPackageKey "dev-lang" "deno-bin")) {grPv = "2.9.3"})
  assertTrue "passed" (case got of GatePassed {} -> True; _ -> False)
  pkg <- firstId "package" evs
  case [a | (_, Just p, "gate.run", a) <- spanStarts evs, p == pkg] of
    [a] -> do
      assertEq "package" (Just (String "dev-lang/deno-bin")) (KM.lookup "package" a)
      assertEq "pv" (Just (String "2.9.3")) (KM.lookup "pv" a)
    other -> assertTrue ("expected one gate.run under the package, got " <> show (length other)) False
  let endAttrs = [a | e <- evs, evKind e == "span_end", Just (Object a) <- [field "attrs" e]]
  assertTrue
    "gate outcome and stage recorded"
    (any (\a -> KM.lookup "gate_outcome" a == Just (String "pass") && KM.lookup "stage" a == Just (String "checks")) endAttrs)
