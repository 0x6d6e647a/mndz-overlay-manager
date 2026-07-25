{-# LANGUAGE OverloadedStrings #-}

-- | Integration (and light Unit) coverage for Update.Apply.Materialize /
-- applyDepsAndAssets across npm, bun, and cargo — injectable Ops only.
module Test.Materialize (unitTests, integrationTests) where

import CLI.Jobs (newWorkBudget)
import CLI.Progress (MultiHandle (..))
import Control.Concurrent.MVar (newMVar)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeBaseName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertTrue)
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
    applyPackagePhase1,
  )
import Update.Apply.TestSupport (fullPathMaterializeSteps)
import Update.Assets.Hash (digestSHA512, hashBytes)
import Update.Assets.Layout (cratesTarballName, depsTarballName)
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseOps (..),
  )
import Update.Bun.Cache (BunCacheOps (..))
import Update.Cargo.Crates (CargoOps (..))
import Update.Check (PackageEntry (..))
import Update.Deps.Plan (DepsPlanOps (..))
import Update.Git (GitOps (..))
import Update.Go.ModFetch (GoModKey (..))
import Update.Go.Plan (PlanOps (..))
import Update.Go.Vendor (VendorOps (..))
import Update.Npm.Cache (NpmCacheOps (..))
import Update.Runtime.Ceilings (RuntimeCeilings (..))
import Update.Types
  ( ApplyOutcome (..),
    SuccessLine (..),
    UpdateSource (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "Materialize"
    [ testCase "npm soft-skip when plan already matches" testNpmSoftSkip,
      testCase "bun soft-skip when plan already matches" testBunSoftSkip,
      testCase "cargo soft-skip when plan already matches" testCargoSoftSkip,
      testCase "npm builder failure hard-fails materialize" testNpmBuilderHardFail
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "Materialize"
    [ testCase "npm full-path applyDepsAndAssets success" testNpmFullPathSuccess,
      testCase "npm reuse-path apply success" testNpmReusePathSuccess,
      testCase "bun full-path applyDepsAndAssets success" testBunFullPathSuccess,
      testCase "bun reuse-path apply success" testBunReusePathSuccess,
      testCase "cargo full-path applyDepsAndAssets success" testCargoFullPathSuccess,
      testCase "cargo reuse-path apply success" testCargoReusePathSuccess,
      testCase "npm full-path materialize progress sequence" testNpmFullPathProgressSequence,
      testCase "go residual applyDepsAndAssets full path" testGoResidualApplyDepsAndAssets
    ]

------------------------------------------------------------------------
-- Ceilings / DepsPlanOps helpers (mirror Test.CheckPlan)
------------------------------------------------------------------------

dualArchCeilings :: T.Text -> Maybe T.Text -> Maybe T.Text -> RuntimeCeilings
dualArchCeilings atom plain tilde =
  let base = dualArchGoCeilings plain tilde
   in base {rcAtom = atom}

nodeCeilings :: RuntimeCeilings
nodeCeilings = dualArchCeilings "net-libs/nodejs" (Just "20.0.0") (Just "22.0.0")

bunCeilings :: RuntimeCeilings
bunCeilings = dualArchCeilings "dev-lang/bun-bin" (Just "1.1.0") (Just "1.2.0")

rustCeilings :: RuntimeCeilings
rustCeilings = dualArchCeilings "dev-lang/rust|rust-bin" (Just "1.80.0") (Just "1.85.0")

goCeilings :: RuntimeCeilings
goCeilings = dualArchCeilings "dev-lang/go" (Just "1.26.3") (Just "1.26.5")

mkDepsPlanOps ::
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (GoModKey -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)) ->
  (T.Text -> T.Text -> T.Text -> T.Text -> Maybe FilePath -> IO (Either T.Text T.Text)) ->
  Maybe FilePath ->
  IO DepsPlanOps
mkDepsPlanOps listVers fetchGo fetchNpm fetchBun fetchCargo mOverlay = do
  mgr <- newManager tlsManagerSettings
  budget <- newWorkBudget 4
  goCache <- newMVar (Just goCeilings)
  nodeCache <- newMVar (Just nodeCeilings)
  bunCache <- newMVar (Just bunCeilings)
  rustCache <- newMVar (Just rustCeilings)
  pure
    DepsPlanOps
      { dpoPortageq = \_ -> pure (Left "portageq unused in Materialize tests"),
        dpoListVersions = listVers,
        dpoFetchGoMod = fetchGo,
        dpoFetchNpmEngines = fetchNpm,
        dpoFetchBunEngines = fetchBun,
        dpoFetchCargoToml = fetchCargo,
        dpoWorkBudget = budget,
        dpoGoCeilingsCache = goCache,
        dpoNodeCeilingsCache = nodeCache,
        dpoBunCeilingsCache = bunCache,
        dpoRustCeilingsCache = rustCache,
        dpoOverlayRoot = mOverlay,
        dpoManager = mgr
      }

listFixed :: [T.Text] -> UpdateSource -> IO (Either T.Text [EbuildVersion])
listFixed vers _ = pure (Right (map parseEbuildVersion vers))

unusedGoMod :: GoModKey -> IO (Either T.Text T.Text)
unusedGoMod _ = pure (Left "go.mod unused")

unusedNpm :: T.Text -> T.Text -> IO (Either T.Text T.Text)
unusedNpm _ _ = pure (Left "npm engines unused")

unusedBun :: T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)
unusedBun _ _ _ _ = pure (Left "bun engines unused")

unusedCargo ::
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  Maybe FilePath ->
  IO (Either T.Text T.Text)
unusedCargo _ _ _ _ _ = pure (Left "cargo toml unused")

------------------------------------------------------------------------
-- Fake eco builders
------------------------------------------------------------------------

-- | Shared tarball payload so hashFile / Manifest digests stay aligned.
npmAssetBytes :: BS.ByteString
npmAssetBytes = encodeUtf8 "npm-deps-tarball-bytes"

bunAssetBytes :: BS.ByteString
bunAssetBytes = encodeUtf8 "bun-deps-tarball-bytes"

cargoAssetBytes :: BS.ByteString
cargoAssetBytes = encodeUtf8 "crates-tarball-bytes"

goAssetBytes :: BS.ByteString
goAssetBytes = encodeUtf8 "vendor-go-residual-bytes"

fakeNpmSuccessOps :: NpmCacheOps
fakeNpmSuccessOps =
  NpmCacheOps
    { ncoHostNodeVersion = pure (Right "22.0.0"),
      ncoNpmPack = \_pkg _pv workDir -> do
        let tgz = workDir </> "pkg.tgz"
        BS.writeFile tgz "packed"
        pure (Right tgz),
      ncoNpmInstallCache = \_tgz _cache -> pure (Right ()),
      ncoTarXz = \_work _entry outPath -> do
        BS.writeFile outPath npmAssetBytes
        pure (Right ())
    }

fakeBunSuccessOps :: BunCacheOps
fakeBunSuccessOps =
  BunCacheOps
    { bcoClone = \_url _tag dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "bun.lock") "{}"
        pure (Right ()),
      bcoHostBunVersion = pure (Right "1.2.0"),
      bcoBunInstall = \_clone _cache -> pure (Right ()),
      bcoTarXz = \_work _entry outPath -> do
        BS.writeFile outPath bunAssetBytes
        pure (Right ())
    }

fakeCargoSuccessOps :: CargoOps
fakeCargoSuccessOps =
  CargoOps
    { coClone = \_url _tag dest -> do
        createDirectoryIfMissing True dest
        TIO.writeFile (dest </> "Cargo.lock") "# lock\n"
        TIO.writeFile
          (dest </> "Cargo.toml")
          "[package]\nname = \"pkg\"\nrust-version = \"1.85.0\"\n"
        pure (Right ()),
      coPycargoebuild = \ebuildPath _lockRoot outPath _dist -> do
        body <- TIO.readFile ebuildPath
        TIO.writeFile ebuildPath (body <> "\n# pycargoebuild\n")
        BS.writeFile outPath cargoAssetBytes
        pure (Right ())
    }

------------------------------------------------------------------------
-- Shared git / ebuild / release helpers
------------------------------------------------------------------------

cleanGitOps :: GitOps
cleanGitOps =
  GitOps
    { goIsWorkTree = \_ -> pure True,
      goPathsDirty = \_ _ -> pure (Right False),
      goAddAndCommit = \_ _ _ -> pure (Right ()),
      goPush = \_ -> pure (Right ())
    }

-- | Ebuild runner that writes a DIST line matching the ebuild basename + kind.
-- e.g. openspec-2.0.0.ebuild + "-deps.tar.xz" → openspec-2.0.0-deps.tar.xz
manifestRunner ::
  FilePath ->
  T.Text ->
  BS.ByteString ->
  FilePath ->
  FilePath ->
  IO (Either T.Text ())
manifestRunner pkgDir kindSuffix assetBytes _pkg name = do
  let base = T.pack (takeBaseName name)
      tarballName = base <> kindSuffix
      digests = hashBytes assetBytes
  TIO.writeFile
    (pkgDir </> "Manifest")
    ( "DIST "
        <> tarballName
        <> " 1 SHA512 "
        <> digestSHA512 digests
        <> "\n"
    )
  pure (Right ())

depsKind :: T.Text
depsKind = "-deps.tar.xz"

cratesKind :: T.Text
cratesKind = "-crates.tar.xz"

vendorKind :: T.Text
vendorKind = "-vendor.tar.xz"

releaseMissing :: ReleaseOps
releaseMissing =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "should not download"),
      roCreateReleaseWithAsset = \_ _ -> pure (Right ())
    }

-- | Release exists for any tag; asset name is @tag <> kindSuffix@.
releaseFound :: T.Text -> BS.ByteString -> ReleaseOps
releaseFound kindSuffix assetBytes =
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
                        { raName = tag <> kindSuffix,
                          raBrowserDownloadUrl = "https://example/" <> tag
                        }
                    ]
                },
      roDownloadAsset = \_url dest -> do
        BS.writeFile dest assetBytes
        pure (Right ()),
      roCreateReleaseWithAsset = \_ _ -> pure (Left "should not create on reuse")
    }

recordingMulti :: IORef [T.Text] -> MultiHandle
recordingMulti events =
  let logEv e = atomicModifyIORef' events (\es -> (e : es, ()))
   in MultiHandle
        { mhStart = \_ -> pure (),
          mhStatus = \_ name -> logEv ("status:" <> name),
          mhSteps = \_ n -> logEv ("steps:" <> T.pack (show n)),
          mhStep = \_ name -> logEv ("step:" <> name),
          mhSuccess = \_ -> pure (),
          mhSkip = \_ _ -> pure (),
          mhFail = \_ _ -> pure ()
        }

-- | Build ApplyEnv with injectable deps + eco ops (overrides mkTestApplyEnv defaults).
mkMatEnv ::
  GitOps ->
  FilePath ->
  FilePath ->
  EbuildRunnerLike ->
  ReleaseOps ->
  DepsPlanOps ->
  NpmCacheOps ->
  BunCacheOps ->
  CargoOps ->
  VendorOps ->
  Maybe MultiHandle ->
  IO ApplyEnv
mkMatEnv gitOps assetsRoot _overlayRoot ebuildRun releaseOps depsOps npmOps bunOps cargoOps vendorOps mMh = do
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
  budget <- newWorkBudget 2
  ceilingsCache <- newMVar Nothing
  let planOps =
        PlanOps
          { poPortageq = dpoPortageq depsOps,
            poListVersions = dpoListVersions depsOps,
            poFetchGoMod = dpoFetchGoMod depsOps,
            poWorkBudget = budget,
            poCeilingsCache = ceilingsCache
          }
  env0 <-
    mkTestApplyEnv
      gitOps
      planOps
      ebuildRun
      releaseOps
      vendorOps
      (Just assetsRoot)
      assetsLock
      overlayLock
  pure $
    env0
      { aeDepsPlanOps = depsOps,
        aeNpmCacheOps = npmOps,
        aeBunCacheOps = bunOps,
        aeCargoOps = cargoOps,
        aeMulti = fromMaybe (aeMulti env0) mMh
      }

type EbuildRunnerLike = FilePath -> FilePath -> IO (Either T.Text ())

expectSuccess :: String -> [ApplyOutcome] -> IO ()
expectSuccess label outcomes =
  case outcomes of
    [ApplySuccess {}] -> pure ()
    other -> do
      hPutStrLn stderr (label <> ": expected ApplySuccess, got " <> show other)
      exitFailure

expectSoftSkip :: String -> T.Text -> [ApplyOutcome] -> IO ()
expectSoftSkip label needle outcomes =
  case outcomes of
    [ApplySoftSkip _ reason] ->
      assertTrue (label <> " reason") (needle `T.isInfixOf` reason)
    other -> do
      hPutStrLn stderr (label <> ": expected SoftSkip, got " <> show other)
      exitFailure

expectHardFail :: String -> T.Text -> [ApplyOutcome] -> IO ()
expectHardFail label needle outcomes =
  case outcomes of
    [ApplyHardFail _ msg _ _] ->
      assertTrue (label <> " message") (needle `T.isInfixOf` msg)
    other -> do
      hPutStrLn stderr (label <> ": expected HardFail, got " <> show other)
      exitFailure

------------------------------------------------------------------------
-- Ebuild donors
------------------------------------------------------------------------

npmEbuildBody :: T.Text -> T.Text -> T.Text
npmEbuildBody keywords bdepend =
  T.unlines
    [ "EAPI=8",
      "DESCRIPTION=\"openspec test\"",
      "BDEPEND=\"" <> bdepend <> "\"",
      "KEYWORDS=\"" <> keywords <> "\"",
      "SRC_URI=\"https://registry.npmjs.org/@fission-ai/openspec/-/openspec-${PV}.tgz\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/openspec-${PV}/openspec-${PV}-deps.tar.xz\""
    ]

bunEbuildBody :: T.Text -> T.Text -> T.Text
bunEbuildBody keywords bdepend =
  T.unlines
    [ "EAPI=8",
      "DESCRIPTION=\"ralph-tui test\"",
      "BDEPEND=\"" <> bdepend <> "\"",
      "KEYWORDS=\"" <> keywords <> "\"",
      "SRC_URI=\"https://github.com/subsy/ralph-tui/archive/v${PV}.tar.gz\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/ralph-tui-${PV}/ralph-tui-${PV}-deps.tar.xz\""
    ]

cargoEbuildBody :: T.Text -> T.Text -> T.Text
cargoEbuildBody keywords msrv =
  T.unlines
    [ "EAPI=8",
      "inherit cargo",
      "DESCRIPTION=\"hk test\"",
      "RUST_MIN_VER=\"" <> msrv <> "\"",
      "KEYWORDS=\"" <> keywords <> "\"",
      "SRC_URI=\"https://github.com/jdx/hk/archive/v${PV}.tar.gz\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/hk-${PV}/hk-${PV}-crates.tar.xz\"",
      "CRATES=\"\""
    ]

goEbuildBody :: T.Text -> T.Text -> T.Text
goEbuildBody keywords goAtom =
  T.unlines
    [ "EAPI=8",
      "inherit go-module",
      "BDEPEND=\"" <> goAtom <> "\"",
      "KEYWORDS=\"" <> keywords <> "\"",
      "SRC_URI=\"https://example/a-${PV}.tar.gz\"",
      "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/crush-${PV}/crush-${PV}-vendor.tar.xz\""
    ]

-- | Plain dual-arch keywords (runtime req under plain ceiling).
kwPlain :: T.Text
kwPlain = "amd64 arm64"

-- | Tilde dual-arch keywords (runtime req only under tilde ceiling).
kwTilde :: T.Text
kwTilde = "~amd64 ~arm64"

------------------------------------------------------------------------
-- npm
------------------------------------------------------------------------

-- | Local ebuild already matches plan for 1.0.0 (plain lanes); only 2.0.0 is a gap.
seedNpmLocalOk :: FilePath -> FilePath -> T.Text -> IO ()
seedNpmLocalOk overlayRoot pkgDir pn = do
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> "openspec-1.0.0.ebuild")
    (npmEbuildBody kwPlain ">=net-libs/nodejs-20.0.0[npm]")
  TIO.writeFile
    (pkgDir </> "Manifest")
    ("DIST " <> T.pack (depsTarballName pn "1.0.0") <> " 1 SHA512 deadbeef\n")
  writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir

npmEngines :: T.Text -> T.Text -> IO (Either T.Text T.Text)
npmEngines _pkg pv =
  pure $
    Right $
      case pv of
        "1.0.0" -> "20.0.0"
        "2.0.0" -> "22.0.0"
        _ -> "18.0.0"

testNpmFullPathSuccess :: IO ()
testNpmFullPathSuccess =
  withSystemTempDirectory "mndz-mat-npm-full-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "openspec-1.0.0.ebuild"
            }
    createDirectoryIfMissing True assetsRoot
    seedNpmLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["2.0.0", "1.0.0"])
        unusedGoMod
        npmEngines
        unusedBun
        unusedCargo
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir depsKind npmAssetBytes)
        releaseMissing
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSuccess "npm full" outcomes

testNpmReusePathSuccess :: IO ()
testNpmReusePathSuccess =
  withSystemTempDirectory "mndz-mat-npm-reuse-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "openspec-1.0.0.ebuild"
            }
    packCalls <- newIORef (0 :: Int)
    createDirectoryIfMissing True assetsRoot
    seedNpmLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["2.0.0", "1.0.0"])
        unusedGoMod
        npmEngines
        unusedBun
        unusedCargo
        (Just overlayRoot)
    let npmOps =
          fakeNpmSuccessOps
            { ncoNpmPack = \_ _ _ -> do
                atomicModifyIORef' packCalls (\n -> (n + 1, ()))
                pure (Left "pack should not run on reuse")
            }
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir depsKind npmAssetBytes)
        (releaseFound depsKind npmAssetBytes)
        depsOps
        npmOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    case outcomes of
      [ApplySuccess _ sls _] -> do
        assertTrue "reuse marks lines" (all slAssetsReused sls)
        n <- readIORef packCalls
        assertEq "npm pack skipped on reuse" 0 n
      other -> do
        hPutStrLn stderr ("npm reuse: expected success, got " <> show other)
        exitFailure

testNpmSoftSkip :: IO ()
testNpmSoftSkip =
  withSystemTempDirectory "mndz-mat-npm-skip-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        local = parseEbuildVersion "2.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "openspec-2.0.0.ebuild"
            }
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    -- engines 22.0.0 only fits tilde ceiling → ~amd64 ~arm64
    TIO.writeFile
      (pkgDir </> "openspec-2.0.0.ebuild")
      (npmEbuildBody kwTilde ">=net-libs/nodejs-22.0.0[npm]")
    TIO.writeFile
      (pkgDir </> "Manifest")
      ("DIST " <> T.pack (depsTarballName pn "2.0.0") <> " 1 SHA512 deadbeef\n")
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    depsOps <-
      mkDepsPlanOps
        (listFixed ["2.0.0"])
        unusedGoMod
        (\_pkg _pv -> pure (Right "22.0.0"))
        unusedBun
        unusedCargo
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSoftSkip "npm skip" "already matches" outcomes

testNpmBuilderHardFail :: IO ()
testNpmBuilderHardFail =
  withSystemTempDirectory "mndz-mat-npm-fail-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "openspec-1.0.0.ebuild"
            }
    createDirectoryIfMissing True assetsRoot
    seedNpmLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["2.0.0", "1.0.0"])
        unusedGoMod
        npmEngines
        unusedBun
        unusedCargo
        (Just overlayRoot)
    let npmOps =
          fakeNpmSuccessOps
            { ncoNpmPack = \_ _ _ -> pure (Left "npm pack failed: boom")
            }
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (\_ _ -> pure (Right ()))
        releaseMissing
        depsOps
        npmOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectHardFail "npm pack fail" "boom" outcomes

testNpmFullPathProgressSequence :: IO ()
testNpmFullPathProgressSequence =
  withSystemTempDirectory "mndz-mat-npm-prog-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "openspec"
        pn = "openspec" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "openspec",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "openspec-1.0.0.ebuild"
            }
    events <- newIORef ([] :: [T.Text])
    createDirectoryIfMissing True assetsRoot
    seedNpmLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["2.0.0", "1.0.0"])
        unusedGoMod
        npmEngines
        unusedBun
        unusedCargo
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir depsKind npmAssetBytes)
        releaseMissing
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        (Just (recordingMulti events))
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSuccess "npm progress" outcomes
    evs <- reverse <$> readIORef events
    let statuses = [e | e <- evs, "status:" `T.isPrefixOf` e]
        steps = [e | e <- evs, "step:" `T.isPrefixOf` e]
        expectedMat =
          [ "step:npm pack",
            "step:npm cache install",
            "step:compressing tarball",
            "step:committing assets",
            "step:pushing assets",
            "step:uploading release asset",
            "step:regenerating manifest"
          ]
        matSteps = filter (`elem` expectedMat) steps
    assertTrue
      "plan ceilings status"
      (any ("discovering nodejs ceilings" `T.isInfixOf`) statuses)
    assertTrue
      "plan list status"
      (any ("listing versions" `T.isInfixOf`) statuses)
    -- Probe is mark-only (mhStep); no mhStatus for engines.node.
    assertTrue
      "plan probe step"
      (any ("probing engines.node" `T.isInfixOf`) steps)
    assertTrue
      "probe release"
      (any ("probing release asset" `T.isInfixOf`) statuses)
    assertEq "npm full-path materialize steps" expectedMat matSteps
    assertEq "seven materialize steps" fullPathMaterializeSteps (length matSteps)

------------------------------------------------------------------------
-- bun
------------------------------------------------------------------------

seedBunLocalOk :: FilePath -> FilePath -> T.Text -> IO ()
seedBunLocalOk overlayRoot pkgDir pn = do
  createDirectoryIfMissing True pkgDir
  TIO.writeFile
    (pkgDir </> "ralph-tui-1.0.0.ebuild")
    (bunEbuildBody kwPlain ">=dev-lang/bun-bin-1.1.0")
  TIO.writeFile
    (pkgDir </> "Manifest")
    ("DIST " <> T.pack (depsTarballName pn "1.0.0") <> " 1 SHA512 deadbeef\n")
  writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir

bunEngines :: T.Text -> T.Text -> T.Text -> T.Text -> IO (Either T.Text T.Text)
bunEngines _o _r _p pv =
  pure $
    Right $
      case pv of
        "1.0.0" -> "1.1.0"
        "1.5.0" -> "1.2.0"
        _ -> "1.0.0"

testBunFullPathSuccess :: IO ()
testBunFullPathSuccess =
  withSystemTempDirectory "mndz-mat-bun-full-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "ralph-tui"
        pn = "ralph-tui" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "ralph-tui-1.0.0.ebuild"
            }
    createDirectoryIfMissing True assetsRoot
    seedBunLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["1.5.0", "1.0.0"])
        unusedGoMod
        unusedNpm
        bunEngines
        unusedCargo
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir depsKind bunAssetBytes)
        releaseMissing
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSuccess "bun full" outcomes

testBunReusePathSuccess :: IO ()
testBunReusePathSuccess =
  withSystemTempDirectory "mndz-mat-bun-reuse-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "ralph-tui"
        pn = "ralph-tui" :: T.Text
        local = parseEbuildVersion "1.0.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "ralph-tui-1.0.0.ebuild"
            }
    cloneCalls <- newIORef (0 :: Int)
    createDirectoryIfMissing True assetsRoot
    seedBunLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["1.5.0", "1.0.0"])
        unusedGoMod
        unusedNpm
        bunEngines
        unusedCargo
        (Just overlayRoot)
    let bunOps =
          fakeBunSuccessOps
            { bcoClone = \_ _ _ -> do
                atomicModifyIORef' cloneCalls (\n -> (n + 1, ()))
                pure (Left "clone should not run on reuse")
            }
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir depsKind bunAssetBytes)
        (releaseFound depsKind bunAssetBytes)
        depsOps
        fakeNpmSuccessOps
        bunOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    case outcomes of
      [ApplySuccess _ sls _] -> do
        assertTrue "reuse marks lines" (all slAssetsReused sls)
        n <- readIORef cloneCalls
        assertEq "bun clone skipped on reuse" 0 n
      other -> do
        hPutStrLn stderr ("bun reuse: expected success, got " <> show other)
        exitFailure

testBunSoftSkip :: IO ()
testBunSoftSkip =
  withSystemTempDirectory "mndz-mat-bun-skip-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "ralph-tui"
        pn = "ralph-tui" :: T.Text
        local = parseEbuildVersion "1.5.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "ralph-tui",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "ralph-tui-1.5.0.ebuild"
            }
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile
      (pkgDir </> "ralph-tui-1.5.0.ebuild")
      (bunEbuildBody kwTilde ">=dev-lang/bun-bin-1.2.0")
    TIO.writeFile
      (pkgDir </> "Manifest")
      ("DIST " <> T.pack (depsTarballName pn "1.5.0") <> " 1 SHA512 deadbeef\n")
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    depsOps <-
      mkDepsPlanOps
        (listFixed ["1.5.0"])
        unusedGoMod
        unusedNpm
        (\_o _r _p _pv -> pure (Right "1.2.0"))
        unusedCargo
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSoftSkip "bun skip" "already matches" outcomes

------------------------------------------------------------------------
-- cargo
------------------------------------------------------------------------

seedCargoLocalOk :: FilePath -> FilePath -> T.Text -> IO ()
seedCargoLocalOk overlayRoot pkgDir pn = do
  createDirectoryIfMissing True pkgDir
  TIO.writeFile (pkgDir </> "hk-0.40.0.ebuild") (cargoEbuildBody kwPlain "1.80.0")
  TIO.writeFile
    (pkgDir </> "Manifest")
    ("DIST " <> T.pack (cratesTarballName pn "0.40.0") <> " 1 SHA512 deadbeef\n")
  writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir

cargoTomls ::
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  Maybe FilePath ->
  IO (Either T.Text T.Text)
cargoTomls _o _r _p pv mSub =
  pure $
    case (pv, mSub) of
      ("0.40.0", Nothing) ->
        Right " [package]\nrust-version = \"1.80.0\"\n"
      ("0.50.0", Nothing) ->
        Right " [package]\nrust-version = \"1.85.0\"\n"
      _ -> Left "missing Cargo.toml"

testCargoFullPathSuccess :: IO ()
testCargoFullPathSuccess =
  withSystemTempDirectory "mndz-mat-cargo-full-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "hk"
        pn = "hk" :: T.Text
        local = parseEbuildVersion "0.40.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "hk",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "hk-0.40.0.ebuild"
            }
    createDirectoryIfMissing True assetsRoot
    seedCargoLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["0.50.0", "0.40.0"])
        unusedGoMod
        unusedNpm
        unusedBun
        cargoTomls
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir cratesKind cargoAssetBytes)
        releaseMissing
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSuccess "cargo full" outcomes

testCargoReusePathSuccess :: IO ()
testCargoReusePathSuccess =
  withSystemTempDirectory "mndz-mat-cargo-reuse-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "hk"
        pn = "hk" :: T.Text
        local = parseEbuildVersion "0.40.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "hk",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "hk-0.40.0.ebuild"
            }
    cloneCalls <- newIORef (0 :: Int)
    createDirectoryIfMissing True assetsRoot
    seedCargoLocalOk overlayRoot pkgDir pn
    depsOps <-
      mkDepsPlanOps
        (listFixed ["0.50.0", "0.40.0"])
        unusedGoMod
        unusedNpm
        unusedBun
        cargoTomls
        (Just overlayRoot)
    let cargoOps =
          fakeCargoSuccessOps
            { coClone = \_ _ _ -> do
                atomicModifyIORef' cloneCalls (\n -> (n + 1, ()))
                pure (Left "clone should not run on reuse")
            }
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir cratesKind cargoAssetBytes)
        (releaseFound cratesKind cargoAssetBytes)
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        cargoOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    case outcomes of
      [ApplySuccess _ sls _] -> do
        assertTrue "reuse marks lines" (all slAssetsReused sls)
        n <- readIORef cloneCalls
        assertEq "cargo clone skipped on reuse" 0 n
      other -> do
        hPutStrLn stderr ("cargo reuse: expected success, got " <> show other)
        exitFailure

testCargoSoftSkip :: IO ()
testCargoSoftSkip =
  withSystemTempDirectory "mndz-mat-cargo-skip-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "hk"
        pn = "hk" :: T.Text
        local = parseEbuildVersion "0.50.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "hk",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "hk-0.50.0.ebuild"
            }
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile (pkgDir </> "hk-0.50.0.ebuild") (cargoEbuildBody kwTilde "1.85.0")
    TIO.writeFile
      (pkgDir </> "Manifest")
      ("DIST " <> T.pack (cratesTarballName pn "0.50.0") <> " 1 SHA512 deadbeef\n")
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    depsOps <-
      mkDepsPlanOps
        (listFixed ["0.50.0"])
        unusedGoMod
        unusedNpm
        unusedBun
        ( \_o _r _p _pv mSub ->
            pure $
              case mSub of
                Nothing -> Right " [package]\nrust-version = \"1.85.0\"\n"
                _ -> Left "no sub"
        )
        (Just overlayRoot)
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (\_ _ -> pure (Right ()))
        unusedReleaseOps
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        unusedVendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSoftSkip "cargo skip" "already matches" outcomes

------------------------------------------------------------------------
-- Go residual: exercise applyDepsAndAssets (not legacy materializePlan)
------------------------------------------------------------------------

testGoResidualApplyDepsAndAssets :: IO ()
testGoResidualApplyDepsAndAssets =
  withSystemTempDirectory "mndz-mat-go-residual-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "dev-util" </> "crush"
        pn = "crush" :: T.Text
        local = parseEbuildVersion "0.80.0"
        entry =
          PackageEntry
            { peKey = mkPackageKey "dev-util" "crush",
              pePN = pn,
              peLocal = local,
              pePath = pkgDir </> "crush-0.80.0.ebuild"
            }
    createDirectoryIfMissing True pkgDir
    createDirectoryIfMissing True assetsRoot
    -- Local already content-ok under plain lanes (go 1.26.3); remote needs 1.26.5 tilde.
    TIO.writeFile
      (pkgDir </> "crush-0.80.0.ebuild")
      (goEbuildBody kwPlain ">=dev-lang/go-1.26.3:=")
    TIO.writeFile
      (pkgDir </> "Manifest")
      "DIST crush-0.80.0-vendor.tar.xz 1 SHA512 deadbeef\n"
    writeMatchingCachesForPackage overlayRoot "dev-util" pn pkgDir
    depsOps <-
      mkDepsPlanOps
        (listFixed ["0.84.0", "0.80.0"])
        ( \key ->
            pure $
              Right $
                case gmkTag key of
                  "v0.80.0" -> "module x\ngo 1.26.3\n"
                  "v0.84.0" -> "module x\ngo 1.26.5\n"
                  _ -> "module x\ngo 1.26.5\n"
        )
        unusedNpm
        unusedBun
        unusedCargo
        (Just overlayRoot)
    let vendorOps =
          VendorOps
            { voClone = \_ _ dest -> do
                createDirectoryIfMissing True dest
                TIO.writeFile (dest </> "go.mod") "module x\ngo 1.26.5\n"
                pure (Right ()),
              voHostGoVersion = pure (Right "1.26.5"),
              voGoModDownload = \_ -> pure (Right ()),
              voTarXz = \_ _ outPath -> do
                BS.writeFile outPath goAssetBytes
                pure (Right ())
            }
    env <-
      mkMatEnv
        cleanGitOps
        assetsRoot
        overlayRoot
        (manifestRunner pkgDir vendorKind goAssetBytes)
        releaseMissing
        depsOps
        fakeNpmSuccessOps
        fakeBunSuccessOps
        fakeCargoSuccessOps
        vendorOps
        Nothing
    outcomes <- applyPackagePhase1 env overlayRoot entry
    expectSuccess "go residual" outcomes
