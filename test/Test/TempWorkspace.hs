{-# LANGUAGE OverloadedStrings #-}

module Test.TempWorkspace (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Process (getProcessID)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.TempWorkspace
  ( RunRoot (..),
    UnitDirs (..),
    UnitKind (..),
    cleanupRunSuccess,
    deleteUnit,
    ensureUnit,
    openRunRootAt,
    retainUnitError,
    runRootPath,
    unitDirPath,
    unitKindSuffix,
  )

tests :: TestTree
tests =
  testGroup
    "TempWorkspace"
    [ testCase "unit kind suffixes" testUnitKindSuffix,
      testCase "path construction full and reuse" testPathConstruction,
      testCase "run id has pid and random hex" testRunIdFormat,
      testCase "openRunRootAt creates brand path" testOpenRunRoot,
      testCase "ensureUnit creates out and work" testEnsureUnit,
      testCase "deleteUnit prunes empty package/category" testDeleteUnitPrune,
      testCase "cleanupRunSuccess upward-prunes brand dirs" testCleanupRunSuccess,
      testCase "retainUnitError includes absolute unit path" testRetainUnitError,
      testCase "multi-unit: success cleans, fail retains sibling" testMultiUnitLifecycle
    ]

testUnitKindSuffix :: IO ()
testUnitKindSuffix = do
  assertEq "full" "full" (unitKindSuffix UnitFull)
  assertEq "reuse" "reuse" (unitKindSuffix UnitReuse)

testPathConstruction :: IO ()
testPathConstruction = do
  let run = runRootPath "/tmp" "2026-08-10T15:42:07-07:00-4242.a8f3"
  assertEq
    "run root"
    "/tmp/mndz/overlay-manager/2026-08-10T15:42:07-07:00-4242.a8f3"
    run
  assertEq
    "full unit"
    ( run
        </> "dev-util"
        </> "crush"
        </> "0.77.0-full"
    )
    (unitDirPath run "dev-util" "crush" "0.77.0" UnitFull)
  assertEq
    "reuse unit"
    ( run
        </> "dev-util"
        </> "crush"
        </> "0.77.0-reuse"
    )
    (unitDirPath run "dev-util" "crush" "0.77.0" UnitReuse)

testRunIdFormat :: IO ()
testRunIdFormat =
  withSystemTempDirectory "mndz-tw-id-" $ \tmp -> do
    run <- openRunRootAt tmp
    pid <- getProcessID
    let rid = rrRunId run
    assertTrue "contains pid" (show pid `isInfixOf` rid)
    assertTrue "has T timestamp" ('T' `elem` rid)
    -- random segment after last '.'
    let rand = reverse (takeWhile (/= '.') (reverse rid))
    assertEq "random length 4" 4 (length rand)
    assertTrue "random hex" (all (`elem` ("0123456789abcdef" :: String)) rand)
    assertTrue "pid.random suffix" ((show pid <> "." <> rand) `isInfixOf` rid)

testOpenRunRoot :: IO ()
testOpenRunRoot =
  withSystemTempDirectory "mndz-tw-open-" $ \tmp -> do
    run <- openRunRootAt tmp
    assertEq "temp root" tmp (rrTempRoot run)
    assertTrue "run path exists" =<< doesDirectoryExist (rrPath run)
    assertEq
      "path under brand"
      (tmp </> "mndz" </> "overlay-manager" </> rrRunId run)
      (rrPath run)

testEnsureUnit :: IO ()
testEnsureUnit =
  withSystemTempDirectory "mndz-tw-unit-" $ \tmp -> do
    run <- openRunRootAt tmp
    unit <- ensureUnit run "dev-util" "crush" "0.77.0" UnitFull
    assertTrue "unit dir" =<< doesDirectoryExist (udPath unit)
    assertTrue "out" =<< doesDirectoryExist (udOut unit)
    assertTrue "work" =<< doesDirectoryExist (udWork unit)
    assertEq
      "unit path shape"
      (rrPath run </> "dev-util" </> "crush" </> "0.77.0-full")
      (udPath unit)

testDeleteUnitPrune :: IO ()
testDeleteUnitPrune =
  withSystemTempDirectory "mndz-tw-del-" $ \tmp -> do
    run <- openRunRootAt tmp
    unit <- ensureUnit run "dev-util" "crush" "0.77.0" UnitFull
    writeFile (udWork unit </> "marker") "x"
    deleteUnit unit
    assertTrue "unit gone" . not =<< doesDirectoryExist (udPath unit)
    assertTrue "package pruned" . not
      =<< doesDirectoryExist (rrPath run </> "dev-util" </> "crush")
    assertTrue "category pruned" . not
      =<< doesDirectoryExist (rrPath run </> "dev-util")
    assertTrue "run root remains" =<< doesDirectoryExist (rrPath run)

testCleanupRunSuccess :: IO ()
testCleanupRunSuccess =
  withSystemTempDirectory "mndz-tw-clean-" $ \tmp -> do
    run <- openRunRootAt tmp
    unit <- ensureUnit run "dev-util" "crush" "0.1.0" UnitReuse
    writeFile (udOut unit </> "a") "1"
    cleanupRunSuccess run
    assertTrue "run gone" . not =<< doesDirectoryExist (rrPath run)
    assertTrue "overlay-manager pruned" . not
      =<< doesDirectoryExist (tmp </> "mndz" </> "overlay-manager")
    assertTrue "mndz pruned" . not
      =<< doesDirectoryExist (tmp </> "mndz")

testRetainUnitError :: IO ()
testRetainUnitError =
  withSystemTempDirectory "mndz-tw-err-" $ \tmp -> do
    run <- openRunRootAt tmp
    unit <- ensureUnit run "dev-util" "crush" "0.78.0" UnitFull
    let msg = retainUnitError unit "clone failed"
    assertTrue "original text" ("clone failed" `T.isInfixOf` msg)
    assertTrue "unit path" (T.pack (udPath unit) `T.isInfixOf` msg)

testMultiUnitLifecycle :: IO ()
testMultiUnitLifecycle =
  withSystemTempDirectory "mndz-tw-multi-" $ \tmp -> do
    run <- openRunRootAt tmp
    okUnit <- ensureUnit run "dev-util" "crush" "0.77.0" UnitFull
    writeFile (udWork okUnit </> "ok") "1"
    failUnit <- ensureUnit run "dev-util" "crush" "0.78.0" UnitFull
    writeFile (udWork failUnit </> "fail") "1"
    -- success cleans immediately
    deleteUnit okUnit
    assertTrue "ok unit gone" . not =<< doesDirectoryExist (udPath okUnit)
    assertTrue "fail unit kept" =<< doesDirectoryExist (udPath failUnit)
    assertTrue "marker kept" =<< doesFileExist (udWork failUnit </> "fail")
    -- package dir still exists because fail unit remains
    assertTrue "package dir" =<< doesDirectoryExist (rrPath run </> "dev-util" </> "crush")
