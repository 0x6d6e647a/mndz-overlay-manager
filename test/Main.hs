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
import Overlay.Version
  ( EbuildVersion (..)
  , comparePV
  , parseEbuildVersion
  , prettyVersion
  )
import System.Directory (makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Update.Check (PackageEntry (..), groupNewest)
import Update.Hardcoded (lookupHardcoded)
import Update.Infer (PackageContext (..), expandEbuild, inferSource)
import Update.Resolve (resolveFromText)
import Update.Types
  ( PackageKey (..)
  , UpdateReport (..)
  , UpdateSource (..)
  , UpdateStatus (..)
  , mkPackageKey
  , packageKeyText
  )

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
  testVersionParse
  testVersionRender
  testVersionCompare
  testHardcodedGrok
  testInferDolt
  testInferBun
  testInferOpenspecNpm
  testInferAssetsOnly
  testGroupNewest
  testCheckOverlayStatuses
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

------------------------------------------------------------------------
-- Ebuild version
------------------------------------------------------------------------

testVersionParse :: IO ()
testVersionParse = do
  assertEq "numeric with rev"
    (Numeric [1, 5, 3] (Just 2))
    (parseEbuildVersion "1.5.3-r2")
  assertEq "numeric no rev"
    (Numeric [0, 2, 93] Nothing)
    (parseEbuildVersion "0.2.93")
  assertEq "raw fallback"
    (Raw "1.0_alpha")
    (parseEbuildVersion "1.0_alpha")

testVersionRender :: IO ()
testVersionRender = do
  assertEq "pretty with rev"
    "v1.5.3-r2"
    (prettyVersion (Numeric [1, 5, 3] (Just 2)))
  assertEq "pretty no rev"
    "v2.1.10"
    (prettyVersion (Numeric [2, 1, 10] Nothing))

testVersionCompare :: IO ()
testVersionCompare = do
  assertEq "outdated"
    (Just LT)
    (comparePV (parseEbuildVersion "1.17.16") (parseEbuildVersion "1.17.18"))
  assertEq "rev ignored"
    (Just EQ)
    (comparePV (parseEbuildVersion "1.2.3-r5") (parseEbuildVersion "1.2.3"))
  assertEq "numeric order"
    (Just GT)
    (comparePV (parseEbuildVersion "1.10.0") (parseEbuildVersion "1.9.0"))
  assertEq "incomparable raw"
    Nothing
    (comparePV (Raw "foo") (parseEbuildVersion "1.0"))

------------------------------------------------------------------------
-- Inference / hardcoded
------------------------------------------------------------------------

testHardcodedGrok :: IO ()
testHardcodedGrok = do
  let key = PackageKey "dev-util/grok-build-bin"
  case lookupHardcoded key of
    Just (Http primary (Just fb)) -> do
      assertEq "primary" "https://x.ai/cli/stable" primary
      assertTrue "fallback mentions gcs" ("storage.googleapis.com" `T.isInfixOf` fb)
    other -> do
      hPutStrLn stderr $ "expected hardcoded Http, got " <> show other
      exitFailure
  let resolved =
        resolveFromText key "grok-build-bin" "0.2.93" "SRC_URI=https://example.com"
  case resolved of
    Just (Http {}) -> pure ()
    other -> do
      hPutStrLn stderr $ "resolve should prefer hardcoded: " <> show other
      exitFailure

doltSnippet :: T.Text
doltSnippet =
  T.unlines
    [ "HOMEPAGE=\"https://github.com/dolthub/dolt\""
    , "SRC_URI=\"https://github.com/dolthub/dolt/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz\""
    , "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-2.1.6/dolt-2.1.6-vendor.tar.xz\""
    ]

bunSnippet :: T.Text
bunSnippet =
  T.unlines
    [ "BUN_PN=\"${PN//-bin/}\""
    , "BASE_URI=\"https://github.com/oven-sh/${BUN_PN}/releases/download/${BUN_PN}-v${PV}\""
    , "SRC_URI=\"${BASE_URI}/bun-linux-x64.zip\""
    ]

openspecSnippet :: T.Text
openspecSnippet =
  T.unlines
    [ "HOMEPAGE=\"https://github.com/Fission-AI/OpenSpec\""
    , "SRC_URI=\""
    , "\thttps://registry.npmjs.org/@fission-ai/openspec/-/openspec-${PV}.tgz"
    , "\t\t-> ${P}.tgz"
    , "\thttps://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/openspec-${PV}/openspec-${PV}-deps.tar.xz"
    , "\""
    ]

assetsOnlySnippet :: T.Text
assetsOnlySnippet =
  "SRC_URI=\"https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/foo-1.0/foo.tar.xz\""

testInferDolt :: IO ()
testInferDolt = do
  let ctx = PackageContext "dolt" "2.1.6"
  case inferSource ctx doltSnippet of
    Just (GitHub owner repo prefix) -> do
      assertEq "owner" "dolthub" owner
      assertEq "repo" "dolt" repo
      assertEq "prefix" "v" prefix
    other -> do
      hPutStrLn stderr $ "dolt infer: " <> show other
      exitFailure

testInferBun :: IO ()
testInferBun = do
  let ctx = PackageContext "bun-bin" "1.3.14"
  case inferSource ctx bunSnippet of
    Just (GitHub owner repo prefix) -> do
      assertEq "owner" "oven-sh" owner
      assertEq "repo" "bun" repo
      assertEq "prefix" "bun-v" prefix
    other -> do
      hPutStrLn stderr $
        "bun infer: "
          <> show other
          <> " expanded="
          <> T.unpack (expandEbuild ctx bunSnippet)
      exitFailure

testInferOpenspecNpm :: IO ()
testInferOpenspecNpm = do
  let ctx = PackageContext "openspec" "1.4.1"
  case inferSource ctx openspecSnippet of
    Just (Npm pkg) ->
      assertEq "npm pkg" "@fission-ai/openspec" pkg
    other -> do
      hPutStrLn stderr $ "openspec infer: " <> show other
      exitFailure

testInferAssetsOnly :: IO ()
testInferAssetsOnly = do
  let ctx = PackageContext "foo" "1.0"
  assertEq "assets only" Nothing (inferSource ctx assetsOnlySnippet)

------------------------------------------------------------------------
-- Check pipeline
------------------------------------------------------------------------

testGroupNewest :: IO ()
testGroupNewest = do
  let ebuilds =
        [ Ebuild "dev-lang" "haskell" "9.4.5" "/tmp/haskell-9.4.5.ebuild"
        , Ebuild "dev-lang" "haskell" "9.6.1" "/tmp/haskell-9.6.1.ebuild"
        , Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim.ebuild"
        ]
      grouped = groupNewest ebuilds
      keys = sort (map (T.unpack . packageKeyText . peKey) grouped)
  assertEq "keys" ["app-editors/vim", "dev-lang/haskell"] keys
  case [e | e <- grouped, peKey e == PackageKey "dev-lang/haskell"] of
    (haskell : _) -> do
      assertEq "newest haskell" (Numeric [9, 6, 1] Nothing) (peLocal haskell)
      assertEq "path" "/tmp/haskell-9.6.1.ebuild" (pePath haskell)
    [] -> do
      hPutStrLn stderr "missing haskell group"
      exitFailure

testCheckOverlayStatuses :: IO ()
testCheckOverlayStatuses = do
  let fetch src = pure $ case src of
        GitHub "dolthub" "dolt" _ -> Right (parseEbuildVersion "2.1.10")
        GitHub "ok" "ok" _ -> Right (parseEbuildVersion "1.0.0")
        GitHub "ahead" "ahead" _ -> Right (parseEbuildVersion "1.5.0")
        GitHub "fail" "fail" _ -> Left "network down"
        _ -> Left "unexpected source"
  reports <- checkWithFakeResolve fetch
    [ (mkPackageKey "dev-db" "dolt", "dolt", "2.1.6", Just (GitHub "dolthub" "dolt" "v"))
    , (mkPackageKey "dev-util" "okpkg", "okpkg", "1.0.0", Just (GitHub "ok" "ok" "v"))
    , (mkPackageKey "dev-util" "ahead", "ahead", "2.0.0", Just (GitHub "ahead" "ahead" "v"))
    , (mkPackageKey "dev-util" "none", "none", "1.0", Nothing)
    , (mkPackageKey "dev-util" "fail", "fail", "1.0", Just (GitHub "fail" "fail" "v"))
    ]
  let statuses = map reportStatus reports
  assertTrue "has outdated" (any isOutdated statuses)
  assertTrue "has ok" (any isOk statuses)
  assertTrue "has ahead" (any isAhead statuses)
  assertTrue "has unconfigured" (any (== Unconfigured) statuses)
  assertTrue "has error" (any isErr statuses)
  where
    isOutdated (Outdated _ _) = True
    isOutdated _ = False
    isOk (Ok _) = True
    isOk _ = False
    isAhead (Ahead _ _) = True
    isAhead _ = False
    isErr (FetchError _) = True
    isErr _ = False

-- | Check packages with pre-resolved sources (avoids filesystem for unit tests).
checkWithFakeResolve
  :: (UpdateSource -> IO (Either T.Text EbuildVersion))
  -> [(PackageKey, T.Text, T.Text, Maybe UpdateSource)]
  -> IO [UpdateReport]
checkWithFakeResolve fetch pkgs =
  mapM go pkgs
  where
    go (key, _pn, pv, mSrc) = do
      let local = parseEbuildVersion pv
      case mSrc of
        Nothing ->
          pure UpdateReport { reportKey = key, reportStatus = Unconfigured }
        Just src -> do
          result <- fetch src
          pure $ case result of
            Left err ->
              UpdateReport { reportKey = key, reportStatus = FetchError err }
            Right remote ->
              UpdateReport
                { reportKey = key
                , reportStatus = case comparePV local remote of
                    Just LT -> Outdated local remote
                    Just EQ -> Ok local
                    Just GT -> Ahead local remote
                    Nothing -> FetchError "incomparable"
                }
