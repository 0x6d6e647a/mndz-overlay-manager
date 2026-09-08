{-# LANGUAGE OverloadedStrings #-}

-- | Pure overlay-internal atom parse, match, keep-set, rename-away, cycle.
module Test.AtomClosure (unitTests) where

import Data.Containers.ListUtils (nubOrd)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply.TestSupport
  ( DepNeed (..),
    OverlayAtom (..),
    ProviderVer (..),
    VersionOp (..),
    asSlotZero,
    atomMatchesPV,
    extrasBeyondKeep,
    keepProviderPVs,
    parseConsumerNeeds,
    prettyOverlayAtom,
    prettyWaitCycle,
    pvsSatisfyNeed,
    renameAwayUnsatisfied,
    waitCycleWithEdge,
  )
import Update.Types (PackageKey (..), mkPackageKey, packageKeyText)

unitTests :: TestTree
unitTests =
  testGroup
    "AtomClosure"
    [ testCase "hk USE-conditional usage is overlay-internal" testHkUsageConditional,
      testCase "opencode ripgrep is not overlay-internal" testOpencodeRipgrepIgnored,
      testCase "ralph bun-bin >= is overlay-internal" testRalphBunBinGe,
      testCase "autolith gentoo || is ignored" testAutolithOrIgnored,
      testCase "self-atom is ignored" testSelfAtomIgnored,
      testCase "same-file ${RDEPEND} expand" testRdependExpand,
      testCase ":= slot operator is stripped" testColonEqStrip,
      testCase "PV operators match via comparePV" testPvOperators,
      testCase "unparseable DEPEND-family is Left" testUnparseableFailClosed,
      testCase "overlay-internal blocker is Left" testBlockerFailClosed,
      testCase "explicit non-0 slot is Left" testNonZeroSlotFailClosed,
      testCase "unknown operator is Left" testUnknownOpFailClosed,
      testCase "keep-set retains exact-pin extra" testKeepExactPin,
      testCase "keep-set drops unneeded siblings" testKeepDropsUnversionedExtra,
      testCase "keep-set does not invent a missing PV" testKeepDoesNotInvent,
      testCase "rename-away exact pin fails; >= and unversioned succeed" testRenameAway,
      testCase "bun-bin :0 floor matches SLOT=0 only" testBunBinSlotSatisfy,
      testCase "wait cycle path names both packages" testWaitCycle
    ]

hkKey :: PackageKey
hkKey = mkPackageKey "dev-util" "hk"

usageKey :: PackageKey
usageKey = mkPackageKey "dev-util" "usage"

ralphKey :: PackageKey
ralphKey = mkPackageKey "dev-util" "ralph-tui"

opencodeKey :: PackageKey
opencodeKey = mkPackageKey "dev-util" "opencode"

autolithKey :: PackageKey
autolithKey = mkPackageKey "dev-util" "autolith"

bunBinKey :: PackageKey
bunBinKey = mkPackageKey "dev-lang" "bun-bin"

overlayKeys :: Set.Set PackageKey
overlayKeys =
  Set.fromList
    [hkKey, usageKey, ralphKey, opencodeKey, autolithKey, bunBinKey]

needsOf :: PackageKey -> Text -> IO [DepNeed]
needsOf consumer body =
  assertRight "parse" (parseConsumerNeeds overlayKeys consumer body)

needKeys :: [DepNeed] -> [PackageKey]
needKeys = concatMap keys
  where
    keys (NeedAtom a) = [oaKey a]
    keys (NeedOr as) = map oaKey as

hkUsageBody :: Text
hkUsageBody =
  T.unlines
    [ "EAPI=8",
      "IUSE=\"bash-completion\"",
      "RDEPEND=\"",
      "\tbash-completion? ( dev-util/usage )",
      "\""
    ]

testHkUsageConditional :: IO ()
testHkUsageConditional = do
  needs <- needsOf hkKey hkUsageBody
  assertEq "usage atom" [usageKey] (needKeys needs)
  case needs of
    [NeedAtom a] -> do
      assertEq "unversioned" OpUnversioned (oaOp a)
      assertEq "pretty" "dev-util/usage" (prettyOverlayAtom a)
    other ->
      assertEq "single usage atom" True (null other)

testOpencodeRipgrepIgnored :: IO ()
testOpencodeRipgrepIgnored = do
  let body =
        T.unlines
          [ "RDEPEND=\"sys-apps/ripgrep\"",
            "BDEPEND=\">=dev-lang/bun-bin-1.3.6\""
          ]
  needs <- needsOf opencodeKey body
  assertTrue "ripgrep not overlay-internal" (usageKey `notElem` needKeys needs)
  assertEq "bun-bin kept" [bunBinKey] (needKeys needs)

testRalphBunBinGe :: IO ()
testRalphBunBinGe = do
  needs <- needsOf ralphKey "BDEPEND=\">=dev-lang/bun-bin-1.3.6\"\n"
  case needs of
    [NeedAtom a] -> do
      assertEq "key" bunBinKey (oaKey a)
      assertEq ">=" OpGe (oaOp a)
      assertEq "pretty" ">=dev-lang/bun-bin-1.3.6" (prettyOverlayAtom a)
      assertTrue
        "1.4.1 matches"
        (atomMatchesPV a (parseEbuildVersion "1.4.1"))
      assertTrue
        "1.3.6 matches"
        (atomMatchesPV a (parseEbuildVersion "1.3.6"))
      assertTrue
        "1.3.5 does not"
        (not (atomMatchesPV a (parseEbuildVersion "1.3.5")))
    other -> assertEq "one >= atom" [] other

testAutolithOrIgnored :: IO ()
testAutolithOrIgnored = do
  needs <-
    needsOf
      autolithKey
      "BDEPEND=\"|| ( dev-lang/rust-bin dev-lang/rust )\"\n"
  assertEq "gentoo or-group ignored" [] needs

testSelfAtomIgnored :: IO ()
testSelfAtomIgnored = do
  needs <-
    needsOf
      hkKey
      "RDEPEND=\"dev-util/hk\n\tdev-util/usage\"\n"
  assertEq "self ignored; usage kept" [usageKey] (needKeys needs)

testRdependExpand :: IO ()
testRdependExpand = do
  let body =
        T.unlines
          [ "RDEPEND=\"dev-util/usage\"",
            "DEPEND=\"${RDEPEND}\""
          ]
  needs <- needsOf hkKey body
  assertEq "expanded usage" [usageKey] (nubOrd (needKeys needs))

testColonEqStrip :: IO ()
testColonEqStrip = do
  needs <- needsOf ralphKey "BDEPEND=\">=dev-lang/bun-bin-1.3.6:=\"\n"
  case needs of
    [NeedAtom a] -> assertEq "still >=" OpGe (oaOp a)
    other -> assertEq "parsed :=" [] other

testPvOperators :: IO ()
testPvOperators = do
  let pv661 = parseEbuildVersion "6.6.1"
      pv680 = parseEbuildVersion "6.8.0"
      unv = OverlayAtom usageKey OpUnversioned Nothing
      ge = OverlayAtom usageKey OpGe (Just pv661)
      le = OverlayAtom usageKey OpLe (Just pv661)
      gt = OverlayAtom usageKey OpGt (Just pv661)
      lt = OverlayAtom usageKey OpLt (Just pv680)
      eq = OverlayAtom usageKey OpEq (Just pv661)
      approx = OverlayAtom usageKey OpApprox (Just pv661)
  assertTrue "unversioned any" (atomMatchesPV unv pv680)
  assertTrue ">=" (atomMatchesPV ge pv680)
  assertTrue "<= eq" (atomMatchesPV le pv661)
  assertTrue "<= not newer" (not (atomMatchesPV le pv680))
  assertTrue ">" (atomMatchesPV gt pv680)
  assertTrue "<" (atomMatchesPV lt pv661)
  assertTrue "=" (atomMatchesPV eq pv661)
  assertTrue "= not other" (not (atomMatchesPV eq pv680))
  assertTrue "~ same pv" (atomMatchesPV approx pv661)
  assertTrue "~ ignores rev" (atomMatchesPV approx (parseEbuildVersion "6.6.1-r1"))

failClosed :: PackageKey -> Text -> IO Text
failClosed consumer body = do
  err <- assertLeft "expected Left" (parseConsumerNeeds overlayKeys consumer body)
  assertTrue "names consumer" (packageKeyText consumer `T.isInfixOf` err)
  assertTrue "not empty-success" (not (T.null err))
  pure err

testUnparseableFailClosed :: IO ()
testUnparseableFailClosed = do
  err <- failClosed hkKey "RDEPEND=\"unterminated\n"
  assertTrue "unparseable reason" ("could not parse" `T.isInfixOf` err)

testBlockerFailClosed :: IO ()
testBlockerFailClosed = do
  err <- failClosed hkKey "RDEPEND=\"!dev-util/usage\"\n"
  assertTrue "blocker" ("blocker" `T.isInfixOf` err)
  assertTrue "names usage" ("dev-util/usage" `T.isInfixOf` err)

testNonZeroSlotFailClosed :: IO ()
testNonZeroSlotFailClosed = do
  err <- failClosed hkKey "RDEPEND=\"dev-util/usage:1\"\n"
  assertTrue "slot" ("slot" `T.isInfixOf` err)

testUnknownOpFailClosed :: IO ()
testUnknownOpFailClosed = do
  err <- failClosed hkKey "RDEPEND=\"*dev-util/usage\"\n"
  assertTrue "unknown operator" ("unknown version operator" `T.isInfixOf` err)

pvsUsage :: [EbuildVersion] -> PackageKey -> [ProviderVer]
pvsUsage usagePvs k
  | k == usageKey = asSlotZero usagePvs
  | otherwise = []

testKeepExactPin :: IO ()
testKeepExactPin = do
  let unique = [parseEbuildVersion "6.8.0"]
      disk = [parseEbuildVersion "6.6.1", parseEbuildVersion "6.8.0"]
      pin =
        NeedAtom
          OverlayAtom
            { oaKey = usageKey,
              oaOp = OpEq,
              oaVersion = Just (parseEbuildVersion "6.6.1")
            }
      keep = keepProviderPVs usageKey unique (asSlotZero disk) (pvsUsage unique) [pin]
      extras = extrasBeyondKeep disk keep
  assertTrue "keeps 6.6.1" (parseEbuildVersion "6.6.1" `elem` keep)
  assertTrue "keeps planned" (parseEbuildVersion "6.8.0" `elem` keep)
  assertEq "no extras to delete" [] extras

testKeepDropsUnversionedExtra :: IO ()
testKeepDropsUnversionedExtra = do
  let unique = [parseEbuildVersion "6.8.0"]
      disk = [parseEbuildVersion "6.6.1", parseEbuildVersion "6.8.0"]
      unv = NeedAtom OverlayAtom {oaKey = usageKey, oaOp = OpUnversioned, oaVersion = Nothing}
      keep = keepProviderPVs usageKey unique (asSlotZero disk) (pvsUsage unique) [unv]
      extras = extrasBeyondKeep disk keep
  assertEq "only planned" unique keep
  assertEq "drop 6.6.1" [parseEbuildVersion "6.6.1"] extras

testKeepDoesNotInvent :: IO ()
testKeepDoesNotInvent = do
  let unique = [parseEbuildVersion "6.8.0"]
      disk = [parseEbuildVersion "6.8.0"]
      pin =
        NeedAtom
          OverlayAtom
            { oaKey = usageKey,
              oaOp = OpEq,
              oaVersion = Just (parseEbuildVersion "6.6.1")
            }
      keep = keepProviderPVs usageKey unique (asSlotZero disk) (pvsUsage unique) [pin]
  assertEq "does not invent 6.6.1" disk keep
  assertTrue "6.6.1 absent" (parseEbuildVersion "6.6.1" `notElem` keep)

testRenameAway :: IO ()
testRenameAway = do
  let bunDisk = [parseEbuildVersion "1.3.14"]
      old = parseEbuildVersion "1.3.14"
      new = parseEbuildVersion "1.4.0"
      ge =
        NeedAtom
          OverlayAtom
            { oaKey = bunBinKey,
              oaOp = OpGe,
              oaVersion = Just (parseEbuildVersion "1.3.6")
            }
      unv = NeedAtom OverlayAtom {oaKey = bunBinKey, oaOp = OpUnversioned, oaVersion = Nothing}
      pin =
        NeedAtom
          OverlayAtom
            { oaKey = usageKey,
              oaOp = OpEq,
              oaVersion = Just (parseEbuildVersion "6.6.1")
            }
      none _ = []
  assertEq
    ">= still satisfied by New"
    Nothing
    (renameAwayUnsatisfied bunBinKey (asSlotZero bunDisk) old new none [ge])
  assertEq
    "unversioned still satisfied by New"
    Nothing
    (renameAwayUnsatisfied bunBinKey (asSlotZero bunDisk) old new none [unv])
  let usageDisk = [parseEbuildVersion "6.6.1"]
      usageNew = parseEbuildVersion "6.8.0"
  case renameAwayUnsatisfied usageKey (asSlotZero usageDisk) (parseEbuildVersion "6.6.1") usageNew none [pin] of
    Just atom -> assertEq "exact pin" OpEq (oaOp atom)
    Nothing -> assertEq "expected pin fail" True False

testBunBinSlotSatisfy :: IO ()
testBunBinSlotSatisfy = do
  let floorAtom =
        OverlayAtom
          { oaKey = bunBinKey,
            oaOp = OpGe,
            oaVersion = Just (parseEbuildVersion "1.3.6")
          }
      pinAtom =
        OverlayAtom
          { oaKey = bunBinKey,
            oaOp = OpEq,
            oaVersion = Just (parseEbuildVersion "1.3.14")
          }
      latest = ProviderVer (parseEbuildVersion "1.4.2") True
      pin = ProviderVer (parseEbuildVersion "1.3.14") False
      pvsBoth k
        | k == bunBinKey = [latest, pin]
        | otherwise = []
      pvsPinOnly k
        | k == bunBinKey = [pin]
        | otherwise = []
  assertTrue
    "latest SLOT=0 satisfies :0 floor"
    (pvsSatisfyNeed pvsBoth (NeedAtom floorAtom))
  assertTrue
    "pin alone does not satisfy :0 floor"
    (not (pvsSatisfyNeed pvsPinOnly (NeedAtom floorAtom)))
  assertTrue
    "exact pin matches pin-slot PV"
    (pvsSatisfyNeed pvsPinOnly (NeedAtom pinAtom))
  err <- failClosed ralphKey "BDEPEND=\">=dev-lang/bun-bin-1.3.6:1.3.14\"\n"
  assertTrue "consumer pin slot hard-fails" ("slot" `T.isInfixOf` err)

testWaitCycle :: IO ()
testWaitCycle = do
  let waiting = Map.singleton hkKey usageKey
  case waitCycleWithEdge waiting usageKey hkKey of
    Just cyc -> do
      assertTrue "names hk" (packageKeyText hkKey `T.isInfixOf` prettyWaitCycle cyc)
      assertTrue "names usage" (packageKeyText usageKey `T.isInfixOf` prettyWaitCycle cyc)
      assertTrue "cycle wording" ("cycle" `T.isInfixOf` prettyWaitCycle cyc)
    Nothing -> assertEq "expected cycle" True False
  assertEq
    "no cycle on first edge"
    Nothing
    (waitCycleWithEdge Map.empty hkKey usageKey)
