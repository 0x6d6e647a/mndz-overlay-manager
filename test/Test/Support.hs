{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Support
  ( dualArchGoCeilings,
    mkTestApplyEnv,
    writeMatchingCacheFile,
    writeMatchingCachesForPackage,
    mockEgencacheWriteMatching,
    unusedVendorOps,
    unusedReleaseOps,
  )
where

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

-- | Dual-arch Go ceilings helper for tests.
dualArchGoCeilings :: Maybe T.Text -> Maybe T.Text -> RuntimeCeilings
dualArchGoCeilings plainTok tildeTok =
  let plain = parseEbuildVersion <$> plainTok
      tilde = parseEbuildVersion <$> tildeTok
      ac = ArchCeilings {acPlain = plain, acTilde = tilde}
   in RuntimeCeilings
        { rcAtom = "dev-lang/go",
          rcByArch = Map.fromList [("amd64", ac), ("arm64", ac)]
        }

-- | Minimal ApplyEnv for content-fix / unit-apply tests.

-- | Minimal ApplyEnv for content-fix / unit-apply tests.
mkTestApplyEnv ::
  GitOps ->
  PlanOps ->
  EbuildRunner ->
  ReleaseOps ->
  VendorOps ->
  Maybe FilePath ->
  MVar () ->
  MVar () ->
  IO ApplyEnv
mkTestApplyEnv gitOps planOps ebuildRun releaseOps vendorOps assetsRoot assetsLock overlayLock = do
  depsBase <- productionDepsPlanOps (Just "tok") 1 Nothing
  let depsOps =
        depsBase
          { dpoPortageq = poPortageq planOps,
            dpoListVersions = poListVersions planOps,
            dpoFetchGoMod = poFetchGoMod planOps,
            dpoWorkBudget = poWorkBudget planOps,
            dpoGoCeilingsCache = poCeilingsCache planOps
          }
  pure
    ApplyEnv
      { aeFetcher = \_ -> pure (Left "unused"),
        aeGitOps = gitOps,
        aeEbuildRunner = ebuildRun,
        aeEgencacheRunner = mockEgencacheWriteMatching,
        aeVendorOps = vendorOps,
        aeNpmCacheOps = productionNpmCacheOps,
        aeBunCacheOps = productionBunCacheOps,
        aeCargoOps = productionCargoOps,
        aeReleaseOps = releaseOps,
        aeAssetsRoot = assetsRoot,
        aeGitHubToken = Just "tok",
        aeAssetsOwner = "0x6d6e647a",
        aeAssetsRepo = "mndz-overlay-assets",
        aeAssetsLock = assetsLock,
        aeOverlayLock = overlayLock,
        aeJobs = 1,
        aeMulti = noopMultiHandle,
        aePlanOps = planOps,
        aeDepsPlanOps = depsOps
      }

-- | Write a matching md5-dict cache file for one ebuild.

-- | Write a matching md5-dict cache file for one ebuild.
writeMatchingCacheFile :: FilePath -> T.Text -> T.Text -> T.Text -> FilePath -> IO ()
writeMatchingCacheFile overlayRoot category pn verText ebuildPath = do
  md5 <- ebuildFileMd5 ebuildPath
  let cpath = cacheFilePath overlayRoot category pn verText
  createDirectoryIfMissing True (takeDirectory cpath)
  TIO.writeFile cpath ("_md5_=" <> md5 <> "\nDESCRIPTION=test\n")

-- | Matching cache for every non-live ebuild under a package directory.

-- | Matching cache for every non-live ebuild under a package directory.
writeMatchingCachesForPackage :: FilePath -> T.Text -> T.Text -> FilePath -> IO ()
writeMatchingCachesForPackage overlayRoot category pn pkgDir = do
  vers <- listNonLiveEbuildVersions pkgDir pn
  mapM_ (uncurry (writeMatchingCacheFile overlayRoot category pn)) vers

-- | Mock egencache: rewrite matching cache entries for requested atoms.

-- | Mock egencache: rewrite matching cache entries for requested atoms.
mockEgencacheWriteMatching :: EgencacheRequest -> IO (Either T.Text ())
mockEgencacheWriteMatching req = do
  let root = erOverlayRoot req
      atoms =
        if null (erAtoms req)
          then []
          else erAtoms req
  if null atoms
    then pure (Right ())
    else do
      mapM_
        ( \atom ->
            case T.breakOn "/" atom of
              (cat, rest)
                | Just ('/', pn) <- T.uncons rest -> do
                    let pkgDir = root </> T.unpack cat </> T.unpack pn
                    writeMatchingCachesForPackage root cat pn pkgDir
                | otherwise -> pure ()
        )
        atoms
      pure (Right ())

unusedVendorOps :: VendorOps
unusedVendorOps =
  VendorOps
    { voClone = \_ _ _ -> pure (Left "unused"),
      voHostGoVersion = pure (Right "1.26.5"),
      voGoModDownload = \_ -> pure (Left "unused"),
      voTarXz = \_ _ _ -> pure (Left "unused")
    }

unusedReleaseOps :: ReleaseOps
unusedReleaseOps =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "unused"),
      roCreateReleaseWithAsset = \_ _ -> pure (Left "unused")
    }
