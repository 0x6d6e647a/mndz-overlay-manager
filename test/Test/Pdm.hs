{-# LANGUAGE OverloadedStrings #-}

-- | PDM lock parsing, slot planning, pack plan, and ebuild rewrites.
module Test.Pdm (tests) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Overlay.Version (parseEbuildVersion, samePV)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.EbuildEdit (ensurePythonSlot, ensureUvArchiveTag)
import Update.Go.Lanes
  ( GapLine (..),
    LaneId (..),
    LaneTarget (..),
    PlanError (..),
    PlannedEbuild (..),
    RuntimeLanePlan (..),
    buildGapLines,
    lookupUvRawTag,
  )
import Update.Pdm.Lock
  ( PdmFile (..),
    PdmLock (..),
    PdmPackage (..),
    parsePdmLock,
    parsePdmLockFile,
    pdmLockRequiresPython,
  )
import Update.Pdm.Pack
  ( BackendOffer (..),
    PackedFile (..),
    chooseLockedFile,
    finalizePack,
    parsePdmDryRun,
    pdmArgsAvoidFetch,
    pdmDryRunArgs,
    pdmUseArgs,
    verifyFileHash,
  )
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Uv.Lock (parsePyprojectRequiresPython)
import Update.Uv.Python
  ( PythonSlotInventory,
    UvCandidate (..),
    inventoryFromRows,
    pdmRecordedSync,
    planUvFromCandidates,
  )

tests :: TestTree
tests =
  testGroup
    "Pdm"
    [ testCase "lock entry without a url" testLockEntry,
      testCase "missing lock file" testMissingLock,
      testCase "requires-python sources" testRequiresSources,
      testCase "recorded slot ignores a missing interpreter" testRecordedSlot,
      testCase "excluded stable slot stays a plain lane" testExcludedCeiling,
      testCase "tilde-only slot has no plain label" testTildeOnlyLabel,
      testCase "shared slot collapses to the newer pv" testCollapse,
      testCase "plain and tilde disagreement keeps both pvs" testDisagreement,
      testCase "3.12 keywords and tilde label" testSlot312Keywords,
      testCase "archive tag and slot rewrite" testRewrite,
      testCase "dry-run is the closure authority" testDryRunArgs,
      testCase "twelve wheels plus coverage sdist" testPackPlan,
      testCase "hash mismatch fails" testHashMismatch
    ]

testLockEntry :: IO ()
testLockEntry = do
  lock <- assertRight "lock" (parsePdmLock sampleLock)
  let pkgs = [p | p <- plPackages lock, ppName p == "attrs"]
  pkg <- case pkgs of
    [p] -> pure p
    other -> fail ("attrs count " <> show (length other))
  assertEq "version" "23.2.0" (ppVersion pkg)
  assertEq "no groups" [] (ppGroups pkg)
  assertEq "no extras" [] (ppExtras pkg)
  host <- case [p | p <- plPackages lock, ppName p == "click-host"] of
    [p] -> pure p
    other -> fail ("click-host count " <> show (length other))
  assertEq "dependency string" ["click"] (ppDependencies host)
  file <- assertRight "file" (chooseLockedFile pkg)
  assertEq "filename" "attrs-23.2.0-py3-none-any.whl" (pfFile file)
  assertEq "hash" "sha256:abc" (pfHash file)
  assertEq "no url" Nothing (pfUrl file)
  cov <- case [p | p <- plPackages lock, ppName p == "coverage", null (ppExtras p)] of
    [p] -> pure p
    other -> fail ("coverage count " <> show (length other))
  chosen <- assertRight "coverage file" (chooseLockedFile cov)
  assertTrue "coverage sdist" (".tar.gz" `T.isSuffixOf` pfFile chosen)
  assertTrue "not the pp wheel" (not ("pp38" `T.isInfixOf` pfFile chosen))

testMissingLock :: IO ()
testMissingLock =
  withSystemTempDirectory "pdm-lock" $ \dir -> do
    err <- assertLeft "missing" =<< parsePdmLockFile (dir </> "pdm.lock")
    assertTrue "names the path" ("pdm.lock is missing" `T.isInfixOf` err)
    bad <- assertLeft "unreadable" (parsePdmLock "this is not [ a lock")
    assertTrue "unreadable" ("unreadable pdm.lock" `T.isInfixOf` bad)

testRequiresSources :: IO ()
testRequiresSources = do
  withMeta <- assertRight "meta" (parsePdmLock metaLock)
  assertEq "lock specifier" (Just ">=3.8,<3.14") (pdmLockRequiresPython withMeta)
  omitted <- assertRight "omitted" (parsePdmLock sampleLock)
  assertEq "lock omits specifier" Nothing (pdmLockRequiresPython omitted)
  py <- assertRight "pyproject" (parsePyprojectRequiresPython pyproject)
  assertEq "pyproject specifier" (Just ">=3.8.0,<3.13") py
  assertEq "unrecognized records nothing" Set.empty (pdmRecordedSync pdmInv (Just "python3"))
  assertEq "missing records nothing" Set.empty (pdmRecordedSync pdmInv Nothing)

testRecordedSlot :: IO ()
testRecordedSlot = do
  let narrow = ">=3.8,<3.13"
      wide = ">=3.8,<3.14"
  assertEq "3.12 without a binary" (Set.singleton "3.12") (pdmRecordedSync pdmInv (Just narrow))
  assertEq "3.13 head" (Set.singleton "3.13") (pdmRecordedSync pdmInv (Just wide))
  old <- mustPlan [cand "0.1.10" "v0.1.10" narrow]
  assertTrue "plain lanes selected" (not (null (selectedPlain old)))
  assertTrue "plain records 3.12" (all ((== Just "3.12") . ltGoReq) (selectedPlain old))
  assertTrue "tilde records 3.12" (all ((== Just "3.12") . ltGoReq) (selected old))
  new <- mustPlan [cand "0.1.11" "v0.1.11" wide]
  assertTrue
    "plain lane is 3.13"
    (all ((== Just "3.13") . ltGoReq) (selectedPlain new))
  excluded <-
    assertLeft "excluded" $
      planOf [cand "0.1.10" "v0.1.10" ">=3.20"]
  assertEq "not selected" PlanZeroPlannedPVs excluded

testCollapse :: IO ()
testCollapse = do
  plan <-
    mustPlan
      [ cand "0.1.10" "v0.1.10" ">=3.8,<3.13",
        cand "0.1.11" "v0.1.11" ">=3.8,<3.14"
      ]
  assertEq "newer pv" [parseEbuildVersion "0.1.11"] (glpUniquePVs plan)
  assertTrue "plain is 3.13" (all ((== Just "3.13") . ltGoReq) (selectedPlain plan))
  assertTrue "tilde is 3.13" (all ((== Just "3.13") . ltGoReq) (selectedTilde plan))
  assertEq
    "raw tag"
    (Just "v0.1.11")
    (lookupUvRawTag plan (parseEbuildVersion "0.1.11"))

testDisagreement :: IO ()
testDisagreement = do
  plan <-
    mustPlan
      [ cand "0.1.10" "v0.1.10" ">=3.8,<3.14",
        cand "0.1.11" "v0.1.11" ">=3.14"
      ]
  assertEq "two pvs" 2 (length (glpEbuilds plan))
  mapM_ (assertTildeOnly plan) ["0.1.10", "0.1.11"]

testSlot312Keywords :: IO ()
testSlot312Keywords = do
  plan <- mustPlan [cand "0.1.10" "v0.1.10" ">=3.8,<3.13"]
  eb <- case glpEbuilds plan of
    [one] -> pure one
    other -> fail ("ebuild count " <> show (length other))
  assertTrue "~amd64" ("~amd64" `elem` peKeywords eb)
  assertTrue "~arm64" ("~arm64" `elem` peKeywords eb)
  assertTrue "no bare amd64" ("amd64" `notElem` peKeywords eb)
  assertTrue "no mask" ("-*" `notElem` peKeywords eb)
  let labels = map glLabel (buildGapLines [] (glpUniquePVs plan) plan)
  assertTrue
    "plain label"
    ("(dev-lang/python:3.12 amd64)" `elem` labels)
  assertTrue
    "tilde label"
    (any (\l -> "dev-lang/python:3.12" `T.isInfixOf` l && "~amd64" `T.isInfixOf` l) labels)

testExcludedCeiling :: IO ()
testExcludedCeiling = do
  let inv =
        inventoryFromRows
          [ ("3.12", ["amd64", "arm64"]),
            ("3.13", ["amd64", "arm64"]),
            ("3.14", ["amd64", "arm64"]),
            ("3.15", ["~amd64", "~arm64"])
          ]
      req = ">=3.8,<3.14"
      one =
        UvCandidate
          { ucPV = parseEbuildVersion "0.1.11",
            ucTag = "v0.1.11",
            ucRequires = Just req,
            ucSynced = pdmRecordedSync inv (Just req)
          }
  assertEq "records 3.13" (Set.singleton "3.13") (ucSynced one)
  got <-
    assertRight "plan" $
      planUvFromCandidates inv [] [ucPV one] [one]
  assertTrue "plain selected" (not (null (selectedPlain got)))
  assertTrue "plain is 3.13" (all ((== Just "3.13") . ltGoReq) (selectedPlain got))
  assertTrue "tilde is 3.13" (all ((== Just "3.13") . ltGoReq) (selectedTilde got))

testTildeOnlyLabel :: IO ()
testTildeOnlyLabel = do
  plan <- mustPlan [cand "0.1.12" "v0.1.12" ">=3.15"]
  assertTrue "no plain target" (all ((== Nothing) . ltPackagePV) (plainLanes plan))
  let labels = map glLabel (buildGapLines [] (glpUniquePVs plan) plan)
  assertTrue
    "tilde label"
    (any (\l -> "dev-lang/python:3.15" `T.isInfixOf` l && "~amd64" `T.isInfixOf` l) labels)
  assertTrue
    "no plain line"
    (all (\l -> not ("3.15 amd64)" `T.isInfixOf` l)) labels)

testRewrite :: IO ()
testRewrite = do
  let body = ensureUvArchiveTag "v0.1.10" seedUri
  assertTrue "raw tag" ("refs/tags/v0.1.10.tar.gz" `T.isInfixOf` body)
  assertTrue "parameterized assets" ("cmake-language-server-${PV}" `T.isInfixOf` body)
  let rewritten = ensurePythonSlot "3.13" donor
  assertTrue "format flag" ("IUSE=\"+format\"" `T.isInfixOf` rewritten)
  assertTrue "format install" ("cmakelang==0.6.13" `T.isInfixOf` rewritten)
  assertTrue "six pin" ("six==1.16.0" `T.isInfixOf` rewritten)
  assertTrue "cmake-format" ("/usr/bin/cmake-format" `T.isInfixOf` rewritten)
  assertTrue "parse variables" ("test_parse_variables" `T.isInfixOf` rewritten)
  assertTrue "parse modules" ("test_parse_modules" `T.isInfixOf` rewritten)
  assertTrue "find_package" ("find_package(" `T.isInfixOf` rewritten)
  assertTrue "boost" ("Boost" `T.isInfixOf` rewritten)
  assertTrue "slot atom" ("dev-lang/python:3.13" `T.isInfixOf` rewritten)
  assertTrue "compat" ("python3_13" `T.isInfixOf` rewritten)
  assertTrue "interpreter" ("/usr/bin/python3.13" `T.isInfixOf` rewritten)
  assertTrue "old interpreter gone" (not ("/usr/bin/python3.12" `T.isInfixOf` rewritten))

testDryRunArgs :: IO ()
testDryRunArgs = do
  assertEq "use" ["use", "-f", "/usr/bin/python3.12"] (pdmUseArgs "3.12")
  assertEq "dry-run" ["sync", "-G", "dev", "--dry-run"] pdmDryRunArgs
  assertTrue "use does not fetch" (pdmArgsAvoidFetch (pdmUseArgs "3.12"))
  assertTrue "dry-run does not fetch" (pdmArgsAvoidFetch pdmDryRunArgs)
  names <- assertRight "summary" (parsePdmDryRun dryRun)
  assertEq "dev set" (devPins ++ [("ignored", "0.2")]) names
  empty <- assertLeft "empty" (parsePdmDryRun "All packages are synced.\n")
  assertTrue "dev set missing" ("did not list" `T.isInfixOf` empty)

testPackPlan :: IO ()
testPackPlan = do
  let summary =
        T.unlines $
          "Packages to add:"
            : [ "  - " <> name <> " " <> ver
              | (name, ver) <- devPins ++ [("colorama", "0.4.6")]
              ]
  names <- assertRight "summary" (parsePdmDryRun summary)
  files <-
    assertRight "pack" $
      finalizePack
        packLock
        "cmake-language-server"
        (("cmake-language-server", "0.1.10") : names)
        "3.12"
        ( Map.fromList
            [ ("coverage", ["setuptools"]),
              ("setuptools", ["wheel"])
            ]
        )
        ["pdm-backend"]
        catalog
  let bases = map (T.pack . pkPath) files
  assertEq "file count" 15 (length files)
  mapM_ (assertHasWheel files) devWheels
  cov <- case [f | f <- files, pkName f == "coverage"] of
    [f] -> pure f
    other -> fail ("coverage files " <> show (length other))
  assertEq "coverage sdist" "dists/coverage-7.4.4.tar.gz" (pkPath cov)
  assertTrue "no coverage wheel" (not (any isCoverageWheel files))
  assertTrue "no lint" (not (any isLint files))
  assertTrue "setuptools" (any (("setuptools-70.1.0" `T.isInfixOf`) . pkFile) files)
  assertTrue "not the too-new setuptools" (not (any (("setuptools-71" `T.isInfixOf`) . pkFile) files))
  assertTrue "pdm-backend" (any (("pdm_backend-2.4.3" `T.isInfixOf`) . pkFile) files)
  assertTrue "wheel stops the walk" (not (any (("/wheel-" `T.isInfixOf`) . T.pack . pkPath) files))
  assertTrue "no colorama" (all ((/= "colorama") . pkName) files)
  assertTrue "dists layout" (all (\p -> "dists/" `T.isPrefixOf` p) bases)
  where
    isCoverageWheel f =
      pkName f == "coverage" && ".whl" `T.isSuffixOf` pkFile f
    isLint f = pkName f `elem` ["mypy", "black", "flake8", "isort"]

testHashMismatch :: IO ()
testHashMismatch = do
  ok <- assertRight "match" (verifyFileHash "sha256:AbC" "abc")
  assertEq "unit" () ok
  err <- assertLeft "mismatch" (verifyFileHash "sha256:abc" "def")
  assertTrue "mismatch text" ("hash mismatch" `T.isInfixOf` err)

sampleLock :: T.Text
sampleLock =
  T.unlines
    [ "[metadata]",
      "groups = [\"default\", \"dev\", \"lint\"]",
      "lock_version = \"4.4.1\"",
      "",
      "[[package]]",
      "name = \"attrs\"",
      "version = \"23.2.0\"",
      "requires_python = \">=3.7\"",
      "files = [",
      "    {file = \"attrs-23.2.0-py3-none-any.whl\", hash = \"sha256:abc\"},",
      "    {file = \"attrs-23.2.0.tar.gz\", hash = \"sha256:def\"},",
      "]",
      "",
      "[[package]]",
      "name = \"click-host\"",
      "version = \"8.1.7\"",
      "dependencies = [",
      "    \"click\",",
      "]",
      "files = [",
      "    {file = \"click-8.1.7-py3-none-any.whl\", hash = \"sha256:c\"},",
      "]",
      "",
      "[[package]]",
      "name = \"coverage\"",
      "version = \"7.4.4\"",
      "files = [",
      "    {file = \"coverage-7.4.4-cp312-cp312-manylinux.whl\", hash = \"sha256:w\"},",
      "    {file = \"coverage-7.4.4-pp38.pp39.pp310-none-any.whl\", hash = \"sha256:p\"},",
      "    {file = \"coverage-7.4.4.tar.gz\", hash = \"sha256:s\"},",
      "]",
      "",
      "[[package]]",
      "name = \"coverage\"",
      "version = \"7.4.4\"",
      "extras = [\"toml\"]",
      "files = [",
      "    {file = \"coverage-7.4.4.tar.gz\", hash = \"sha256:s\"},",
      "]"
    ]

metaLock :: T.Text
metaLock =
  T.unlines
    [ "[metadata]",
      "requires_python = \">=3.8,<3.14\"",
      "",
      "[[package]]",
      "name = \"attrs\"",
      "version = \"23.2.0\"",
      "files = [",
      "    {file = \"attrs-23.2.0-py3-none-any.whl\", hash = \"sha256:abc\"},",
      "]"
    ]

pyproject :: T.Text
pyproject =
  T.unlines
    [ "[project]",
      "name = \"cmake-language-server\"",
      "requires-python = \">=3.8.0,<3.13\"",
      "",
      "[build-system]",
      "requires = [\"pdm-backend\"]",
      "build-backend = \"pdm.backend\""
    ]

devWheels :: [(T.Text, T.Text)]
devWheels =
  [ ("pygls", "1.3.1"),
    ("lsprotocol", "2023.0.1"),
    ("cattrs", "23.2.3"),
    ("attrs", "23.2.0"),
    ("pytest", "8.1.1"),
    ("pytest-datadir", "1.5.0"),
    ("pytest-cov", "5.0.0"),
    ("cmakelang", "0.6.13"),
    ("six", "1.16.0"),
    ("iniconfig", "2.0.0"),
    ("packaging", "24.0"),
    ("pluggy", "1.4.0")
  ]

devPins :: [(T.Text, T.Text)]
devPins = devWheels ++ [("coverage", "7.4.4")]

dryRun :: T.Text
dryRun =
  T.unlines $
    "Packages to add:"
      : [ "  - " <> name <> " " <> ver
        | (name, ver) <- devPins
        ]
      ++ [ "Packages to update:",
           "  - ignored 0.1 -> 0.2",
           "Packages to remove:",
           "  - stale 1.0"
         ]

packLock :: PdmLock
packLock =
  PdmLock
    { plRequiresPython = Nothing,
      plPackages =
        [ wheelPkg name ver [] []
        | (name, ver) <- devWheels,
          name /= "six"
        ]
          ++ [ withFiles
                 (wheelPkg "six" "1.16.0" [] [])
                 [ PdmFile "six-1.16.0-py2.py3-none-any.whl" "sha256:six" Nothing,
                   PdmFile "six-1.16.0.tar.gz" "sha256:sixs" Nothing
                 ],
               wheelPkg "click" "8.1.7" ["colorama; platform_system == \"Windows\""] [],
               wheelPkg "colorama" "0.4.6" [] [],
               withFiles
                 (wheelPkg "coverage" "7.4.4" [] [])
                 [ PdmFile "coverage-7.4.4-cp312-cp312-manylinux.whl" "sha256:w" Nothing,
                   PdmFile "coverage-7.4.4-pp38.pp39.pp310-none-any.whl" "sha256:p" Nothing,
                   PdmFile "coverage-7.4.4.tar.gz" "sha256:s" Nothing
                 ],
               withFiles
                 (wheelPkg "coverage" "7.4.4" [] ["toml"])
                 [PdmFile "coverage-7.4.4.tar.gz" "sha256:s" Nothing],
               wheelPkg "mypy" "1.9.0" [] [],
               wheelPkg "black" "24.3.0" [] [],
               wheelPkg "flake8" "5.0.4" [] [],
               wheelPkg "isort" "5.13.2" [] []
             ]
    }

withFiles :: PdmPackage -> [PdmFile] -> PdmPackage
withFiles pkg files = pkg {ppFiles = files}

wheelPkg :: T.Text -> T.Text -> [T.Text] -> [T.Text] -> PdmPackage
wheelPkg name ver deps extras =
  PdmPackage
    { ppName = name,
      ppVersion = ver,
      ppRequiresPython = Nothing,
      ppExtras = extras,
      ppGroups = [],
      ppDependencies = deps,
      ppFiles =
        [ PdmFile (name <> "-" <> ver <> "-py3-none-any.whl") "sha256:w" Nothing,
          PdmFile (name <> "-" <> ver <> ".tar.gz") "sha256:s" Nothing
        ]
    }

catalog :: Map.Map T.Text [BackendOffer]
catalog =
  Map.fromList
    [ ( "setuptools",
        [ BackendOffer "69.0.0" (Just ">=3.8") [offer "setuptools-69.0.0-py3-none-any.whl"],
          BackendOffer "71.0.0" (Just ">=3.14") [offer "setuptools-71.0.0-py3-none-any.whl"],
          BackendOffer "70.1.0" (Just ">=3.8") [offer "setuptools-70.1.0-py3-none-any.whl"]
        ]
      ),
      ( "pdm-backend",
        [BackendOffer "2.4.3" (Just ">=3.7") [offer "pdm_backend-2.4.3-py3-none-any.whl"]]
      ),
      ( "wheel",
        [BackendOffer "0.43.0" (Just ">=3.8") [offer "wheel-0.43.0-py3-none-any.whl"]]
      )
    ]
  where
    offer file = PdmFile file "sha256:b" Nothing

assertHasWheel :: [PackedFile] -> (T.Text, T.Text) -> IO ()
assertHasWheel files (name, ver) =
  assertTrue (T.unpack name) $
    any
      ( \f ->
          pkName f == name
            && (name <> "-" <> ver) `T.isInfixOf` pkFile f
            && ".whl" `T.isSuffixOf` pkFile f
      )
      files

seedUri :: T.Text
seedUri =
  T.unlines
    [ "SRC_URI=\"",
      "  https://github.com/regen100/cmake-language-server/archive/refs/tags/v0.0.0.tar.gz -> ${P}.tar.gz",
      "  https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/cmake-language-server-${PV}/cmake-language-server-${PV}-deps.tar.xz",
      "\""
    ]

donor :: T.Text
donor =
  T.unlines
    [ "EAPI=8",
      "PYTHON_COMPAT=( python3_12 )",
      "IUSE=\"+format\"",
      "RDEPEND=\"dev-lang/python:3.12\"",
      "src_test() {",
      "  epytest tests -k 'not test_parse_variables and not test_parse_modules and not find_package( and not Boost'",
      "}",
      "src_install() {",
      "  \"${VIRTUAL_ENV}/bin/pip\" install --no-index 'cmakelang==0.6.13' 'six==1.16.0'",
      "  dosym ../lib/cmake-language-server/bin/cmake-format /usr/bin/cmake-format",
      "  pdm use -f /usr/bin/python3.12",
      "}"
    ]

pdmInv :: PythonSlotInventory
pdmInv =
  inventoryFromRows
    [ ("3.12", ["amd64", "arm64"]),
      ("3.12", ["~amd64", "~arm64"]),
      ("3.13", ["amd64", "arm64"]),
      ("3.13", ["~amd64", "~arm64"]),
      ("3.14", ["~amd64", "~arm64"]),
      ("3.15", ["~amd64", "~arm64"])
    ]

cand :: T.Text -> T.Text -> T.Text -> UvCandidate
cand pv tag req =
  UvCandidate
    { ucPV = parseEbuildVersion pv,
      ucTag = tag,
      ucRequires = Just req,
      ucSynced = pdmRecordedSync pdmInv (Just req)
    }

planOf :: [UvCandidate] -> Either PlanError RuntimeLanePlan
planOf cands =
  planUvFromCandidates pdmInv [] (map ucPV cands) cands

mustPlan :: [UvCandidate] -> IO RuntimeLanePlan
mustPlan cands = assertRight "plan" (planOf cands)

plainLanes :: RuntimeLanePlan -> [LaneTarget]
plainLanes plan = [t | t <- glpLanes plan, liTier (ltLane t) == Plain]

selected :: RuntimeLanePlan -> [LaneTarget]
selected plan = [t | t <- glpLanes plan, isJust (ltPackagePV t)]

selectedPlain :: RuntimeLanePlan -> [LaneTarget]
selectedPlain plan = [t | t <- plainLanes plan, isJust (ltPackagePV t)]

selectedTilde :: RuntimeLanePlan -> [LaneTarget]
selectedTilde plan =
  [t | t <- glpLanes plan, liTier (ltLane t) == Tilde, isJust (ltPackagePV t)]

assertTildeOnly :: RuntimeLanePlan -> T.Text -> IO ()
assertTildeOnly plan pv = do
  eb <- case [e | e <- glpEbuilds plan, samePV (pePV e) (parseEbuildVersion pv)] of
    [e] -> pure e
    other -> fail (T.unpack pv <> " count " <> show (length other))
  assertTrue (T.unpack pv <> " tilde") (all ("~" `T.isPrefixOf`) (peKeywords eb))
  assertTrue (T.unpack pv <> " no mask") ("-*" `notElem` peKeywords eb)
  assertTrue (T.unpack pv <> " no bare") (all (T.isPrefixOf "~") (peKeywords eb))
