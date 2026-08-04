{-# LANGUAGE OverloadedStrings #-}

module Test.DiskSpace (tests) where

import Data.Ratio ((%))
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.DiskSpace
  ( DiskGateOk (..),
    DiskSpaceProbe (..),
    ManifestDistEntry (..),
    MaterializeClass (..),
    UnitDiskPlan (..),
    combineSameDeviceNeeds,
    concurrentSumNeed,
    estimateNeedBytes,
    evaluateDiskFeasibility,
    factorCargo,
    factorGoFull,
    factorNpmBun,
    factorReuse,
    factorSbcl,
    floorCargoTemp,
    floorGitMvDist,
    floorGoTemp,
    floorNpmBunTemp,
    floorReuseTemp,
    floorSbclTemp,
    lookupManifestBaselineBySuffix,
    lookupManifestBaselineForClass,
    maxNeed,
    parseManifestDistEntries,
    presentDistfileNeed,
    runDiskSpaceGate,
    safetyMarginBytes,
  )
import Update.Types (PackageKey (..))

tests :: TestTree
tests =
  testGroup
    "DiskSpace"
    [ testCase "margin and floors include 256 MiB" testMarginAndFloors,
      testCase "baseline times factors" testFactors,
      testCase "max and concurrent sum jobs 1 and 2" testMaxAndConcurrent,
      testCase "same-device combined needs" testSameDeviceCombine,
      testCase "gate fails when free below max" testGateFailMax,
      testCase "gate fails when free below concurrent sum" testGateFailConcurrent,
      testCase "gate passes with ample free" testGatePass,
      testCase "Portage warn does not hard-fail" testPortageWarnOnly,
      testCase "Manifest DIST size parse" testManifestParse,
      testCase "present distfile zeros need" testPresentDistfileZero
    ]

giB :: Integer
giB = 1024 * 1024 * 1024

testMarginAndFloors :: IO ()
testMarginAndFloors = do
  assertEq "margin" (256 * 1024 * 1024) safetyMarginBytes
  assertEq "go floor+margin" (floorGoTemp + safetyMarginBytes) (estimateNeedBytes FullGo Nothing)
  assertEq "cargo floor+margin" (floorCargoTemp + safetyMarginBytes) (estimateNeedBytes FullCargo Nothing)
  assertEq "npm floor+margin" (floorNpmBunTemp + safetyMarginBytes) (estimateNeedBytes FullNpmBun Nothing)
  assertEq "sbcl floor+margin" (floorSbclTemp + safetyMarginBytes) (estimateNeedBytes FullSbcl Nothing)
  assertEq "reuse floor+margin" (floorReuseTemp + safetyMarginBytes) (estimateNeedBytes ReusePath Nothing)
  assertEq "gitmv floor+margin" (floorGitMvDist + safetyMarginBytes) (estimateNeedBytes GitMvFetch Nothing)

testFactors :: IO ()
testFactors = do
  let base = 100 * 1024 * 1024 -- 100 MiB
  assertEq "go factor 5" (5 * base + safetyMarginBytes) (estimateNeedBytes FullGo (Just base))
  assertEq "cargo factor 12" (12 * base + safetyMarginBytes) (estimateNeedBytes FullCargo (Just base))
  assertEq "npm factor 4" (4 * base + safetyMarginBytes) (estimateNeedBytes FullNpmBun (Just base))
  assertEq "sbcl factor 10" (10 * base + safetyMarginBytes) (estimateNeedBytes FullSbcl (Just base))
  -- 1.1 × base = 110 MiB
  assertEq "reuse 1.1" ((base * 11) `div` 10 + safetyMarginBytes) (estimateNeedBytes ReusePath (Just base))
  -- sanity: named factors match design table
  assertEq "factor go" 5 (numeratorLike factorGoFull)
  assertEq "factor cargo" 12 (numeratorLike factorCargo)
  assertEq "factor npm" 4 (numeratorLike factorNpmBun)
  assertEq "factor sbcl" 10 (numeratorLike factorSbcl)
  assertTrue "reuse ~1.1" (factorReuse > 1 && factorReuse < (12 % 10) + (1 % 100))
  where
    numeratorLike r = round (fromRational r :: Double) :: Integer

testMaxAndConcurrent :: IO ()
testMaxAndConcurrent = do
  let needs = [1 * giB, 2 * giB, 3 * giB]
  assertEq "max" (3 * giB) (maxNeed needs)
  assertEq "jobs 1" (3 * giB) (concurrentSumNeed 1 needs)
  assertEq "jobs 2" (5 * giB) (concurrentSumNeed 2 needs)
  assertEq "jobs 3" (6 * giB) (concurrentSumNeed 3 needs)
  assertEq "empty max" 0 (maxNeed [])
  assertEq "empty conc" 0 (concurrentSumNeed 2 [])

testSameDeviceCombine :: IO ()
testSameDeviceCombine = do
  assertEq "zip sum" [3, 5, 4] (combineSameDeviceNeeds [1, 2, 4] [2, 3])
  assertEq "left only" [1, 2] (combineSameDeviceNeeds [1, 2] [])
  assertEq "right only" [9] (combineSameDeviceNeeds [] [9])

sampleUnits :: [UnitDiskPlan]
sampleUnits =
  [ UnitDiskPlan (PackageKey "a/a") FullGo (3 * giB) 0,
    UnitDiskPlan (PackageKey "b/b") FullGo (2 * giB) 0,
    UnitDiskPlan (PackageKey "c/c") FullGo (1 * giB) 0
  ]

testGateFailMax :: IO ()
testGateFailMax = do
  let err =
        evaluateDiskFeasibility
          1
          "/tmp"
          (1 * giB) -- free below largest unit
          1
          "/cache/dist"
          (100 * giB)
          2
          False
          Nothing
          sampleUnits
  case err of
    Left msg -> assertTrue "mentions temp" ("temp root" `T.isInfixOf` msg || "/tmp" `T.isInfixOf` msg)
    Right _ -> fail "expected gate failure for free < max"

testGateFailConcurrent :: IO ()
testGateFailConcurrent = do
  -- free fits max (3G) but not concurrent sum under jobs 2 (5G)
  let err =
        evaluateDiskFeasibility
          2
          "/tmp"
          (4 * giB)
          1
          "/cache/dist"
          (100 * giB)
          2
          False
          Nothing
          sampleUnits
  case err of
    Left msg -> do
      assertTrue "concurrent" ("concurrent" `T.isInfixOf` msg)
      assertTrue "jobs hint" ("--jobs" `T.isInfixOf` msg)
    Right _ -> fail "expected concurrent sum failure"

testGatePass :: IO ()
testGatePass = do
  let probe =
        DiskSpaceProbe
          { dspFreeBytes = \_ -> pure (Right (20 * giB)),
            dspDeviceId = \p -> pure (Right (if p == "/tmp" then 1 else 2))
          }
  ok <-
    runDiskSpaceGate
      probe
      2
      "/tmp"
      "/cache/dist"
      Nothing
      sampleUnits
  DiskGateOk warns <- assertRight "gate pass" ok
  assertEq "no warnings" [] warns

testPortageWarnOnly :: IO ()
testPortageWarnOnly = do
  let result =
        evaluateDiskFeasibility
          1
          "/tmp"
          (20 * giB)
          1
          "/cache/dist"
          (20 * giB)
          2
          False
          (Just ("/var/cache/distfiles", 100 * 1024 * 1024)) -- 100 MiB free
          sampleUnits
  DiskGateOk warns <- assertRight "portage does not hard-fail" result
  assertTrue "has warning" (not (null warns))
  assertTrue "mentions Portage" (any ("Portage DISTDIR" `T.isInfixOf`) warns)

testManifestParse :: IO ()
testManifestParse = do
  let man =
        T.unlines
          [ "DIST crush-0.84.0-vendor.tar.xz 104857600 BLAKE2B deadbeef SHA512 cafebabe",
            "DIST other-1.0.tar.gz 50 SHA512 abc",
            "EBUILD crush-0.84.0.ebuild 123 BLAKE2B x SHA512 y",
            "DIST bad-line",
            "DIST beads-1.0-vendor.tar.xz 209715200 BLAKE2B a SHA512 b"
          ]
      entries = parseManifestDistEntries man
  assertEq
    "two DIST"
    [ ManifestDistEntry "crush-0.84.0-vendor.tar.xz" 104857600,
      ManifestDistEntry "other-1.0.tar.gz" 50,
      ManifestDistEntry "beads-1.0-vendor.tar.xz" 209715200
    ]
    entries
  assertEq
    "largest vendor"
    (Just 209715200)
    (lookupManifestBaselineBySuffix man "-vendor.tar.xz")
  assertEq
    "go class"
    (Just 209715200)
    (lookupManifestBaselineForClass man FullGo)

testPresentDistfileZero :: IO ()
testPresentDistfileZero =
  withSystemTempDirectory "mndz-diskspace-test-" $ \tmp -> do
    let distDir = tmp </> "distfiles"
        name = "pkg-1.0-vendor.tar.xz"
    createDirectoryIfMissing True distDir
    writeFile (distDir </> name) "x"
    needPresent <-
      presentDistfileNeed doesFileExist distDir name (100 * 1024 * 1024)
    assertEq "present → 0" 0 needPresent
    needMissing <-
      presentDistfileNeed doesFileExist distDir "missing.tar.xz" (100 * 1024 * 1024)
    assertTrue "missing > 0" (needMissing > 0)
