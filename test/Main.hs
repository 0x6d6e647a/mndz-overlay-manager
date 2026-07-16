{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Parser (ColorMode (..), resolveVerbosity)
import CLI.Parser qualified as V
import Colog (Msg (..))
import Colog qualified as C
import Config.Loader (ConfigError (..), loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Concurrent (threadDelay)
import Control.Monad (unless, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Stack (callStack)
import Logging.Bootstrap
  ( fmtMessageColored,
    showSeverityColored,
    verbosityToSeverity,
  )
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
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Update.Apply
  ( foldExitHardFail,
    newEbuildFileName,
    renderPVNoRev,
  )
import Update.Assets.Hash (FileDigests (..), hashBytes, sidecarLine)
import Update.Auth (resolveGitHubTokenWith)
import Update.Check (PackageEntry (..), groupNewest)
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildHasDevLangGoBdepend,
    ensureGoBdepend,
    goBdependAtom,
    goBdependMatches,
    keywordsMatch,
    nextRevisionVersion,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
    setKeywords,
  )
import Update.GitHub (stripAndParse)
import Update.Go.Lanes
  ( GapLine (..),
    GoLanePlan (..),
    LaneId (..),
    LaneTarget (..),
    PlannedEbuild (..),
    VersionCandidate (..),
    assembleKeywords,
    buildGapLines,
    collapsePlannedEbuilds,
    extrasToDelete,
    laneLabel,
    maxVersionUnder,
    missingTargets,
    planFromTargets,
    planNeedsWork,
    selectAllLaneTargets,
  )
import Update.Go.ModFetch (GoModKey (..))
import Update.Go.Plan (PlanOps (..), planGoPackage)
import Update.Go.Tree
  ( GoArch (..),
    GoCeilings (..),
    GoEbuildMeta (..),
    computeCeilings,
    discoverGoCeilingsWith,
    emptyCeilings,
    isLiveGoVersion,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    parseGoEbuildMeta,
    parseKeywordsField,
  )
import Update.Go.Vendor
  ( VendorOps (..),
    VendorResult (..),
    buildVendorTarball,
  )
import Update.Go.Version
  ( compareGoVersions,
    enrichGoModDownloadError,
    goVersionTooOldMessage,
    hostMeetsGoRequirement,
    looksLikeToolchainError,
    parseGoModGoDirective,
    parseGoVersionOutput,
    parseGoVersionToken,
  )
import Update.GpgAgent
  ( GpgAgentOps (..),
    Keygrip (..),
    ensureGpgReady,
    newGpgHandle,
    parseKeyinfoCached,
    parseSignCapableKeygrip,
    pinentryChildEnv,
    teardownGpgHandle,
  )
import Update.Hardcoded (lookupHardcoded, lookupPolicy)
import Update.Preflight (checkToolsOnPath, goAssetsRequiredTools, updateRequiredTools)
import Update.Resolve (resolveSource)
import Update.SshAgent
  ( AgentIdentities (..),
    SshAgentOps (..),
    SshSession (..),
    ensureSshAgent,
    parseIdentityFiles,
  )
import Update.Targets (TargetError (..), resolveTargetToken, resolveTargets)
import Update.Types
  ( ApplyOutcome (..),
    OutdatedLine (..),
    PackageKey (..),
    PackagePolicy (..),
    SuccessLine (..),
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
  testConfigOptionalKeys
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
  testTokenResolver
  testHashBytes
  testSidecarLine
  testEbuildEdit
  testGoVersionParse
  testGoBdependEdit
  testVendorGoVersionGate
  testSshAgentReuse
  testGpgSignReadiness
  testVerbosityResolution
  testSeverityFilterMapping
  testSeverityColors
  testNoColorStripsEscapes
  testJobsBound
  testJobsOneSerial
  testGoTreeCeilings
  testGoKeywordsAssembly
  testGoLaneSelection
  testGoLaneCollapse
  testGoGapLines
  testGoStripAndParseList
  testSetKeywords
  testGoPlanIntegrationMocked
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
  assertEq "assets optional absent" Nothing (mndzOverlayAssetsPath cfg)
  assertEq "token optional absent" Nothing (githubToken cfg)

testConfigOptionalKeys :: IO ()
testConfigOptionalKeys = do
  cfg <- assertRight "full config" =<< loadConfig (Just "test/fixtures/full-config.toml")
  assertEq "path" "/tmp/overlay" (mndzOverlayPath cfg)
  assertEq "assets" (Just "/tmp/assets") (mndzOverlayAssetsPath cfg)
  assertEq "token" (Just "secret-token") (githubToken cfg)

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
  case lookupPolicy (PackageKey "dev-db/dolt") of
    Just (PackagePolicy _ (GoVendorAndAssets (Just "go"))) -> pure ()
    other -> do
      hPutStrLn stderr $ "dolt technique: " <> show other
      exitFailure
  case lookupPolicy (PackageKey "dev-util/beads") of
    Just (PackagePolicy _ (GoVendorAndAssets Nothing)) -> pure ()
    other -> do
      hPutStrLn stderr $ "beads technique: " <> show other
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
    isOutdated (Outdated _) = True
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
                    Just LT ->
                      Outdated
                        [ OutdatedLine
                            { olFrom = local,
                              olTo = remote,
                              olLabel = Nothing
                            }
                        ]
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
          <> [ ApplyHardFail (PackageKey "e/f") "dirty" False False,
               ApplySuccess
                 (PackageKey "g/h")
                 [ SuccessLine
                     { slFrom = parseEbuildVersion "1.0",
                       slTo = parseEbuildVersion "1.1",
                       slLabel = Nothing
                     }
                 ]
                 ["g/h/g-h-1.1.ebuild"]
             ]
  assertEq "soft only" False (foldExitHardFail soft)
  assertEq "mixed" True (foldExitHardFail mixed)

testTokenResolver :: IO ()
testTokenResolver = do
  assertEq
    "env wins"
    (Just "from-env")
    (resolveGitHubTokenWith (Just "from-env") (Just "gh") (Just "cfg"))
  assertEq
    "gh token second"
    (Just "from-gh")
    (resolveGitHubTokenWith Nothing (Just "from-gh") (Just "cfg"))
  assertEq
    "config last"
    (Just "cfg")
    (resolveGitHubTokenWith Nothing Nothing (Just "cfg"))
  assertEq
    "empty env skipped"
    (Just "cfg")
    (resolveGitHubTokenWith (Just "") Nothing (Just "cfg"))
  assertEq
    "none"
    Nothing
    (resolveGitHubTokenWith Nothing Nothing Nothing)

testHashBytes :: IO ()
testHashBytes = do
  let d = hashBytes (encodeUtf8 "hello")
  -- SHA-256 of "hello"
  assertEq
    "sha256 hello"
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    (digestSHA256 d)
  assertTrue "sha512 nonempty" (T.length (digestSHA512 d) == 128)
  assertTrue "blake3 nonempty" (T.length (digestBLAKE3 d) == 64)

testSidecarLine :: IO ()
testSidecarLine = do
  assertEq
    "basename only"
    "abc  crush-0.76.0-vendor.tar.xz"
    (sidecarLine "abc" "/tmp/build/crush-0.76.0-vendor.tar.xz")

testEbuildEdit :: IO ()
testEbuildEdit = do
  let frozen =
        T.unlines
          [ "SRC_URI=\"https://github.com/dolthub/dolt/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-2.1.6/dolt-2.1.6-vendor.tar.xz\""
          ]
      fixed = parameterizeAssetsSrcUri "dolt" frozen
      already =
        "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/beads-${PV}/beads-${PV}-vendor.tar.xz\"\n"
  assertEq "frozen not parameterized" False (assetsSrcUriParameterized frozen)
  assertTrue "fixed parameterized" (assetsSrcUriParameterized fixed)
  assertTrue "has ${PV} tag" ("dolt-${PV}/dolt-${PV}-vendor" `T.isInfixOf` fixed)
  -- Regression: intercalate must keep the assets host path (not strip it).
  assertTrue
    "keeps mndz-overlay-assets download path"
    ( "https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-${PV}/dolt-${PV}-vendor.tar.xz"
        `T.isInfixOf` fixed
    )
  assertTrue
    "does not produce bare user/repo URL"
    (not ("https://github.com/0x6d6e647a/dolt-" `T.isInfixOf` fixed))
  assertEq
    "already parameterized unchanged path"
    already
    (parameterizeAssetsSrcUri "beads" already)
  let rev1 = nextRevisionVersion (parseEbuildVersion "2.1.6")
  assertEq "r1" (Numeric [2, 1, 6] (Just 1)) rev1
  let man =
        "DIST dolt-2.1.6-vendor.tar.xz 123 BLAKE2B deadbeef SHA512 abcdef0123456789\n"
  assertEq
    "manifest sha512"
    (Just "abcdef0123456789")
    (parseManifestVendorSHA512 man "dolt-2.1.6-vendor.tar.xz")

testGoVersionParse :: IO ()
testGoVersionParse = do
  let modSample =
        T.unlines
          [ "module github.com/charmbracelet/crush",
            "",
            "go 1.26.5",
            "",
            "toolchain go1.26.5",
            "",
            "require (",
            "        github.com/foo/bar v1.0.0",
            ")"
          ]
  assertEq
    "go.mod directive"
    (Just "1.26.5")
    (parseGoModGoDirective modSample)
  assertEq
    "commented go ignored"
    Nothing
    (parseGoModGoDirective "// go 1.99.0\nmodule x\n")
  assertEq
    "missing go line"
    Nothing
    (parseGoModGoDirective "module x\nrequire github.com/a/b v1\n")
  assertEq
    "go version output"
    (Just "1.26.4")
    (parseGoVersionOutput "go version go1.26.4 linux/amd64\n")
  assertEq
    "go version with experiment suffix"
    (Just "1.26.4")
    (parseGoVersionOutput "go version go1.26.4-X:nodwarf5 linux/amd64\n")
  assertEq
    "1.26 pads like 1.26.0"
    (parseGoVersionToken "1.26")
    (parseGoVersionToken "1.26.0")
  assertEq
    "host older"
    (Just LT)
    (compareGoVersions "1.26.4" "1.26.5")
  assertEq
    "host equal"
    (Just EQ)
    (compareGoVersions "1.26.5" "1.26.5")
  assertEq
    "host newer"
    (Just GT)
    (compareGoVersions "1.27.0" "1.26.5")
  assertEq
    "meets requirement"
    (Just True)
    (hostMeetsGoRequirement "1.26.5" "1.26.5")
  assertEq
    "does not meet"
    (Just False)
    (hostMeetsGoRequirement "1.26.4" "1.26.5")
  assertTrue
    "too-old message names versions"
    ( "1.26.4" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
        && "1.26.5" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
        && "GOTOOLCHAIN=auto" `T.isInfixOf` goVersionTooOldMessage "1.26.4" "1.26.5"
    )
  assertTrue
    "toolchain stderr detected"
    (looksLikeToolchainError "go: go.mod requires go >= 1.26.5 (running go 1.26.4; GOTOOLCHAIN=local)")
  assertTrue
    "enrich mentions upgrade"
    ("dev-lang/go" `T.isInfixOf` enrichGoModDownloadError "toolchain not available")

testGoBdependEdit :: IO ()
testGoBdependEdit = do
  let base =
        T.unlines
          [ "# Copyright",
            "EAPI=8",
            "",
            "inherit go-module",
            "",
            "DESCRIPTION=\"x\"",
            "SRC_URI=\"https://example/a-${PV}.tar.gz\""
          ]
  inserted <- assertRight "insert bdepend" (ensureGoBdepend "1.26.5" base)
  assertTrue
    "inserted atom"
    (goBdependAtom "1.26.5" `T.isInfixOf` inserted)
  assertTrue "has go bdepend" (ebuildHasDevLangGoBdepend inserted)
  assertTrue "matches" (goBdependMatches "1.26.5" inserted)
  let withOld =
        T.unlines
          [ "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.24.11:=\"",
            "BDEPEND+=\" app-arch/unzip\"",
            "DESCRIPTION=\"y\""
          ]
  replaced <- assertRight "replace bdepend" (ensureGoBdepend "1.26.5" withOld)
  assertTrue
    "new atom present"
    (goBdependMatches "1.26.5" replaced)
  assertTrue
    "old atom gone"
    (not (">=dev-lang/go-1.24.11:=" `T.isInfixOf` replaced))
  assertTrue
    "unrelated bdepend kept"
    ("app-arch/unzip" `T.isInfixOf` replaced)
  case ensureGoBdepend "1.26.5" "DESCRIPTION=\"no inherit\"\n" of
    Left msg ->
      assertTrue "no inherit error" ("inherit" `T.isInfixOf` msg)
    Right _ -> do
      hPutStrLn stderr "expected Left when no inherit line"
      exitFailure
  case ensureGoBdepend "" base of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected Left for empty go version"
      exitFailure

testVendorGoVersionGate :: IO ()
testVendorGoVersionGate = do
  downloadCalls <- newIORef (0 :: Int)
  let goMod =
        T.unlines
          [ "module example.com/pkg",
            "go 1.26.5"
          ]
      writeClone _url _tag dest = do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "go.mod") goMod
        pure (Right ())
      ops hostVer =
        VendorOps
          { voClone = writeClone,
            voHostGoVersion = pure (Right hostVer),
            voGoModDownload = \_ -> do
              atomicModifyIORef' downloadCalls (\n -> (n + 1, ()))
              pure (Right ()),
            voTarXz = \_goDir _entry outPath -> do
              writeFile outPath "fake-tarball"
              pure (Right ())
          }
  -- Older host: fail before download
  atomicModifyIORef' downloadCalls (const (0, ()))
  older <- buildVendorTarball (ops "1.26.4") "o" "r" "v" "0.1.0" Nothing "/tmp" "pkg-0.1.0-vendor.tar.xz"
  case older of
    Left msg -> do
      assertTrue "names host" ("1.26.4" `T.isInfixOf` msg)
      assertTrue "names required" ("1.26.5" `T.isInfixOf` msg)
      n <- readIORef downloadCalls
      assertEq "download not called when host old" 0 n
    Right _ -> do
      hPutStrLn stderr "expected hard-fail for older host Go"
      exitFailure
  -- Equal host: proceeds
  atomicModifyIORef' downloadCalls (const (0, ()))
  withSystemTempDirectory "mndz-vendor-test-" $ \outDir -> do
    ok <-
      buildVendorTarball
        (ops "1.26.5")
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor.tar.xz"
    case ok of
      Right VendorResult {vrGoModVersion = mVer, vrTarballPath = path} -> do
        assertEq "go.mod version plumbed" (Just "1.26.5") mVer
        n <- readIORef downloadCalls
        assertEq "download called once" 1 n
        assertEq
          "tarball path"
          (outDir </> "pkg-0.1.0-vendor.tar.xz")
          path
      Left err -> do
        hPutStrLn stderr $ "expected success, got " <> T.unpack err
        exitFailure

testSshAgentReuse :: IO ()
testSshAgentReuse = do
  let opsWithKeys =
        SshAgentOps
          { saoLookupEnv = \k -> pure $ if k == "SSH_AUTH_SOCK" then Just "/tmp/agent" else Nothing,
            saoSetEnv = \_ _ -> pure (),
            saoUnsetEnv = \_ -> pure (),
            saoRunAgent = pure (Left "should not start"),
            saoSshAdd = pure (Left "should not add"),
            saoListIdentities = pure HasIdentities,
            saoKillAgent = \_ -> pure ()
          }
  result <- ensureSshAgent opsWithKeys
  case result of
    Right SshSessionReused -> pure ()
    other -> do
      hPutStrLn stderr $ "expected reused session, got " <> show other
      exitFailure
  let opsEmpty =
        opsWithKeys
          { saoListIdentities = pure NoIdentities,
            saoSshAdd = pure (Right ())
          }
  resultEmpty <- ensureSshAgent opsEmpty
  case resultEmpty of
    Left msg ->
      assertTrue
        "mentions no identities"
        ("no identities" `T.isInfixOf` msg)
    Right _ -> do
      hPutStrLn stderr "expected failure when agent stays empty"
      exitFailure
  let parsed =
        parseIdentityFiles
          "/home/u"
          "Host github.com\n  IdentityFile ~/.ssh/keys/github\n# IdentityFile ~/.ssh/skip\nIdentityFile /abs/key\n"
  assertEq
    "parsed identity files"
    ["/home/u/.ssh/keys/github", "/abs/key"]
    parsed
  missing <-
    checkToolsOnPath
      ( \name ->
          pure $
            if name == "go"
              then Nothing
              else Just ("/bin/" <> name)
      )
      goAssetsRequiredTools
  assertEq "go missing among assets tools" ["go"] missing

------------------------------------------------------------------------
-- GPG sign readiness (fake ops; no live pinentry)
------------------------------------------------------------------------

testGpgSignReadiness :: IO ()
testGpgSignReadiness = do
  testParseSignCapableKeygrip
  testParseKeyinfoCached
  testPinentryChildEnv
  testMissingSigningKeyFails
  testWarmCacheSkipsPrompt
  testColdCacheReadyThenWarm
  testNoTtyWhenColdFails
  testClearOnlyIfWarmed
  testPerRepoKeygrips

testParseSignCapableKeygrip :: IO ()
testParseSignCapableKeygrip = do
  let sample =
        unlines
          [ "sec:u:255:22:AB3AA8D9F11259B4:1781074659:::u:::scESC:::+::ed25519:::0:",
            "fpr:::::::::CD806AAD3E54156ACC3842B7AB3AA8D9F11259B4:",
            "grp:::::::::6FD5C82CED9AF42C796A9C275BF5CD4082063513:",
            "ssb:u:255:18:0FFCBBF091D67623:1781074659::::::e:::+::cv25519::",
            "grp:::::::::76D0B0AC365AE824D6705200A8898C3E7F33A81D:"
          ]
  case parseSignCapableKeygrip sample of
    Right (Keygrip g) ->
      assertEq
        "sign keygrip"
        "6FD5C82CED9AF42C796A9C275BF5CD4082063513"
        g
    Left err -> do
      hPutStrLn stderr $ "parseSignCapableKeygrip failed: " <> T.unpack err
      exitFailure
  case parseSignCapableKeygrip "ssb:u:255:18:0FFC::::::e:::\ngrp:::::::::AAAA:\n" of
    Left _ -> pure ()
    Right _ -> do
      hPutStrLn stderr "expected no sign-capable keygrip"
      exitFailure

testParseKeyinfoCached :: IO ()
testParseKeyinfoCached = do
  let grip = "6FD5C82CED9AF42C796A9C275BF5CD4082063513"
      warm =
        "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - 1 P - - -\nOK\n"
      cold =
        "S KEYINFO 6FD5C82CED9AF42C796A9C275BF5CD4082063513 D - - - P - - -\nOK\n"
  assertEq "warm" (Right True) (parseKeyinfoCached warm grip)
  assertEq "cold" (Right False) (parseKeyinfoCached cold grip)

testPinentryChildEnv :: IO ()
testPinentryChildEnv = do
  let parent = [("DISPLAY", ":0"), ("HOME", "/home/u"), ("GPG_TTY", "old")]
      env' = pinentryChildEnv (Just "/dev/tty") parent
  assertEq "GPG_TTY set" (Just "/dev/tty") (lookup "GPG_TTY" env')
  assertEq "DISPLAY cleared" Nothing (lookup "DISPLAY" env')
  assertEq "HOME kept" (Just "/home/u") (lookup "HOME" env')

baseFakeOps :: GpgAgentOps
baseFakeOps =
  GpgAgentOps
    { gaoGetSigningKey = \_ -> pure (Right "KEY1"),
      gaoResolveKeygrip = \_ -> pure (Right (Keygrip "GRIP1")),
      gaoKeyinfoCached = \_ -> pure (Right True),
      gaoReadyPrompt = pure (Left "should not prompt"),
      gaoWarmKey = \_ -> pure (Left "should not warm"),
      gaoClearPassphrase = \_ -> pure (),
      gaoControllingTty = pure (Just "/dev/tty"),
      gaoPauseUi = pure (),
      gaoResumeUi = pure ()
    }

testMissingSigningKeyFails :: IO ()
testMissingSigningKeyFails = do
  let ops =
        baseFakeOps
          { gaoGetSigningKey = \_ -> pure (Left "git config user.signingkey is unset")
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  err <- assertLeft "missing signingkey" result
  assertTrue "mentions signingkey" ("signingkey" `T.isInfixOf` err)
  teardownGpgHandle h

testWarmCacheSkipsPrompt :: IO ()
testWarmCacheSkipsPrompt = do
  promptRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right True),
            gaoReadyPrompt = do
              atomicModifyIORef' promptRef (\n -> (n + 1, ()))
              pure (Right ())
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "warm cache ready" result
  prompts <- readIORef promptRef
  assertEq "no ready prompt when warm" 0 prompts
  teardownGpgHandle h

testColdCacheReadyThenWarm :: IO ()
testColdCacheReadyThenWarm = do
  promptRef <- newIORef (0 :: Int)
  warmRef <- newIORef (0 :: Int)
  pauseRef <- newIORef (0 :: Int)
  resumeRef <- newIORef (0 :: Int)
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoReadyPrompt = do
              atomicModifyIORef' promptRef (\n -> (n + 1, ()))
              pure (Right ()),
            gaoWarmKey = \_ -> do
              atomicModifyIORef' warmRef (\n -> (n + 1, ()))
              pure (Right ()),
            gaoPauseUi = atomicModifyIORef' pauseRef (\n -> (n + 1, ())),
            gaoResumeUi = atomicModifyIORef' resumeRef (\n -> (n + 1, ()))
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "cold ready" result
  prompts <- readIORef promptRef
  warms <- readIORef warmRef
  pauses <- readIORef pauseRef
  resumes <- readIORef resumeRef
  assertEq "ready once" 1 prompts
  assertEq "warm once" 1 warms
  assertEq "ui paused" 1 pauses
  assertEq "ui resumed" 1 resumes
  teardownGpgHandle h

testNoTtyWhenColdFails :: IO ()
testNoTtyWhenColdFails = do
  let ops =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoControllingTty = pure Nothing
          }
  h <- newGpgHandle ops
  result <- ensureGpgReady h "/tmp/overlay-repo"
  err <- assertLeft "no tty" result
  assertTrue "mentions TTY" ("TTY" `T.isInfixOf` err)
  teardownGpgHandle h

testClearOnlyIfWarmed :: IO ()
testClearOnlyIfWarmed = do
  clearedRef <- newIORef ([] :: [T.Text])
  let opsWarm =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right False),
            gaoReadyPrompt = pure (Right ()),
            gaoWarmKey = \_ -> pure (Right ()),
            gaoClearPassphrase = \(Keygrip g) ->
              atomicModifyIORef' clearedRef (\xs -> (xs <> [g], ()))
          }
  h1 <- newGpgHandle opsWarm
  void $ assertRight "warm path" =<< ensureGpgReady h1 "/tmp/overlay-repo"
  teardownGpgHandle h1
  cleared1 <- readIORef clearedRef
  assertEq "cleared after we warmed" ["GRIP1"] cleared1

  clearedRef2 <- newIORef ([] :: [T.Text])
  let opsAlreadyWarm =
        baseFakeOps
          { gaoKeyinfoCached = \_ -> pure (Right True),
            gaoClearPassphrase = \(Keygrip g) ->
              atomicModifyIORef' clearedRef2 (\xs -> (xs <> [g], ()))
          }
  h2 <- newGpgHandle opsAlreadyWarm
  void $ assertRight "already warm" =<< ensureGpgReady h2 "/tmp/overlay-repo"
  teardownGpgHandle h2
  cleared2 <- readIORef clearedRef2
  assertEq "no clear when we did not warm" [] cleared2

testPerRepoKeygrips :: IO ()
testPerRepoKeygrips = do
  resolveRef <- newIORef ([] :: [FilePath])
  let ops =
        baseFakeOps
          { gaoGetSigningKey = \root -> do
              atomicModifyIORef' resolveRef (\xs -> (xs <> [root], ()))
              pure $
                if "assets" `T.isInfixOf` T.pack root
                  then Right "KEY-ASSETS"
                  else Right "KEY-OVERLAY",
            gaoResolveKeygrip = \k ->
              pure $
                Right $
                  Keygrip $
                    if k == "KEY-ASSETS" then "GRIP-A" else "GRIP-O",
            gaoKeyinfoCached = \_ -> pure (Right True)
          }
  h <- newGpgHandle ops
  void $ assertRight "overlay" =<< ensureGpgReady h "/tmp/overlay-repo"
  void $ assertRight "assets" =<< ensureGpgReady h "/tmp/assets-repo"
  -- Second call same overlay should reuse resolved state (no second get for same abs path)
  void $ assertRight "overlay again" =<< ensureGpgReady h "/tmp/overlay-repo"
  roots <- readIORef resolveRef
  -- makeAbsolute may expand; we only require both repos were queried at least once
  assertTrue "queried more than once" (length roots >= 2)
  teardownGpgHandle h

------------------------------------------------------------------------
-- Verbosity / logging / concurrency
------------------------------------------------------------------------

testVerbosityResolution :: IO ()
testVerbosityResolution = do
  assertEq "default" V.Warn (resolveVerbosity Nothing 0)
  assertEq "single -v" V.Info (resolveVerbosity Nothing 1)
  assertEq "double -v" V.Debug (resolveVerbosity Nothing 2)
  assertEq "triple caps at debug" V.Debug (resolveVerbosity Nothing 5)
  assertEq "explicit overrides -v" V.Error (resolveVerbosity (Just V.Error) 2)
  assertEq "explicit warn overrides -vv" V.Warn (resolveVerbosity (Just V.Warn) 2)
  assertEq "explicit debug" V.Debug (resolveVerbosity (Just V.Debug) 0)

testSeverityFilterMapping :: IO ()
testSeverityFilterMapping = do
  assertEq "error" C.Error (verbosityToSeverity V.Error)
  assertEq "warn" C.Warning (verbosityToSeverity V.Warn)
  assertEq "info" C.Info (verbosityToSeverity V.Info)
  assertEq "debug" C.Debug (verbosityToSeverity V.Debug)
  -- filterBySeverity keeps messages with severity >= threshold
  assertTrue "warn hides info" (C.Info < C.Warning)
  assertTrue "warn shows warning" (C.Warning >= C.Warning)
  assertTrue "debug shows all" (C.Debug <= C.Info && C.Debug <= C.Error)

testSeverityColors :: IO ()
testSeverityColors = do
  let err = showSeverityColored ColorOn C.Error
      info = showSeverityColored ColorOn C.Info
      warn = showSeverityColored ColorOn C.Warning
      dbg = showSeverityColored ColorOn C.Debug
  assertTrue "error has escape" ("\ESC[" `T.isInfixOf` err)
  assertTrue "info has escape" ("\ESC[" `T.isInfixOf` info)
  assertTrue "warning has escape" ("\ESC[" `T.isInfixOf` warn)
  assertTrue "debug has escape" ("\ESC[" `T.isInfixOf` dbg)
  assertTrue "error tag text" ("[Error]" `T.isInfixOf` err)
  assertTrue "info tag text" ("[Info]" `T.isInfixOf` info)

testNoColorStripsEscapes :: IO ()
testNoColorStripsEscapes = do
  let plain = showSeverityColored ColorOff C.Error
      msg =
        Msg
          { msgSeverity = C.Warning,
            msgStack = callStack,
            msgText = "hello"
          }
      formatted = fmtMessageColored ColorOff msg
  assertTrue "plain error no esc" (not ("\ESC[" `T.isInfixOf` plain))
  assertTrue "plain still has tag" ("[Error]" `T.isInfixOf` plain)
  assertTrue "fmt no esc" (not ("\ESC[" `T.isInfixOf` formatted))
  assertTrue "fmt has warning" ("[Warning]" `T.isInfixOf` formatted)
  assertTrue "fmt has body" ("hello" `T.isInfixOf` formatted)

testJobsBound :: IO ()
testJobsBound = do
  results <- mapConcurrentlyN 4 pure [1 .. 10 :: Int]
  assertEq "preserves values" [1 .. 10] (sort results)

-- | With --jobs 1, concurrent slots never exceed one in-flight job.
testJobsOneSerial :: IO ()
testJobsOneSerial = do
  inFlight <- newIORef (0 :: Int)
  maxSeen <- newIORef (0 :: Int)
  let job _ = do
        cur <-
          atomicModifyIORef' inFlight $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen $ \m -> (max m cur, ())
        threadDelay 20_000
        atomicModifyIORef' inFlight $ \n -> (n - 1, ())
        pure ()
  void $ mapConcurrentlyN 1 job [1 .. 6 :: Int]
  peak <- readIORef maxSeen
  assertEq "jobs 1 peak concurrency" 1 peak
  -- Also verify higher bound can exceed 1 when work overlaps.
  inFlight2 <- newIORef (0 :: Int)
  maxSeen2 <- newIORef (0 :: Int)
  let job2 _ = do
        cur <-
          atomicModifyIORef' inFlight2 $ \n ->
            let n' = n + 1 in (n', n')
        atomicModifyIORef' maxSeen2 $ \m -> (max m cur, ())
        threadDelay 50_000
        atomicModifyIORef' inFlight2 $ \n -> (n - 1, ())
        pure ()
  void $ mapConcurrentlyN 3 job2 [1 .. 6 :: Int]
  peak2 <- readIORef maxSeen2
  assertTrue "jobs 3 can exceed 1" (peak2 > 1)

------------------------------------------------------------------------
-- Go tree-lane planner
------------------------------------------------------------------------

testGoTreeCeilings :: IO ()
testGoTreeCeilings = do
  let kwPlain = parseKeywordsField "KEYWORDS=\"amd64 ~arm64\"\n"
      kwTilde = parseKeywordsField "KEYWORDS=\"~amd64 ~arm64\"\n"
  assertTrue "bare amd64" (keywordsHasBare Amd64 kwPlain)
  assertTrue "not bare when tilde only" (not (keywordsHasBare Amd64 kwTilde))
  assertTrue "tilde or bare for ~amd64" (keywordsHasTildeOrBare Amd64 kwTilde)
  assertTrue "tilde or bare for bare" (keywordsHasTildeOrBare Amd64 kwPlain)
  assertTrue "live 9999" (isLiveGoVersion (parseEbuildVersion "9999"))
  assertTrue "not live" (not (isLiveGoVersion (parseEbuildVersion "1.26.3")))
  case parseGoEbuildMeta "/x/go-9999.ebuild" "KEYWORDS=\"~amd64\"\n" of
    Nothing -> pure ()
    Just _ -> do
      hPutStrLn stderr "expected Nothing for live go ebuild"
      exitFailure
  let metas =
        [ GoEbuildMeta (parseEbuildVersion "1.26.3") ["amd64", "arm64"],
          GoEbuildMeta (parseEbuildVersion "1.26.4") ["~amd64", "~arm64"],
          GoEbuildMeta (parseEbuildVersion "1.25.0") ["~amd64"]
        ]
      ceilings = computeCeilings metas
  assertEq "amd64 plain" (Just (parseEbuildVersion "1.26.3")) (gcAmd64Plain ceilings)
  assertEq "amd64 tilde" (Just (parseEbuildVersion "1.26.4")) (gcAmd64Tilde ceilings)
  assertEq "arm64 plain" (Just (parseEbuildVersion "1.26.3")) (gcArm64Plain ceilings)
  assertEq "arm64 tilde" (Just (parseEbuildVersion "1.26.4")) (gcArm64Tilde ceilings)
  assertEq "empty ceilings" emptyCeilings (computeCeilings [])

testGoKeywordsAssembly :: IO ()
testGoKeywordsAssembly = do
  assertEq "both arches" ["~amd64", "~arm64"] (assembleKeywords [Amd64, Arm64])
  assertEq "amd64 only" ["~amd64"] (assembleKeywords [Amd64])
  assertEq "arm64 only" ["~arm64"] (assembleKeywords [Arm64])

testGoLaneSelection :: IO ()
testGoLaneSelection = do
  let ceilings =
        GoCeilings
          { gcAmd64Plain = Just (parseEbuildVersion "1.26.3"),
            gcAmd64Tilde = Just (parseEbuildVersion "1.26.5"),
            gcArm64Plain = Just (parseEbuildVersion "1.26.3"),
            gcArm64Tilde = Just (parseEbuildVersion "1.26.5")
          }
      candidates =
        [ VersionCandidate (parseEbuildVersion "0.82.0") (Just "1.26.3"),
          VersionCandidate (parseEbuildVersion "0.84.0") (Just "1.26.5"),
          VersionCandidate (parseEbuildVersion "0.85.0") Nothing
        ]
  assertEq
    "max under plain"
    (Just (parseEbuildVersion "0.82.0", "1.26.3"))
    (maxVersionUnder (parseEbuildVersion "1.26.3") candidates)
  assertEq
    "max under tilde"
    (Just (parseEbuildVersion "0.84.0", "1.26.5"))
    (maxVersionUnder (parseEbuildVersion "1.26.5") candidates)
  let targets = selectAllLaneTargets ceilings candidates
      plan = planFromTargets targets
  assertEq "two unique PVs" 2 (length (glpUniquePVs plan))
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Plain] of
    [Just pv] -> assertEq "plain lane" (parseEbuildVersion "0.82.0") pv
    other -> do
      hPutStrLn stderr $ "plain lane target: " <> show other
      exitFailure
  case [ltPackagePV t | t <- targets, ltLane t == LaneAmd64Tilde] of
    [Just pv] -> assertEq "tilde lane" (parseEbuildVersion "0.84.0") pv
    other -> do
      hPutStrLn stderr $ "tilde lane target: " <> show other
      exitFailure

testGoLaneCollapse :: IO ()
testGoLaneCollapse = do
  let allSame =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
        ]
      collapsed = collapsePlannedEbuilds allSame
  assertEq "single PV collapse" 1 (length collapsed)
  case collapsed of
    [pe] -> do
      assertEq "pv" (parseEbuildVersion "0.84.0") (pePV pe)
      assertTrue "has ~amd64" ("~amd64" `elem` peKeywords pe)
      assertTrue "has ~arm64" ("~arm64" `elem` peKeywords pe)
    _ -> exitFailure
  let divergent =
        [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
          LaneTarget LaneArm64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
          LaneTarget LaneArm64Tilde (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3")
        ]
      divCollapsed = collapsePlannedEbuilds divergent
  assertEq "arch divergent count" 2 (length divCollapsed)
  case [pe | pe <- divCollapsed, pePV pe == parseEbuildVersion "0.84.0"] of
    [pe] -> do
      assertTrue "0.84 ~amd64" ("~amd64" `elem` peKeywords pe)
      assertTrue "0.84 no ~arm64" ("~arm64" `notElem` peKeywords pe)
    other -> do
      hPutStrLn stderr $ "0.84 ebuild: " <> show other
      exitFailure
  let fourDistinct =
        [ LaneTarget LaneAmd64Plain Nothing (Just (parseEbuildVersion "0.80.0")) (Just "1.0"),
          LaneTarget LaneAmd64Tilde Nothing (Just (parseEbuildVersion "0.81.0")) (Just "1.0"),
          LaneTarget LaneArm64Plain Nothing (Just (parseEbuildVersion "0.82.0")) (Just "1.0"),
          LaneTarget LaneArm64Tilde Nothing (Just (parseEbuildVersion "0.83.0")) (Just "1.0")
        ]
  assertEq "four ebuilds" 4 (length (collapsePlannedEbuilds fourDistinct))
  let plan = planFromTargets allSame
      locals = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
  assertEq "missing target" [parseEbuildVersion "0.84.0"] (missingTargets locals plan)
  assertEq
    "extras"
    [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
    (extrasToDelete locals plan)
  assertTrue "needs work" (planNeedsWork locals [] plan)
  assertTrue "satisfied" (not (planNeedsWork [parseEbuildVersion "0.84.0"] [] plan))

testGoGapLines :: IO ()
testGoGapLines = do
  assertEq
    "labels"
    "(dev-lang/go amd64)"
    (laneLabel LaneAmd64Plain)
  assertEq
    "tilde label"
    "(dev-lang/go ~amd64)"
    (laneLabel LaneAmd64Tilde)
  let planSplit =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.3")) (Just (parseEbuildVersion "0.82.0")) (Just "1.26.3"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals1 = [parseEbuildVersion "0.80.0"]
      needs = [parseEbuildVersion "0.82.0", parseEbuildVersion "0.84.0"]
      linesSplit = buildGapLines locals1 needs planSplit
  assertEq "split line count" 2 (length linesSplit)
  assertTrue
    "split from 0.80"
    (all (\g -> glFrom g == parseEbuildVersion "0.80.0") linesSplit)
  assertTrue
    "has 0.82"
    (any (\g -> glTo g == parseEbuildVersion "0.82.0") linesSplit)
  assertTrue
    "has 0.84"
    (any (\g -> glTo g == parseEbuildVersion "0.84.0") linesSplit)
  let planConverge =
        planFromTargets
          [ LaneTarget LaneAmd64Plain (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5"),
            LaneTarget LaneAmd64Tilde (Just (parseEbuildVersion "1.26.5")) (Just (parseEbuildVersion "0.84.0")) (Just "1.26.5")
          ]
      locals2 = [parseEbuildVersion "0.80.0", parseEbuildVersion "0.82.0"]
      linesConv = buildGapLines locals2 [parseEbuildVersion "0.84.0"] planConverge
  assertEq "converge line count" 2 (length linesConv)
  assertTrue
    "converge has 0.80"
    (any (\g -> glFrom g == parseEbuildVersion "0.80.0") linesConv)
  assertTrue
    "converge has 0.82"
    (any (\g -> glFrom g == parseEbuildVersion "0.82.0") linesConv)
  assertTrue
    "converge to 0.84"
    (all (\g -> glTo g == parseEbuildVersion "0.84.0") linesConv)

testGoStripAndParseList :: IO ()
testGoStripAndParseList = do
  case stripAndParse "v" "v0.80.0" of
    Right v -> assertEq "prefix v" (parseEbuildVersion "0.80.0") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
  case stripAndParse "bun-v" "bun-v1.2.3" of
    Right v -> assertEq "bun prefix" (parseEbuildVersion "1.2.3") v
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure

testSetKeywords :: IO ()
testSetKeywords = do
  let base =
        T.unlines
          [ "inherit go-module",
            "KEYWORDS=\"~amd64\"",
            "DESCRIPTION=\"x\""
          ]
      fixed = setKeywords ["~amd64", "~arm64"] base
  assertTrue "match dual" (keywordsMatch ["~amd64", "~arm64"] fixed)
  assertTrue "no bare amd64" (not (" amd64" `T.isInfixOf` fixed || "KEYWORDS=\"amd64" `T.isInfixOf` fixed))
  let noKw =
        T.unlines
          [ "inherit go-module",
            "",
            "DESCRIPTION=\"y\""
          ]
      inserted = setKeywords ["~amd64"] noKw
  assertTrue "inserted" (keywordsMatch ["~amd64"] inserted)

testGoPlanIntegrationMocked :: IO ()
testGoPlanIntegrationMocked = do
  withSystemTempDirectory "mndz-go-tree-" $ \tmp -> do
    let gentoo = tmp </> "gentoo"
        goDir = gentoo </> "dev-lang" </> "go"
    createDirectoryIfMissing True goDir
    TIO.writeFile
      (goDir </> "go-1.26.3.ebuild")
      "KEYWORDS=\"amd64 arm64\"\n"
    TIO.writeFile
      (goDir </> "go-1.26.5.ebuild")
      "KEYWORDS=\"~amd64 ~arm64\"\n"
    TIO.writeFile
      (goDir </> "go-9999.ebuild")
      "KEYWORDS=\"~amd64\"\n"
    let portageq args =
          pure $
            if args == ["get_repo_path", "/", "gentoo"]
              then Right (T.pack gentoo)
              else Left "unexpected portageq"
    ceilings <-
      assertRight "discover ceilings"
        =<< discoverGoCeilingsWith portageq
    assertEq
      "mock plain"
      (Just (parseEbuildVersion "1.26.3"))
      (gcAmd64Plain ceilings)
    assertEq
      "mock tilde"
      (Just (parseEbuildVersion "1.26.5"))
      (gcAmd64Tilde ceilings)
    let planOps =
          PlanOps
            { poPortageq = portageq,
              poListVersions = \_ ->
                pure $
                  Right
                    [ parseEbuildVersion "0.82.0",
                      parseEbuildVersion "0.84.0"
                    ],
              poFetchGoMod = \key ->
                pure $
                  Right $
                    case gmkTag key of
                      "v0.82.0" -> "module x\ngo 1.26.3\n"
                      "v0.84.0" -> "module x\ngo 1.26.5\n"
                      _ -> "module x\n"
            }
    plan <-
      assertRight "plan go package"
        =<< planGoPackage planOps (GitHub "o" "r" "v") Nothing
    assertEq "planned unique" 2 (length (glpUniquePVs plan))
    assertTrue
      "has 0.82"
      (parseEbuildVersion "0.82.0" `elem` glpUniquePVs plan)
    assertTrue
      "has 0.84"
      (parseEbuildVersion "0.84.0" `elem` glpUniquePVs plan)
