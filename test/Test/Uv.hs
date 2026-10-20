{-# LANGUAGE OverloadedStrings #-}

-- | Uv lock parsing, pack plan, Python slot lanes, and ebuild rewrites.
module Test.Uv (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Version (parseEbuildVersion, samePV)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
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
import Update.Process
  ( ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Uv.Deps (backendSdistUrl, planBackendSdists)
import Update.Uv.Lock
  ( UvEdge (..),
    UvFile (..),
    UvLock (..),
    UvPackage (..),
    UvSource (..),
    parseUvLock,
    parseUvLockFile,
  )
import Update.Uv.Pack
  ( PyprojectBuild (..),
    SdistPack (..),
    acceptFrozenSync,
    buildRequiresOf,
    classifyPyprojectBuild,
    frozenUvSyncArgs,
    frozenUvSyncEnv,
    nameKeptDespiteWindowsMarker,
    packRunsUvLock,
    packSdists,
    parseDryRunSdists,
    parseSelectingSdists,
    requirementName,
    setuptoolsFallbackRequires,
    windowsOnlyNames,
  )
import Update.Uv.Python
  ( ProbeStep (..),
    PythonSlotInventory,
    UvCandidate (..),
    classifyPythonFind,
    inventoryFromRows,
    parseRequiresPython,
    plainCeilingSlot,
    planUvFromCandidates,
    probeOrdered,
    pythonEbuildRows,
    pythonEbuildSlot,
    slotsInProbeOrder,
    tildeCeilingSlot,
  )

tests :: TestTree
tests =
  testGroup
    "Uv"
    [ testCase "uv.lock revision 3" testLockRevision3,
      testCase "uv.lock revision 2 git and path" testLockRevision2,
      testCase "missing uv.lock is a hard failure" testMissingLock,
      testCase "windows-only names stay parsed and leave the pack" testWindowsPack,
      testCase "frozen sync pack plan" testFrozenPack,
      testCase "python slot ceilings" testSlotCeilings,
      testCase "python PYVER slot" testPythonPyverSlot,
      testCase "requires-python chooses one slot" testRequiresPython,
      testCase "sync filter splits and drops plain" testSyncFilter,
      testCase "specifier excludes the newer stable slot" testSpecifierCeiling,
      testCase "probe order and missing interpreter" testProbeOrder,
      testCase "keywords and lane labels" testKeywords,
      testCase "raw archive tag rewrite" testArchiveTag,
      testCase "python slot donor rewrite" testDonorSlot,
      testCase "build-backend sdist closure" testBuildBackends,
      testCase "backend scratch stays in the work dir" testBackendScratch
    ]

fullArches :: [T.Text]
fullArches =
  [ "alpha",
    "amd64",
    "arm",
    "arm64",
    "hppa",
    "loong",
    "m68k",
    "mips",
    "ppc",
    "ppc64",
    "riscv",
    "s390",
    "sparc",
    "x86"
  ]

plainArches :: [T.Text]
plainArches = ["amd64", "arm", "arm64", "ppc", "ppc64", "x86"]

fullKeywords :: T.Text
fullKeywords = T.unwords (map ("~" <>) fullArches)

plainKeywords :: T.Text
plainKeywords = T.unwords (map ("~" <>) plainArches)

fixtureInv :: PythonSlotInventory
fixtureInv =
  inventoryFromRows
    [ ("3.14", plainArches),
      ("3.14", map ("~" <>) fullArches),
      ("3.15", map ("~" <>) fullArches)
    ]

richInv :: PythonSlotInventory
richInv =
  inventoryFromRows
    [ ("3.13", plainArches),
      ("3.13", map ("~" <>) fullArches),
      ("3.14", plainArches),
      ("3.14", map ("~" <>) fullArches),
      ("3.15", map ("~" <>) fullArches)
    ]

rev3Doc :: T.Text
rev3Doc =
  T.unlines
    [ "version = 1",
      "revision = 3",
      "requires-python = \">=3.11\"",
      "",
      "[[package]]",
      "name = \"codex-as-mcp\"",
      "version = \"2026.2.2.1\"",
      "source = { editable = \".\" }",
      "dependencies = [",
      "  { name = \"click\" },",
      "  { name = \"packaging\" },",
      "  { name = \"packaging\", marker = \"sys_platform == 'win32'\" },",
      "  { name = \"colorama\", marker = \"sys_platform == 'win32'\" },",
      "  { name = \"pywin32-ctypes\", marker = \"os_name == 'nt'\" },",
      "]",
      "",
      "[[package]]",
      "name = \"click\"",
      "version = \"8.1.7\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "sdist = { url = \"https://files.example/click-8.1.7.tar.gz\", hash = \"sha256:click\" }",
      "",
      "[[package]]",
      "name = \"packaging\"",
      "version = \"24.0\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "sdist = { url = \"https://files.example/packaging-24.0.tar.gz\", hash = \"sha256:pack\" }",
      "",
      "[[package]]",
      "name = \"colorama\"",
      "version = \"0.4.6\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "sdist = { url = \"https://files.example/colorama-0.4.6.tar.gz\", hash = \"sha256:color\" }",
      "",
      "[[package]]",
      "name = \"pywin32\"",
      "version = \"311\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "wheels = [",
      "  { url = \"https://files.example/pywin32-311.whl\", hash = \"sha256:win\" },",
      "]",
      "",
      "[[package]]",
      "name = \"pywin32-ctypes\"",
      "version = \"0.2.2\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "sdist = { url = \"https://files.example/pywin32-ctypes-0.2.2.tar.gz\", hash = \"sha256:ctypes\" }",
      ""
    ]

rev2Doc :: T.Text
rev2Doc =
  T.unlines
    [ "version = 1",
      "revision = 2",
      "requires-python = \">=3.11\"",
      "",
      "[[package]]",
      "name = \"demo\"",
      "version = \"1.0.0\"",
      "source = { editable = \".\" }",
      "dependencies = [ { name = \"tool\" } ]",
      "dev-dependencies = { dev = [ { name = \"pytest\" } ] }",
      "",
      "[[package]]",
      "name = \"tool\"",
      "version = \"0.1.0\"",
      "source = { git = \"https://github.com/example/tool.git\", rev = \"abc123\" }",
      "sdist = { url = \"https://example.invalid/tool-0.1.0.tar.gz\", hash = \"sha256:git\" }",
      "",
      "[[package]]",
      "name = \"localdep\"",
      "version = \"0.0.1\"",
      "source = { path = \"../localdep\" }",
      ""
    ]

testLockRevision3 :: IO ()
testLockRevision3 = do
  lock <- assertRight "rev 3" (parseUvLock rev3Doc)
  assertEq "version" 1 (ulVersion lock)
  assertEq "revision" (Just 3) (ulRevision lock)
  assertEq "requires" (Just ">=3.11") (ulRequiresPython lock)
  let names = map upName (ulPackages lock)
  assertTrue "click parsed" ("click" `elem` names)
  assertTrue "colorama stays in the model" ("colorama" `elem` names)
  assertTrue "pywin32 stays in the model" ("pywin32" `elem` names)
  click <- assertRight "click" (findPkg lock "click")
  assertEq
    "registry"
    (UvRegistry "https://pypi.org/simple")
    (upSource click)
  let colorEdge =
        [ e
        | p <- ulPackages lock,
          e <- upDependencies p,
          ueName e == "colorama"
        ]
  assertEq
    "windows marker"
    [Just "sys_platform == 'win32'"]
    (map ueMarker colorEdge)
  pywin <- assertRight "pywin32" (findPkg lock "pywin32")
  assertEq "wheel only" Nothing (upSdist pywin)
  assertTrue "wheel kept on the package" (not (null (upWheels pywin)))
  err <- assertLeft "unreadable" (parseUvLock "version = [")
  assertTrue "unreadable document" ("unreadable uv.lock" `T.isInfixOf` err)

testLockRevision2 :: IO ()
testLockRevision2 = do
  lock <- assertRight "rev 2" (parseUvLock rev2Doc)
  assertEq "revision 2" (Just 2) (ulRevision lock)
  tool <- assertRight "tool" (findPkg lock "tool")
  assertEq
    "git source"
    (UvGit "https://github.com/example/tool.git" "abc123")
    (upSource tool)
  localdep <- assertRight "path" (findPkg lock "localdep")
  assertEq "path source" (UvPath "../localdep") (upSource localdep)
  demo <- assertRight "demo" (findPkg lock "demo")
  let devNames =
        [ ueName e
        | edges <- Map.elems (upDevDependencies demo),
          e <- edges
        ]
  assertEq "dev group" ["pytest"] devNames

testMissingLock :: IO ()
testMissingLock =
  withSystemTempDirectory "uv-lock-missing" $ \dir -> do
    err <- assertLeft "missing" =<< parseUvLockFile (dir </> "uv.lock")
    assertTrue "missing file" ("uv.lock is missing" `T.isInfixOf` err)

testWindowsPack :: IO ()
testWindowsPack = do
  lock <- assertRight "lock" (parseUvLock rev3Doc)
  assertEq
    "windows-only names"
    (Set.fromList ["colorama", "pywin32-ctypes"])
    (windowsOnlyNames lock)
  assertTrue
    "unconditional and windows marker is kept"
    (nameKeptDespiteWindowsMarker lock "packaging")
  assertTrue
    "windows-only name is not the kept case"
    (not (nameKeptDespiteWindowsMarker lock "colorama"))
  let resolved = Set.fromList ["click", "packaging"]
  packed <- assertRight "pack" (packSdists lock resolved Set.empty)
  assertEq
    "linux closure only"
    ["click", "packaging"]
    (map spName packed)
  assertTrue
    "sdists layout"
    (all (\p -> "sdists/" `T.isPrefixOf` T.pack (spRelativePath p)) packed)
  wheelErr <- assertLeft "wheel only" (packSdists lock (Set.singleton "pywin32") Set.empty)
  assertTrue "no sdist" ("has no sdist" `T.isInfixOf` wheelErr)

testBuildBackends :: IO ()
testBuildBackends = do
  quoted <-
    assertRight "single quotes" $
      classifyPyprojectBuild $
        T.unlines
          [ "[build-system]",
            "requires = [",
            "  'setuptools>=61.2',",
            "  'setuptools_scm[toml]>=3.4.1', # keep",
            "]"
          ]
  assertEq
    "quoted requires"
    (BuildRequires ["setuptools>=61.2", "setuptools_scm[toml]>=3.4.1"])
    quoted
  assertEq
    "requirement name"
    "setuptools-scm"
    (requirementName "setuptools_scm[toml]>=3.4.1")
  assertEq
    "marker name"
    "typing-extensions"
    (requirementName "typing-extensions >=4.6.0,!=4.7.0")
  assertEq
    "no build-system table"
    (Right NoBuildSystem)
    (classifyPyprojectBuild "[project]\nname = \"h11\"\n")
  assertEq "setuptools fallback" ["setuptools", "wheel"] (buildRequiresOf NoBuildSystem)
  assertEq "exported fallback" ["setuptools", "wheel"] setuptoolsFallbackRequires
  malformed <- assertLeft "malformed requires" $ classifyPyprojectBuild "[build-system]\nrequires = 1\n"
  assertTrue "requires array" ("not an array" `T.isInfixOf` malformed)
  emptyReqs <- assertRight "empty requires" $ classifyPyprojectBuild "[build-system]\nrequires = []\n"
  assertEq "empty list" (BuildRequires []) emptyReqs
  hatchlingPick <-
    assertRight "selecting line" $
      parseSelectingSdists
        "DEBUG Selecting: hatchling==1.32.4 [compatible] (hatchling-1.32.4.tar.gz)\n"
  assertEq
    "hatchling sdist"
    [("hatchling", "1.32.4", "hatchling-1.32.4.tar.gz")]
    hatchlingPick
  wheelErr <-
    assertLeft "wheel filename" $
      parseSelectingSdists
        "DEBUG Selecting: poetry-core==2.5.0 [compatible] (poetry_core-2.5.0-py3-none-any.whl)\n"
  assertTrue "non-sdist" ("non-sdist" `T.isInfixOf` wheelErr)
  chosen <-
    assertRight "would install" $
      parseDryRunSdists $
        T.unlines
          [ "DEBUG Selecting: setuptools-scm==10.3.4 [compatible] (setuptools_scm-10.3.4.tar.gz)",
            "DEBUG Selecting: setuptools-scm==8.3.1 [compatible] (setuptools_scm-8.3.1.tar.gz)",
            "DEBUG Selecting: setuptools==84.0.0 [compatible] (setuptools-84.0.0.tar.gz)",
            "Would install 2 packages",
            " + setuptools==84.0.0",
            " + setuptools-scm==8.3.1"
          ]
  assertEq
    "final sdists only"
    [ ("setuptools", "84.0.0", "setuptools-84.0.0.tar.gz"),
      ("setuptools-scm", "8.3.1", "setuptools_scm-8.3.1.tar.gz")
    ]
    chosen
  onlyWheel <-
    assertLeft "would install wheel" $
      parseDryRunSdists $
        T.unlines
          [ "DEBUG Selecting: poetry-core==2.5.0 [compatible] (poetry_core-2.5.0-py3-none-any.whl)",
            "Would install 1 package",
            " + poetry-core==2.5.0"
          ]
  assertTrue "wheel is not packed" ("non-sdist" `T.isInfixOf` onlyWheel)

-- | The materialize container bind-mounts the unit work directory. A fake
-- runner records the paths uv and python are given and reads those files
-- while the call is in progress.
testBackendScratch :: IO ()
testBackendScratch = withSystemTempDirectory "uv-scratch" $ \work -> do
  called <- newIORef False
  empty <- planBackendSdists (mark called) "3.13" [] (work </> "missing")
  assertEq "empty plan" (Right []) empty
  assertEq "empty plan does not run" False =<< readIORef called
  venvRef <- newIORef ""
  reqRef <- newIORef ""
  let dry =
        T.unlines
          [ "DEBUG Selecting: setuptools==84.0.0 [compatible] (setuptools-84.0.0.tar.gz)",
            "Would install 1 package",
            " + setuptools==84.0.0"
          ]
      runPlan req = case prMode req of
        ExecCmd "uv" ["venv", "--python", py, venv] -> do
          assertEq "slot interpreter" "/usr/bin/python3.13" py
          writeIORef venvRef venv
          pure ok
        ExecCmd "uv" args -> do
          let path = flagArg "-r" args
          exists <- doesFileExist path
          body <- TIO.readFile path
          assertTrue "requirements exist when uv runs" exists
          assertEq "requirements body" "setuptools>=61\n" body
          writeIORef reqRef path
          pure ok {prStdout = T.unpack dry}
        other -> assertFailure ("unexpected plan command: " <> show other)
  planned <-
    assertRight "plan" =<< planBackendSdists runPlan "3.13" ["setuptools>=61"] work
  assertEq
    "planned sdist"
    [("setuptools", "84.0.0", "setuptools-84.0.0.tar.gz")]
    planned
  venv <- readIORef venvRef
  reqPath <- readIORef reqRef
  assertTrue "venv under work" (underWork work venv)
  assertTrue "requirements under work" (underWork work reqPath)
  assertEq "same scratch dir" (takeDirectory venv) (takeDirectory reqPath)
  assertTrue
    "plan prefix"
    ("uv-backend-plan-" `isPrefixOf` takeFileName (takeDirectory reqPath))
  scriptRef <- newIORef ""
  let runUrl req = case prMode req of
        ExecCmd "/usr/bin/python3.13" (script : "setuptools" : "84.0.0" : _) -> do
          exists <- doesFileExist script
          body <- TIO.readFile script
          assertTrue "script exists when python runs" exists
          assertTrue "script queries pypi" ("pypi.org" `T.isInfixOf` body)
          writeIORef scriptRef script
          pure
            ok
              { prStdout =
                  "https://files.pythonhosted.org/packages/source/s/setuptools/setuptools-84.0.0.tar.gz\n"
              }
        other -> assertFailure ("unexpected url command: " <> show other)
  url <-
    assertRight "url"
      =<< backendSdistUrl runUrl "3.13" "setuptools" "84.0.0" work
  assertEq
    "sdist url"
    "https://files.pythonhosted.org/packages/source/s/setuptools/setuptools-84.0.0.tar.gz"
    url
  script <- readIORef scriptRef
  assertTrue "script under work" (underWork work script)
  assertEq "script name" "sdist_url.py" (takeFileName script)
  assertTrue
    "url prefix"
    ("uv-sdist-url-" `isPrefixOf` takeFileName (takeDirectory script))
  where
    mark ref _ = do
      writeIORef ref True
      pure ok
    ok =
      ProcessResult
        { prExitCode = ExitSuccess,
          prStdout = "",
          prStderr = ""
        }
    flagArg flag args = case dropWhile (/= flag) args of
      (_ : path : _) -> path
      _ -> ""
    underWork parent path =
      splitDirectories parent `isPrefixOf` splitDirectories path

testFrozenPack :: IO ()
testFrozenPack = do
  assertEq "frozen success" (Right ()) (acceptFrozenSync True True)
  assertEq "stale lock still packs" (Right ()) (acceptFrozenSync True False)
  assertEq "sync failure" (Left "uv sync --frozen failed") (acceptFrozenSync False True)
  assertTrue "does not run uv lock" (not packRunsUvLock)
  assertEq
    "frozen args"
    [ "sync",
      "--frozen",
      "--all-groups",
      "--no-install-project",
      "--python",
      "3.14"
    ]
    (frozenUvSyncArgs "3.14")
  assertTrue
    "args do not lock"
    (not (any (T.isInfixOf "lock") (frozenUvSyncArgs "3.14")))
  assertEq "no python downloads" [("UV_PYTHON_DOWNLOADS", "never")] frozenUvSyncEnv
  lock <- assertRight "lock" (parseUvLock rustDoc)
  packed <-
    assertRight
      "vendor mark"
      (packSdists lock (Set.singleton "pydantic-core") (Set.singleton "pydantic-core"))
  assertEq "one sdist" ["pydantic-core"] (map spName packed)
  assertEq "marked for cargo vendor" [True] (map spCargoVendor packed)
  assertEq
    "relative path"
    ["sdists/pydantic_core-2.0.0.tar.gz"]
    (map spRelativePath packed)

rustDoc :: T.Text
rustDoc =
  T.unlines
    [ "version = 1",
      "revision = 3",
      "requires-python = \">=3.11\"",
      "",
      "[[package]]",
      "name = \"pydantic-core\"",
      "version = \"2.0.0\"",
      "source = { registry = \"https://pypi.org/simple\" }",
      "sdist = { url = \"https://files.example/pydantic_core-2.0.0.tar.gz\", hash = \"sha256:rust\" }",
      ""
    ]

testSlotCeilings :: IO ()
testSlotCeilings = do
  assertEq "amd64 plain" (Just "3.14") (plainCeilingSlot "amd64" fixtureInv)
  assertEq "amd64 tilde" (Just "3.15") (tildeCeilingSlot "amd64" fixtureInv)
  assertEq "alpha plain" Nothing (plainCeilingSlot "alpha" fixtureInv)
  assertEq "alpha tilde" (Just "3.15") (tildeCeilingSlot "alpha" fixtureInv)

testPythonPyverSlot :: IO ()
testPythonPyverSlot = do
  assertEq
    "regular slot"
    (Just "3.14")
    (pythonEbuildSlot "3.14.7" (pyverEbuild "$(ver_cut 1-2)" "amd64 ~arm"))
  assertEq
    "free-threaded slot"
    Nothing
    (pythonEbuildSlot "0.3.14.7" (pyverEbuild "\"$(ver_cut 2-3)t\"" "~amd64"))
  let rows =
        concat
          [ pythonEbuildRows "3.14.7" (pyverEbuild "$(ver_cut 1-2)" "amd64 ~arm"),
            pythonEbuildRows "3.14.8" (pyverEbuild "$(ver_cut 1-2)" "~amd64 ~arm"),
            pythonEbuildRows "3.15.0" (pyverEbuild "$(ver_cut 1-2)" "~amd64 ~arm"),
            pythonEbuildRows "0.3.15.0" (pyverEbuild "\"$(ver_cut 2-3)t\"" "~amd64"),
            pythonEbuildRows "3.14.9999" (pyverEbuild "$(ver_cut 1-2)" "~amd64"),
            pythonEbuildRows "3.16.0_rc1" (pyverEbuild "$(ver_cut 1-2)" "~amd64")
          ]
      inv = inventoryFromRows rows
  assertEq "pyver plain" (Just "3.14") (plainCeilingSlot "amd64" inv)
  assertEq "pyver tilde" (Just "3.15") (tildeCeilingSlot "amd64" inv)
  where
    pyverEbuild expr keywords =
      T.unlines
        [ "PYVER=" <> expr,
          "SLOT=\"${PYVER}\"",
          "KEYWORDS=\"" <> keywords <> "\""
        ]

testRequiresPython :: IO ()
testRequiresPython = do
  broad <-
    mustPlan
      ">=3.11"
      [cand "2026.2.2.1" "2026.2.2.1" ">=3.11"]
  assertEq "one pv" [parseEbuildVersion "2026.2.2.1"] (glpUniquePVs broad)
  assertTrue
    "bare slot while 3.14 is stable"
    (all ((== Just "3.14") . ltGoReq) (selected broad))
  onlyNew <-
    mustPlan
      ">=3.15"
      [cand "2026.6.29.1" "v2026.6.29.1" ">=3.15"]
  assertTrue
    "no plain target"
    (all ((== Nothing) . ltPackagePV) (plainLanes onlyNew))
  assertTrue
    "tilde lanes choose 3.15"
    (all ((== Just "3.15") . ltGoReq) (selected onlyNew))
  let narrow =
        planUvFromCandidates
          fixtureInv
          []
          [parseEbuildVersion "2026.2.2.1"]
          [cand "2026.2.2.1" "2026.2.2.1" ">=3.8,<3.14"]
  assertEq "below 3.14 is not selected" (Left PlanZeroPlannedPVs) narrow
  let bad =
        planUvFromCandidates
          fixtureInv
          []
          [parseEbuildVersion "2026.2.2.1"]
          [cand "2026.2.2.1" "2026.2.2.1" "python3"]
  assertEq "unrecognized specifier" (Left PlanZeroPlannedPVs) bad
  split <-
    mustPlan
      "two slots"
      [ cand "2026.2.2.1" "2026.2.2.1" ">=3.11",
        cand "2026.6.29.1" "v2026.6.29.1" ">=3.15"
      ]
  assertEq "two pvs" 2 (length (glpUniquePVs split))
  one <-
    mustPlan
      "same slot"
      [cand "2026.2.2.1" "2026.2.2.1" ">=3.11"]
  assertEq "one pv when slots agree" 1 (length (glpUniquePVs one))

testSyncFilter :: IO ()
testSyncFilter = do
  only313 <-
    mustPlanOn
      richInv
      "tilde only"
      [ candSynced "2026.2.2.1" "2026.2.2.1" ">=3.11" ["3.13"],
        candSynced "2026.6.29.1" "v2026.6.29.1" ">=3.11" ["3.13"]
      ]
  assertEq
    "newer pv only"
    [parseEbuildVersion "2026.6.29.1"]
    (glpUniquePVs only313)
  assertTrue
    "plain has no target"
    (all ((== Nothing) . ltPackagePV) (plainLanes only313))
  assertTrue "plain lanes exist" (not (null (plainLanes only313)))
  assertTrue
    "tilde slot 3.13"
    (all ((== Just "3.13") . ltGoReq) (selected only313))
  eb313 <- assertRight "3.13 ebuild" (oneEbuild only313)
  assertEq "full tilde keywords" fullKeywords (T.unwords (peKeywords eb313))
  assertTrue "empty allowlist omits -*" ("-*" `notElem` peKeywords eb313)
  let labels = map glLabel (buildGapLines [] (glpUniquePVs only313) only313)
  assertTrue
    "tilde label"
    ("(dev-lang/python:3.13 ~amd64)" `elem` labels)
  assertTrue
    "no plain label"
    ("(dev-lang/python:3.13 amd64)" `notElem` labels)
  down <-
    mustPlanOn
      richInv
      "down split"
      [ candSynced "2026.2.2.1" "2026.2.2.1" ">=3.11" ["3.14"],
        candSynced "2026.6.29.1" "v2026.6.29.1" ">=3.11" ["3.13"]
      ]
  assertEq "two pvs down" 2 (length (glpUniquePVs down))
  assertTrue "plain lanes selected" (not (null (selectedPlain down)))
  assertTrue
    "plain keeps older slot"
    ( all
        ( \t ->
            ltPackagePV t == Just (parseEbuildVersion "2026.2.2.1")
              && ltGoReq t == Just "3.14"
        )
        (selectedPlain down)
    )
  assertTrue
    "tilde takes newer lower slot"
    ( all
        ( \t ->
            ltPackagePV t == Just (parseEbuildVersion "2026.6.29.1")
              && ltGoReq t == Just "3.13"
        )
        (selectedTilde down)
    )
  oldDown <- assertRight "old down" (ebuildFor down "2026.2.2.1")
  newDown <- assertRight "new down" (ebuildFor down "2026.6.29.1")
  assertEq "plain keywords" plainKeywords (T.unwords (peKeywords oldDown))
  assertEq "tilde keywords down" fullKeywords (T.unwords (peKeywords newDown))
  up <-
    mustPlanOn
      richInv
      "up split"
      [ candSynced "2026.2.2.1" "2026.2.2.1" ">=3.11" ["3.14"],
        candSynced "2026.6.29.1" "v2026.6.29.1" ">=3.11" ["3.15"]
      ]
  assertEq "two pvs up" 2 (length (glpUniquePVs up))
  assertTrue
    "plain keeps 3.14"
    (all ((== Just "3.14") . ltGoReq) (selectedPlain up))
  assertTrue
    "tilde takes 3.15"
    (all ((== Just "3.15") . ltGoReq) (selectedTilde up))

testSpecifierCeiling :: IO ()
testSpecifierCeiling = do
  plan <-
    mustPlanOn
      richInv
      "below 3.14"
      [candSynced "2026.2.2.1" "2026.2.2.1" ">=3.8,<3.14" ["3.13"]]
  assertTrue "plain selected" (not (null (selectedPlain plan)))
  assertTrue
    "plain is 3.13"
    (all ((== Just "3.13") . ltGoReq) (selectedPlain plan))
  assertTrue
    "tilde is 3.13"
    (all ((== Just "3.13") . ltGoReq) (selected plan))
  let labels = map glLabel (buildGapLines [] (glpUniquePVs plan) plan)
  assertTrue "plain label" ("(dev-lang/python:3.13 amd64)" `elem` labels)

testProbeOrder :: IO ()
testProbeOrder = do
  broad <- assertRight "broad" (parseRequiresPython ">=3.11")
  assertEq
    "bare then tilde"
    ["3.14", "3.13", "3.15"]
    (slotsInProbeOrder richInv broad)
  onlyNew <- assertRight "3.15" (parseRequiresPython ">=3.15")
  assertEq "tilde only order" ["3.15"] (slotsInProbeOrder richInv onlyNew)
  narrow <- assertRight "narrow" (parseRequiresPython ">=3.8,<3.14")
  assertEq "no legal slot" [] (slotsInProbeOrder fixtureInv narrow)
  stopped <-
    runProbe [("3.14", ProbeOk), ("3.13", ProbeReject), ("3.15", ProbeReject)]
  assertEq "stop at bare success" (Right (Set.singleton "3.14"), ["3.14"]) stopped
  fallen <-
    runProbe [("3.14", ProbeReject), ("3.13", ProbeOk), ("3.15", ProbeOk)]
  assertEq "next bare" (Right (Set.singleton "3.13"), ["3.14", "3.13"]) fallen
  tilde <-
    runProbe [("3.14", ProbeReject), ("3.13", ProbeReject), ("3.15", ProbeOk)]
  assertEq
    "tilde after bare"
    (Right (Set.singleton "3.15"), ["3.14", "3.13", "3.15"])
    tilde
  missing <-
    runProbe
      [ ("3.14", ProbeHardFail "python slot 3.14 is not installed"),
        ("3.13", ProbeOk)
      ]
  assertEq
    "missing stops"
    (Left "python slot 3.14 is not installed", ["3.14"])
    missing
  assertEq
    "missing interpreter message"
    (Left "python slot 3.13 is not installed")
    ( classifyPythonFind
        "3.13"
        (ExitFailure 1)
        "error: No interpreter found for Python 3.13\n"
        ""
    )
  assertEq
    "failed to find"
    (Left "python slot 3.13 is not installed")
    ( classifyPythonFind
        "3.13"
        (ExitFailure 1)
        ""
        "Failed to find Python interpreter at /usr/bin/python3.13"
    )
  assertEq
    "other find failure stays a hard failure"
    (Left "error: invalid request")
    (classifyPythonFind "3.13" (ExitFailure 2) "error: invalid request\n" "")
  assertEq
    "find success"
    (Right ())
    (classifyPythonFind "3.14" ExitSuccess "/usr/bin/python3.14\n" "")

testKeywords :: IO ()
testKeywords = do
  plan <-
    mustPlan
      "3.14 keywords"
      [cand "2026.2.2.1" "2026.2.2.1" ">=3.11"]
  eb <- assertRight "ebuild" (oneEbuild plan)
  assertEq "full tilde keywords" fullKeywords (T.unwords (peKeywords eb))
  assertTrue "empty allowlist omits -*" ("-*" `notElem` peKeywords eb)
  let labels = map glLabel (buildGapLines [] (glpUniquePVs plan) plan)
  assertTrue
    "python slot label"
    (any ("dev-lang/python:3.14" `T.isInfixOf`) labels)
  assertTrue
    "arch tier label"
    ("(dev-lang/python:3.14 amd64)" `elem` labels)
  assertEq
    "raw tag"
    (Just "2026.2.2.1")
    (lookupUvRawTag plan (parseEbuildVersion "2026.2.2.1"))
  split <-
    mustPlan
      "split keywords"
      [ cand "2026.2.2.1" "2026.2.2.1" ">=3.11",
        cand "2026.6.29.1" "v2026.6.29.1" ">=3.15"
      ]
  old <- assertRight "old" (ebuildFor split "2026.2.2.1")
  new <- assertRight "new" (ebuildFor split "2026.6.29.1")
  assertEq "plain arches only" plainKeywords (T.unwords (peKeywords old))
  assertEq "tilde arches" fullKeywords (T.unwords (peKeywords new))
  assertEq
    "v tag"
    (Just "v2026.6.29.1")
    (lookupUvRawTag split (parseEbuildVersion "2026.6.29.1"))
  limited <-
    assertRight "allowlist" $
      planUvFromCandidates
        fixtureInv
        ["amd64"]
        [parseEbuildVersion "2026.2.2.1"]
        [cand "2026.2.2.1" "2026.2.2.1" ">=3.11"]
  lim <- assertRight "limited ebuild" (oneEbuild limited)
  assertEq "allowlist prepends -*" ["-*", "~amd64"] (peKeywords lim)

testArchiveTag :: IO ()
testArchiveTag = do
  let seed =
        T.unlines
          [ "SRC_URI=\"",
            "  https://github.com/kky42/codex-as-mcp/archive/refs/tags/0.0.0.tar.gz -> ${P}.tar.gz",
            "  https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/codex-as-mcp-${PV}/codex-as-mcp-${PV}-deps.tar.xz",
            "\""
          ]
      bare = ensureUvArchiveTag "2026.2.2.1" seed
      prefixed = ensureUvArchiveTag "v2026.6.29.1" seed
  assertTrue "bare tag" ("refs/tags/2026.2.2.1.tar.gz" `T.isInfixOf` bare)
  assertTrue "v tag" ("refs/tags/v2026.6.29.1.tar.gz" `T.isInfixOf` prefixed)
  assertTrue "assets stay parameterized" ("codex-as-mcp-${PV}" `T.isInfixOf` bare)
  assertTrue "prefixed assets stay parameterized" ("codex-as-mcp-${PV}" `T.isInfixOf` prefixed)
  assertTrue "does not invent v${PV}" (not ("refs/tags/v${PV}.tar.gz" `T.isInfixOf` prefixed))

donor :: T.Text
donor =
  T.unlines
    [ "EAPI=8",
      "PYTHON_COMPAT=( python3_13 python3_13t )",
      "IUSE=\"external-codex test\"",
      "RESTRICT=\"!test? ( test )\"",
      "RDEPEND=\"dev-lang/python:3.13\"",
      "src_test() {",
      "  if [[ -f tests/test_server.py ]]; then",
      "    epytest tests/test_server.py",
      "  fi",
      "}",
      "src_install() {",
      "  uv venv --python /usr/bin/python3.13 \"${venv}\"",
      "  dobin codex-as-mcp",
      "}"
    ]

testDonorSlot :: IO ()
testDonorSlot = do
  let slot314 = ensurePythonSlot "3.14" donor
      slot315 = ensurePythonSlot "3.15" slot314
  assertDonorPieces slot314 "3.14" "python3_14"
  assertDonorPieces slot315 "3.15" "python3_15"
  assertTrue "3.14 token replaced" (not ("python3_14" `T.isInfixOf` slot315))
  assertTrue "3.13 path replaced" (not ("/usr/bin/python3.13" `T.isInfixOf` slot314))
  assertTrue "3.14 path replaced" (not ("/usr/bin/python3.14" `T.isInfixOf` slot315))
  assertTrue "free-threaded token stays" ("python3_13t" `T.isInfixOf` slot315)
  where
    assertDonorPieces body slot token = do
      assertTrue (T.unpack slot <> " atom") (("dev-lang/python:" <> slot) `T.isInfixOf` body)
      assertTrue (T.unpack token <> " compat") (token `T.isInfixOf` body)
      assertTrue "external-codex" ("external-codex" `T.isInfixOf` body)
      assertTrue "test flag" ("IUSE=\"external-codex test\"" `T.isInfixOf` body)
      assertTrue "pytest body" ("tests/test_server.py" `T.isInfixOf` body)
      assertTrue "wrapper install" ("src_install()" `T.isInfixOf` body)
      assertTrue "dobin" ("dobin codex-as-mcp" `T.isInfixOf` body)
      assertTrue
        "venv interpreter"
        (("/usr/bin/python" <> slot) `T.isInfixOf` body)

cand :: T.Text -> T.Text -> T.Text -> UvCandidate
cand pv tag req =
  candSynced pv tag req ["3.11", "3.12", "3.13", "3.14", "3.15"]

candSynced :: T.Text -> T.Text -> T.Text -> [T.Text] -> UvCandidate
candSynced pv tag req slots =
  UvCandidate
    { ucPV = parseEbuildVersion pv,
      ucTag = tag,
      ucRequires = Just req,
      ucSynced = Set.fromList slots
    }

mustPlan :: String -> [UvCandidate] -> IO RuntimeLanePlan
mustPlan = mustPlanOn fixtureInv

mustPlanOn :: PythonSlotInventory -> String -> [UvCandidate] -> IO RuntimeLanePlan
mustPlanOn inv label cands =
  assertRight label $
    planUvFromCandidates
      inv
      []
      (map ucPV cands)
      cands

runProbe ::
  [(T.Text, ProbeStep)] ->
  IO (Either T.Text (Set.Set T.Text), [T.Text])
runProbe script = do
  asked <- newIORef []
  let step slot = do
        modifyIORef' asked (slot :)
        pure (fromMaybe ProbeReject (lookup slot script))
  result <- probeOrdered step (map fst script)
  seen <- reverse <$> readIORef asked
  pure (result, seen)

selected :: RuntimeLanePlan -> [LaneTarget]
selected plan = [t | t <- glpLanes plan, isJust (ltPackagePV t)]

plainLanes :: RuntimeLanePlan -> [LaneTarget]
plainLanes plan = [t | t <- glpLanes plan, liTier (ltLane t) == Plain]

selectedPlain :: RuntimeLanePlan -> [LaneTarget]
selectedPlain plan = [t | t <- plainLanes plan, isJust (ltPackagePV t)]

selectedTilde :: RuntimeLanePlan -> [LaneTarget]
selectedTilde plan =
  [t | t <- glpLanes plan, liTier (ltLane t) == Tilde, isJust (ltPackagePV t)]

oneEbuild :: RuntimeLanePlan -> Either String PlannedEbuild
oneEbuild plan =
  case glpEbuilds plan of
    [eb] -> Right eb
    other -> Left ("expected one ebuild, got " <> show (length other))

ebuildFor :: RuntimeLanePlan -> T.Text -> Either String PlannedEbuild
ebuildFor plan pv =
  case [eb | eb <- glpEbuilds plan, samePV (pePV eb) (parseEbuildVersion pv)] of
    [eb] -> Right eb
    other -> Left ("expected one ebuild for " <> T.unpack pv <> ", got " <> show (length other))

findPkg :: UvLock -> T.Text -> Either String UvPackage
findPkg lock name =
  case [p | p <- ulPackages lock, upName p == name] of
    [p] -> Right p
    other -> Left (T.unpack name <> " count " <> show (length other))
