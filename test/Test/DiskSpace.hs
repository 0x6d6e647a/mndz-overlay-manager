{-# LANGUAGE OverloadedStrings #-}

module Test.DiskSpace (tests) where

import Data.Ratio ((%))
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply
  ( ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    PlannedWork (..),
    PvDiskEstimate (..),
    buildUnitPlanFromPvEstimates,
    buildUnitPlansFromClassified,
    classifyPackageUnits,
    estimateFullTempNeed,
    estimateReuseTempNeed,
  )
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseOps (..),
  )
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
    getFreeBytes,
    lookupManifestBaselineBySuffix,
    lookupManifestBaselineForClass,
    maxNeed,
    parseManifestDistEntries,
    presentDistfileNeed,
    runDiskSpaceGate,
    safetyMarginBytes,
  )
import Update.Go.Lanes
  ( PlannedEbuild (..),
    RuntimeLanePlan (..),
  )
import Update.Types
  ( EcosystemSpec (..),
    PackageKey (..),
    UpdateSource (..),
  )

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
      testCase "present distfile zeros need" testPresentDistfileZero,
      testCase "production getFreeBytes smoke" testGetFreeBytesSmoke,
      testCase "multi-PV max single PV unit plan" testMultiPvMaxUnit,
      testCase "mixed reuse and full concurrent sum" testMixedReuseFullConcurrent,
      testCase "reuse vs full estimate helpers" testReuseFullHelpers,
      testCase "classified units omit empty" testClassifiedOmitEmpty,
      testCase "classify asset+size → reuse" testClassifyReuseWithSize,
      testCase "classify no asset → full" testClassifyFullMissing,
      testCase "classify probe error → hard-fail" testClassifyProbeError,
      testCase "gate needs-work only not full inventory" testGateNeedsWorkOnly
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

-- | Smoke: production @statvfs@ path returns non-negative free bytes.
testGetFreeBytesSmoke :: IO ()
testGetFreeBytesSmoke =
  withSystemTempDirectory "mndz-diskspace-statvfs-" $ \tmp -> do
    result <- getFreeBytes tmp
    n <- assertRight "getFreeBytes succeeds" result
    assertTrue "free bytes non-negative" (n >= 0)

testMultiPvMaxUnit :: IO ()
testMultiPvMaxUnit = do
  let key = PackageKey "dev-util/crush"
      estimates =
        [ PvDiskEstimate FullGo (1 * giB) 0,
          PvDiskEstimate FullGo (2 * giB) 0,
          PvDiskEstimate FullGo (3 * giB) 0
        ]
  case buildUnitPlanFromPvEstimates key estimates of
    Nothing -> fail "expected unit plan"
    Just u -> do
      assertEq "temp is max not sum" (3 * giB) (udpTempNeed u)
      assertEq "key" key (udpKey u)
  -- Concurrent sum for a single package unit is just that unit's need.
  let units = case buildUnitPlanFromPvEstimates key estimates of
        Just u -> [u]
        Nothing -> []
  assertEq "jobs any → max only" (3 * giB) (concurrentSumNeed 4 (map udpTempNeed units))

testMixedReuseFullConcurrent :: IO ()
testMixedReuseFullConcurrent = do
  let reuseNeed = estimateNeedBytes ReusePath (Just (100 * 1024 * 1024))
      fullNeed = estimateNeedBytes FullGo (Just (100 * 1024 * 1024))
      units =
        [ UnitDiskPlan (PackageKey "a/a") ReusePath reuseNeed 0,
          UnitDiskPlan (PackageKey "b/b") FullGo fullNeed 0
        ]
      needs = map udpTempNeed units
  assertTrue "full > reuse" (fullNeed > reuseNeed)
  assertEq "jobs 1 is max" (maxNeed needs) (concurrentSumNeed 1 needs)
  assertEq "jobs 2 is sum" (reuseNeed + fullNeed) (concurrentSumNeed 2 needs)
  let err =
        evaluateDiskFeasibility
          2
          "/tmp"
          (reuseNeed + fullNeed - 1)
          1
          "/cache/dist"
          (100 * giB)
          2
          False
          Nothing
          units
  case err of
    Left msg -> assertTrue "concurrent" ("concurrent" `T.isInfixOf` msg)
    Right _ -> fail "expected concurrent sum failure for mixed units"

testReuseFullHelpers :: IO ()
testReuseFullHelpers = do
  let base = 50 * 1024 * 1024
  assertEq
    "reuse helper"
    (estimateNeedBytes ReusePath (Just base))
    (estimateReuseTempNeed (Just base))
  assertEq
    "full helper"
    (estimateNeedBytes FullGo (Just base))
    (estimateFullTempNeed (Go Nothing) (Just base))

testClassifiedOmitEmpty :: IO ()
testClassifiedOmitEmpty = do
  let key = PackageKey "dev-util/crush"
      pv = parseEbuildVersion "1.0.0"
      unit =
        ClassifiedPvUnit
          { cpuKey = key,
            cpuPN = "crush",
            cpuPV = pv,
            cpuEco = Go Nothing,
            cpuClass = FullGo,
            cpuTempBaseline = Just (10 * 1024 * 1024)
          }
      plans = buildUnitPlansFromClassified [unit]
  case plans of
    [p] -> assertTrue "temp > 0" (udpTempNeed p > 0)
    _ -> fail ("expected one unit, got " <> show (length plans))

fakeReleaseOps ::
  IO (Either T.Text (Maybe ReleaseInfo)) ->
  ReleaseOps
fakeReleaseOps getTag =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> getTag,
      roDownloadAsset = \_ _ -> pure (Left "unused"),
      roCreateReleaseWithAssets = \_ _ -> pure (Left "unused")
    }

mkDepsWork :: EcosystemSpec -> [EbuildVersion] -> PlannedWork
mkDepsWork eco needPVs =
  PlannedDeps
    { pdEco = eco,
      pdSource = GitHub "o" "r" "v",
      pdPlan =
        RuntimeLanePlan
          { glpLanes = [],
            glpEbuilds =
              [ PlannedEbuild
                  { pePV = pv,
                    peKeywords = [],
                    peLanes = []
                  }
              | pv <- needPVs
              ],
            glpUniquePVs = needPVs,
            glpRuntimeAtom = "dev-lang/go"
          },
      pdLocalPVs = [],
      pdContentFix = []
    }

testClassifyReuseWithSize :: IO ()
testClassifyReuseWithSize =
  withSystemTempDirectory "mndz-classify-" $ \tmp -> do
    let key = PackageKey "dev-util/crush"
        pn = "crush"
        pv = parseEbuildVersion "0.84.0"
        assetName = "crush-0.84.0-vendor.tar.xz"
        ops =
          fakeReleaseOps $
            pure $
              Right $
                Just
                  ReleaseInfo
                    { riId = 1,
                      riTag = "crush-0.84.0",
                      riAssets =
                        [ ReleaseAsset
                            { raName = T.pack assetName,
                              raBrowserDownloadUrl = "https://example/asset",
                              raSize = Just (42 * 1024 * 1024)
                            }
                        ]
                    }
    result <-
      classifyPackageUnits
        ops
        "owner"
        "repo"
        tmp
        key
        pn
        (mkDepsWork (Go Nothing) [pv])
    case result of
      ClassifyOk k [u] -> do
        assertEq "key" key k
        assertEq "reuse class" ReusePath (cpuClass u)
        assertEq "size baseline" (Just (42 * 1024 * 1024)) (cpuTempBaseline u)
      other -> fail ("unexpected: " <> show other)

testClassifyFullMissing :: IO ()
testClassifyFullMissing =
  withSystemTempDirectory "mndz-classify-full-" $ \tmp -> do
    let key = PackageKey "dev-util/crush"
        pn = "crush"
        pv = parseEbuildVersion "0.84.0"
        ops = fakeReleaseOps (pure (Right Nothing))
    result <-
      classifyPackageUnits
        ops
        "owner"
        "repo"
        tmp
        key
        pn
        (mkDepsWork (Go Nothing) [pv])
    case result of
      ClassifyOk _ [u] -> assertEq "full go" FullGo (cpuClass u)
      other -> fail ("unexpected: " <> show other)

testClassifyProbeError :: IO ()
testClassifyProbeError =
  withSystemTempDirectory "mndz-classify-err-" $ \tmp -> do
    let key = PackageKey "dev-util/crush"
        pn = "crush"
        pv = parseEbuildVersion "0.84.0"
        ops = fakeReleaseOps (pure (Left "network boom"))
    result <-
      classifyPackageUnits
        ops
        "owner"
        "repo"
        tmp
        key
        pn
        (mkDepsWork (Go Nothing) [pv])
    case result of
      ClassifyHardFail k msg -> do
        assertEq "key" key k
        assertTrue "mentions lookup" ("release asset lookup failed" `T.isInfixOf` msg)
      other -> fail ("unexpected: " <> show other)

-- | Free space for one needs-work unit passes; full-inventory estimate would fail.
testGateNeedsWorkOnly :: IO ()
testGateNeedsWorkOnly = do
  let oneNeed = estimateNeedBytes FullGo (Just (100 * 1024 * 1024))
      needsWorkUnits =
        [UnitDiskPlan (PackageKey "dev-util/crush") FullGo oneNeed 0]
      inventoryUnits =
        needsWorkUnits
          <> [ UnitDiskPlan (PackageKey ("dev-util/pkg" <> T.pack (show n))) FullGo oneNeed 0
             | n <- [1 .. 5 :: Int]
             ]
      free = oneNeed + (10 * 1024 * 1024) -- fits one, not six concurrent
  case evaluateDiskFeasibility
    6
    "/tmp"
    free
    1
    "/cache/dist"
    (100 * giB)
    2
    False
    Nothing
    needsWorkUnits of
    Left err -> fail ("needs-work should pass: " <> T.unpack err)
    Right _ -> pure ()
  case evaluateDiskFeasibility
    6
    "/tmp"
    free
    1
    "/cache/dist"
    (100 * giB)
    2
    False
    Nothing
    inventoryUnits of
    Left _ -> pure ()
    Right _ -> fail "full inventory should fail concurrent sum"
