{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Apply (unitTests, integrationTests) where

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
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
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
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Support
  ( dualArchGoCeilings,
    mkTestApplyEnv,
    unusedReleaseOps,
    unusedVendorOps,
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
    ReleaseOps (..),
    findAssetByName,
    lookupNamedAsset,
    parseReleaseInfo,
  )
import Update.Auth (resolveGitHubTokenWith)
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

-- | Single-concern helpers (pure apply math / vendor event order).
unitTests :: TestTree
unitTests =
  testGroup
    "Apply"
    [ testCase "New Ebuild File Name" testNewEbuildFileName,
      testCase "Fold Exit Hard Fail" testFoldExitHardFail,
      testCase "Mark Success Lines Reused" testMarkSuccessLinesReused,
      testCase "Vendor Progress Event Order" testVendorProgressEventOrder,
      testCase "Materialize Step Budget" testMaterializeStepBudget,
      testCase "Bdepend Mismatch Needs Fix" testBdependMismatchNeedsFix,
      testCase "Bdepend Missing Needs Fix" testBdependMissingNeedsFix
    ]

-- | Multi-module apply/plan/commit spine with ApplyEnv / PlanOps / temp overlays.
integrationTests :: TestTree
integrationTests =
  testGroup
    "Apply"
    [ testCase "Content Fix Manifest" testContentFixManifest,
      testCase "Reuse Vs Full Publish" testReuseVsFullPublish,
      testCase "Git Mv Commits On Success" testGitMvCommitsOnSuccess,
      testCase "Go Multi Pv Sequential Commits" testGoMultiPvSequentialCommits,
      testCase "Go Multi Pv Stop On Hard Fail" testGoMultiPvStopOnHardFail,
      testCase "Full Path Apply Progress Sequence" testFullPathApplyProgressSequence,
      testCase "Reuse Path Apply Progress Sequence" testReusePathApplyProgressSequence,
      testCase "Overlay Commit Lock" testOverlayCommitLock
    ]

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
                       slLabel = Nothing,
                       slAssetsReused = False
                     }
                 ]
                 ["g/h/g-h-1.1.ebuild"]
             ]
  assertEq "soft only" False (foldExitHardFail soft)
  assertEq "mixed" True (foldExitHardFail mixed)

testContentFixManifest :: IO ()
testContentFixManifest =
  withSystemTempDirectory "mndz-content-fix-" $ \tmp -> do
    let pkgDir = tmp </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        plan =
          RuntimeLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild
                    { pePV = pv,
                      peKeywords = ["~amd64"],
                      peLanes = []
                    }
                ],
              glpUniquePVs = [pv],
              glpRuntimeAtom = "dev-lang/go"
            }
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused budget",
              poCeilingsCache = error "unused ceilings"
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps' =
          planOps
            { poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
    env <-
      mkTestApplyEnv
        gitOps
        planOps'
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    -- No Manifest → needs work
    fix1 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "missing Manifest needs work" [pv] fix1
    -- Manifest without vendor DIST → needs work
    TIO.writeFile (pkgDir </> "Manifest") "DIST crush-0.84.0.tar.gz 1 SHA512 deadbeef\n"
    fix2 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "missing vendor DIST needs work" [pv] fix2
    -- Complete Manifest + good ebuild → no content fix
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST crush-0.84.0-vendor.tar.xz 123 BLAKE2B aa SHA512 abcdef0123456789\n"
    fix3 <- contentFixNeeded env "charmbracelet" "crush" "v" Nothing pkgDir pn plan
    assertEq "complete Manifest no content fix" [] fix3
    assertTrue
      "ebuild content ok"
      ( not
          ( ebuildNeedsContentFix
              ["~amd64"]
              ebuildBody
              (Just "1.26.5")
          )
      )

testMarkSuccessLinesReused :: IO ()
testMarkSuccessLinesReused = do
  let sl =
        SuccessLine
          { slFrom = parseEbuildVersion "0.80.0",
            slTo = parseEbuildVersion "0.84.0",
            slLabel = Just "(dev-lang/go ~amd64)",
            slAssetsReused = False
          }
      marked = markSuccessLinesReused [sl]
  assertEq "flag set" True (all slAssetsReused marked)
  case marked of
    (m : _) -> assertEq "from preserved" (slFrom sl) (slFrom m)
    [] -> do
      hPutStrLn stderr "expected non-empty marked success lines"
      exitFailure

testReuseVsFullPublish :: IO ()
testReuseVsFullPublish =
  withSystemTempDirectory "mndz-reuse-pub-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
    vendorCallRef <- newIORef (0 :: Int)
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    -- Seed a known asset body for download + Manifest hash match.
    let assetBytes = encodeUtf8 "vendor-tarball-bytes-for-reuse-test"
        digests0 = hashBytes assetBytes
        ebuildRunnerWrong _pkg _name = do
          -- Write Manifest with wrong SHA512 to force hard-fail path later.
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> ("0" <> T.replicate 127 "1")
                <> "\n"
            )
          pure (Right ())
        ebuildRunnerOk _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ ->
                pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused budget",
              poCeilingsCache = error "unused ceilings"
            }
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    let planOps' =
          planOps
            { poWorkBudget = budget,
              poCeilingsCache = ceilingsCache
            }
        vendorOps =
          VendorOps
            { voClone = \_ _ _ -> do
                atomicModifyIORef' vendorCallRef (\n -> (n + 1, ()))
                pure (Left "vendor should not run on reuse"),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Left "vendor should not run on reuse"),
              voTarXz = \_ _ _ -> pure (Left "vendor should not run on reuse")
            }
        -- Partially applied: locks supplied at call sites.
        mkEnv releaseOps ebuildRun =
          mkTestApplyEnv
            gitOps
            planOps'
            ebuildRun
            releaseOps
            vendorOps
            (Just assetsRoot)
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
        releaseFound =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = "crush-0.84.0",
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack tarballName,
                                  raBrowserDownloadUrl = "https://example/vendor"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
        releaseMissing =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
              roDownloadAsset = \_ _ -> pure (Left "should not download"),
              roCreateReleaseWithAsset = \_ _ -> pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    -- Reuse path: no vendor calls; success with assets reused; Manifest matches.
    writeIORef vendorCallRef 0
    stepsDoneReuse <- newIORef (0 :: Int)
    envReuse <- mkEnv releaseFound ebuildRunnerOk assetsLock overlayLock
    outcomeReuse <-
      goPublishAndOverlay
        envReuse
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneReuse
        1
    case outcomeReuse of
      ApplySuccess _ sls _ -> do
        assertTrue "reuse marks lines" (all slAssetsReused sls)
        n <- readIORef vendorCallRef
        assertEq "reuse skips vendor" 0 n
      other -> do
        hPutStrLn stderr ("expected reuse success, got: " <> show other)
        exitFailure
    -- Manifest mismatch hard-fails on reuse.
    stepsDoneBad <- newIORef (0 :: Int)
    envBad <- mkEnv releaseFound ebuildRunnerWrong assetsLock overlayLock
    outcomeBad <-
      goPublishAndOverlay
        envBad
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneBad
        1
    case outcomeBad of
      ApplyHardFail _ msg _ _ ->
        assertTrue
          "manifest mismatch message"
          ("Manifest SHA512" `T.isInfixOf` msg)
      other -> do
        hPutStrLn stderr ("expected hard fail, got: " <> show other)
        exitFailure
    -- Not-found → full path (vendor called). Use lock for full path.
    let vendorOpsFull =
          VendorOps
            { voClone = \_ _ dest -> do
                atomicModifyIORef' vendorCallRef (\n -> (n + 1, ()))
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                BS.writeFile outPath assetBytes
                pure (Right ())
            }
    writeIORef vendorCallRef 0
    stepsDoneFull <- newIORef (0 :: Int)
    envFull0 <- mkEnv releaseMissing ebuildRunnerOk assetsLock overlayLock
    let envFull = envFull0 {aeVendorOps = vendorOpsFull}
    _ <-
      goPublishAndOverlay
        envFull
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDoneFull
        1
    nFull <- readIORef vendorCallRef
    assertTrue "not-found uses full vendor path" (nFull > 0)

-- | GitMv success signs/commits before returning ApplySuccess (no barrier).

-- | GitMv success signs/commits before returning ApplySuccess (no barrier).
testGitMvCommitsOnSuccess :: IO ()
testGitMvCommitsOnSuccess =
  withSystemTempDirectory "mndz-gitmv-commit-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        pkgDir = overlayRoot </> "dev-util" </> "grok-build-bin"
        oldName = "grok-build-bin-0.2.99.ebuild"
        local = parseEbuildVersion "0.2.99"
        remote = parseEbuildVersion "0.2.101"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "grok-build-bin",
              pePN = "grok-build-bin",
              peLocal = local,
              pePath = pkgDir </> oldName
            }
    commitCount <- newIORef (0 :: Int)
    commitMsgs <- newIORef ([] :: [T.Text])
    commitPaths <- newIORef ([] :: [[FilePath]])
    createDirectoryIfMissing True pkgDir
    TIO.writeFile (pkgDir </> oldName) "EAPI=8\n"
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage
      overlayRoot
      "dev-util"
      "grok-build-bin"
      pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_root paths msg -> do
                atomicModifyIORef' commitCount (\n -> (n + 1, ()))
                atomicModifyIORef' commitMsgs (\ms -> (msg : ms, ()))
                atomicModifyIORef' commitPaths (\ps -> (paths : ps, ()))
                assertTrue "stages paths" (not (null paths))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg name = do
          -- Simulate ebuild manifest creating Manifest after rename.
          TIO.writeFile (pkgDir </> "Manifest") ("DIST " <> T.pack name <> " 1\n")
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Left "unused"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 1
    ceilingsCache <- newMVar Nothing
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        unusedReleaseOps
        unusedVendorOps
        Nothing
        assetsLock
        overlayLock
    let env = env0 {aeFetcher = \_ -> pure (Right remote)}
    outcomes <- applyPackagePhase1 env overlayRoot entry
    case outcomes of
      [ApplySuccess _ _ paths] -> do
        n <- readIORef commitCount
        assertEq "exactly one signed commit" 1 n
        msgs <- readIORef commitMsgs
        assertTrue
          "commit message format"
          ("dev-util/grok-build-bin: 0.2.101" `elem` msgs)
        assertTrue "paths recorded" (not (null paths))
        assertTrue
          "commit includes md5-cache path"
          (any (("md5-cache" `T.isInfixOf`) . T.pack) paths)
      other -> do
        hPutStrLn stderr ("expected single ApplySuccess, got: " <> show other)
        exitFailure

-- | Two Go PVs: commit after first; second dirty check sees clean tree; two commits.

-- | Two Go PVs: commit after first; second dirty check sees clean tree; two commits.
testGoMultiPvSequentialCommits :: IO ()
testGoMultiPvSequentialCommits =
  withSystemTempDirectory "mndz-multi-pv-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        pv1 = parseEbuildVersion "0.82.0"
        pv2 = parseEbuildVersion "0.84.0"
        tip = parseEbuildVersion "0.80.0"
        ebuildBody goAtom =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\"" <> goAtom <> "\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = tip,
              pePath = pkgDir </> "crush-0.80.0.ebuild"
            }
        plan =
          RuntimeLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild {pePV = pv1, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv2, peKeywords = ["~amd64"], peLanes = []}
                ],
              -- Include tip so prune does not add a third commit in this test.
              glpUniquePVs = [tip, pv1, pv2],
              glpRuntimeAtom = "dev-lang/go"
            }
        assetBytes = encodeUtf8 "vendor-bytes-multi-pv"
        digests0 = hashBytes assetBytes
    commitMsgs <- newIORef ([] :: [T.Text])
    -- After each commit, paths are clean (simulate HEAD includes them).
    dirtyPaths <- newIORef ([] :: [FilePath])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> "crush-0.80.0.ebuild") (ebuildBody ">=dev-lang/go-1.26.5:=")
    TIO.writeFile (pkgDir </> "Manifest") "DIST crush-0.80.0.tar.gz 1 SHA512 aa\n"
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ paths -> do
                dirty <- readIORef dirtyPaths
                pure (Right (any (`elem` dirty) paths)),
              goAddAndCommit = \_root paths msg -> do
                atomicModifyIORef' commitMsgs (\ms -> (msg : ms, ()))
                -- Commit clears dirt for those paths.
                modifyIORef' dirtyPaths (filter (`notElem` paths))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg name = do
          let tarball =
                if "0.82.0" `T.isInfixOf` T.pack name
                  then "crush-0.82.0-vendor.tar.xz"
                  else "crush-0.84.0-vendor.tar.xz"
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarball
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          -- Mutating Manifest dirties it until commit.
          atomicModifyIORef'
            dirtyPaths
            (\d -> (nub ("dev-util/crush/Manifest" : d), ()))
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ tag ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = tag,
                          riAssets =
                            [ ReleaseAsset
                                { raName =
                                    if "0.82.0" `T.isInfixOf` tag
                                      then "crush-0.82.0-vendor.tar.xz"
                                      else "crush-0.84.0-vendor.tar.xz",
                                  raBrowserDownloadUrl = "https://example/v"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    env <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    outcomes <-
      materializePlan
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        plan
        [tip]
        [] -- contentFix empty; missing targets drive need
        0
    let successes = [o | o@ApplySuccess {} <- outcomes]
    assertEq "two PV successes" 2 (length successes)
    msgs <- reverse <$> readIORef commitMsgs
    assertEq "two overlay commits" 2 (length msgs)
    assertTrue
      "first PV commit"
      ("dev-util/crush: 0.82.0" `elem` msgs)
    assertTrue
      "second PV commit"
      ("dev-util/crush: 0.84.0" `elem` msgs)
    assertTrue
      "PV commits include md5-cache"
      ( all
          ( \case
              ApplySuccess _ _ paths ->
                any (("md5-cache" `T.isInfixOf`) . T.pack) paths
              _ -> False
          )
          successes
      )

-- | First PV commits; second hard-fails; no prune; later PVs not started.

-- | First PV commits; second hard-fails; no prune; later PVs not started.
testGoMultiPvStopOnHardFail :: IO ()
testGoMultiPvStopOnHardFail =
  withSystemTempDirectory "mndz-multi-pv-fail-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        pv1 = parseEbuildVersion "0.82.0"
        pv2 = parseEbuildVersion "0.84.0"
        pv3 = parseEbuildVersion "0.86.0"
        tip = parseEbuildVersion "0.80.0"
        extraName = "crush-0.70.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = tip,
              pePath = pkgDir </> "crush-0.80.0.ebuild"
            }
        plan =
          RuntimeLanePlan
            { glpLanes = [],
              glpEbuilds =
                [ PlannedEbuild {pePV = pv1, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv2, peKeywords = ["~amd64"], peLanes = []},
                  PlannedEbuild {pePV = pv3, peKeywords = ["~amd64"], peLanes = []}
                ],
              glpUniquePVs = [pv1, pv2, pv3],
              glpRuntimeAtom = "dev-lang/go"
            }
        assetBytes = encodeUtf8 "vendor-bytes-fail-test"
        digests0 = hashBytes assetBytes
    commitCount <- newIORef (0 :: Int)
    materializeCount <- newIORef (0 :: Int)
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> "crush-0.80.0.ebuild") ebuildBody
    TIO.writeFile (pkgDir </> extraName) ebuildBody -- would be pruned only on full success
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    let gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> do
                atomicModifyIORef' commitCount (\n -> (n + 1, ()))
                pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          atomicModifyIORef' materializeCount (\n -> (n + 1, ()))
          n <- readIORef materializeCount
          if n >= 2
            then pure (Left "simulated ebuild manifest failure")
            else do
              TIO.writeFile
                (pkgDir </> "Manifest")
                ( "DIST crush-0.82.0-vendor.tar.xz 1 SHA512 "
                    <> digestSHA512 digests0
                    <> "\n"
                )
              pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ tag ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = tag,
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack (T.unpack tag <> "-vendor.tar.xz"),
                                  raBrowserDownloadUrl = "https://example/v"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    env <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    outcomes <-
      materializePlan
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        plan
        [tip]
        []
        0
    let successes = [o | o@ApplySuccess {} <- outcomes]
        fails = [o | o@ApplyHardFail {} <- outcomes]
    assertEq "one success retained" 1 (length successes)
    assertEq "one hard fail" 1 (length fails)
    nMat <- readIORef materializeCount
    assertEq "stopped after second PV (no third)" 2 nMat
    nCommit <- readIORef commitCount
    assertEq "only first PV committed (no prune commit)" 1 nCommit
    -- Extra ebuild still present (prune not run).
    extraExists <- doesFileExist (pkgDir </> extraName)
    assertTrue "prune not run" extraExists

-- | Vendor progress fires clone → download → compress start/done in order.

-- | Vendor progress fires clone → download → compress start/done in order.
testVendorProgressEventOrder :: IO ()
testVendorProgressEventOrder =
  withSystemTempDirectory "mndz-vendor-progress-" $ \outDir -> do
    events <- newIORef ([] :: [T.Text])
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        progress =
          VendorProgress
            { vpOnCloneStart = logEv "clone-start",
              vpOnCloneDone = logEv "clone-done",
              vpOnDownloadStart = logEv "download-start",
              vpOnDownloadDone = logEv "download-done",
              vpOnCompressStart = logEv "compress-start",
              vpOnCompressDone = logEv "compress-done"
            }
        ops =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                writeFile outPath "fake-tarball"
                pure (Right ())
            }
    result <-
      buildVendorTarball
        ops
        progress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor.tar.xz"
    case result of
      Left err -> do
        hPutStrLn stderr ("expected vendor success, got: " <> T.unpack err)
        exitFailure
      Right _ -> pure ()
    evs <- reverse <$> readIORef events
    assertEq
      "vendor progress order"
      [ "clone-start",
        "clone-done",
        "download-start",
        "download-done",
        "compress-start",
        "compress-done"
      ]
      evs
    -- No-op progress still succeeds.
    void $
      buildVendorTarball
        ops
        noopVendorProgress
        "o"
        "r"
        "v"
        "0.1.0"
        Nothing
        outDir
        "pkg-0.1.0-vendor-noop.tar.xz"

-- | Full-path apply advances fine-grained status/step events in order.

-- | Full-path apply advances fine-grained status/step events in order.
testFullPathApplyProgressSequence :: IO ()
testFullPathApplyProgressSequence =
  withSystemTempDirectory "mndz-full-progress-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        assetBytes = encodeUtf8 "vendor-tarball-bytes-for-full-progress"
        digests0 = hashBytes assetBytes
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
    events <- newIORef ([] :: [T.Text])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "app-misc" pn pkgDir
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        mh =
          MultiHandle
            { mhStart = \_ -> pure (),
              mhStatus = \_ name -> logEv ("status:" <> name),
              mhSteps = \_ n -> logEv ("steps:" <> T.pack (show n)),
              mhStep = \_ name -> logEv ("step:" <> name),
              mhSuccess = \_ -> pure (),
              mhSkip = \_ _ -> pure (),
              mhFail = \_ _ -> pure ()
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
              roDownloadAsset = \_ _ -> pure (Left "should not download"),
              roCreateReleaseWithAsset = \_ _ -> pure (Right ())
            }
        vendorOps =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_goDir _entry outPath -> do
                BS.writeFile outPath assetBytes
                pure (Right ())
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    stepsDone <- newIORef (0 :: Int)
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        vendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    let env = env0 {aeMulti = mh}
    outcome <-
      goPublishAndOverlay
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDone
        1
    case outcome of
      ApplySuccess {} -> pure ()
      other -> do
        hPutStrLn stderr ("expected full-path success, got: " <> show other)
        exitFailure
    evs <- reverse <$> readIORef events
    let statuses = [e | e <- evs, "status:" `T.isPrefixOf` e]
        steps = [e | e <- evs, "step:" `T.isPrefixOf` e]
    assertEq
      "full-path status sequence"
      [ "status:probing release asset",
        "status:cloning upstream",
        "status:go mod download",
        "status:compressing tarball",
        "status:committing assets",
        "status:pushing assets",
        "status:uploading release asset",
        "status:regenerating manifest"
      ]
      statuses
    assertEq
      "full-path step sequence"
      [ "step:cloning upstream",
        "step:go mod download",
        "step:compressing tarball",
        "step:committing assets",
        "step:pushing assets",
        "step:uploading release asset",
        "step:regenerating manifest"
      ]
      steps
    assertTrue
      "no coarse vendoring label"
      (not (any ("vendoring" `T.isInfixOf`) evs))
    assertTrue
      "no coarse publishing assets label"
      (not (any ("publishing assets" `T.isInfixOf`) evs))
    done <- readIORef stepsDone
    assertEq "full path marks 7 steps done" fullPathMaterializeSteps done

-- | Reuse-path apply uses reuse step names only.

-- | Reuse-path apply uses reuse step names only.
testReusePathApplyProgressSequence :: IO ()
testReusePathApplyProgressSequence =
  withSystemTempDirectory "mndz-reuse-progress-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "app-misc" </> "crush"
        pn = "crush" :: T.Text
        pv = parseEbuildVersion "0.84.0"
        ebuildName = "crush-0.84.0.ebuild"
        ebuildBody =
          T.unlines
            [ "EAPI=8",
              "inherit go-module",
              "BDEPEND=\">=dev-lang/go-1.26.5:=\"",
              "KEYWORDS=\"~amd64\"",
              "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
              "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
            ]
        tarballName = vendorTarballName pn "0.84.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "app-misc" "crush",
              pePN = pn,
              peLocal = pv,
              pePath = pkgDir </> ebuildName
            }
        assetBytes = encodeUtf8 "vendor-tarball-bytes-for-reuse-progress"
        digests0 = hashBytes assetBytes
        lines_ =
          [ SuccessLine
              { slFrom = parseEbuildVersion "0.80.0",
                slTo = pv,
                slLabel = Just "(dev-lang/go ~amd64)",
                slAssetsReused = False
              }
          ]
    events <- newIORef ([] :: [T.Text])
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> ebuildName) ebuildBody
    TIO.writeFile (pkgDir </> "Manifest") "DIST x 1\n"
    writeMatchingCachesForPackage overlayRoot "app-misc" pn pkgDir
    let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
        mh =
          MultiHandle
            { mhStart = \_ -> pure (),
              mhStatus = \_ name -> logEv ("status:" <> name),
              mhSteps = \_ n -> logEv ("steps:" <> T.pack (show n)),
              mhStep = \_ name -> logEv ("step:" <> name),
              mhSuccess = \_ -> pure (),
              mhSkip = \_ _ -> pure (),
              mhFail = \_ _ -> pure ()
            }
        gitOps =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ())
            }
        ebuildRun _pkg _name = do
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> T.pack tarballName
                <> " 1 SHA512 "
                <> digestSHA512 digests0
                <> "\n"
            )
          pure (Right ())
        planOps =
          PlanOps
            { poPortageq = \_ -> pure (Left "unused"),
              poListVersions = \_ -> pure (Left "unused"),
              poFetchGoMod = \_ -> pure (Right "module x\ngo 1.26.5\n"),
              poWorkBudget = error "unused",
              poCeilingsCache = error "unused"
            }
        releaseOps =
          ReleaseOps
            { roGetReleaseByTag = \_ _ _ ->
                pure $
                  Right $
                    Just
                      ReleaseInfo
                        { riId = 1,
                          riTag = "crush-0.84.0",
                          riAssets =
                            [ ReleaseAsset
                                { raName = T.pack tarballName,
                                  raBrowserDownloadUrl = "https://example/vendor"
                                }
                            ]
                        },
              roDownloadAsset = \_url dest -> do
                BS.writeFile dest assetBytes
                pure (Right ()),
              roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
            }
    assetsLock <- newMVar ()
    overlayLock <- newMVar ()
    budget <- newWorkBudget 2
    ceilingsCache <- newMVar Nothing
    stepsDone <- newIORef (0 :: Int)
    env0 <-
      mkTestApplyEnv
        gitOps
        planOps {poWorkBudget = budget, poCeilingsCache = ceilingsCache}
        ebuildRun
        releaseOps
        unusedVendorOps
        (Just assetsRoot)
        assetsLock
        overlayLock
    let env = env0 {aeMulti = mh}
    outcome <-
      goPublishAndOverlay
        env
        overlayRoot
        entry
        "charmbracelet"
        "crush"
        "v"
        Nothing
        ["~amd64"]
        lines_
        pv
        stepsDone
        1
    case outcome of
      ApplySuccess _ sls _ ->
        assertTrue "reuse marks lines" (all slAssetsReused sls)
      other -> do
        hPutStrLn stderr ("expected reuse success, got: " <> show other)
        exitFailure
    evs <- reverse <$> readIORef events
    let statuses = [e | e <- evs, "status:" `T.isPrefixOf` e]
        steps = [e | e <- evs, "step:" `T.isPrefixOf` e]
        forbidden =
          [ "vendoring",
            "publishing assets",
            "cloning upstream",
            "go mod download",
            "compressing tarball",
            "committing assets",
            "pushing assets",
            "uploading release asset"
          ]
    assertEq
      "reuse status sequence"
      [ "status:probing release asset",
        "status:reusing release assets",
        "status:verifying vendor asset",
        "status:regenerating manifest"
      ]
      statuses
    assertEq
      "reuse step sequence"
      [ "step:reusing release assets",
        "step:verifying vendor asset",
        "step:regenerating manifest"
      ]
      steps
    assertTrue
      "no full-path / coarse names on reuse"
      (not (any (\bad -> any (bad `T.isInfixOf`) evs) forbidden))
    done <- readIORef stepsDone
    assertEq "reuse path marks 3 steps done" reusePathMaterializeSteps done

-- | Step-total upper bound and revise-after-probe math for full vs reuse.

-- | Step-total upper bound and revise-after-probe math for full vs reuse.
testMaterializeStepBudget :: IO ()
testMaterializeStepBudget = do
  assertEq "full path step count" 7 fullPathMaterializeSteps
  assertEq "reuse path step count" 3 reusePathMaterializeSteps
  assertEq
    "upper bound planDone=3 n=2"
    17
    (materializeStepTotalUpper 3 2)
  assertEq
    "single full path total"
    7
    (reviseMaterializeStepTotal 0 fullPathMaterializeSteps 0)
  assertEq
    "single reuse path total"
    3
    (reviseMaterializeStepTotal 0 reusePathMaterializeSteps 0)
  -- Mixed: planDone=3, first PV reuses (3), one PV remains at full upper bound.
  assertEq
    "reuse first of two"
    (3 + 3 + 7)
    (reviseMaterializeStepTotal 3 reusePathMaterializeSteps 1)
  -- After first full path (7), second reuses:
  assertEq
    "reuse second after full"
    (3 + 7 + 3)
    (reviseMaterializeStepTotal (3 + 7) reusePathMaterializeSteps 0)
  -- After first reuse (3), second full:
  assertEq
    "full second after reuse"
    (3 + 3 + 7)
    (reviseMaterializeStepTotal (3 + 3) fullPathMaterializeSteps 0)

-- | Concurrent overlay commits serialize under aeOverlayLock.

-- | Concurrent overlay commits serialize under aeOverlayLock.
testOverlayCommitLock :: IO ()
testOverlayCommitLock = do
  inCritical <- newIORef (0 :: Int)
  maxInCritical <- newIORef (0 :: Int)
  let gitOps =
        GitOps
          { goIsWorkTree = \_ -> pure True,
            goPathsDirty = \_ _ -> pure (Right False),
            goAddAndCommit = \_ _ _ -> do
              n <- atomicModifyIORef' inCritical (\x -> (x + 1, x + 1))
              atomicModifyIORef' maxInCritical (\m -> (max m n, ()))
              threadDelay 30_000
              atomicModifyIORef' inCritical (\x -> (x - 1, ()))
              pure (Right ()),
            goPush = \_ -> pure (Right ())
          }
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
  budget <- newWorkBudget 2
  ceilingsCache <- newMVar Nothing
  let planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Left "unused"),
            poFetchGoMod = \_ -> pure (Left "unused"),
            poWorkBudget = budget,
            poCeilingsCache = ceilingsCache
          }
  env <-
    mkTestApplyEnv
      gitOps
      planOps
      (\_ _ -> pure (Right ()))
      unusedReleaseOps
      unusedVendorOps
      Nothing
      assetsLock
      overlayLock
  _ <-
    mapConcurrently
      (signedOverlayCommit env "/tmp" ["a.ebuild"])
      ["msg-a" :: T.Text, "msg-b"]
  peak <- readIORef maxInCritical
  assertEq "no overlapping overlay critical section" 1 peak

-- | Presence of wrong-version go BDEPEND still needs content-fix.

-- | Presence of wrong-version go BDEPEND still needs content-fix.
testBdependMismatchNeedsFix :: IO ()
testBdependMismatchNeedsFix = do
  let body =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.24.11:=\"",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  assertTrue
    "presence alone does not satisfy"
    (ebuildHasDevLangGoBdepend body)
  assertTrue
    "mismatch needs fix"
    (ebuildNeedsContentFix ["~amd64"] body (Just "1.26.5"))
  assertTrue
    "matching does not need fix"
    ( not
        ( ebuildNeedsContentFix
            ["~amd64"]
            (T.replace "1.24.11" "1.26.5" body)
            (Just "1.26.5")
        )
    )
  assertTrue
    "goBdependMatches rejects wrong ver"
    (not (goBdependMatches "1.26.5" body))

-- | Missing BDEPEND with known go.mod still needs-work; ensureGoBdepend still works.

-- | Missing BDEPEND with known go.mod still needs-work; ensureGoBdepend still works.
testBdependMissingNeedsFix :: IO ()
testBdependMissingNeedsFix = do
  let body =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  assertTrue
    "missing needs fix"
    (ebuildNeedsContentFix ["~amd64"] body (Just "1.26.5"))
  inserted <- assertRight "insert" (ensureGoBdepend "1.26.5" body)
  assertTrue "matches after insert" (goBdependMatches "1.26.5" inserted)
  assertTrue
    "no longer needs fix"
    (not (ebuildNeedsContentFix ["~amd64"] inserted (Just "1.26.5")))
  let withOld =
        T.unlines
          [ "EAPI=8",
            "inherit go-module",
            "BDEPEND=\">=dev-lang/go-1.20:=\"",
            "KEYWORDS=\"~amd64\"",
            "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
          ]
  replaced <- assertRight "replace" (ensureGoBdepend "1.26.5" withOld)
  assertTrue "replace matches" (goBdependMatches "1.26.5" replaced)
