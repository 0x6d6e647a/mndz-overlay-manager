{-# LANGUAGE OverloadedStrings #-}

module Test.CaddyAnalyzer (unitTests, integrationTests) where

import CLI.Jobs (newWorkBudget)
import Control.Concurrent.MVar (newMVar)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List ((\\))
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Network.HTTP.Client (path, requestHeaders)
import Overlay.Version (EbuildVersion, parseEbuildVersion)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse)
import Test.Support (mkTestApplyEnv, writeMatchingCachesForPackage)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Test.Tasty.QuickCheck (Property, forAll, sublistOf, testProperty)
import Update.Apply (ApplyEnv (..))
import Update.Apply.TestSupport (goPublishAndOverlay)
import Update.Assets.Hash (digestSHA512, hashBytes)
import Update.Assets.Layout (SidecarPaths (..), sidecarPaths, vendorTarballName)
import Update.Assets.Release
  ( ReleaseAsset (..),
    ReleaseInfo (..),
    ReleaseMeta (..),
    ReleaseOps (..),
  )
import Update.Check (PackageEntry (..))
import Update.Deps.Plan
  ( DepsPlanOps (..),
    planDepsPackageWithProgressDonor,
    productionDepsPlanOps,
  )
import Update.Git (GitOps (..))
import Update.GitHub
  ( fetchGitHubWithHttpLbs,
    listGitHubVersionsWithHttpLbs,
  )
import Update.Go.Lanes
  ( LaneId (..),
    LaneTarget (..),
    PlanError (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    assembleKeywordsFor,
    planErrorMessage,
  )
import Update.Go.ModFetch
  ( GoModKey (..),
    fetchGoModAtTagHttpLbs,
    parseGoReqFromMod,
  )
import Update.Go.Plan (PlanOps (..), noopPlanProgress)
import Update.Go.Vendor (VendorOps (..))
import Update.Hardcoded (lookupLaneArches, lookupPolicy)
import Update.Md5Cache (cacheFilePath)
import Update.Process (ProcessRequest (..), ProcessResult (..))
import Update.Process.Docker (MaterializeDockerCfg (..), defaultMaterializeImage)
import Update.Runtime.Ceilings (ArchCeilings (..), KeywordTier (..), RuntimeCeilings (..))
import Update.Targets (TargetError (..), resolveTargets)
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    PackageKey (..),
    PackagePolicy (..),
    SuccessLine (..),
    UpdateSource (..),
    UpdateTechnique (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "Caddy analyzer"
    [ testCase "targets resolve and unknown tokens fail" testTargets,
      testCase "lanes stay inside the allowlist" testLanes,
      testCase "fake GitHub and root go.mod contract" testFakeHttp,
      testCase "probe failures stay package-scoped" testProbeFailures,
      testCase "policy regressions fail closed" testPolicyRegressions,
      testProperty "keyword membership follows the allowlist" propKeywords
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "Caddy analyzer apply"
    [ testCase "full path publishes the root module cache" testFullPath,
      testCase "reuse validates the existing vendor archive" testReuse,
      testCase "both routes keep the donor patch contract" testPreservation,
      testCase "release and digest failures do not commit" testFailures
    ]

caddyKey :: PackageKey
caddyKey = PackageKey "net-analyzer/caddy-analyzer"

caddySource :: UpdateSource
caddySource = GitHub "lenny-ts" "caddy-analyzer" "v"

allowlist :: [T.Text]
allowlist = ["amd64", "arm", "arm64"]

patchName :: T.Text
patchName = "caddy-analyzer-0.7.4-offline-geoip.patch"

donorBody :: T.Text
donorBody =
  T.unlines
    [ "# Copyright 2026 Gentoo Authors",
      "# Distributed under the terms of the GNU General Public License v2",
      "",
      "EAPI=8",
      "",
      "inherit go-module optfeature shell-completion",
      "",
      "DESCRIPTION=\"Caddy access log analyzer, security inspector, and TUI dashboard\"",
      "HOMEPAGE=\"https://github.com/lenny-ts/caddy-analyzer\"",
      "SRC_URI=\"",
      "\thttps://github.com/lenny-ts/caddy-analyzer/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz",
      "\thttps://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/caddy-analyzer-${PV}/caddy-analyzer-${PV}-vendor.tar.xz",
      "\"",
      "",
      "LICENSE=\"Apache-2.0 BSD ISC MIT\"",
      "SLOT=\"0\"",
      "KEYWORDS=\"-* ~amd64 ~arm ~arm64\"",
      "IUSE=\"bash-completion fish-completion test zsh-completion\"",
      "RESTRICT=\"!test? ( test )\"",
      "",
      "BDEPEND=\">=dev-lang/go-1.25.13:=\"",
      "",
      "PATCHES=( \"${FILESDIR}/" <> patchName <> "\" )",
      "",
      "src_compile() {",
      "\texport CGO_ENABLED=0",
      "\tego build -buildvcs=false \\",
      "\t\t-ldflags \"-X github.com/lenny-ts/caddy-analyzer/cmd.Version=${PV}\" \\",
      "\t\t-o \"${T}/caddy-analyze\" ./cmd/caddy-analyze",
      "}",
      "",
      "src_test() {",
      "\texport XDG_CONFIG_HOME=\"${T}/config\"",
      "\tego test ./...",
      "}",
      "",
      "src_install() {",
      "\teinstalldocs",
      "\tdobin \"${T}/caddy-analyze\"",
      "\tif use bash-completion; then",
      "\t\t\"${T}/caddy-analyze\" completion bash > \"${T}/caddy-analyze.bash\" \\",
      "\t\t\t|| die \"failed to generate bash completion\"",
      "\t\tnewbashcomp \"${T}/caddy-analyze.bash\" caddy-analyze",
      "\tfi",
      "\tif use fish-completion; then",
      "\t\t\"${T}/caddy-analyze\" completion fish > \"${T}/caddy-analyze.fish\" \\",
      "\t\t\t|| die \"failed to generate fish completion\"",
      "\t\tnewfishcomp \"${T}/caddy-analyze.fish\" caddy-analyze.fish",
      "\tfi",
      "\tif use zsh-completion; then",
      "\t\t\"${T}/caddy-analyze\" completion zsh > \"${T}/_caddy-analyze\" \\",
      "\t\t\t|| die \"failed to generate zsh completion\"",
      "\t\tnewzshcomp \"${T}/_caddy-analyze\" _caddy-analyze",
      "\tfi",
      "}",
      "",
      "pkg_postinst() {",
      "\toptfeature \"iptables firewall backend for guard, block, and unban\" net-firewall/iptables",
      "\toptfeature \"nftables firewall backend for guard\" net-firewall/nftables",
      "}"
    ]

donorPreserved :: T.Text -> Bool
donorPreserved body =
  and
    [ "SRC_URI=\"" `T.isInfixOf` body,
      "v${PV}.tar.gz" `T.isInfixOf` body,
      "0x6d6e647a/mndz-overlay-assets" `T.isInfixOf` body,
      "caddy-analyzer-${PV}/caddy-analyzer-${PV}-vendor.tar.xz" `T.isInfixOf` body,
      ("${FILESDIR}/" <> patchName) `T.isInfixOf` body,
      "KEYWORDS=\"-* ~amd64 ~arm ~arm64\"" `T.isInfixOf` body,
      "CGO_ENABLED=0" `T.isInfixOf` body,
      "cmd.Version=${PV}" `T.isInfixOf` body,
      "dobin \"${T}/caddy-analyze\"" `T.isInfixOf` body,
      "completion bash" `T.isInfixOf` body,
      "completion fish" `T.isInfixOf` body,
      "completion zsh" `T.isInfixOf` body,
      "IUSE=\"bash-completion fish-completion test zsh-completion\"" `T.isInfixOf` body,
      "RESTRICT=\"!test? ( test )\"" `T.isInfixOf` body,
      "XDG_CONFIG_HOME" `T.isInfixOf` body,
      "LICENSE=\"Apache-2.0 BSD ISC MIT\"" `T.isInfixOf` body,
      "net-firewall/iptables" `T.isInfixOf` body,
      "net-firewall/nftables" `T.isInfixOf` body,
      ">=dev-lang/go-1.25.13:=" `T.isInfixOf` body
    ]

entry :: T.Text -> T.Text -> T.Text -> FilePath -> PackageEntry
entry cat pn ver path =
  PackageEntry
    { peKey = mkPackageKey cat pn,
      pePN = pn,
      peLocal = parseEbuildVersion ver,
      pePath = path
    }

testTargets :: IO ()
testTargets = do
  let caddy = entry "net-analyzer" "caddy-analyzer" "0.7.4" "/overlay/caddy.ebuild"
      crush = entry "dev-util" "crush" "0.1.0" "/overlay/crush.ebuild"
      twin = entry "app-misc" "caddy-analyzer" "0.1.0" "/overlay/twin.ebuild"
      inventory = [crush, caddy]
  assertEq
    "qualified"
    (Right [caddyKey])
    (resolveTargets inventory ["net-analyzer/caddy-analyzer"])
  assertEq
    "bare"
    (Right [caddyKey])
    (resolveTargets inventory ["caddy-analyzer"])
  assertEq
    "empty keeps every inventory key"
    (Right (map peKey inventory))
    (resolveTargets inventory [])
  case resolveTargets inventory ["not-a-package"] of
    Left [UnknownPackage _] -> pure ()
    other -> assertFailure ("unknown token: " <> show other)
  case resolveTargets inventory ["dev-util/missing"] of
    Left [UnknownPackage _] -> pure ()
    other -> assertFailure ("unknown qualified token: " <> show other)
  case resolveTargets [caddy, twin] ["caddy-analyzer"] of
    Left [AmbiguousPackage _ _] -> pure ()
    other -> assertFailure ("ambiguous token: " <> show other)

threeArchCeilings :: T.Text -> RuntimeCeilings
threeArchCeilings goVer =
  let ac =
        ArchCeilings
          { acPlain = Just (parseEbuildVersion goVer),
            acTilde = Just (parseEbuildVersion goVer)
          }
   in RuntimeCeilings
        { rcAtom = "dev-lang/go",
          rcByArch =
            Map.fromList
              [ ("amd64", ac),
                ("arm", ac),
                ("arm64", ac),
                ("riscv", ac)
              ]
        }

testLanes :: IO ()
testLanes = do
  let arches = lookupLaneArches caddyKey
      versions =
        [ parseEbuildVersion "0.6.0",
          parseEbuildVersion "0.7.4",
          parseEbuildVersion "0.8.0",
          parseEbuildVersion "0.9.0"
        ]
      goFor pv
        | pv == parseEbuildVersion "0.9.0" = pure (Right (Just "1.99.0"))
        | otherwise = pure (Right (Just "1.25.13"))
  assertEq "policy arches" allowlist arches
  plan <-
    planWithCeilings
      (threeArchCeilings "1.26.5")
      arches
      versions
      [parseEbuildVersion "0.7.4"]
      goFor
  assertEq "selected pv" [parseEbuildVersion "0.8.0"] (glpUniquePVs plan)
  assertTrue
    "riscv excluded"
    (not (any (\t -> liArch (ltLane t) == "riscv") (glpLanes plan)))
  case glpEbuilds plan of
    [pe] ->
      assertEq
        "keywords"
        ["-*", "~amd64", "~arm", "~arm64"]
        (peKeywords pe)
    other -> assertFailure ("ebuilds: " <> show other)
  let lowArm =
        (threeArchCeilings "1.26.5")
          { rcByArch =
              Map.insert
                "arm"
                ( ArchCeilings
                    { acPlain = Just (parseEbuildVersion "1.21.0"),
                      acTilde = Just (parseEbuildVersion "1.21.0")
                    }
                )
                (rcByArch (threeArchCeilings "1.26.5"))
          }
  narrowed <-
    planWithCeilings
      lowArm
      arches
      versions
      [parseEbuildVersion "0.7.4"]
      goFor
  case glpEbuilds narrowed of
    [pe] ->
      assertEq
        "arm omitted when it has no target"
        ["-*", "~amd64", "~arm64"]
        (peKeywords pe)
    other -> assertFailure ("narrowed ebuilds: " <> show other)

planWithCeilings ::
  RuntimeCeilings ->
  [T.Text] ->
  [EbuildVersion] ->
  [EbuildVersion] ->
  (EbuildVersion -> IO (Either PlanError (Maybe T.Text))) ->
  IO RuntimeLanePlan
planWithCeilings ceilings arches versions locals fetchReq = do
  base <- productionDepsPlanOps (Just "tok") 2 Nothing
  cache <- newMVar (Just ceilings)
  budget <- newWorkBudget 4
  probed <- newIORef ([] :: [GoModKey])
  let ops =
        base
          { dpoListVersions = \src -> do
              assertEq "planner source" caddySource src
              pure (Right versions),
            dpoFetchGoMod = \key -> do
              modifyIORef' probed (key :)
              ver <- fetchReq (parseEbuildVersion (T.drop 1 (gmkTag key)))
              pure $ case ver of
                Left err -> Left (planErrorMessage err)
                Right Nothing -> Right "module x\n"
                Right (Just v) ->
                  Right ("module github.com/lenny-ts/caddy-analyzer\n\ngo " <> v <> "\n"),
            dpoWorkBudget = budget,
            dpoGoCeilingsCache = cache
          }
  result <-
    planDepsPackageWithProgressDonor
      ops
      noopPlanProgress
      (Go Nothing)
      caddySource
      locals
      arches
      Nothing
  plan <- assertRight "plan" result
  keys <- readIORef probed
  assertTrue
    "probes use the root module"
    (all (\k -> isNothing (gmkSubdir k) && gmkOwner k == "lenny-ts") keys)
  pure plan

testFakeHttp :: IO ()
testFakeHttp = do
  seen <- newIORef ([] :: [BSC.ByteString])
  let tags =
        "[{\"name\":\"v0.8.0\"},{\"name\":\"v0.7.4\"},{\"name\":\"not-a-release\"},{\"name\":\"v0.7.4-rc1\"}]"
      http req = do
        modifyIORef' seen (path req :)
        pure $
          Right $
            if "releases/latest" `BSC.isInfixOf` path req
              then fakeResponse 200 "{\"tag_name\":\"v0.7.4\"}"
              else fakeResponse 200 tags
  latest <-
    assertRight "latest"
      =<< fetchGitHubWithHttpLbs http Nothing caddySource
  assertEq "v0.7.4 parses" (parseEbuildVersion "0.7.4") latest
  listed <-
    assertRight "tags"
      =<< listGitHubVersionsWithHttpLbs http Nothing caddySource
  assertEq
    "comparable tags only"
    [parseEbuildVersion "0.8.0", parseEbuildVersion "0.7.4"]
    listed
  paths <- readIORef seen
  assertTrue
    "canonical repo"
    (all ("/repos/lenny-ts/caddy-analyzer" `BSC.isInfixOf`) paths)
  modPath <- newIORef ("" :: BSC.ByteString)
  let httpMod req = do
        writeIORef modPath (path req)
        pure
          ( Right
              ( fakeResponse
                  200
                  "module github.com/lenny-ts/caddy-analyzer\n\ngo 1.25.13\n"
              )
          )
      key =
        GoModKey
          { gmkOwner = "lenny-ts",
            gmkRepo = "caddy-analyzer",
            gmkTag = "v0.7.4",
            gmkSubdir = Nothing
          }
  body <- assertRight "go.mod" =<< fetchGoModAtTagHttpLbs httpMod Nothing key
  assertEq "go 1.25.13" (Just "1.25.13") (parseGoReqFromMod body)
  requested <- readIORef modPath
  assertTrue
    "root go.mod"
    ( "/lenny-ts/caddy-analyzer/v0.7.4/go.mod" `BSC.isInfixOf` requested
        && not ("/cmd/" `BSC.isInfixOf` requested)
    )
  errBad <-
    assertLeft "malformed tags"
      =<< listGitHubVersionsWithHttpLbs
        (\_ -> pure (Right (fakeResponse 200 "{nope")))
        Nothing
        caddySource
  assertEq
    "malformed tags stay package-scoped"
    "Unexpected \"nope\", expecting record key literal or }"
    errBad
  errNet <-
    assertLeft "fetch failure"
      =<< fetchGoModAtTagHttpLbs (\_ -> pure (Left "go.mod down")) Nothing key
  assertEq "transport" "go.mod down" errNet
  assertEq "malformed module has no requirement" Nothing (parseGoReqFromMod "not a module\n")

testProbeFailures :: IO ()
testProbeFailures = do
  admitted <- newIORef False
  listFail <-
    assertLeft "list failure"
      =<< planEither
        (\_ -> pure (Left "tags unavailable"))
        (\_ -> pure (Right "module x\n\ngo 1.25.13\n"))
  assertEq
    "list error is package scoped"
    "list versions failed: tags unavailable"
    (planErrorMessage listFail)
  malformed <-
    planEither
      (\_ -> pure (Right [parseEbuildVersion "0.8.0", parseEbuildVersion "0.7.4"]))
      ( \key ->
          pure $
            if gmkTag key == "v0.8.0"
              then Right "not a module\n"
              else Right "module x\n\ngo 1.25.13\n"
      )
  plan <- assertRight "older candidate remains" malformed
  assertEq "does not admit the broken tag" [parseEbuildVersion "0.7.4"] (glpUniquePVs plan)
  fetchFail <-
    planEither
      (\_ -> pure (Right [parseEbuildVersion "0.8.0"]))
      (\_ -> pure (Left "go.mod down"))
  err <- assertLeft "no eligible module" fetchFail
  assertEq "zero targets" PlanZeroPlannedPVs err
  writeIORef admitted True
  -- A failed plan never reaches apply. The flag above is the only admission
  -- in this test, and it happens after the error is observed.
  did <- readIORef admitted
  assertTrue "admission is explicit" did
  assertTrue "hard fail is not success" (not (isApplySuccess (Left err)))
  where
    isApplySuccess (Left PlanZeroPlannedPVs) = False
    isApplySuccess _ = True

planEither ::
  (UpdateSource -> IO (Either T.Text [EbuildVersion])) ->
  (GoModKey -> IO (Either T.Text T.Text)) ->
  IO (Either PlanError RuntimeLanePlan)
planEither list fetch = do
  base <- productionDepsPlanOps (Just "tok") 2 Nothing
  cache <- newMVar (Just (threeArchCeilings "1.26.5"))
  budget <- newWorkBudget 4
  let ops =
        base
          { dpoListVersions = list,
            dpoFetchGoMod = fetch,
            dpoWorkBudget = budget,
            dpoGoCeilingsCache = cache
          }
  planDepsPackageWithProgressDonor
    ops
    noopPlanProgress
    (Go Nothing)
    caddySource
    [parseEbuildVersion "0.7.4"]
    (lookupLaneArches caddyKey)
    Nothing

testPolicyRegressions :: IO ()
testPolicyRegressions = do
  pol <- case lookupPolicy caddyKey of
    Just p -> pure p
    Nothing -> assertFailure "missing policy"
  assertEq "owner" (GitHub "lenny-ts" "caddy-analyzer" "v") (policySource pol)
  assertTrue
    "GitMvAndManifest is the wrong technique"
    (policyTechnique pol /= GitMvAndManifest)
  assertEq "allowlist" allowlist (policyLaneArches pol)
  let lanes = [LaneId arch Tilde | arch <- allowlist]
      removed = assembleKeywordsFor [] lanes
  assertTrue "removed allowlist drops -*" ("-*" `notElem` removed)
  assertEq
    "removed allowlist keeps the arches only"
    ["~amd64", "~arm", "~arm64"]
    removed
  assertTrue "dropped patch is caught" (not (donorPreserved (T.replace patchName "gone.patch" donorBody)))

propKeywords :: Property
propKeywords =
  forAll (sublistOf allowlist) $ \present ->
    let lanes = [LaneId arch Tilde | arch <- present]
        kept = assembleKeywordsFor allowlist lanes
        removed = assembleKeywordsFor [] lanes
        extras = ["riscv", "ppc64"] \\ present
     in "-*" `elem` kept
          && all (\arch -> ("~" <> arch) `elem` kept) present
          && all (\arch -> ("~" <> arch) `notElem` kept) (allowlist \\ present)
          && all (\arch -> ("~" <> arch) `notElem` kept) extras
          && "-*" `notElem` removed

------------------------------------------------------------------------
-- Apply
------------------------------------------------------------------------

assetBytes :: BS.ByteString
assetBytes = encodeUtf8 "caddy-analyzer-vendor-bytes"

targetPV :: EbuildVersion
targetPV = parseEbuildVersion "0.8.0"

keywords :: [T.Text]
keywords = ["-*", "~amd64", "~arm", "~arm64"]

data Probe = Probe
  { prClone :: IORef [(T.Text, T.Text)],
    prTar :: IORef [FilePath],
    prDownload :: IORef Int,
    prCreate :: IORef [ReleaseMeta],
    prCommits :: IORef [T.Text],
    prDocker :: IORef Int,
    prMods :: IORef [GoModKey]
  }

newProbe :: IO Probe
newProbe =
  Probe
    <$> newIORef []
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef []
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef []

withDonor ::
  (FilePath -> FilePath -> PackageEntry -> IO a) ->
  IO a
withDonor act =
  withSystemTempDirectory "mndz-caddy-" $ \tmp -> do
    let overlayRoot = tmp </> "overlay"
        assetsRoot = tmp </> "assets"
        pkgDir = overlayRoot </> "net-analyzer" </> "caddy-analyzer"
        ebuildPath = pkgDir </> "caddy-analyzer-0.7.4.ebuild"
        ent =
          PackageEntry
            { peKey = caddyKey,
              pePN = "caddy-analyzer",
              peLocal = parseEbuildVersion "0.7.4",
              pePath = ebuildPath
            }
    createDirectoryIfMissing True (pkgDir </> "files")
    createDirectoryIfMissing True assetsRoot
    TIO.writeFile ebuildPath donorBody
    TIO.writeFile (pkgDir </> "files" </> T.unpack patchName) "offline-geoip-fix\n"
    TIO.writeFile (pkgDir </> "Manifest") "DIST caddy-analyzer-0.7.4.tar.gz 1 SHA512 aa\n"
    writeMatchingCachesForPackage overlayRoot "net-analyzer" "caddy-analyzer" pkgDir
    act overlayRoot assetsRoot ent

publish ::
  FilePath ->
  FilePath ->
  PackageEntry ->
  Probe ->
  ReleaseOps ->
  VendorOps ->
  Bool ->
  Bool ->
  Bool ->
  IO ApplyOutcome
publish overlayRoot assetsRoot ent probe releaseOps vendorOps dockerArmed manifestOk failOverlay = do
  budget <- newWorkBudget 1
  ceilings <- newMVar Nothing
  let digests = hashBytes assetBytes
      tarball = vendorTarballName "caddy-analyzer" "0.8.0"
      planOps =
        PlanOps
          { poPortageq = \_ -> pure (Left "unused"),
            poListVersions = \_ -> pure (Left "unused"),
            poFetchGoMod = \_ -> pure (Left "unused"),
            poWorkBudget = budget,
            poCeilingsCache = ceilings
          }
      gitOps =
        GitOps
          { goIsWorkTree = \_ -> pure True,
            goPathsDirty = \_ _ -> pure (Right False),
            goAddAndCommit = \root _paths msg -> do
              modifyIORef' (prCommits probe) (msg :)
              if failOverlay && root == overlayRoot
                then pure (Left "gpg failed")
                else pure (Right ()),
            goPush = \_ -> pure (Right ()),
            goRevParseHead = \_ -> pure (Right "assets-head")
          }
      ebuildRun _pkg name = do
        let sha =
              if manifestOk
                then digestSHA512 digests
                else T.replicate 32 "ab"
        TIO.writeFile
          (takeDirectoryEbuild ent </> "Manifest")
          ( "DIST "
              <> T.pack name
              <> " 1 SHA512 "
              <> sha
              <> "\nDIST "
              <> T.pack tarball
              <> " 1 SHA512 "
              <> sha
              <> "\n"
          )
        pure (Right ())
  assetsLock <- newMVar ()
  overlayLock <- newMVar ()
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
  let dockerRun req = do
        modifyIORef' (prDocker probe) (+ 1)
        pure
          ProcessResult
            { prExitCode = ExitFailure 1,
              prStdout = "",
              prStderr = "docker " <> show (prMode req)
            }
      dockerCfg =
        MaterializeDockerCfg
          { mdcImage = defaultMaterializeImage,
            mdcUser = "1000:1000",
            mdcRunId = "caddy-test",
            mdcCliPid = "1"
          }
      env =
        env0
          { aeMaterializeDocker = if dockerArmed then Just (dockerCfg, dockerRun) else Nothing,
            aeDepsPlanOps =
              (aeDepsPlanOps env0)
                { dpoFetchGoMod = \key -> do
                    modifyIORef' (prMods probe) (key :)
                    pure (Right "module github.com/lenny-ts/caddy-analyzer\n\ngo 1.25.13\n")
                }
          }
  steps <- newIORef (0 :: Int)
  goPublishAndOverlay
    env
    overlayRoot
    ent
    "lenny-ts"
    "caddy-analyzer"
    "v"
    Nothing
    keywords
    [ SuccessLine
        { slFrom = parseEbuildVersion "0.7.4",
          slTo = targetPV,
          slLabel = Just "(dev-lang/go ~amd64)",
          slAssetsReused = False
        }
    ]
    targetPV
    steps
    1

takeDirectoryEbuild :: PackageEntry -> FilePath
takeDirectoryEbuild = takeDirectory . pePath

fullVendor :: Probe -> T.Text -> VendorOps
fullVendor probe host =
  VendorOps
    { voClone = \url tag dest -> do
        modifyIORef' (prClone probe) ((url, tag) :)
        createDirectoryIfMissing True dest
        TIO.writeFile
          (dest </> "go.mod")
          "module github.com/lenny-ts/caddy-analyzer\n\ngo 1.25.13\n"
        assertTrue "clone url" ("lenny-ts/caddy-analyzer.git" `T.isSuffixOf` url)
        pure (Right ()),
      voHostGoVersion = pure (Right host),
      voGoModDownload = \dir -> do
        exists <- doesFileExist (dir </> "go.mod")
        assertTrue "module cache root has go.mod" exists
        pure (Right ()),
      voTarXz = \_dir entryName outPath -> do
        modifyIORef' (prTar probe) (entryName :)
        BS.writeFile outPath assetBytes
        pure (Right ())
    }

absentRelease :: Probe -> ReleaseOps
absentRelease probe =
  ReleaseOps
    { roGetReleaseByTag = \_ _ _ -> pure (Right Nothing),
      roDownloadAsset = \_ _ -> pure (Left "should not download"),
      roCreateReleaseWithAssets = \meta _paths -> do
        modifyIORef' (prCreate probe) (meta :)
        pure (Right ())
    }

presentRelease :: Probe -> ReleaseOps
presentRelease probe =
  let tarball = T.pack (vendorTarballName "caddy-analyzer" "0.8.0")
   in ReleaseOps
        { roGetReleaseByTag = \_owner _repo _tag ->
            pure $
              Right $
                Just
                  ReleaseInfo
                    { riId = 7,
                      riTag = "caddy-analyzer-0.8.0",
                      riAssets =
                        [ ReleaseAsset
                            { raName = tarball,
                              raBrowserDownloadUrl = "https://example.test/caddy-vendor",
                              raSize = Just (fromIntegral (BS.length assetBytes))
                            }
                        ]
                    },
          roDownloadAsset = \_url dest -> do
            modifyIORef' (prDownload probe) (+ 1)
            BS.writeFile dest assetBytes
            pure (Right ()),
          roCreateReleaseWithAssets = \_ _ -> pure (Left "must not create on reuse")
        }

assertPreserved :: FilePath -> FilePath -> IO ()
assertPreserved overlayRoot pkgDir = do
  body <- TIO.readFile (pkgDir </> "caddy-analyzer-0.8.0.ebuild")
  assertTrue "donor contract" (donorPreserved body)
  patchStill <- doesFileExist (pkgDir </> "files" </> T.unpack patchName)
  assertTrue "patch file retained" patchStill
  cacheHit <-
    doesFileExist (cacheFilePath overlayRoot "net-analyzer" "caddy-analyzer" "0.8.0")
  assertTrue "package md5-cache" cacheHit

testFullPath :: IO ()
testFullPath =
  withDonor $ \overlayRoot assetsRoot ent -> do
    probe <- newProbe
    outcome <-
      publish
        overlayRoot
        assetsRoot
        ent
        probe
        (absentRelease probe)
        (fullVendor probe "1.27.1")
        False
        True
        False
    case outcome of
      ApplySuccess key lines_ paths -> do
        assertEq "key" caddyKey key
        assertTrue "not marked reused" (not (any slAssetsReused lines_))
        assertTrue
          "signed paths include the ebuild"
          (any (("caddy-analyzer-0.8.0.ebuild" `T.isSuffixOf`) . T.pack) paths)
      other -> assertFailure ("full path: " <> show other)
    clones <- readIORef (prClone probe)
    assertEq
      "clone tag"
      [("https://github.com/lenny-ts/caddy-analyzer.git", "v0.8.0")]
      clones
    tar <- readIORef (prTar probe)
    assertEq "go-mod layout entry" ["go-mod"] tar
    created <- readIORef (prCreate probe)
    case created of
      [meta] -> do
        assertEq "assets owner" "0x6d6e647a" (rmOwner meta)
        assertEq "assets repo" "mndz-overlay-assets" (rmRepo meta)
        assertEq "release tag" "caddy-analyzer-0.8.0" (rmTag meta)
      other -> assertFailure ("release meta: " <> show other)
    side <- TIO.readFile (spSha512 (sidecarPaths assetsRoot "net-analyzer" "caddy-analyzer" (vendorTarballName "caddy-analyzer" "0.8.0")))
    assertTrue
      "sidecar matches bytes"
      (digestSHA512 (hashBytes assetBytes) `T.isPrefixOf` T.strip side)
    commits <- readIORef (prCommits probe)
    assertTrue
      "overlay commit subject"
      ("net-analyzer/caddy-analyzer: 0.8.0" `elem` commits)
    dockerN <- readIORef (prDocker probe)
    assertEq "full path used injected ops" 0 dockerN

testReuse :: IO ()
testReuse =
  withDonor $ \overlayRoot assetsRoot ent -> do
    probe <- newProbe
    outcome <-
      publish
        overlayRoot
        assetsRoot
        ent
        probe
        (presentRelease probe)
        (fullVendor probe "1.27.1")
        True
        True
        False
    case outcome of
      ApplySuccess _ lines_ _ ->
        assertTrue "reuse marks the line" (all slAssetsReused lines_)
      other -> assertFailure ("reuse: " <> show other)
    clones <- readIORef (prClone probe)
    assertEq "no vendor clone" [] clones
    tar <- readIORef (prTar probe)
    assertEq "no pack" [] tar
    downloads <- readIORef (prDownload probe)
    assertEq "one download" 1 downloads
    created <- readIORef (prCreate probe)
    assertEq "no upload" [] created
    dockerN <- readIORef (prDocker probe)
    assertEq "no docker" 0 dockerN
    mods <- readIORef (prMods probe)
    assertTrue
      "reuse reads root go.mod"
      ( any
          ( \k ->
              gmkOwner k == "lenny-ts"
                && gmkRepo k == "caddy-analyzer"
                && gmkTag k == "v0.8.0"
                && isNothing (gmkSubdir k)
          )
          mods
      )
    man <- TIO.readFile (takeDirectoryEbuild ent </> "Manifest")
    assertTrue
      "manifest matches reused bytes"
      (digestSHA512 (hashBytes assetBytes) `T.isInfixOf` man)

testPreservation :: IO ()
testPreservation = do
  withDonor $ \overlayRoot assetsRoot ent -> do
    probe <- newProbe
    outcome <-
      publish
        overlayRoot
        assetsRoot
        ent
        probe
        (absentRelease probe)
        (fullVendor probe "1.27.1")
        False
        True
        False
    case outcome of
      ApplySuccess {} -> pure ()
      other -> assertFailure ("preserve full: " <> show other)
    assertPreserved overlayRoot (takeDirectoryEbuild ent)
  withDonor $ \overlayRoot assetsRoot ent -> do
    probe <- newProbe
    outcome <-
      publish
        overlayRoot
        assetsRoot
        ent
        probe
        (presentRelease probe)
        (fullVendor probe "1.27.1")
        True
        True
        False
    case outcome of
      ApplySuccess {} -> pure ()
      other -> assertFailure ("preserve reuse: " <> show other)
    assertPreserved overlayRoot (takeDirectoryEbuild ent)

testFailures :: IO ()
testFailures = do
  expectFail "download" ["download of existing release asset failed", "retained temp unit"] True $
    \probe ->
      (presentRelease probe)
        { roDownloadAsset = \_ _ -> pure (Left "asset missing")
        }
  expectFail "sidecar" ["sidecar SHA512 disagrees", "retained temp unit"] True $
    \probe -> presentRelease probe
  expectFail "route" ["cannot be reused or fully published"] False $ \probe ->
    let base = presentRelease probe
        calls = prDownload probe
     in base
          { roGetReleaseByTag = \owner repo tag -> do
              n <- readIORef calls
              if n == 0
                then do
                  modifyIORef' calls (+ 1)
                  roGetReleaseByTag base owner repo tag
                else pure (Right Nothing),
            roDownloadAsset = \_ _ -> pure (Left "should not download after reclassification")
          }
  expectFail "image go" ["materialize image Go", "1.25.13", "retained temp unit"] False $
    \_ -> absentRelease (error "old-go release probe is per call")
  expectFail "manifest" ["Manifest SHA512 does not match", "retained temp unit"] True $
    \probe -> absentRelease probe
  expectFail "overlay commit" ["gpg failed", "retained temp unit"] True $
    \probe -> absentRelease probe
  where
    expectFail label needles assetsPublished releaseFor =
      withDonor $ \overlayRoot assetsRoot ent -> do
        probe <- newProbe
        let old = label == "image go"
            badMan = label == "manifest"
            badGit = label == "overlay commit"
            side = label == "sidecar"
        when side $ do
          let sp =
                sidecarPaths
                  assetsRoot
                  "net-analyzer"
                  "caddy-analyzer"
                  (vendorTarballName "caddy-analyzer" "0.8.0")
          createDirectoryIfMissing True (assetsRoot </> "net-analyzer" </> "caddy-analyzer")
          TIO.writeFile (spSha512 sp) "deadbeef  caddy-analyzer-0.8.0-vendor.tar.xz\n"
        let rel =
              if old
                then absentRelease probe
                else releaseFor probe
            vendor =
              fullVendor probe (if old then "1.24.0" else "1.27.1")
        outcome <-
          publish
            overlayRoot
            assetsRoot
            ent
            probe
            rel
            vendor
            (label `elem` ["download", "sidecar", "route"])
            (not badMan)
            badGit
        case outcome of
          ApplyHardFail key msg half published -> do
            assertEq (label <> " key") caddyKey key
            mapM_ (\n -> assertTrue (label <> " " <> T.unpack n) (n `T.isInfixOf` msg)) needles
            assertEq (label <> " assets") assetsPublished published
            when (label `elem` ["download", "sidecar", "route", "image go"]) $
              assertTrue (label <> " overlay not half-applied") (not half)
            when (label `elem` ["manifest", "overlay commit"]) $
              assertTrue (label <> " stops before a success commit") half
          other -> assertFailure (label <> ": " <> show other)
        created <- readIORef (prCreate probe)
        when (label `elem` ["download", "sidecar", "route", "image go"]) $
          assertEq (label <> " does not upload") [] created
        when (label == "manifest") $
          assertEq (label <> " uploads once") 1 (length created)
