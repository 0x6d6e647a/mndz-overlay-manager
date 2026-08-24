{-# LANGUAGE OverloadedStrings #-}

-- | Fake-ops spine tests for overlay wait-edges (admit / re-plan / cascade).
module Test.Waves (integrationTests) where

import CLI.Jobs (newWorkBudget)
import CLI.Parser (ColorMode (..))
import CLI.Progress (ProgressConfig, mkProgressConfig)
import Colog (LogAction (..))
import Config.Types (CheckCacheTtl (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar
  ( modifyMVar_,
    newEmptyMVar,
    newMVar,
    putMVar,
    takeMVar,
  )
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Logging.Bootstrap (mkLogHold)
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion, parseEbuildVersion, prettyVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeBaseName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Assert (assertEq, assertTrue)
import Test.Support (mockEgencacheWriteMatching, writeMatchingCachesForPackage)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Assets.Hash (digestSHA512, hashBytes)
import Update.Assets.Layout (depsTarballName)
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseOps (..),
  )
import Update.Check (PackageEntry (..), groupNewest)
import Update.CheckCache
  ( computeFingerprintFromDir,
    lookupDeps,
    openCheckCache,
  )
import Update.Deps.Plan (DepsPlanOps (..))
import Update.DiskSpace (DiskSpaceProbe (..))
import Update.Git (GitOps (..))
import Update.Materialize (EnsureOutcome (..), NeededFloors (..))
import Update.Preflight (AssetsPreflight (..))
import Update.Spine
  ( UpdateSpineDeps (..),
    UpdateSpineResult (..),
    runUpdatePhases,
  )
import Update.SshAgent
  ( AgentIdentities (..),
    SshAgentOps (..),
  )
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource (..),
    mkPackageKey,
  )

integrationTests :: TestTree
integrationTests =
  testGroup
    "Waves"
    [ testCase
        "bun-bin hard-fail cascades to ralph"
        testProviderHardFailCascade,
      testCase
        "jobs=1 bun-bin runs while ralph waits"
        testJobs1BunBinWhileRalphWaits,
      testCase
        "t0 skip then re-plan; docker fail keeps bun-bin commit"
        testReplanDockerFailKeepsCommit,
      testCase
        "same-run bun-bin commit then ralph higher PV"
        testSameRunBunThenRalph,
      testCase
        "GitMv-only never calls image ensure"
        testGitMvOnlyNeverEnsure,
      testCase
        "reuse-only never calls image ensure"
        testReuseOnlyNeverEnsure,
      testCase
        "re-entry ensure after bun-bin; failed ensure keeps commit"
        testFailedReEnsureKeepsCommit,
      testCase
        "second ensure after bun-bin commit"
        testSecondEnsureAfterBunBin,
      testCase
        "leftover bun-bin dirt fails update dolt without ensure"
        testDirtyBunBinFailsUpdateDolt,
      testCase
        "dirty selected package fails before mutate"
        testDirtySelectedPackageFails,
      testCase
        "overlay-root README dirt does not fail"
        testOverlayRootDirtOk,
      testCase
        "ensure waits for bun-bin Manifest"
        testEnsureWaitsForBunBinManifest,
      testCase
        "grok-build-bin may overlap ensure"
        testGrokBuildBinOverlapsEnsure,
      testCase
        "t0 ensure bun floor is hypo remote"
        testT0EnsureHypoBunFloor,
      testCase
        "safety-assert mismatch hard-fails ralph"
        testSafetyAssertMismatch,
      testCase
        "hypo ralph plan is not cached under old bun-bin fingerprint"
        testHypoPlanNotCachedUnderOldBunBin
    ]

------------------------------------------------------------------------
-- Shared fakes
------------------------------------------------------------------------

plentyDisk :: DiskSpaceProbe
plentyDisk =
  DiskSpaceProbe
    { dspFreeBytes = \_ -> pure (Right (100 * 1024 * 1024 * 1024)),
      dspDeviceId = \_ -> pure (Right 1)
    }

sshOk :: SshAgentOps
sshOk =
  SshAgentOps
    { saoLookupEnv = \k ->
        pure $
          if k == "SSH_AUTH_SOCK"
            then Just "/tmp/fake-ssh"
            else Nothing,
      saoSetEnv = \_ _ -> pure (),
      saoUnsetEnv = \_ -> pure (),
      saoRunAgent = pure (Left "should not start"),
      saoSshAdd = pure (Left "should not add"),
      saoListIdentities = pure HasIdentities,
      saoKillAgent = \_ -> pure ()
    }

cleanGit :: GitOps
cleanGit =
  GitOps
    { goIsWorkTree = \_ -> pure True,
      goPathsDirty = \_ _ -> pure (Right False),
      goAddAndCommit = \_ _ _ -> pure (Right ()),
      goPush = \_ -> pure (Right ())
    }

fakeEbuildRun :: FilePath -> FilePath -> IO (Either T.Text ())
fakeEbuildRun pkgDir name = do
  TIO.writeFile (pkgDir </> "Manifest") ("DIST " <> T.pack name <> " 1\n")
  pure (Right ())

preflightNoDocker :: AssetsPreflight -> IO (Either T.Text ())
preflightNoDocker ap
  | apNeedDocker ap = pure (Left "docker missing at re-entry")
  | otherwise = pure (Right ())

preflightOk :: AssetsPreflight -> IO (Either T.Text ())
preflightOk _ = pure (Right ())

disabledProgress :: IO ProgressConfig
disabledProgress = do
  hold <- mkLogHold
  mkProgressConfig False ColorOff hold (LogAction (\_ -> pure ()))

bunEngines ::
  T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)
bunEngines _o _r _p pv =
  pure $
    Right $
      case pv of
        "1.0.0" -> "1.1.0"
        "1.5.0" -> "1.2.0"
        _ -> "1.0.0"

listRalphAndBun :: UpdateSource -> IO (Either T.Text [EbuildVersion])
listRalphAndBun src = case src of
  GitHub "subsy" "ralph-tui" _ ->
    pure (Right (map parseEbuildVersion ["1.5.0", "1.0.0"]))
  _ -> pure (Right [parseEbuildVersion "1.0.0"])

liveBunOps :: FilePath -> IO DepsPlanOps
liveBunOps overlay = do
  base <-
    mkWavePlanOps
      listRalphAndBun
      bunEngines
      overlay
  modifyMVar_ (dpoBunCeilingsCache base) (\_ -> pure Nothing)
  pure base

mkWavePlanOps ::
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  FilePath ->
  IO DepsPlanOps
mkWavePlanOps listVers fetchBun overlay = do
  mgr <- newManager tlsManagerSettings
  budget <- newWorkBudget 2
  goCache <- newMVar Nothing
  nodeCache <- newMVar Nothing
  bunCache <- newMVar Nothing
  rustCache <- newMVar Nothing
  sbclCache <- newMVar Nothing
  pure
    DepsPlanOps
      { dpoPortageq = \_ -> pure (Left "portageq unused"),
        dpoListVersions = listVers,
        dpoFetchGoMod = \_ -> pure (Left "go.mod unused"),
        dpoFetchNpmEngines = \_ _ -> pure (Left "npm unused"),
        dpoFetchBunEngines = fetchBun,
        dpoFetchCargoToml = \_ _ _ _ _ -> pure (Left "cargo unused"),
        dpoFetchSbclVersion = \_ _ _ _ -> pure (Left "sbcl unused"),
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoSbclCeilingsCache = sbclCache,
        dpoOverlayRoot = Just overlay,
        dpoManager = mgr
      }

initGitDir :: FilePath -> IO ()
initGitDir dir = do
  createDirectoryIfMissing True dir
  callProcess "git" ["init", "-q", dir]

seedBunBin :: FilePath -> T.Text -> IO FilePath
seedBunBin overlay ver = do
  let pkgDir = overlay </> "dev-lang" </> "bun-bin"
      name = "bun-bin-" <> T.unpack ver <> ".ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> name)
    "EAPI=8\nKEYWORDS=\"~amd64 ~arm64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST bun 1\n"
  writeMatchingCachesForPackage overlay "dev-lang" "bun-bin" pkgDir
  pure (pkgDir </> name)

ralphEbuildBody :: T.Text
ralphEbuildBody =
  T.unlines
    [ "EAPI=8",
      "KEYWORDS=\"~amd64 ~arm64\"",
      "BDEPEND=\">=dev-lang/bun-bin-1.1.0\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/ralph-tui-${PV}/ralph-tui-${PV}-deps.tar.xz\""
    ]

seedRalph :: FilePath -> IO FilePath
seedRalph overlay = do
  let pkgDir = overlay </> "dev-util" </> "ralph-tui"
      pn = "ralph-tui" :: T.Text
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> "ralph-tui-1.0.0.ebuild") ralphEbuildBody
  TIO.writeFile
    (pkgDir </> "Manifest")
    ("DIST " <> T.pack (depsTarballName pn "1.0.0") <> " 1 SHA512 deadbeef\n")
  writeMatchingCachesForPackage overlay "dev-util" pn pkgDir
  pure (pkgDir </> "ralph-tui-1.0.0.ebuild")

bunAssetBytes :: BS.ByteString
bunAssetBytes = encodeUtf8 "bun-deps-tarball-bytes"

releaseMissing :: ReleaseOps
releaseMissing =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "should not download"),
      roCreateReleaseWithAssets = \_ _ -> pure (Right ())
    }

releaseRalphReuse :: ReleaseOps
releaseRalphReuse =
  let kind = "-deps.tar.xz"
   in ReleaseOps
        { roGetReleaseByTag = \_ _ tag ->
            pure $
              Right $
                Just
                  ReleaseInfo
                    { riId = 1,
                      riTag = tag,
                      riAssets =
                        [ ReleaseAsset
                            { raName = tag <> kind,
                              raBrowserDownloadUrl = "https://example/" <> tag,
                              raSize = Just 32
                            }
                        ]
                    },
          roDownloadAsset = \_url dest -> do
            BS.writeFile dest bunAssetBytes
            pure (Right ()),
          roCreateReleaseWithAssets = \_ _ -> pure (Left "should not create")
        }

mkEntries :: FilePath -> FilePath -> ([PackageEntry], [Ebuild])
mkEntries bunPath ralphPath =
  let ebuilds =
        [ Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath,
          Ebuild "dev-util" "ralph-tui" "1.0.0" ralphPath
        ]
   in (groupNewest ebuilds, ebuilds)

fetchBunLatest :: UpdateSource -> IO (Either T.Text EbuildVersion)
fetchBunLatest src = case src of
  GitHub "oven-sh" "bun" _ ->
    pure (Right (parseEbuildVersion "1.2.0"))
  _ -> pure (Left "unexpected fetch")

baseSpine ::
  FilePath ->
  FilePath ->
  FilePath ->
  GitOps ->
  ReleaseOps ->
  Int ->
  (AssetsPreflight -> IO (Either T.Text ())) ->
  IO UpdateSpineDeps
baseSpine overlay assets dist gitOps releaseOps jobs preflight = do
  pcfg <- disabledProgress
  (cache, _) <- openCheckCache CacheDisabled False overlay
  depsOps <- liveBunOps overlay
  pure
    UpdateSpineDeps
      { usdJobs = jobs,
        usdProgress = pcfg,
        usdFetcher = fetchBunLatest,
        usdDepsPlanOps = depsOps,
        usdReleaseOps = releaseOps,
        usdDiskProbe = plentyDisk,
        usdGitOps = gitOps,
        usdCheckCache = cache,
        usdAssetsOwner = "0x6d6e647a",
        usdAssetsRepo = "mndz-overlay-assets",
        usdGitHubToken = Just "tok",
        usdAssetsPathCfg = Just assets,
        usdDistDir = dist,
        usdOverlayRoot = overlay,
        usdSshOps = sshOk,
        usdEbuildRunner = fakeEbuildRun,
        usdEgencacheRunner = mockEgencacheWriteMatching,
        usdPreflightTools = preflight,
        usdEnsureImage = \_ -> pure (Right EnsureSkipped),
        usdPruneMaterialize = pure ()
      }

outcomeKey :: ApplyOutcome -> PackageKey
outcomeKey = \case
  ApplySuccess k _ _ -> k
  ApplySoftSkip k _ -> k
  ApplyHardFail k _ _ _ -> k

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

testProviderHardFailCascade :: IO ()
testProviderHardFailCascade =
  withSystemTempDirectory "om-wave-cascade" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let failBunManifest pkgDir name =
          if "bun-bin" `T.isInfixOf` T.pack name
            then pure (Left "bun-bin manifest failed")
            else fakeEbuildRun pkgDir name
        (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightNoDocker
    let deps = deps0 {usdEbuildRunner = failBunManifest}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let outs = usrOutcomes res
            ralphKey = mkPackageKey "dev-util" "ralph-tui"
            bunKey = mkPackageKey "dev-lang" "bun-bin"
        assertTrue
          "bun-bin hard-fail"
          ( any
              ( \case
                  ApplyHardFail k _ _ _ -> k == bunKey
                  _ -> False
              )
              outs
          )
        case [m | ApplyHardFail k m _ _ <- outs, k == ralphKey] of
          (msg : _) ->
            assertTrue "ralph names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` msg)
          [] -> assertFailure "expected ralph cascade hard-fail"
        still <- doesFileExist ralphPath
        assertTrue "ralph not mutated" still

testJobs1BunBinWhileRalphWaits :: IO ()
testJobs1BunBinWhileRalphWaits =
  withSystemTempDirectory "om-wave-jobs1" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 1 preflightNoDocker
    raced <-
      race
        (threadDelay 15_000_000)
        (runUpdatePhases deps0 entries ebuilds entries)
    case raced of
      Left () ->
        assertFailure
          "deadlock: waiting ralph likely occupied the only job slot"
      Right (Left err) ->
        assertFailure $ "spine failed: " <> T.unpack err
      Right (Right res) -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
        assertTrue
          "bun-bin applied under jobs=1"
          ( any
              ( \case
                  ApplySuccess k _ _ -> k == bunKey
                  ApplyHardFail k _ _ _ -> k == bunKey
                  _ -> False
              )
              (usrOutcomes res)
          )
        exists <- doesFileExist (overlay </> "dev-lang" </> "bun-bin" </> "bun-bin-1.2.0.ebuild")
        assertTrue "bun-bin renamed while ralph waited" exists

testReplanDockerFailKeepsCommit :: IO ()
testReplanDockerFailKeepsCommit =
  withSystemTempDirectory "om-wave-docker" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let (entries, ebuilds) = mkEntries bunPath ralphPath
    deps <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightNoDocker
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
            ralphKey = mkPackageKey "dev-util" "ralph-tui"
            outs = usrOutcomes res
        assertTrue
          "bun-bin success kept"
          (any (\case ApplySuccess k _ _ -> k == bunKey; _ -> False) outs)
        case [m | ApplyHardFail k m _ _ <- outs, k == ralphKey] of
          (msg : _) ->
            assertTrue "ralph docker/re-entry fail" ("docker" `T.isInfixOf` msg)
          [] -> assertFailure "expected ralph hard-fail at re-entry"
        exists <-
          doesFileExist
            (overlay </> "dev-lang" </> "bun-bin" </> "bun-bin-1.2.0.ebuild")
        assertTrue "bun-bin commit/rename remains" exists

testSameRunBunThenRalph :: IO ()
testSameRunBunThenRalph =
  withSystemTempDirectory "om-wave-same-run" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let (entries, ebuilds) = mkEntries bunPath ralphPath
        ebuildReuse pkgDir name = do
          let base = T.pack (takeBaseName name)
              tarball = base <> "-deps.tar.xz"
              digests = hashBytes bunAssetBytes
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> tarball
                <> " 1 SHA512 "
                <> digestSHA512 digests
                <> "\n"
            )
          pure (Right ())
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseRalphReuse 2 preflightOk
    let deps = deps0 {usdEbuildRunner = ebuildReuse}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
            ralphKey = mkPackageKey "dev-util" "ralph-tui"
            outs = usrOutcomes res
        assertTrue
          "bun-bin success"
          (any (\case ApplySuccess k _ _ -> k == bunKey; _ -> False) outs)
        case [ls | ApplySuccess k ls _ <- outs, k == ralphKey] of
          (lines_ : _) ->
            assertTrue
              "ralph higher PV"
              (any (\sl -> prettyVersion (slTo sl) == "1.5.0") lines_)
          [] ->
            assertFailure $
              "expected ralph success, outcomes=" <> show (map outcomeKey outs)
        exists <-
          doesFileExist
            (overlay </> "dev-util" </> "ralph-tui" </> "ralph-tui-1.5.0.ebuild")
        assertTrue "ralph 1.5.0 ebuild written" exists

countingEnsure ::
  IORef Int ->
  NeededFloors ->
  IO (Either T.Text EnsureOutcome)
countingEnsure ref _ = do
  atomicModifyIORef' ref (\n -> (n + 1, ()))
  pure (Right EnsureSkipped)

failingEnsure :: NeededFloors -> IO (Either T.Text EnsureOutcome)
failingEnsure _ = pure (Left "ensure failed for test")

testGitMvOnlyNeverEnsure :: IO ()
testGitMvOnlyNeverEnsure =
  withSystemTempDirectory "om-wave-gitmv-only" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    initGitDir assets
    createDirectoryIfMissing True dist
    let ebuilds = [Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath]
        entries = groupNewest ebuilds
    nEnsure <- newIORef (0 :: Int)
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps = deps0 {usdEnsureImage = countingEnsure nEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
        assertTrue
          "bun-bin outcome"
          ( any
              ( \case
                  ApplySuccess k _ _ -> k == bunKey
                  ApplyHardFail k _ _ _ -> k == bunKey
                  _ -> False
              )
              (usrOutcomes res)
          )
        n <- readIORef nEnsure
        assertEq "GitMv-only never ensures" 0 n

testReuseOnlyNeverEnsure :: IO ()
testReuseOnlyNeverEnsure =
  withSystemTempDirectory "om-wave-reuse-only" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    -- bun-bin already at fetched latest; ralph reuses release assets.
    bunPath <- seedBunBin overlay "1.2.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let ebuilds =
          [ Ebuild "dev-lang" "bun-bin" "1.2.0" bunPath,
            Ebuild "dev-util" "ralph-tui" "1.0.0" ralphPath
          ]
        entries = groupNewest ebuilds
    nEnsure <- newIORef (0 :: Int)
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseRalphReuse 2 preflightOk
    let deps = deps0 {usdEnsureImage = countingEnsure nEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right _ -> do
        n <- readIORef nEnsure
        assertEq "reuse-only never ensures" 0 n

testFailedReEnsureKeepsCommit :: IO ()
testFailedReEnsureKeepsCommit =
  withSystemTempDirectory "om-wave-ensure-fail" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps = deps0 {usdEnsureImage = failingEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
            ralphKey = mkPackageKey "dev-util" "ralph-tui"
            outs = usrOutcomes res
        assertTrue
          "bun-bin success kept"
          (any (\case ApplySuccess k _ _ -> k == bunKey; _ -> False) outs)
        case [m | ApplyHardFail k m _ _ <- outs, k == ralphKey] of
          (msg : _) ->
            assertTrue "ralph ensure fail" ("ensure failed" `T.isInfixOf` msg)
          [] -> assertFailure "expected ralph hard-fail at re-ensure"
        exists <-
          doesFileExist
            (overlay </> "dev-lang" </> "bun-bin" </> "bun-bin-1.2.0.ebuild")
        assertTrue "bun-bin commit/rename remains" exists

testSecondEnsureAfterBunBin :: IO ()
testSecondEnsureAfterBunBin =
  withSystemTempDirectory "om-wave-second-ensure" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let (entries, ebuilds) = mkEntries bunPath ralphPath
    nEnsure <- newIORef (0 :: Int)
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps = deps0 {usdEnsureImage = countingEnsure nEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
            outs = usrOutcomes res
        assertTrue
          "bun-bin success"
          (any (\case ApplySuccess k _ _ -> k == bunKey; _ -> False) outs)
        n <- readIORef nEnsure
        assertEq "one t0 ensure; no second after bun-bin commit" 1 n

seedDolt :: FilePath -> IO FilePath
seedDolt overlay = do
  let pkgDir = overlay </> "dev-db" </> "dolt"
      name = "dolt-1.0.0.ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> name) "EAPI=8\nKEYWORDS=\"~amd64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST dolt 1\n"
  writeMatchingCachesForPackage overlay "dev-db" "dolt" pkgDir
  pure (pkgDir </> name)

seedGrok :: FilePath -> T.Text -> IO FilePath
seedGrok overlay ver = do
  let pkgDir = overlay </> "dev-util" </> "grok-build-bin"
      name = "grok-build-bin-" <> T.unpack ver <> ".ebuild"
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> name)
    "EAPI=8\nKEYWORDS=\"~amd64\"\n"
  TIO.writeFile (pkgDir </> "Manifest") "DIST grok 1\n"
  writeMatchingCachesForPackage overlay "dev-util" "grok-build-bin" pkgDir
  pure (pkgDir </> name)

dirtyIfPathContains :: T.Text -> GitOps
dirtyIfPathContains needle =
  cleanGit
    { goPathsDirty = \_ paths ->
        pure $
          Right
            (any (\p -> needle `T.isInfixOf` T.pack p) paths)
    }

testDirtyBunBinFailsUpdateDolt :: IO ()
testDirtyBunBinFailsUpdateDolt =
  withSystemTempDirectory "om-wave-dirty-dolt" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    _bunPath <- seedBunBin overlay "1.1.0"
    doltPath <- seedDolt overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    nEnsure <- newIORef (0 :: Int)
    let ebuilds = [Ebuild "dev-db" "dolt" "1.0.0" doltPath]
        entries = groupNewest ebuilds
    deps0 <-
      baseSpine
        overlay
        assets
        dist
        (dirtyIfPathContains "bun-bin")
        releaseMissing
        2
        preflightOk
    let deps =
          deps0
            { usdEnsureImage = countingEnsure nEnsure,
              usdFetcher = \_ -> pure (Right (parseEbuildVersion "1.0.1"))
            }
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> do
        assertTrue "names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` err)
        assertTrue "restore/finish" ("restore or finish" `T.isInfixOf` err)
      Right _ -> assertFailure "expected dirty preflight hard-fail"
    n <- readIORef nEnsure
    assertEq "no ensure after dirty bun-bin" 0 n
    still <- doesFileExist doltPath
    assertTrue "dolt not mutated" still

testDirtySelectedPackageFails :: IO ()
testDirtySelectedPackageFails =
  withSystemTempDirectory "om-wave-dirty-sel" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    nEnsure <- newIORef (0 :: Int)
    let (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine
        overlay
        assets
        dist
        (dirtyIfPathContains "ralph-tui")
        releaseMissing
        2
        preflightOk
    let deps = deps0 {usdEnsureImage = countingEnsure nEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err ->
        assertTrue "names ralph" ("ralph-tui" `T.isInfixOf` err)
      Right _ -> assertFailure "expected dirty selected package to fail"
    n <- readIORef nEnsure
    assertEq "no ensure" 0 n

testOverlayRootDirtOk :: IO ()
testOverlayRootDirtOk =
  withSystemTempDirectory "om-wave-readme-dirt" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    initGitDir assets
    createDirectoryIfMissing True dist
    nEnsure <- newIORef (0 :: Int)
    let ebuilds = [Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath]
        entries = groupNewest ebuilds
    deps0 <-
      baseSpine
        overlay
        assets
        dist
        (dirtyIfPathContains "README")
        releaseMissing
        2
        preflightOk
    let deps = deps0 {usdEnsureImage = countingEnsure nEnsure}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err ->
        assertFailure $
          "README-only dirt should not fail preflight: " <> T.unpack err
      Right res -> do
        let bunKey = mkPackageKey "dev-lang" "bun-bin"
        assertTrue
          "bun-bin proceeded"
          ( any
              ( \case
                  ApplySuccess k _ _ -> k == bunKey
                  ApplyHardFail k _ _ _ -> k == bunKey
                  ApplySoftSkip k _ -> k == bunKey
              )
              (usrOutcomes res)
          )
        n <- readIORef nEnsure
        assertEq "GitMv-only no ensure" 0 n

testEnsureWaitsForBunBinManifest :: IO ()
testEnsureWaitsForBunBinManifest =
  withSystemTempDirectory "om-wave-manifest-gate" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
        bunMan = overlay </> "dev-lang" </> "bun-bin" </> "Manifest"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    sawReady <- newIORef False
    let delayedEbuild pkgDir name = do
          threadDelay 150_000
          fakeEbuildRun pkgDir name
        gatedEnsure _floors = do
          man <- TIO.readFile bunMan
          writeIORef sawReady ("bun-bin-1.2.0" `T.isInfixOf` man)
          pure (Right EnsureSkipped)
        (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps =
          deps0
            { usdEbuildRunner = delayedEbuild,
              usdEnsureImage = gatedEnsure
            }
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right _ -> do
        ready <- readIORef sawReady
        assertTrue "ensure saw Manifest DIST for new bun-bin PV" ready

testGrokBuildBinOverlapsEnsure :: IO ()
testGrokBuildBinOverlapsEnsure =
  withSystemTempDirectory "om-wave-grok-overlap" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    grokPath <- seedGrok overlay "0.2.99"
    initGitDir assets
    createDirectoryIfMissing True dist
    grokUnblock <- newEmptyMVar
    ensureStarted <- newIORef False
    let blockGrok pkgDir name =
          if "grok-build-bin" `T.isInfixOf` T.pack name
            then do
              takeMVar grokUnblock
              fakeEbuildRun pkgDir name
            else fakeEbuildRun pkgDir name
        overlappingEnsure _ = do
          writeIORef ensureStarted True
          putMVar grokUnblock ()
          pure (Right EnsureSkipped)
        fetchMix src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.2.0"))
          Http {} ->
            pure (Right (parseEbuildVersion "0.2.101"))
          _ ->
            pure (Left "unexpected fetch")
        ebuilds =
          [ Ebuild "dev-lang" "bun-bin" "1.1.0" bunPath,
            Ebuild "dev-util" "ralph-tui" "1.0.0" ralphPath,
            Ebuild "dev-util" "grok-build-bin" "0.2.99" grokPath
          ]
        entries = groupNewest ebuilds
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps =
          deps0
            { usdFetcher = fetchMix,
              usdEbuildRunner = blockGrok,
              usdEnsureImage = overlappingEnsure
            }
    raced <-
      race
        (threadDelay 15_000_000)
        (runUpdatePhases deps entries ebuilds entries)
    case raced of
      Left () ->
        assertFailure
          "deadlock: ensure likely waited on grok-build-bin Manifest"
      Right (Left err) ->
        assertFailure $ "spine failed: " <> T.unpack err
      Right (Right _) -> do
        started <- readIORef ensureStarted
        assertTrue "ensure started (did not wait on grok-build-bin)" started

testT0EnsureHypoBunFloor :: IO ()
testT0EnsureHypoBunFloor =
  withSystemTempDirectory "om-wave-hypo-floor" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.3.14"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    floorsRef <- newIORef (Nothing :: Maybe NeededFloors)
    let recordFloors floors = do
          writeIORef floorsRef (Just floors)
          pure (Right EnsureSkipped)
        fetch14 src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "1.4.0"))
          _ -> fetchBunLatest src
        bunEngines14 _o _r _p pv =
          pure $
            Right $
              case pv of
                "1.0.0" -> "1.3.14"
                "1.5.0" -> "1.4.0"
                _ -> "1.0.0"
        ebuilds =
          [ Ebuild "dev-lang" "bun-bin" "1.3.14" bunPath,
            Ebuild "dev-util" "ralph-tui" "1.0.0" ralphPath
          ]
        entries = groupNewest ebuilds
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    ops <- liveBunOps overlay
    let ops14 = ops {dpoFetchBunEngines = bunEngines14}
        deps =
          deps0
            { usdFetcher = fetch14,
              usdDepsPlanOps = ops14,
              usdEnsureImage = recordFloors
            }
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right _ -> do
        mf <- readIORef floorsRef
        case mf of
          Nothing -> assertFailure "expected t0 ensure to run"
          Just floors ->
            assertEq "hypo bun floor is remote 1.4.0" (Just "1.4.0") (nfBun floors)

testSafetyAssertMismatch :: IO ()
testSafetyAssertMismatch =
  withSystemTempDirectory "om-wave-safety-assert" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    let revertAfterCommit _root paths _msg = do
          if any (\p -> "bun-bin" `T.isInfixOf` T.pack p) paths
            then do
              let bunDir = overlay </> "dev-lang" </> "bun-bin"
              renameFile
                (bunDir </> "bun-bin-1.2.0.ebuild")
                (bunDir </> "bun-bin-1.1.0.ebuild")
              pure (Right ())
            else pure (Right ())
        gitOps = cleanGit {goAddAndCommit = revertAfterCommit}
        ebuildReuse pkgDir name = do
          let base = T.pack (takeBaseName name)
              tarball = base <> "-deps.tar.xz"
              digests = hashBytes bunAssetBytes
          TIO.writeFile
            (pkgDir </> "Manifest")
            ( "DIST "
                <> tarball
                <> " 1 SHA512 "
                <> digestSHA512 digests
                <> "\n"
            )
          pure (Right ())
        (entries, ebuilds) = mkEntries bunPath ralphPath
    deps0 <-
      baseSpine overlay assets dist gitOps releaseRalphReuse 2 preflightOk
    let deps = deps0 {usdEbuildRunner = ebuildReuse}
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right res -> do
        let ralphKey = mkPackageKey "dev-util" "ralph-tui"
            bunKey = mkPackageKey "dev-lang" "bun-bin"
            outs = usrOutcomes res
        assertTrue
          "bun-bin success"
          (any (\case ApplySuccess k _ _ -> k == bunKey; _ -> False) outs)
        case [m | ApplyHardFail k m _ _ <- outs, k == ralphKey] of
          (msg : _) -> do
            assertTrue "names bun-bin" ("dev-lang/bun-bin" `T.isInfixOf` msg)
            assertTrue "names planned PV" ("1.2.0" `T.isInfixOf` msg)
            assertTrue "names overlay PV" ("1.1.0" `T.isInfixOf` msg)
            assertTrue "not mutated" ("not mutated" `T.isInfixOf` msg)
          [] -> assertFailure "expected ralph safety-assert hard-fail"
        still <- doesFileExist ralphPath
        assertTrue "ralph overlay not rewritten" still

testHypoPlanNotCachedUnderOldBunBin :: IO ()
testHypoPlanNotCachedUnderOldBunBin =
  withSystemTempDirectory "om-wave-hypo-cache" $ \tmp -> do
    let overlay = tmp </> "ov"
        assets = tmp </> "assets"
        dist = tmp </> "dist"
        cacheDir = tmp </> "check-cache"
    bunPath <- seedBunBin overlay "1.1.0"
    ralphPath <- seedRalph overlay
    initGitDir assets
    createDirectoryIfMissing True dist
    (cache, _) <- openCheckCache (CacheTtl (60 * 60)) False overlay
    bunFp <-
      computeFingerprintFromDir
        (GitHub "oven-sh" "bun" "bun-v")
        (overlay </> "dev-lang" </> "bun-bin")
        "bun-bin"
    ralphFp <-
      computeFingerprintFromDir
        (GitHub "subsy" "ralph-tui" "v")
        (overlay </> "dev-util" </> "ralph-tui")
        "ralph-tui"
    let (entries, ebuilds) = mkEntries bunPath ralphPath
        ralphKey = mkPackageKey "dev-util" "ralph-tui"
    deps0 <-
      baseSpine overlay assets dist cleanGit releaseMissing 2 preflightOk
    let deps =
          deps0
            { usdCheckCache = cache,
              usdEnsureImage = failingEnsure
            }
    result <- runUpdatePhases deps entries ebuilds entries
    case result of
      Left err -> assertFailure $ "spine failed: " <> T.unpack err
      Right _ -> do
        hit <- lookupDeps cache ralphKey ralphFp (Just bunFp)
        assertEq
          "no 1.2.0 hypo plan under bun-bin 1.1.0 fingerprint"
          Nothing
          hit
        -- Silence unused cacheDir (handle is in-memory + overlay path).
        createDirectoryIfMissing True cacheDir
