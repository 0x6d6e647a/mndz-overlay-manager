{-# LANGUAGE OverloadedStrings #-}

-- | Unit + Integration coverage for GitHub REST diagnostics, latch, health,
-- decrypt-when-live, and outdated abort emission (no live network / TTY).
module Test.GitHubResilience (unitTests, integrationTests) where

import CLI.Progress (noopMultiHandle)
import Config.TokenEnvelope (testEnvelopeParams, wrapTokenWith)
import Config.Types (CheckCacheTtl (..), OverlayConfig (..), defaultCheckCacheTtl)
import Control.Concurrent.Async (concurrently)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Network.HTTP.Client (getUri, parseRequest_, path)
import Network.HTTP.Types (ResponseHeaders)
import Overlay.Types (Ebuild (..))
import Overlay.Version (parseEbuildVersion)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse, fakeResponseHeaders)
import Test.Support (mockEgencacheWriteMatching)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Auth
  ( SecretPrompt (..),
    prepareGitHubToken,
    unauthenticatedGitHubWarning,
  )
import Update.Check
  ( PackageEntry (..),
    checkOverlayWithDepsPlan,
    finishOutdatedReports,
    groupByPackage,
    needsLiveGitHubApi,
  )
import Update.CheckCache
  ( computeFingerprint,
    openCheckCacheAt,
    storeLatest,
  )
import Update.Deps.Plan (productionDepsPlanOps)
import Update.Git
  ( GitOps (..),
  )
import Update.GitHub
  ( GitHubHttpError (..),
    fetchGitHubWithHttpLbs,
    fetchGitHubWithHttpLbsOn,
    formatGitHubHttpError,
    gitHubErrorIsRateLimitClass,
    gitHubErrorIsTokenRejected,
    githubLatchAbortedMessage,
    latchedHttp,
    listGitHubVersionsWithHttpLbsOn,
    newGitHubLatch,
    peekGitHubLatch,
    tripsGitHubLatch,
  )
import Update.GitHubHealth
  ( GitHubHealthOutcome (..),
    GitHubHealthScope (..),
    runGitHubHealthPreflight,
    runGitOperationsHealth,
  )
import Update.Http (HttpLbs)
import Update.Md5Cache (gencachePackages)
import Update.OverlayTree (withNewTreeLock)
import Update.Types
  ( UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    mkPackageKey,
  )

unitTests :: TestTree
unitTests =
  testGroup
    "GitHubResilience"
    [ testCase "format and classify GitHub HTTP errors" testFormatAndClassify,
      testCase "GitMv latest 403 skips tags" testLatest403SkipsTags,
      testCase "GitMv latest 404 still lists tags" testLatest404FallsBack,
      testCase "latch stops a second tags GET" testLatchStopsSecondGet,
      testCase "raw.githubusercontent.com does not trip latch" testRawDoesNotLatch,
      testCase "health remaining 0 fails" testHealthRemainingZero,
      testCase "health 401 fails" testHealth401,
      testCase "health API Requests major_outage fails" testHealthApiOutage,
      testCase "health Copilot outage is ignored" testHealthCopilotIgnored,
      testCase "health Statuspage fetch failure warns" testHealthStatuspageWarn,
      testCase "health degraded warns and continues" testHealthDegradedWarn,
      testCase "health rate_limit transport fails" testHealthRateLimitTransport,
      testCase "Git Operations outage is scoped" testGitOperationsScope,
      testCase "prepareGitHubToken live miss prompts" testPrepareLiveMissPrompts,
      testCase "prepareGitHubToken cache-hit skips decrypt" testPrepareCacheHitNoPrompt,
      testCase "prepareGitHubToken no TTY hard-fails" testPrepareNoTty,
      testCase "unauth warning only when live" testUnauthWarningLiveOnly,
      testCase "gencache path has no GitHub health HTTP" testGencacheNoHealthHttp
    ]

integrationTests :: TestTree
integrationTests =
  testGroup
    "GitHubResilience"
    [ testCase "cache hit skips live GitHub need" testCacheHitSkipsLiveNeed,
      testCase "outdated abort emits completed lines" testOutdatedAbortEmitsLines,
      testCase "latch concurrent in-flight then stop" testLatchConcurrent
    ]

------------------------------------------------------------------------
-- Formatter / classifier
------------------------------------------------------------------------

rateLimit403 :: GitHubHttpError
rateLimit403 =
  GitHubHttpError
    { gheStatus = 403,
      gheUrl = "https://api.github.com/repos/o/r/tags",
      gheMessage = Just "API rate limit exceeded",
      gheRemaining = Just 0,
      gheReset = Just 1700000000
    }

testFormatAndClassify :: IO ()
testFormatAndClassify = do
  let formatted = formatGitHubHttpError rateLimit403
  assertTrue "status" ("403" `T.isInfixOf` formatted)
  assertTrue "url" ("api.github.com/repos/o/r/tags" `T.isInfixOf` formatted)
  assertTrue "message" ("API rate limit exceeded" `T.isInfixOf` formatted)
  assertTrue "remaining" ("remaining=0" `T.isInfixOf` formatted)
  assertTrue "reset" ("1700000000" `T.isInfixOf` formatted)
  assertTrue "rate-limit class" (gitHubErrorIsRateLimitClass rateLimit403)
  assertTrue "trips latch" (tripsGitHubLatch rateLimit403)
  let secondary =
        rateLimit403
          { gheRemaining = Nothing,
            gheMessage = Just "You have exceeded a secondary rate limit"
          }
  assertTrue "secondary class" (gitHubErrorIsRateLimitClass secondary)
  let unauthorized =
        GitHubHttpError
          { gheStatus = 401,
            gheUrl = "https://api.github.com/rate_limit",
            gheMessage = Just "Bad credentials",
            gheRemaining = Nothing,
            gheReset = Nothing
          }
  assertTrue "401 rejected" (gitHubErrorIsTokenRejected unauthorized)
  assertTrue "401 trips" (tripsGitHubLatch unauthorized)
  let missingRepo =
        GitHubHttpError
          { gheStatus = 403,
            gheUrl = "https://api.github.com/repos/o/private",
            gheMessage = Just "Resource not accessible by personal access token",
            gheRemaining = Just 12,
            gheReset = Just 1700000000
          }
  assertTrue "non-rate-limit 403" (not (gitHubErrorIsRateLimitClass missingRepo))
  assertTrue "non-rate-limit does not trip" (not (tripsGitHubLatch missingRepo))
  let html =
        GitHubHttpError
          { gheStatus = 502,
            gheUrl = "https://api.github.com/repos/o/r/tags",
            gheMessage = Nothing,
            gheRemaining = Nothing,
            gheReset = Nothing
          }
  let htmlFmt = formatGitHubHttpError html
  assertTrue "html status" ("502" `T.isInfixOf` htmlFmt)
  assertTrue "html url" ("api.github.com" `T.isInfixOf` htmlFmt)
  assertTrue "no html dump" (not ("<html" `T.isInfixOf` htmlFmt))

------------------------------------------------------------------------
-- Fallback + latch (fake HTTP)
------------------------------------------------------------------------

rateLimitHeaders :: ResponseHeaders
rateLimitHeaders =
  [ ("x-ratelimit-remaining", "0"),
    ("x-ratelimit-reset", "1700000000")
  ]

rateLimitBody :: BSC.ByteString
rateLimitBody = "{\"message\":\"API rate limit exceeded\"}"

testLatest403SkipsTags :: IO ()
testLatest403SkipsTags = do
  urls <- newIORef ([] :: [BSC.ByteString])
  let http req = do
        atomicModifyIORef' urls (\xs -> (xs <> [path req], ()))
        pure $
          Right $
            fakeResponseHeaders 403 rateLimitHeaders (L8.fromStrict rateLimitBody)
  err <-
    assertLeft "latest 403"
      =<< fetchGitHubWithHttpLbs http Nothing (GitHub "o" "r" "v")
  assertTrue "status in err" ("403" `T.isInfixOf` err)
  assertTrue "message in err" ("API rate limit exceeded" `T.isInfixOf` err)
  seen <- readIORef urls
  assertTrue "requested latest" (any ("releases/latest" `BSC.isInfixOf`) seen)
  assertTrue "did not request tags" (not (any ("/tags" `BSC.isInfixOf`) seen))

testLatest404FallsBack :: IO ()
testLatest404FallsBack = do
  urls <- newIORef ([] :: [BSC.ByteString])
  let http req = do
        atomicModifyIORef' urls (\xs -> (xs <> [path req], ()))
        pure $
          Right $
            if "releases" `BSC.isInfixOf` path req
              then fakeResponse 404 "missing"
              else fakeResponse 200 "[{\"name\":\"v1.2.0\"}]"
  ver <-
    assertRight "404 fallback"
      =<< fetchGitHubWithHttpLbs http Nothing (GitHub "o" "r" "v")
  assertEq "tag ver" (parseEbuildVersion "1.2.0") ver
  seen <- readIORef urls
  assertTrue "requested tags" (any ("/tags" `BSC.isInfixOf`) seen)

testLatchStopsSecondGet :: IO ()
testLatchStopsSecondGet = do
  latch <- newGitHubLatch
  starts <- newIORef (0 :: Int)
  let http _req = do
        atomicModifyIORef' starts (\n -> (n + 1, ()))
        pure $
          Right $
            fakeResponseHeaders 403 rateLimitHeaders (L8.fromStrict rateLimitBody)
  err1 <-
    assertLeft "first 403"
      =<< listGitHubVersionsWithHttpLbsOn latch http Nothing (GitHub "o" "r" "v")
  assertTrue "formatted" ("403" `T.isInfixOf` err1)
  n1 <- readIORef starts
  err2 <-
    assertLeft "second aborted"
      =<< listGitHubVersionsWithHttpLbsOn latch http Nothing (GitHub "o2" "r2" "v")
  n2 <- readIORef starts
  assertEq "no second GET" n1 n2
  assertEq "aborted text" githubLatchAbortedMessage err2
  mAbort <- peekGitHubLatch latch
  assertTrue "latch set" (isJust mAbort)

testRawDoesNotLatch :: IO ()
testRawDoesNotLatch = do
  latch <- newGitHubLatch
  starts <- newIORef (0 :: Int)
  let http req = do
        atomicModifyIORef' starts (\n -> (n + 1, ()))
        if "raw.githubusercontent.com" `T.isInfixOf` T.pack (show req)
          then pure (Right (fakeResponse 403 "raw denied"))
          else
            pure $
              Right $
                fakeResponseHeaders 403 rateLimitHeaders (L8.fromStrict rateLimitBody)
      wrapped = latchedHttp latch http
  -- Trip the latch on api.github.com.
  _ <- fetchGitHubWithHttpLbsOn latch wrapped Nothing (GitHub "o" "r" "v")
  before <- readIORef starts
  _ <- wrapped (parseRequest_ "https://raw.githubusercontent.com/o/r/main/go.mod")
  after <- readIORef starts
  assertTrue "raw still fetched after api latch" (after == before + 1)
  _ <- wrapped (parseRequest_ "https://api.github.com/repos/o/r/tags")
  afterApi <- readIORef starts
  assertEq "api GET not started after latch" after afterApi

------------------------------------------------------------------------
-- Health fakes
------------------------------------------------------------------------

statuspage :: Text -> Text -> Text -> Text
statuspage api git copilot =
  "{\"components\":["
    <> component "API Requests" api
    <> ","
    <> component "Git Operations" git
    <> ","
    <> component "Copilot" copilot
    <> "]}"
  where
    component name st =
      "{\"name\":\"" <> name <> "\",\"status\":\"" <> st <> "\"}"

rateLimitJson :: Int -> Text
rateLimitJson remaining =
  "{\"resources\":{\"core\":{\"remaining\":"
    <> T.pack (show remaining)
    <> ",\"reset\":1700000000}}}"

healthHttp :: Text -> Int -> Text -> HttpLbs
healthHttp pageBody rateStatus rateBody req =
  let u = T.pack (show (getUri req))
   in if "githubstatus.com" `T.isInfixOf` u
        then pure (Right (fakeResponse 200 (L8.pack (T.unpack pageBody))))
        else
          if "rate_limit" `T.isInfixOf` u
            then
              pure $
                Right $
                  fakeResponseHeaders
                    rateStatus
                    []
                    (L8.pack (T.unpack rateBody))
            else pure (Left "unexpected health URL")

testHealthRemainingZero :: IO ()
testHealthRemainingZero = do
  latch <- newGitHubLatch
  let http = healthHttp (statuspage "operational" "operational" "operational") 200 (rateLimitJson 0)
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthFailed err -> do
      assertTrue "remaining" ("0" `T.isInfixOf` err)
      assertTrue "reset" ("1700000000" `T.isInfixOf` err)
    GitHubHealthOk w -> assertTrue ("expected fail, got ok " <> T.unpack (T.intercalate "," w)) False

testHealth401 :: IO ()
testHealth401 = do
  latch <- newGitHubLatch
  let http =
        healthHttp
          (statuspage "operational" "operational" "operational")
          401
          "{\"message\":\"Bad credentials\"}"
  out <-
    runGitHubHealthPreflight
      latch
      http
      (Just "bad-token")
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthFailed err ->
      assertTrue "rejected" ("rejected" `T.isInfixOf` T.toLower err || "401" `T.isInfixOf` err)
    GitHubHealthOk _ -> assertTrue "expected 401 fail" False

testHealthApiOutage :: IO ()
testHealthApiOutage = do
  latch <- newGitHubLatch
  let http = healthHttp (statuspage "major_outage" "operational" "operational") 200 (rateLimitJson 50)
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthFailed err ->
      assertTrue "API Requests" ("API Requests" `T.isInfixOf` err)
    GitHubHealthOk _ -> assertTrue "expected outage fail" False

testHealthCopilotIgnored :: IO ()
testHealthCopilotIgnored = do
  latch <- newGitHubLatch
  let http = healthHttp (statuspage "operational" "operational" "major_outage") 200 (rateLimitJson 50)
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthOk _ -> pure ()
    GitHubHealthFailed err -> assertTrue ("copilot should not fail: " <> T.unpack err) False

testHealthStatuspageWarn :: IO ()
testHealthStatuspageWarn = do
  latch <- newGitHubLatch
  let http req =
        let u = T.pack (show (getUri req))
         in if "githubstatus.com" `T.isInfixOf` u
              then pure (Left "statuspage down")
              else
                pure
                  (Right (fakeResponse 200 (L8.pack (T.unpack (rateLimitJson 50)))))
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthOk warns ->
      assertTrue "statuspage warn" (any ("Statuspage" `T.isInfixOf`) warns)
    GitHubHealthFailed err ->
      assertTrue ("expected warn, got fail " <> T.unpack err) False

testHealthDegradedWarn :: IO ()
testHealthDegradedWarn = do
  latch <- newGitHubLatch
  let http = healthHttp (statuspage "degraded_performance" "operational" "operational") 200 (rateLimitJson 50)
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthOk warns ->
      assertTrue "degraded warn" (any ("degraded_performance" `T.isInfixOf`) warns)
    GitHubHealthFailed err ->
      assertTrue ("expected warn, got fail " <> T.unpack err) False

testHealthRateLimitTransport :: IO ()
testHealthRateLimitTransport = do
  latch <- newGitHubLatch
  let http req =
        let u = T.pack (show (getUri req))
         in if "githubstatus.com" `T.isInfixOf` u
              then
                pure
                  ( Right
                      (fakeResponse 200 (L8.pack (T.unpack (statuspage "operational" "operational" "operational"))))
                  )
              else pure (Left "rate_limit down")
  out <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case out of
    GitHubHealthFailed err ->
      assertTrue "rate_limit fetch" ("rate_limit" `T.isInfixOf` err)
    GitHubHealthOk _ -> assertTrue "expected rate_limit fail" False

testGitOperationsScope :: IO ()
testGitOperationsScope = do
  latch <- newGitHubLatch
  let page = statuspage "operational" "major_outage" "operational"
      http = healthHttp page 200 (rateLimitJson 50)
  skipGit <-
    runGitHubHealthPreflight
      latch
      http
      Nothing
      GitHubHealthScope {ghsCheckApiRequests = True, ghsCheckGitOperations = False}
  case skipGit of
    GitHubHealthOk _ -> pure ()
    GitHubHealthFailed err ->
      assertTrue ("GitMv-only should ignore Git Operations: " <> T.unpack err) False
  pushCheck <- runGitOperationsHealth http
  case pushCheck of
    GitHubHealthFailed err ->
      assertTrue "Git Operations named" ("Git Operations" `T.isInfixOf` err)
    GitHubHealthOk _ -> assertTrue "expected Git Operations fail" False

------------------------------------------------------------------------
-- Decrypt / unauth
------------------------------------------------------------------------

testCfg :: Maybe T.Text -> OverlayConfig
testCfg tok =
  OverlayConfig
    { overlayPath = "/tmp/ov",
      assetsPath = Nothing,
      githubToken = tok,
      distfilesPath = Nothing,
      checkCacheTtl = defaultCheckCacheTtl
    }

countingPrompt :: IORef Int -> SecretPrompt
countingPrompt n =
  SecretPrompt
    { spControllingTty = pure (Just "/dev/null"),
      spReadSecret = \_ _ -> do
        atomicModifyIORef' n (\x -> (x + 1, ()))
        pure (Right "wrap-pass"),
      spPauseUi = pure (),
      spResumeUi = pure ()
    }

testPrepareLiveMissPrompts :: IO ()
testPrepareLiveMissPrompts = do
  eEnv <- wrapTokenWith testEnvelopeParams "wrap-pass" "github_pat_secret"
  envelope <- assertRight "wrap" eEnv
  n <- newIORef (0 :: Int)
  cache <- newIORef Nothing
  got <-
    prepareGitHubToken (testCfg (Just envelope)) (countingPrompt n) cache True
  (tok, warns) <- assertRight "prepare" got
  assertEq "token" (Just "github_pat_secret") tok
  assertEq "no extra warns" [] warns
  prompts <- readIORef n
  assertEq "prompted once" 1 prompts

testPrepareCacheHitNoPrompt :: IO ()
testPrepareCacheHitNoPrompt = do
  eEnv <- wrapTokenWith testEnvelopeParams "wrap-pass" "github_pat_secret"
  envelope <- assertRight "wrap" eEnv
  n <- newIORef (0 :: Int)
  cache <- newIORef Nothing
  got <-
    prepareGitHubToken (testCfg (Just envelope)) (countingPrompt n) cache False
  (tok, warns) <- assertRight "prepare" got
  assertEq "no token" Nothing tok
  assertEq "no warns" [] warns
  prompts <- readIORef n
  assertEq "no prompt" 0 prompts

testPrepareNoTty :: IO ()
testPrepareNoTty = do
  eEnv <- wrapTokenWith testEnvelopeParams "wrap-pass" "github_pat_secret"
  envelope <- assertRight "wrap" eEnv
  cache <- newIORef Nothing
  let prompt =
        SecretPrompt
          { spControllingTty = pure Nothing,
            spReadSecret = \_ _ -> pure (Right "wrap-pass"),
            spPauseUi = pure (),
            spResumeUi = pure ()
          }
  err <-
    assertLeft "no tty"
      =<< prepareGitHubToken (testCfg (Just envelope)) prompt cache True
  assertTrue "mentions TTY" ("TTY" `T.isInfixOf` err)

testUnauthWarningLiveOnly :: IO ()
testUnauthWarningLiveOnly = do
  cache <- newIORef Nothing
  n <- newIORef (0 :: Int)
  live <-
    prepareGitHubToken (testCfg Nothing) (countingPrompt n) cache True
  (_, liveWarns) <- assertRight "live" live
  assertTrue
    "unauth warn"
    (unauthenticatedGitHubWarning `elem` liveWarns)
  cached <-
    prepareGitHubToken (testCfg Nothing) (countingPrompt n) cache False
  (_, cachedWarns) <- assertRight "cached" cached
  assertEq "no unauth on cache hit" [] cachedWarns

------------------------------------------------------------------------
-- gencache has no health HTTP
------------------------------------------------------------------------

testGencacheNoHealthHttp :: IO ()
testGencacheNoHealthHttp =
  withSystemTempDirectory "om-gc-health" $ \tmp -> do
    let overlay = tmp </> "ov"
        pkg = overlay </> "dev-lang" </> "haskell"
    createDirectoryIfMissing True (overlay </> "metadata" </> "md5-cache")
    createDirectoryIfMissing True pkg
    TIO.writeFile (pkg </> "haskell-1.0.ebuild") "EAPI=8\n"
    let git =
          GitOps
            { goIsWorkTree = \_ -> pure True,
              goPathsDirty = \_ _ -> pure (Right False),
              goAddAndCommit = \_ _ _ -> pure (Right ()),
              goPush = \_ -> pure (Right ()),
              goRevParseHead = \_ -> pure (Right "abc")
            }
    result <-
      gencachePackages
        mockEgencacheWriteMatching
        git
        overlay
        [mkPackageKey "dev-lang" "haskell"]
        True
        (Just 1)
        (pure (Right ()))
    -- gencache never GETs Statuspage or /rate_limit; this path has no HTTP.
    _ <- assertRight "gencache" result
    pure ()

------------------------------------------------------------------------
-- Cache hit + abort emission
------------------------------------------------------------------------

gitMvEbuild :: FilePath -> T.Text -> T.Text -> T.Text -> IO Ebuild
gitMvEbuild overlay cat pn ver = do
  let dir = overlay </> T.unpack cat </> T.unpack pn
      path = dir </> T.unpack (pn <> "-" <> ver <> ".ebuild")
  createDirectoryIfMissing True dir
  TIO.writeFile path "EAPI=8\n"
  pure
    Ebuild
      { ebuildCategory = cat,
        ebuildPackage = pn,
        ebuildVersion = ver,
        ebuildPath = path
      }

testCacheHitSkipsLiveNeed :: IO ()
testCacheHitSkipsLiveNeed =
  withSystemTempDirectory "om-gh-cache" $ \tmp -> do
    let overlay = tmp </> "ov"
        cacheDir = tmp </> "cc"
    eb <- gitMvEbuild overlay "dev-lang" "bun-bin" "1.1.0"
    let src = GitHub "oven-sh" "bun" "bun-v"
        key = mkPackageKey "dev-lang" "bun-bin"
        entry =
          PackageEntry
            { peKey = key,
              pePN = "bun-bin",
              peLocal = parseEbuildVersion "1.1.0",
              pePath = ebuildPath eb
            }
    now <- getCurrentTime
    (cache, _) <-
      openCheckCacheAt (pure now) (Just cacheDir) (CacheTtl (5 * 60)) False overlay
    fp <- withNewTreeLock $ \tree -> computeFingerprint tree src [eb]
    storeLatest cache key fp (parseEbuildVersion "1.1.0")
    live <- needsLiveGitHubApi cache overlay [entry] (groupByPackage [eb])
    assertTrue "full cache hit is not live GitHub" (not live)

testOutdatedAbortEmitsLines :: IO ()
testOutdatedAbortEmitsLines =
  withSystemTempDirectory "om-gh-abort" $ \tmp -> do
    let overlay = tmp </> "ov"
    bun <- gitMvEbuild overlay "dev-lang" "bun-bin" "1.0.0"
    deno <- gitMvEbuild overlay "dev-lang" "deno-bin" "1.0.0"
    qlot <- gitMvEbuild overlay "dev-lisp" "qlot" "1.0.0"
    let ebuilds = [bun, deno, qlot]
    (cache, _) <- openCheckCacheAt getCurrentTime Nothing CacheDisabled False overlay
    latch <- newGitHubLatch
    let http403 _ =
          pure $
            Right $
              fakeResponseHeaders 403 rateLimitHeaders (L8.fromStrict rateLimitBody)
        fetch src = case src of
          GitHub "oven-sh" "bun" _ ->
            pure (Right (parseEbuildVersion "9.0.0"))
          GitHub "denoland" "deno" _ ->
            pure (Right (parseEbuildVersion "9.0.0"))
          GitHub "fukamachi" "qlot" _ ->
            fetchGitHubWithHttpLbsOn latch http403 Nothing src
          _ -> pure (Left "unexpected source")
    depsOps <- productionDepsPlanOps Nothing 1 Nothing
    reports <-
      checkOverlayWithDepsPlan 1 noopMultiHandle fetch depsOps cache ebuilds
    (keep, mAbort) <- finishOutdatedReports latch reports
    abort <- case mAbort of
      Just t -> pure t
      Nothing -> do
        assertTrue "expected abort" False
        pure ""
    assertTrue "abort mentions 403" ("403" `T.isInfixOf` abort)
    let outdatedKeys =
          [ reportKey r
          | r <- keep,
            case reportStatus r of
              Outdated _ -> True
              _ -> False
          ]
    assertTrue "bun line kept" (mkPackageKey "dev-lang" "bun-bin" `elem` outdatedKeys)
    assertTrue "deno line kept" (mkPackageKey "dev-lang" "deno-bin" `elem` outdatedKeys)
    assertTrue
      "qlot not a fetch-error warning"
      ( all
          ( \r ->
              reportKey r /= mkPackageKey "dev-lisp" "qlot"
                || case reportStatus r of
                  FetchError _ -> False
                  _ -> True
          )
          keep
      )

testLatchConcurrent :: IO ()
testLatchConcurrent = do
  latch <- newGitHubLatch
  starts <- newIORef (0 :: Int)
  let http _ = do
        atomicModifyIORef' starts (\n -> (n + 1, ()))
        pure $
          Right $
            fakeResponseHeaders 403 rateLimitHeaders (L8.fromStrict rateLimitBody)
  _ <-
    concurrently
      (listGitHubVersionsWithHttpLbsOn latch http Nothing (GitHub "a" "r" "v"))
      (listGitHubVersionsWithHttpLbsOn latch http Nothing (GitHub "b" "r" "v"))
  nAfterPair <- readIORef starts
  assertTrue "in-flight may both start" (nAfterPair >= 1 && nAfterPair <= 2)
  _ <- listGitHubVersionsWithHttpLbsOn latch http Nothing (GitHub "c" "r" "v")
  nFinal <- readIORef starts
  assertEq "third GET not started" nAfterPair nFinal
