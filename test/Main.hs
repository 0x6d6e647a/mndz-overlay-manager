{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Config.Loader (ConfigError (..), loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Monad (unless)
import Data.List (sort)
import Data.Text qualified as T
import Overlay.Discovery
  ( DiscoveryError (..),
    collectEbuilds,
    parseEbuildFileName,
  )
import Overlay.Types (Ebuild (..), ebuildAtom)
import Overlay.Validation (validateOverlay)
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    prettyVersion,
  )
import System.Directory (makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Update.Apply
  ( foldExitHardFail,
    newEbuildFileName,
    renderPVNoRev,
  )
import Update.Check (PackageEntry (..), groupNewest)
import Update.Hardcoded (lookupHardcoded, lookupPolicy)
import Update.Preflight (checkToolsOnPath, updateRequiredTools)
import Update.Resolve (resolveSource)
import Update.Targets (TargetError (..), resolveTargetToken, resolveTargets)
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    PackagePolicy (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    UpdateTechnique (..),
    mkPackageKey,
    packageKeyText,
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
  testPolicyClassification
  testResolveMapOnly
  testGroupNewest
  testCheckOverlayStatuses
  testTargetResolution
  testPreflightMissingTools
  testNewEbuildFileName
  testFoldExitHardFail
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
  assertEq
    "atoms"
    [ "app-editors/vim-9.0.1234",
      "dev-lang/haskell-9.4.5",
      "dev-lang/haskell-9.6.1"
    ]
    atoms

testDiscoverySkipsNonCategories :: IO ()
testDiscoverySkipsNonCategories = do
  root <- makeAbsolute "test/fixtures/populated-overlay"
  ebuilds <- assertRight "skip non-cat" =<< collectEbuilds root
  let cats = map (T.unpack . ebuildCategory) ebuilds
  assertTrue "no eclass category" ("eclass" `notElem` cats)
  assertTrue "no licenses category" ("licenses" `notElem` cats)
  assertTrue "no profiles category" ("profiles" `notElem` cats)
  assertTrue "no metadata category" ("metadata" `notElem` cats)

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
  assertEq
    "numeric with rev"
    (Numeric [1, 5, 3] (Just 2))
    (parseEbuildVersion "1.5.3-r2")
  assertEq
    "numeric no rev"
    (Numeric [0, 2, 93] Nothing)
    (parseEbuildVersion "0.2.93")
  assertEq
    "raw fallback"
    (Raw "1.0_alpha")
    (parseEbuildVersion "1.0_alpha")

testVersionRender :: IO ()
testVersionRender = do
  assertEq
    "pretty with rev"
    "v1.5.3-r2"
    (prettyVersion (Numeric [1, 5, 3] (Just 2)))
  assertEq
    "pretty no rev"
    "v2.1.10"
    (prettyVersion (Numeric [2, 1, 10] Nothing))

testVersionCompare :: IO ()
testVersionCompare = do
  assertEq
    "outdated"
    (Just LT)
    (comparePV (parseEbuildVersion "1.17.16") (parseEbuildVersion "1.17.18"))
  assertEq
    "rev ignored"
    (Just EQ)
    (comparePV (parseEbuildVersion "1.2.3-r5") (parseEbuildVersion "1.2.3"))
  assertEq
    "numeric order"
    (Just GT)
    (comparePV (parseEbuildVersion "1.10.0") (parseEbuildVersion "1.9.0"))
  assertEq
    "incomparable raw"
    Nothing
    (comparePV (Raw "foo") (parseEbuildVersion "1.0"))

------------------------------------------------------------------------
-- Hardcoded policy
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
  assertEq "resolve map only" (lookupHardcoded key) (resolveSource key)

testPolicyClassification :: IO ()
testPolicyClassification = do
  case lookupPolicy (PackageKey "dev-util/opencode-bin") of
    Just (PackagePolicy _ GitMvAndManifest) -> pure ()
    other -> do
      hPutStrLn stderr $ "opencode technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/mise") of
    Just (PackagePolicy _ (Unsupported _)) -> pure ()
    other -> do
      hPutStrLn stderr $ "mise technique: " <> show other
      exitFailure
  assertEq "unmapped" Nothing (lookupPolicy (PackageKey "dev-lang/haskell"))
  case lookupPolicy (PackageKey "dev-lang/bun-bin") of
    Just (PackagePolicy (GitHub "oven-sh" "bun" "bun-v") GitMvAndManifest) -> pure ()
    other -> do
      hPutStrLn stderr $ "bun policy: " <> show other
      exitFailure

testResolveMapOnly :: IO ()
testResolveMapOnly = do
  assertEq
    "dolt source"
    (Just (GitHub "dolthub" "dolt" "v"))
    (resolveSource (PackageKey "dev-db/dolt"))
  assertEq
    "unknown"
    Nothing
    (resolveSource (PackageKey "no/such"))

------------------------------------------------------------------------
-- Check pipeline
------------------------------------------------------------------------

testGroupNewest :: IO ()
testGroupNewest = do
  let ebuilds =
        [ Ebuild "dev-lang" "haskell" "9.4.5" "/tmp/haskell-9.4.5.ebuild",
          Ebuild "dev-lang" "haskell" "9.6.1" "/tmp/haskell-9.6.1.ebuild",
          Ebuild "app-editors" "vim" "9.0.1234" "/tmp/vim.ebuild"
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
  reports <-
    checkWithFakeResolve
      fetch
      [ (mkPackageKey "dev-db" "dolt", "dolt", "2.1.6", Just (GitHub "dolthub" "dolt" "v")),
        (mkPackageKey "dev-util" "okpkg", "okpkg", "1.0.0", Just (GitHub "ok" "ok" "v")),
        (mkPackageKey "dev-util" "ahead", "ahead", "2.0.0", Just (GitHub "ahead" "ahead" "v")),
        (mkPackageKey "dev-util" "none", "none", "1.0", Nothing),
        (mkPackageKey "dev-util" "fail", "fail", "1.0", Just (GitHub "fail" "fail" "v"))
      ]
  let statuses = map reportStatus reports
  assertTrue "has outdated" (any isOutdated statuses)
  assertTrue "has ok" (any isOk statuses)
  assertTrue "has ahead" (any isAhead statuses)
  assertTrue "has unconfigured" (Unconfigured `elem` statuses)
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
checkWithFakeResolve ::
  (UpdateSource -> IO (Either T.Text EbuildVersion)) ->
  [(PackageKey, T.Text, T.Text, Maybe UpdateSource)] ->
  IO [UpdateReport]
checkWithFakeResolve fetch = mapM go
  where
    go (key, _pn, pv, mSrc) = do
      let local = parseEbuildVersion pv
      case mSrc of
        Nothing ->
          pure UpdateReport {reportKey = key, reportStatus = Unconfigured}
        Just src -> do
          result <- fetch src
          pure $ case result of
            Left err ->
              UpdateReport {reportKey = key, reportStatus = FetchError err}
            Right remote ->
              UpdateReport
                { reportKey = key,
                  reportStatus = case comparePV local remote of
                    Just LT -> Outdated local remote
                    Just EQ -> Ok local
                    Just GT -> Ahead local remote
                    Nothing -> FetchError "incomparable"
                }

------------------------------------------------------------------------
-- Targets / preflight / apply helpers
------------------------------------------------------------------------

sampleEntries :: [PackageEntry]
sampleEntries =
  [ PackageEntry
      { peKey = PackageKey "dev-lang/deno-bin",
        pePN = "deno-bin",
        peLocal = parseEbuildVersion "2.9.2",
        pePath = "/overlay/dev-lang/deno-bin/deno-bin-2.9.2.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "dev-util/opencode-bin",
        pePN = "opencode-bin",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/dev-util/opencode-bin/opencode-bin-1.0.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "bar/foo",
        pePN = "foo",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/bar/foo/foo-1.0.ebuild"
      },
    PackageEntry
      { peKey = PackageKey "baz/foo",
        pePN = "foo",
        peLocal = parseEbuildVersion "1.0",
        pePath = "/overlay/baz/foo/foo-1.0.ebuild"
      }
  ]

testTargetResolution :: IO ()
testTargetResolution = do
  assertEq
    "full key"
    (Right (PackageKey "dev-lang/deno-bin"))
    (resolveTargetToken sampleEntries "dev-lang/deno-bin")
  assertEq
    "bare unique"
    (Right (PackageKey "dev-util/opencode-bin"))
    (resolveTargetToken sampleEntries "opencode-bin")
  case resolveTargetToken sampleEntries "foo" of
    Left (AmbiguousPackage "foo" keys) ->
      assertEq
        "ambiguous keys"
        (sort (map packageKeyText keys))
        ["bar/foo", "baz/foo"]
    other -> do
      hPutStrLn stderr $ "expected ambiguous foo, got " <> show other
      exitFailure
  case resolveTargets sampleEntries [] of
    Right keys ->
      assertEq "all keys count" 4 (length keys)
    Left e -> do
      hPutStrLn stderr $ "all targets: " <> show e
      exitFailure
  case resolveTargets sampleEntries ["deno-bin", "nope"] of
    Left errs ->
      assertTrue "has unknown" (any isUnknown errs)
    Right _ -> do
      hPutStrLn stderr "expected unknown error"
      exitFailure
  where
    isUnknown (UnknownPackage _) = True
    isUnknown _ = False

testPreflightMissingTools :: IO ()
testPreflightMissingTools = do
  missing <-
    checkToolsOnPath
      ( \name ->
          pure $
            if name == "ebuild"
              then Nothing
              else Just ("/usr/bin/" <> name)
      )
      updateRequiredTools
  assertEq "missing ebuild only" ["ebuild"] missing
  none <-
    checkToolsOnPath
      (\name -> pure (Just ("/bin/" <> name)))
      updateRequiredTools
  assertEq "none missing" [] none

testNewEbuildFileName :: IO ()
testNewEbuildFileName = do
  assertEq
    "filename"
    "opencode-bin-1.17.20.ebuild"
    (newEbuildFileName "opencode-bin" (parseEbuildVersion "1.17.20"))
  assertEq
    "render strips rev for filename base"
    "0.2.99"
    (renderPVNoRev (parseEbuildVersion "0.2.99-r1"))
  assertEq
    "render remote"
    "0.2.101"
    (renderPVNoRev (parseEbuildVersion "0.2.101"))

testFoldExitHardFail :: IO ()
testFoldExitHardFail = do
  let soft =
        [ ApplySoftSkip (PackageKey "a/b") "unsupported",
          ApplySoftSkip (PackageKey "c/d") "not outdated"
        ]
      mixed =
        soft
          <> [ ApplyHardFail (PackageKey "e/f") "dirty" False,
               ApplySuccess
                 (PackageKey "g/h")
                 (parseEbuildVersion "1.0")
                 (parseEbuildVersion "1.1")
                 ["g/h/g-h-1.1.ebuild"]
             ]
  assertEq "soft only" False (foldExitHardFail soft)
  assertEq "mixed" True (foldExitHardFail mixed)
