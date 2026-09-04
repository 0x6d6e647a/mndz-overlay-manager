{-# LANGUAGE OverloadedStrings #-}

-- | Pure overlay wait-edge / admit / plan-delta unit tests.
module Test.OverlayWaves (tests) where

import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Go.Lanes (RuntimeLanePlan (..))
import Update.OverlayWaves
  ( AdmitSets (..),
    OverlayPlanKind (..),
    bunBinPackageKey,
    classifyAdmit,
    hypotheticalCeilings,
    overlayCeilingProvider,
    overlayCeilingProviderForKey,
    overlayDirtyPreflightMessage,
    overlayProviderPvMismatchMessage,
    planDeltaHolds,
    replaceNewestNonLivePv,
  )
import Update.Runtime.Ceilings
  ( CeilingLane (..),
    KeywordTier (..),
    RuntimeEbuildMeta (..),
    bunBinRuntimeAtom,
    ceilingFor,
    computeCeilings,
  )
import Update.Types
  ( EcosystemSpec (..),
    PackageKey (..),
    UpdateTechnique (..),
    mkPackageKey,
  )

tests :: TestTree
tests =
  testGroup
    "OverlayWaves"
    [ testCase "Bun waits on bun-bin; others do not" testTechniqueEdges,
      testCase "Hardcoded ralph/opencode wait; mise does not" testHardcodedEdges,
      testCase "New Bun package inherits the edge" testNewBunInherits,
      testCase "Admit: ralph withheld while bun-bin needs work" testAdmitWithhold,
      testCase "Admit: mise is ready alongside bun-bin" testAdmitMiseReady,
      testCase "Admit: provider already current does not withhold" testAdmitProviderSkip,
      testCase "Waiting keys are not in the ready/job set" testWaitingNotReady,
      testCase "Hypothetical ceilings replace newest PV keep KEYWORDS" testHypotheticalCeilings,
      testCase "Plan-delta on unique PVs and needs-work" testPlanDelta,
      testCase "Dirty preflight message names path and package" testDirtyPreflightMessage,
      testCase "Provider PV mismatch names both PVs" testProviderPvMismatchMessage
    ]

ralph :: PackageKey
ralph = mkPackageKey "dev-util" "ralph-tui"

opencode :: PackageKey
opencode = mkPackageKey "dev-util" "opencode"

mise :: PackageKey
mise = mkPackageKey "dev-util" "mise"

testTechniqueEdges :: IO ()
testTechniqueEdges = do
  assertEq
    "Bun"
    (Just bunBinPackageKey)
    (overlayCeilingProvider (DepsAndAssets Bun))
  assertEq
    "Go"
    Nothing
    (overlayCeilingProvider (DepsAndAssets (Go Nothing)))
  assertEq
    "Npm"
    Nothing
    (overlayCeilingProvider (DepsAndAssets NpmEco))
  assertEq
    "Cargo"
    Nothing
    (overlayCeilingProvider (DepsAndAssets (Cargo Nothing Nothing)))
  assertEq
    "Sbcl"
    Nothing
    (overlayCeilingProvider (DepsAndAssets Sbcl))
  assertEq "GitMv" Nothing (overlayCeilingProvider GitMvAndManifest)

testHardcodedEdges :: IO ()
testHardcodedEdges = do
  assertEq "ralph" (Just bunBinPackageKey) (overlayCeilingProviderForKey ralph)
  assertEq "opencode" (Just bunBinPackageKey) (overlayCeilingProviderForKey opencode)
  assertEq "mise" Nothing (overlayCeilingProviderForKey mise)
  assertEq "bun-bin itself" Nothing (overlayCeilingProviderForKey bunBinPackageKey)
  assertEq "qlot" Nothing (overlayCeilingProviderForKey (mkPackageKey "dev-lisp" "qlot"))
  assertEq
    "node-gyp"
    Nothing
    (overlayCeilingProviderForKey (mkPackageKey "dev-build" "node-gyp"))
  assertEq
    "autolith"
    Nothing
    (overlayCeilingProviderForKey (mkPackageKey "dev-util" "autolith"))

testNewBunInherits :: IO ()
testNewBunInherits = do
  let fresh = mkPackageKey "dev-util" "brand-new-bun-app"
      providerOf k
        | k == fresh = overlayCeilingProvider (DepsAndAssets Bun)
        | otherwise = overlayCeilingProviderForKey k
  assertEq
    "new Bun package waits on bun-bin without an edge table"
    (Just bunBinPackageKey)
    (providerOf fresh)

testAdmitWithhold :: IO ()
testAdmitWithhold = do
  let rows =
        [ (bunBinPackageKey, OverlayPlanWork),
          (ralph, OverlayPlanWork),
          (opencode, OverlayPlanSkip)
        ]
      sets = classifyAdmit overlayCeilingProviderForKey rows
  assertEq "bun-bin ready" [bunBinPackageKey] (asReady sets)
  assertEq
    "ralph and opencode withheld"
    [(ralph, bunBinPackageKey), (opencode, bunBinPackageKey)]
    (asWithheld sets)

testAdmitMiseReady :: IO ()
testAdmitMiseReady = do
  let rows =
        [ (bunBinPackageKey, OverlayPlanWork),
          (mise, OverlayPlanWork),
          (ralph, OverlayPlanWork)
        ]
      sets = classifyAdmit overlayCeilingProviderForKey rows
  assertTrue "mise ready" (mise `elem` asReady sets)
  assertTrue "bun-bin ready" (bunBinPackageKey `elem` asReady sets)
  assertTrue "ralph not ready" (ralph `notElem` asReady sets)
  assertEq "ralph withheld" [(ralph, bunBinPackageKey)] (asWithheld sets)

testAdmitProviderSkip :: IO ()
testAdmitProviderSkip = do
  let rows =
        [ (bunBinPackageKey, OverlayPlanSkip),
          (ralph, OverlayPlanWork)
        ]
      sets = classifyAdmit overlayCeilingProviderForKey rows
  assertEq "ralph ready when bun-bin is current" [ralph] (asReady sets)
  assertEq "nothing withheld" [] (asWithheld sets)
  assertEq "bun-bin terminal skip" [bunBinPackageKey] (asTerminal sets)

testWaitingNotReady :: IO ()
testWaitingNotReady = do
  let rows =
        [ (bunBinPackageKey, OverlayPlanWork),
          (ralph, OverlayPlanWork)
        ]
      sets = classifyAdmit overlayCeilingProviderForKey rows
  assertTrue
    "withheld consumer is not admitted (does not occupy a job slot)"
    (ralph `notElem` asReady sets && ralph `elem` map fst (asWithheld sets))

kwAmd64 :: [Text]
kwAmd64 = ["~amd64"]

testHypotheticalCeilings :: IO ()
testHypotheticalCeilings = do
  let v11 = parseEbuildVersion "1.1.0"
      v12 = parseEbuildVersion "1.2.0"
      old =
        RuntimeEbuildMeta
          { remPV = v11,
            remKeywords = kwAmd64
          }
      older =
        RuntimeEbuildMeta
          { remPV = parseEbuildVersion "1.0.0",
            remKeywords = ["~arm64"]
          }
      replaced = replaceNewestNonLivePv [older, old] v12
  assertEq
    "newest PV replaced"
    [older, old {remPV = v12}]
    replaced
  assertEq
    "KEYWORDS unchanged on replaced meta"
    kwAmd64
    (remKeywords (replaced !! 1))
  let hypo = hypotheticalCeilings [older, old] v12
      onDisk = computeCeilings bunBinRuntimeAtom [older, old]
  assertEq
    "on-disk amd64 tilde is 1.1.0"
    (Just v11)
    (ceilingFor onDisk (CeilingLane "amd64" Tilde))
  assertEq
    "hypo amd64 tilde is 1.2.0"
    (Just v12)
    (ceilingFor hypo (CeilingLane "amd64" Tilde))

testPlanDelta :: IO ()
testPlanDelta = do
  let v1 = parseEbuildVersion "1.0.0"
      v2 = parseEbuildVersion "1.5.0"
      p1 = emptyPlan [v1]
      p2 = emptyPlan [v2]
  assertTrue "unique PVs differ" (planDeltaHolds [v1] False [v2] False)
  assertTrue "needs-work differs" (planDeltaHolds [v1] False [v1] True)
  assertTrue "identical is not delta" (not (planDeltaHolds [v1] True [v1] True))
  assertEq "plans carry unique PVs" [v1] (glpUniquePVs p1)
  assertEq "hypo plan unique" [v2] (glpUniquePVs p2)

emptyPlan :: [EbuildVersion] -> RuntimeLanePlan
emptyPlan pvs =
  RuntimeLanePlan
    { glpLanes = [],
      glpEbuilds = [],
      glpUniquePVs = pvs,
      glpRuntimeAtom = bunBinRuntimeAtom,
      glpDirectTagFloors = [],
      glpFloorPolicy = Nothing
    }

testDirtyPreflightMessage :: IO ()
testDirtyPreflightMessage = do
  let msg =
        overlayDirtyPreflightMessage
          bunBinPackageKey
          "dev-lang/bun-bin"
  assertTrue "names package" ("dev-lang/bun-bin" `T.isInfixOf` msg)
  assertTrue "names path" ("dev-lang/bun-bin" `T.isInfixOf` msg)
  assertTrue "restore" ("restore or finish" `T.isInfixOf` msg)
  assertTrue "HEAD" ("git HEAD" `T.isInfixOf` msg)

testProviderPvMismatchMessage :: IO ()
testProviderPvMismatchMessage = do
  let consumer = mkPackageKey "dev-util" "ralph-tui"
      planned = parseEbuildVersion "1.4.0"
      overlayPv = parseEbuildVersion "1.3.14"
      msg =
        overlayProviderPvMismatchMessage
          consumer
          bunBinPackageKey
          planned
          overlayPv
  assertTrue "names consumer" ("dev-util/ralph-tui" `T.isInfixOf` msg)
  assertTrue "names provider" ("dev-lang/bun-bin" `T.isInfixOf` msg)
  assertTrue "planned PV" ("1.4.0" `T.isInfixOf` msg)
  assertTrue "overlay PV" ("1.3.14" `T.isInfixOf` msg)
  assertTrue "not mutated" ("not mutated" `T.isInfixOf` msg)
  assertTrue "recovery" ("Restore or finish" `T.isInfixOf` msg)
