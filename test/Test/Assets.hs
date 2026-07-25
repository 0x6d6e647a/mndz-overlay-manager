{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Assets (tests) where

import CLI.Jobs
  ( mapConcurrentlyN,
    newWorkBudget,
    withWorkSlot,
    workBudgetCapacity,
  )
import CLI.Parser (ColorMode (..), resolveVerbosity)
import CLI.Parser qualified as V
import CLI.Progress
  ( ActiveJob (..),
    DrawPlan (..),
    JobRow (..),
    MultiHandle (..),
    MultiState (..),
    PanelIO (..),
    ProgressConfig,
    defaultPanelIO,
    mkProgressConfig,
    multiHandle,
    noopMultiHandle,
    pauseActivePanel,
    planDraw,
    renderMulti,
    resumeActivePanel,
    withMultiProgressIO,
    withStepProgressIO,
  )
import Colog (LogAction (..), Message, Msg (..))
import Colog qualified as C
import Config.Loader (ConfigError (..), loadConfig)
import Config.Types (OverlayConfig (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, race)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Exception (SomeException, bracket_, throwIO, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import GHC.Stack (callStack)
import Logging.Bootstrap
  ( fmtMessageColored,
    mkLogHold,
    showSeverityColored,
    verbosityToSeverity,
  )
import Network.HTTP.Client (method, path)
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
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse)
import Test.Support
  ( dualArchGoCeilings,
    mkTestApplyEnv,
    mockEgencacheWriteMatching,
    unusedReleaseOps,
    unusedVendorOps,
    writeMatchingCacheFile,
    writeMatchingCachesForPackage,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Apply
  ( ApplyEnv (..),
    EbuildRunner,
    applyPackagePhase1Tracked,
    foldExitHardFail,
  )
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitErrorMessage,
    applyUnitHardFail,
  )
import Update.Apply.TestSupport
  ( applyPackagePhase1,
    contentFixNeeded,
    fullPathMaterializeSteps,
    goPublishAndOverlay,
    markSuccessLinesReused,
    materializePlan,
    materializeStepTotalUpper,
    newEbuildFileName,
    renderPVNoRev,
    reusePathMaterializeSteps,
    reviseMaterializeStepTotal,
    signedOverlayCommit,
  )
import Update.Assets.Hash (FileDigests (..), digestSHA512, hashBytes, sidecarLine)
import Update.Assets.Layout (cratesTarballName, depsTarballName, vendorTarballName)
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseMeta (..),
    ReleaseOps (..),
    createReleaseWithAssetHttpLbs,
    downloadReleaseAssetHttpLbs,
    findAssetByName,
    getReleaseByTagHttpLbs,
    lookupNamedAsset,
    parseReleaseInfo,
  )
import Update.Auth (resolveGitHubToken, resolveGitHubTokenWith)
import Update.Bun.Cache (productionBunCacheOps)
import Update.Cargo.Crates (productionCargoOps)
import Update.Cargo.Msrv
  ( combineMsrv,
    normalizeRustVersion,
    parseRustMinVerFromEbuild,
    parseRustVersionField,
  )
import Update.Check (PackageEntry (..), groupNewest)
import Update.Deps.Plan (DepsPlanOps (..), productionDepsPlanOps)
import Update.EbuildEdit
  ( assetsSrcUriParameterized,
    ebuildHasDevLangGoBdepend,
    ebuildNeedsCargoContentFix,
    ebuildNeedsContentFix,
    ensureCargoAssetsSrcUri,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureRustMinVer,
    goBdependAtom,
    goBdependMatches,
    keywordsMatch,
    manifestHasVendorDist,
    nextRevisionVersion,
    nodejsBdependMatches,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
    setKeywords,
    writeVersionForPlannedPV,
  )
import Update.Engines (parseEnginesMinimum)
import Update.Git (GitOps (..))
import Update.GitHub (stripAndParse)
import Update.Go.Lanes
  ( GapLine (..),
    LaneId (..),
    LaneTarget (..),
    PlanError (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    VersionCandidate (..),
    assembleKeywords,
    buildGapLines,
    collapsePlannedEbuilds,
    extrasToDelete,
    filterCandidateVersions,
    laneLabel,
    laneLabelWith,
    ltLane,
    maxVersionUnder,
    missingTargets,
    planErrorMessage,
    planFromTargets,
    planNeedsWork,
    selectAllLaneTargets,
    zeroPlannedPVsError,
    pattern LaneAmd64Plain,
    pattern LaneAmd64Tilde,
    pattern LaneArm64Plain,
    pattern LaneArm64Tilde,
  )
import Update.Go.ModFetch (GoModKey (..), withGoModCache)
import Update.Go.Plan
  ( PlanOps (..),
    PlanProgress (..),
    noopPlanProgress,
    planGoPackage,
    planGoPackageWithProgress,
  )
import Update.Go.Vendor
  ( VendorOps (..),
    VendorProgress (..),
    VendorResult (..),
    buildVendorTarball,
    noopVendorProgress,
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
import Update.Md5Cache
  ( EgencacheRequest (..),
    GencacheAction (..),
    PackageCacheIssue (..),
    VersionCacheStatus (..),
    buildRepositoriesConfiguration,
    cacheFilePath,
    checkLayoutCacheFormats,
    classifyVersionCache,
    decideGencacheAction,
    ebuildFileMd5,
    gencachePackages,
    inspectPackageCache,
    listNonLiveEbuildVersions,
    packageCacheGateError,
    readCacheMd5Field,
  )
import Update.Npm.Cache (productionNpmCacheOps)
import Update.Preflight (checkToolsOnPath, goAssetsRequiredTools, updateRequiredTools)
import Update.Resolve (resolveSource)
import Update.Runtime.Ceilings
  ( ArchCeilings (..),
    RuntimeCeilings (..),
    RuntimeEbuildMeta (..),
    computeCeilings,
    discoverGoCeilingsWith,
    emptyCeilings,
    isLiveRuntimeVersion,
    keywordsHasBare,
    keywordsHasTildeOrBare,
    mergeCeilingsMax,
    normalizeArchToken,
    parseKeywordsField,
    parseRuntimeEbuildMeta,
  )
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
    EcosystemSpec (..),
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

tests :: TestTree
tests =
  testGroup
    "Assets"
    [ testCase "Token Resolver" testTokenResolver,
      testCase "Token Resolver IO" testTokenResolverIO,
      testCase "Hash Bytes" testHashBytes,
      testCase "Sidecar Line" testSidecarLine,
      testCase "Deps Distfile Names" testDepsDistfileNames,
      testCase "Release Lookup" testReleaseLookup,
      testCase "Release HTTP Get By Tag" testReleaseHttpGetByTag,
      testCase "Release HTTP Download" testReleaseHttpDownload,
      testCase "Release HTTP Create Upload Delete" testReleaseHttpCreateUploadDelete
    ]

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
  -- whitespace-only is treated as empty; surrounding whitespace is stripped
  assertEq
    "whitespace-only github_token skipped"
    (Just "from-gh")
    (resolveGitHubTokenWith (Just "   ") (Just "from-gh") (Just "cfg"))
  assertEq
    "whitespace-only gh_token skipped"
    (Just "cfg")
    (resolveGitHubTokenWith Nothing (Just " \t ") (Just "cfg"))
  assertEq
    "whitespace-only config skipped"
    Nothing
    (resolveGitHubTokenWith Nothing Nothing (Just "  \n"))
  assertEq
    "strip github_token"
    (Just "tok")
    (resolveGitHubTokenWith (Just "  tok  ") Nothing Nothing)
  assertEq
    "strip gh_token"
    (Just "gh")
    (resolveGitHubTokenWith Nothing (Just "\tgh\n") Nothing)
  assertEq
    "strip config token"
    (Just "cfg")
    (resolveGitHubTokenWith Nothing Nothing (Just " cfg "))
  assertEq
    "empty gh falls through to config"
    (Just "cfg")
    (resolveGitHubTokenWith Nothing (Just "") (Just "cfg"))

-- | Thin IO wrapper over env lookup for GITHUB_TOKEN / GH_TOKEN.
testTokenResolverIO :: IO ()
testTokenResolverIO = do
  let cfg =
        OverlayConfig
          { overlayPath = "/tmp/ov",
            assetsPath = Nothing,
            githubToken = Just "from-config"
          }
  withAuthEnv Nothing Nothing $ do
    assertEq "config only" (Just "from-config") =<< resolveGitHubToken cfg
  withAuthEnv (Just "  env-tok  ") (Just "gh") $ do
    assertEq "GITHUB_TOKEN wins and strips" (Just "env-tok") =<< resolveGitHubToken cfg
  withAuthEnv Nothing (Just "  gh-tok  ") $ do
    assertEq "GH_TOKEN second" (Just "gh-tok") =<< resolveGitHubToken cfg
  withAuthEnv (Just "   ") Nothing $ do
    assertEq "whitespace env skipped" (Just "from-config") =<< resolveGitHubToken cfg
  let cfgNoTok =
        OverlayConfig
          { overlayPath = "/tmp/ov",
            assetsPath = Nothing,
            githubToken = Nothing
          }
  withAuthEnv Nothing Nothing $ do
    assertEq "none" Nothing =<< resolveGitHubToken cfgNoTok

withAuthEnv :: Maybe String -> Maybe String -> IO a -> IO a
withAuthEnv mGithub mGh action =
  withEnvVar "GITHUB_TOKEN" mGithub $
    withEnvVar "GH_TOKEN" mGh action

withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key mVal action = do
  prev <- lookupEnv key
  let restore = case prev of
        Nothing -> unsetEnv key
        Just v -> setEnv key v
      install = case mVal of
        Nothing -> unsetEnv key
        Just v -> setEnv key v
  bracket_ install restore action

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

testDepsDistfileNames :: IO ()
testDepsDistfileNames = do
  assertEq
    "vendor"
    "crush-0.84.0-vendor.tar.xz"
    (vendorTarballName "crush" "0.84.0")
  assertEq
    "deps"
    "openspec-1.4.2-deps.tar.xz"
    (depsTarballName "openspec" "1.4.2")
  assertEq
    "crates"
    "mise-2026.7.5-crates.tar.xz"
    (cratesTarballName "mise" "2026.7.5")

------------------------------------------------------------------------
-- Release lookup / reuse / Manifest content-fix
------------------------------------------------------------------------

testReleaseLookup :: IO ()
testReleaseLookup = do
  let jsonFound =
        encodeUtf8
          "{\"id\":42,\"tag_name\":\"beads-1.0.5\",\"assets\":[{\"name\":\"beads-1.0.5-vendor.tar.xz\",\"browser_download_url\":\"https://example/a\"},{\"name\":\"other.bin\",\"browser_download_url\":\"https://example/b\"}]}"
      jsonWrongAsset =
        encodeUtf8
          "{\"id\":1,\"tag_name\":\"crush-0.84.0\",\"assets\":[{\"name\":\"notes.txt\",\"browser_download_url\":\"https://example/n\"}]}"
  info <- case eitherDecodeStrict' jsonFound of
    Left err -> do
      hPutStrLn stderr ("decode release json: " <> err)
      exitFailure
    Right val ->
      case parseMaybe parseReleaseInfo val of
        Nothing -> do
          hPutStrLn stderr "parseReleaseInfo failed"
          exitFailure
        Just i -> pure i
  assertEq "tag" "beads-1.0.5" (riTag info)
  assertEq
    "find asset"
    (Just "https://example/a")
    (raBrowserDownloadUrl <$> findAssetByName info "beads-1.0.5-vendor.tar.xz")
  assertEq
    "missing asset name"
    Nothing
    (findAssetByName info "nope.tar.xz")
  info2 <- case eitherDecodeStrict' jsonWrongAsset of
    Left err -> do
      hPutStrLn stderr ("decode release json2: " <> err)
      exitFailure
    Right val ->
      case parseMaybe parseReleaseInfo val of
        Nothing -> do
          hPutStrLn stderr "parseReleaseInfo2 failed"
          exitFailure
        Just i -> pure i
  assertEq
    "wrong asset name is nothing"
    Nothing
    (findAssetByName info2 "crush-0.84.0-vendor.tar.xz")
  -- Injectable ops: found / missing tag / missing asset name
  let opsFound =
        ReleaseOps
          { roGetReleaseByTag = \_ _ tag ->
              pure $
                if tag == "beads-1.0.5"
                  then Right (Just info)
                  else Right Nothing,
            roDownloadAsset = \_ _ -> pure (Right ()),
            roCreateReleaseWithAsset = \_ _ -> pure (Left "unused create")
          }
  found <- lookupNamedAsset opsFound "o" "r" "beads-1.0.5" "beads-1.0.5-vendor.tar.xz"
  assertEq "lookup found" (Right (Just "https://example/a")) found
  missingTag <- lookupNamedAsset opsFound "o" "r" "beads-9.9.9" "beads-1.0.5-vendor.tar.xz"
  assertEq "lookup missing tag" (Right Nothing) missingTag
  missingAsset <- lookupNamedAsset opsFound "o" "r" "beads-1.0.5" "wrong-name.tar.xz"
  assertEq "lookup missing asset" (Right Nothing) missingAsset
  -- hard error from ops
  let opsErr =
        ReleaseOps
          { roGetReleaseByTag = \_ _ _ -> pure (Left "auth failed"),
            roDownloadAsset = \_ _ -> pure (Left "unused"),
            roCreateReleaseWithAsset = \_ _ -> pure (Left "unused")
          }
  hard <- lookupNamedAsset opsErr "o" "r" "t" "a"
  assertEq "lookup hard error" (Left "auth failed") hard

testReleaseHttpGetByTag :: IO ()
testReleaseHttpGetByTag = do
  let releaseJson =
        L8.pack
          "{\"id\":7,\"tag_name\":\"v1\",\"assets\":[{\"name\":\"a.tar.xz\",\"browser_download_url\":\"https://example/a\"}]}"
      http404 _ = pure (Right (fakeResponse 404 ""))
      http200 _ = pure (Right (fakeResponse 200 releaseJson))
      http500 _ = pure (Right (fakeResponse 500 "nope"))
      httpNet _ = pure (Left "network down")
      httpBad _ = pure (Right (fakeResponse 200 "{not-json"))
  assertEq
    "404 not found"
    (Right Nothing)
    =<< getReleaseByTagHttpLbs http404 "tok" "o" "r" "missing"
  found <- assertRight "200" =<< getReleaseByTagHttpLbs http200 "tok" "o" "r" "v1"
  case found of
    Just info -> do
      assertEq "id" 7 (riId info)
      assertEq "tag" "v1" (riTag info)
    Nothing -> do
      hPutStrLn stderr "expected Just release"
      exitFailure
  err500 <- assertLeft "500" =<< getReleaseByTagHttpLbs http500 "tok" "o" "r" "v1"
  assertTrue "http 500" ("HTTP 500" `T.isInfixOf` err500)
  errNet <- assertLeft "net" =<< getReleaseByTagHttpLbs httpNet "tok" "o" "r" "v1"
  assertEq "network" "network down" errNet
  errBad <- assertLeft "bad json" =<< getReleaseByTagHttpLbs httpBad "tok" "o" "r" "v1"
  assertTrue "decode err nonempty" (not (T.null errBad))

testReleaseHttpDownload :: IO ()
testReleaseHttpDownload =
  withSystemTempDirectory "rel-dl" $ \tmp -> do
    let dest = tmp </> "out" </> "asset.bin"
        httpOk _ = pure (Right (fakeResponse 200 "asset-bytes"))
        httpFail _ = pure (Right (fakeResponse 403 "denied"))
        httpNet _ = pure (Left "dl net")
    void $ assertRight "download ok" =<< downloadReleaseAssetHttpLbs httpOk "tok" "https://example/a" dest
    exists <- doesFileExist dest
    assertTrue "wrote dest" exists
    body <- BS.readFile dest
    assertEq "body" (encodeUtf8 "asset-bytes") body
    err403 <-
      assertLeft "403" =<< downloadReleaseAssetHttpLbs httpFail "tok" "https://example/a" (tmp </> "x")
    assertTrue "download http" ("HTTP 403" `T.isInfixOf` err403)
    errNet <-
      assertLeft "net" =<< downloadReleaseAssetHttpLbs httpNet "tok" "https://example/a" (tmp </> "y")
    assertEq "net err" "dl net" errNet

testReleaseHttpCreateUploadDelete :: IO ()
testReleaseHttpCreateUploadDelete =
  withSystemTempDirectory "rel-create" $ \tmp -> do
    let assetPath = tmp </> "pkg.tar.xz"
    BS.writeFile assetPath "xz-bytes"
    methodsRef <- newIORef ([] :: [BS.ByteString])
    let meta =
          ReleaseMeta
            { rmOwner = "o",
              rmRepo = "r",
              rmTag = "t1",
              rmName = "n1",
              rmBody = "b",
              rmTargetCommitish = "main"
            }
        createBody =
          L8.pack
            "{\"id\":99,\"upload_url\":\"https://uploads.example/assets{?name,label}\"}"
        -- Success: create 201 then upload 201
        httpSuccess req = do
          atomicModifyIORef' methodsRef (\xs -> (xs <> [method req], ()))
          pure $
            Right $
              if method req == "POST" && "releases" `BSC.isInfixOf` path req
                then fakeResponse 201 createBody
                else fakeResponse 201 ""
    void $
      assertRight "create+upload"
        =<< createReleaseWithAssetHttpLbs httpSuccess "tok" meta assetPath
    methods <- readIORef methodsRef
    assertEq "create then upload" ["POST", "POST"] methods

    -- Create HTTP failure
    let httpCreateFail _ = pure (Right (fakeResponse 422 "bad"))
    errCreate <-
      assertLeft "create fail"
        =<< createReleaseWithAssetHttpLbs httpCreateFail "tok" meta assetPath
    assertTrue "creating release" ("creating release" `T.isInfixOf` errCreate)

    -- Create ok, upload fails → DELETE best-effort
    delRef <- newIORef (0 :: Int)
    let httpUploadFail req = do
          case method req of
            "DELETE" -> do
              atomicModifyIORef' delRef (\n -> (n + 1, ()))
              pure (Right (fakeResponse 204 ""))
            "POST"
              | "releases" `BSC.isInfixOf` path req ->
                  pure (Right (fakeResponse 201 createBody))
            "POST" -> pure (Right (fakeResponse 500 "upload boom"))
            _ -> pure (Right (fakeResponse 500 "unexpected"))
    errUp <-
      assertLeft "upload fail"
        =<< createReleaseWithAssetHttpLbs httpUploadFail "tok" meta assetPath
    assertTrue "upload msg" ("uploading release asset" `T.isInfixOf` errUp)
    deletes <- readIORef delRef
    assertEq "best-effort delete" 1 deletes

    -- Create network error
    let httpNet _ = pure (Left "create net")
    errNet <-
      assertLeft "create net"
        =<< createReleaseWithAssetHttpLbs httpNet "tok" meta assetPath
    assertEq "net" "create net" errNet

-- | Dual-arch Go ceilings helper for tests.
