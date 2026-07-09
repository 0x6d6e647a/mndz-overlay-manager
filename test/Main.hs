{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Config.Loader (ConfigError (..), loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Monad (unless)
import Data.List (sort)
import Data.Text qualified as T
import Overlay.Discovery
  ( DiscoveryError (..)
  , collectEbuilds
  , parseEbuildFileName
  )
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Validation (validateOverlay)
import System.Directory (makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  putStrLn "Running mndz-overlay-manager tests..."
  testEbuildAtom
  testParseEbuildFileName
  testDiscoveryHappyPath
  testDiscoverySkipsNonCategories
  testDiscoveryBadName
  testDiscoveryPackageMismatch
  testConfigLoadSuccess
  testConfigLoadMissing
  testConfigLoadMissingKey
  testEmptyInventoryIsEmptyList
  testValidatePopulated
  putStrLn "All tests passed."

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
  unless (expected == actual) $ do
    hPutStrLn stderr $ label <> ": expected " <> show expected <> " but got " <> show actual
    exitFailure

assertTrue :: String -> Bool -> IO ()
assertTrue label cond =
  unless cond $ do
    hPutStrLn stderr $ label <> ": expected True"
    exitFailure

assertLeft :: (Show a) => String -> Either e a -> IO e
assertLeft label = \case
  Left e -> pure e
  Right a -> do
    hPutStrLn stderr $ label <> ": expected Left, got Right " <> show a
    exitFailure

assertRight :: (Show e) => String -> Either e a -> IO a
assertRight label = \case
  Right a -> pure a
  Left e -> do
    hPutStrLn stderr $ label <> ": expected Right, got Left " <> show e
    exitFailure

testEbuildAtom :: IO ()
testEbuildAtom = do
  let e = Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim-9.0.1234.ebuild"
  assertEq "ebuildAtom" "app-editors/vim-9.0.1234" (ebuildAtom e)

testParseEbuildFileName :: IO ()
testParseEbuildFileName = do
  assertEq "simple" (Just ("haskell", "9.4.5")) (parseEbuildFileName "haskell-9.4.5.ebuild")
  assertEq "revision" (Just ("vim", "9.0.1234-r1")) (parseEbuildFileName "vim-9.0.1234-r1.ebuild")
  assertEq "missing version" Nothing (parseEbuildFileName "haskell.ebuild")
  assertEq "not ebuild" Nothing (parseEbuildFileName "Manifest")

testDiscoveryHappyPath :: IO ()
testDiscoveryHappyPath = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  ebuilds <- assertRight "happy collect" =<< collectEbuilds root
  let atoms = sort (map (T.unpack . ebuildAtom) ebuilds)
  assertEq "atoms"
    [ "app-editors/vim-9.0.1234"
    , "dev-lang/haskell-9.4.5"
    , "dev-lang/haskell-9.6.1"
    ]
    atoms

testDiscoverySkipsNonCategories :: IO ()
testDiscoverySkipsNonCategories = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  ebuilds <- assertRight "skip non-cat" =<< collectEbuilds root
  let cats = map (T.unpack . ebuildCategory) ebuilds
  assertTrue "no eclass category" (notElem "eclass" cats)
  assertTrue "no licenses category" (notElem "licenses" cats)
  assertTrue "no profiles category" (notElem "profiles" cats)
  assertTrue "no metadata category" (notElem "metadata" cats)

testDiscoveryBadName :: IO ()
testDiscoveryBadName = do
  root <- makeAbsolute "test/fixtures/bad-ebuild-name"
  err <- assertLeft "bad name" =<< collectEbuilds root
  case err of
    MalformedEbuildName path ->
      assertTrue "path mentions haskell.ebuild" ("haskell.ebuild" `elem` splitPath path)
    other -> do
      hPutStrLn stderr $ "expected MalformedEbuildName, got " <> show other
      exitFailure
  where
    splitPath = map T.unpack . T.splitOn "/" . T.pack

testDiscoveryPackageMismatch :: IO ()
testDiscoveryPackageMismatch = do
  root <- makeAbsolute "test/fixtures/package-mismatch"
  err <- assertLeft "mismatch" =<< collectEbuilds root
  case err of
    PackageNameMismatch path expected got -> do
      assertEq "expected package" "haskell" expected
      assertEq "got package" "foo" got
      assertTrue "path has foo-1.0.ebuild" ("foo-1.0.ebuild" `elem` splitPath path)
    other -> do
      hPutStrLn stderr $ "expected PackageNameMismatch, got " <> show other
      exitFailure
  where
    splitPath = map T.unpack . T.splitOn "/" . T.pack

testConfigLoadSuccess :: IO ()
testConfigLoadSuccess = do
  cfg <- assertRight "valid config" =<< loadConfig (Just "test/fixtures/valid-config.toml")
  assertEq "path key" "test/fixtures/populated-overlay" (mndzOverlayPath cfg)

testConfigLoadMissing :: IO ()
testConfigLoadMissing = do
  err <- assertLeft "missing config" =<< loadConfig (Just "test/fixtures/does-not-exist.toml")
  case err of
    ConfigNotFound path ->
      assertEq "missing path" "test/fixtures/does-not-exist.toml" path
    other -> do
      hPutStrLn stderr $ "expected ConfigNotFound, got " <> show other
      exitFailure

testConfigLoadMissingKey :: IO ()
testConfigLoadMissingKey = do
  err <- assertLeft "missing key" =<< loadConfig (Just "test/fixtures/missing-key-config.toml")
  case err of
    DecodeError msg ->
      assertTrue "mentions mndz-overlay-path" ("mndz-overlay-path" `elem` words msg || "mndz-overlay-path" `T.isInfixOf` T.pack msg)
    other -> do
      hPutStrLn stderr $ "expected DecodeError, got " <> show other
      exitFailure

testEmptyInventoryIsEmptyList :: IO ()
testEmptyInventoryIsEmptyList = do
  root <- makeAbsolute "test/fixtures/empty-valid-overlay"
  ebuilds <- assertRight "empty collect" =<< collectEbuilds root
  assertEq "empty list" [] ebuilds

testValidatePopulated :: IO ()
testValidatePopulated = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  _ <- assertRight "validate populated" =<< validateOverlay root
  pure ()
