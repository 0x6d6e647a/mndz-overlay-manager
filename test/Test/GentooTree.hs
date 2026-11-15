{-# LANGUAGE OverloadedStrings #-}

-- | Managed Gentoo tree: paths, alignment and signature parsing, key
-- handling, sync fallbacks, and the resolver's locking. Every git, gpg, and
-- HTTP call is a scripted fake.
module Test.GentooTree (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Network.HTTP.Client (getUri)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.HttpFake (fakeResponse)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.DiskSpace (DiskSpaceProbe (..))
import Update.FileLock (LockMode (..), acquireFileLock, releaseFileLock)
import Update.GentooTree
import Update.Http (HttpLbs)
import Update.Process (CommandRunner, ProcessMode (..), ProcessRequest (..), ProcessResult (..))

tests :: TestTree
tests =
  testGroup
    "GentooTree"
    [ testGroup
        "Paths"
        [ testCase "XDG_CACHE_HOME set" testPathsXdg,
          testCase "XDG_CACHE_HOME unset or empty" testPathsHome
        ],
      testGroup
        "Pure helpers"
        [ testCase "Packages TIMESTAMP" testPackagesTimestamp,
          testCase "Newer commits are skipped (12:35 picks 11:16)" testSpikeSelection,
          testCase "Developer commit not chosen" testDeveloperSkipped,
          testCase "VALIDSIG with mirror primary accepted" testSigAccepted,
          testCase "NO_PUBKEY rejected" testSigNoPubkey,
          testCase "Wrong primary key rejected" testSigWrongPrimary,
          testCase "REVKEYSIG and EXPKEYSIG rejected" testSigRevokedExpired,
          testCase "Colon primary fingerprints" testColonFingerprints
        ],
      testGroup
        "Mirror key"
        [ testCase "First sync fetches the key by WKD" testKeyFirstFetch,
          testCase "Mismatched WKD fingerprint rejected" testKeyMismatch,
          testCase "Keyserver fallback by fingerprint" testKeyKeyserverFallback,
          testCase "Refresh failure warns and proceeds" testKeyRefreshWarns,
          testCase "Revoked key fails the sync" testKeyRevoked
        ],
      testGroup
        "Sync"
        [ testCase "Fresh host clones and aligns" testFreshClone,
          testCase "Existing tree fetches incrementally" testExistingFetch,
          testCase "Unchanged commit still writes the stamp" testNoChangeStamp,
          testCase "Binhost unreachable with an existing tree" testBinhostDownExisting,
          testCase "Binhost unreachable on a fresh host" testBinhostDownFresh,
          testCase "Stalled binhost keeps the tree" testStalled,
          testCase "Offline with a tree" testOfflineWithTree,
          testCase "Offline without a tree" testOfflineNoTree,
          testCase "Verification failure leaves the tree" testVerifyFailKeeps,
          testCase "Insufficient space for the clone" testCloneSpace
        ],
      testGroup
        "Resolver"
        [ testCase "Fresh tree is not synced" testResolveFresh,
          testCase "Due tree syncs" testResolveDue,
          testCase "Refresh forces a sync" testResolveRefresh,
          testCase "Sync waits for a run using the tree" testResolveWaits
        ]
    ]

------------------------------------------------------------------------
-- Fixtures

utc :: String -> UTCTime
utc s = case iso8601ParseM s of
  Just t -> t
  Nothing -> error ("bad time " <> s)

epoch :: UTCTime -> Integer
epoch = floor . utcTimeToPOSIXSeconds

binhostTime :: UTCTime
binhostTime = utc "2026-11-14T12:35:00Z"

packagesBody :: UTCTime -> L8.ByteString
packagesBody t =
  L8.pack ("ARCH: amd64\nPACKAGES: 1\nTIMESTAMP: " <> show (epoch t) <> "\nVERSION: 0\n\nCPV: app-misc/foo-1\n")

mirrorCommitLine :: Text -> String -> Text
mirrorCommitLine sha at =
  T.intercalate
    "\t"
    [ sha,
      T.pack (show (epoch (utc at))),
      "Repository mirror & CI",
      T.pack (take 10 at <> " " <> take 8 (drop 11 at) <> " UTC")
    ]

developerCommitLine :: Text -> String -> Text
developerCommitLine sha at =
  T.intercalate "\t" [sha, T.pack (show (epoch (utc at))), "Some Developer", "dev-lang/go: add 1.27.5"]

-- | Newest first, as @git log@ prints.
spikeListing :: Text
spikeListing =
  T.unlines
    [ mirrorCommitLine "c2031" "2026-11-14T20:31:00Z",
      mirrorCommitLine "c1230" "2026-11-14T12:30:00Z",
      mirrorCommitLine "c1116" "2026-11-14T11:16:00Z"
    ]

validSig :: Text -> Text
validSig primary =
  T.unlines
    [ "[GNUPG:] NEWSIG",
      "[GNUPG:] KEY_CONSIDERED " <> primary <> " 0",
      "[GNUPG:] SIG_ID abc 2026-11-14 1763120000",
      "[GNUPG:] GOODSIG 0123456789ABCDEF Gentoo repository mirror",
      "[GNUPG:] VALIDSIG 1111222233334444555566667777888899990000 2026-11-14 1763120000 0 4 0 1 10 00 " <> primary,
      "[GNUPG:] TRUST_UNDEFINED 0 pgp"
    ]

mirrorSig :: Text
mirrorSig = validSig mirrorKeyFingerprint

colonsFor :: Text -> String
colonsFor fpr =
  "tru::1:0:0:0:0:0\npub:-:4096:1:A13D0EF1914E7A72:1:1:::-:::scESC::::::23::0:\nfpr:::::::::"
    <> T.unpack fpr
    <> ":\nuid:-::::1::ABC::Gentoo repository mirror <repomirrorci@gentoo.org>::::::::::0:\n"

------------------------------------------------------------------------
-- Fake world

data World = World
  { wHead :: Maybe Text,
    wTip :: Text,
    wCloneOk :: Bool,
    wFetchOk :: Bool,
    wListing :: Text,
    wVerify :: Text -> Text,
    wHasKey :: Bool,
    wWkdFpr :: Text,
    wRecvOk :: Bool,
    wRefreshOk :: Bool,
    wBinhost :: Maybe UTCTime,
    wWkdUp :: Bool,
    wCalls :: [[String]],
    wHttpCalls :: [String]
  }

defaultWorld :: World
defaultWorld =
  World
    { wHead = Nothing,
      wTip = "c2031",
      wCloneOk = True,
      wFetchOk = True,
      wListing = spikeListing,
      wVerify = const mirrorSig,
      wHasKey = True,
      wWkdFpr = mirrorKeyFingerprint,
      wRecvOk = True,
      wRefreshOk = True,
      wBinhost = Just binhostTime,
      wWkdUp = True,
      wCalls = [],
      wHttpCalls = []
    }

ok :: String -> ProcessResult
ok out = ProcessResult ExitSuccess out ""

failed :: String -> ProcessResult
failed = ProcessResult (ExitFailure 1) ""

-- | Drop @-C dir@ and @-c key=value@ prefixes.
gitVerb :: [String] -> [String]
gitVerb ("-C" : _ : rest) = gitVerb rest
gitVerb ("-c" : _ : rest) = gitVerb rest
gitVerb args = args

fakeRunner :: IORef World -> CommandRunner
fakeRunner ref req = case prMode req of
  ExecCmd cmd args -> do
    modifyIORef' ref (\w -> w {wCalls = wCalls w <> [cmd : args]})
    w <- readIORef ref
    case cmd of
      "git" -> git w (gitVerb args)
      "gpg" -> gpg w (filter (`notElem` ["--with-colons", "--import-options"]) (drop 5 args))
      "gpgconf" -> pure (ok "")
      _ -> pure (failed ("unexpected command " <> cmd))
  ShellCmd s -> pure (failed ("unexpected shell " <> s))
  where
    git w = \case
      ("clone" : rest)
        | wCloneOk w -> do
            let dest = last rest
            createDirectoryIfMissing True (dest </> ".git" </> "info")
            writeFile (dest </> ".git" </> "info" </> "exclude") "# git ls-files --others --exclude-from=.git/info/exclude\n"
            setHead (wTip w)
            pure (ok "")
        | otherwise -> pure (failed "fatal: unable to access 'https://github.com/gentoo-mirror/gentoo.git/': Could not resolve host: github.com")
      ("fetch" : _)
        | wFetchOk w -> pure (ok "")
        | otherwise -> pure (failed "fatal: unable to access 'https://github.com/gentoo-mirror/gentoo.git/': Could not resolve host: github.com")
      ("log" : _) -> pure (ok (T.unpack (wListing w)))
      ("verify-commit" : rest) ->
        let raw = wVerify w (T.pack (last rest))
         in pure
              ( ProcessResult
                  (if "VALIDSIG" `T.isInfixOf` raw && not ("REVKEYSIG" `T.isInfixOf` raw) then ExitSuccess else ExitFailure 1)
                  ""
                  (T.unpack raw)
              )
      ("checkout" : rest) -> setHead (T.pack (last rest)) >> pure (ok "")
      ["rev-parse", "HEAD"] -> pure $ maybe (failed "fatal: not a git repository") (ok . (<> "\n") . T.unpack) (wHead w)
      other -> pure (failed ("unexpected git " <> unwords other))
    gpg w = \case
      ["--list-keys", _]
        | wHasKey w -> pure (ok (colonsFor mirrorKeyFingerprint))
        | otherwise -> pure (failed "gpg: error reading key: No public key")
      ["show-only", "--import", _] -> pure (ok (colonsFor (wWkdFpr w)))
      ["--import", _] -> do
        modifyIORef' ref (\x -> x {wHasKey = wWkdFpr x == mirrorKeyFingerprint})
        pure (ok "")
      [_, _, "--recv-keys", _]
        | wRecvOk w -> modifyIORef' ref (\x -> x {wHasKey = True}) >> pure (ok "")
        | otherwise -> pure (failed "gpg: keyserver receive failed: No data")
      [_, _, "--refresh-keys", _]
        | wRefreshOk w -> pure (ok "")
        | otherwise -> pure (failed "gpg: keyserver refresh failed: Server indicated a failure")
      other -> pure (failed ("unexpected gpg " <> unwords other))
    setHead sha = modifyIORef' ref (\x -> x {wHead = Just sha})

fakeHttp :: IORef World -> HttpLbs
fakeHttp ref req = do
  let url = show (getUri req)
  modifyIORef' ref (\w -> w {wHttpCalls = wHttpCalls w <> [url]})
  w <- readIORef ref
  pure $
    if "/Packages" `isInfixOf` url
      then case wBinhost w of
        Just t -> Right (fakeResponse 206 (packagesBody t))
        Nothing -> Left "ConnectionFailure: distfiles.gentoo.org"
      else
        if wWkdUp w
          then Right (fakeResponse 200 "binary-key-bytes")
          else Right (fakeResponse 404 "")

data Harness = Harness
  { hEnv :: TreeEnv,
    hWorld :: IORef World,
    hWarns :: IORef [Text],
    hInfos :: IORef [Text],
    hPaths :: GentooTreePaths
  }

withHarness :: World -> (Harness -> IO a) -> IO a
withHarness world body =
  withSystemTempDirectory "om-gentoo-tree" $ \tmp -> do
    ref <- newIORef world
    warns <- newIORef []
    infos <- newIORef []
    let paths = gentooTreePathsFromEnv (Just tmp) "/home/unused"
        env =
          TreeEnv
            { tePaths = paths,
              teRun = fakeRunner ref,
              teHttp = fakeHttp ref,
              teNow = pure (utc "2026-11-14T18:00:00Z"),
              teLock = fileTreeLockOps (gtpLock paths),
              teProbe =
                DiskSpaceProbe
                  { dspFreeBytes = \_ -> pure (Right (50 * 1024 * 1024 * 1024)),
                    dspDeviceId = \_ -> pure (Right 1)
                  },
              teUname = "x86_64",
              teBaseEnv = [],
              teMaxAge = 6 * 60 * 60,
              teRefresh = False,
              teInfo = \t -> atomicModifyIORef' infos (\xs -> (xs <> [t], ())),
              teWarn = \t -> atomicModifyIORef' warns (\xs -> (xs <> [t], ()))
            }
    body Harness {hEnv = env, hWorld = ref, hWarns = warns, hInfos = infos, hPaths = paths}

-- | An existing tree at @sha@, with a stamp @age@ before 'teNow'.
seedTree :: Harness -> Text -> Maybe NominalDiffTime -> IO ()
seedTree h sha mAge = do
  let paths = hPaths h
  createDirectoryIfMissing True (gtpTree paths </> ".git" </> "info")
  modifyIORef' (hWorld h) (\w -> w {wHead = Just sha})
  case mAge of
    Nothing -> pure ()
    Just age ->
      writeFile (gtpStamp paths) (iso8601Show (addUTCTime (negate age) (utc "2026-11-14T18:00:00Z")) <> "\n")

calls :: Harness -> IO [[String]]
calls h = wCalls <$> readIORef (hWorld h)

gitVerbs :: Harness -> IO [String]
gitVerbs h = do
  cs <- calls h
  pure [v | ("git" : args) <- cs, (v : _) <- [gitVerb args]]

headOf :: Harness -> IO (Maybe Text)
headOf h = wHead <$> readIORef (hWorld h)

warnings :: Harness -> IO [Text]
warnings h = readIORef (hWarns h)

anyWarning :: Text -> [Text] -> Bool
anyWarning needle = any (needle `T.isInfixOf`)

------------------------------------------------------------------------
-- Paths

testPathsXdg :: IO ()
testPathsXdg = do
  let p = gentooTreePathsFromEnv (Just "/tmp/xdg") "/home/op"
  assertEq "tree" "/tmp/xdg/mndz/overlay-manager/gentoo" (gtpTree p)
  assertEq "keyring" "/tmp/xdg/mndz/overlay-manager/gentoo-keyring" (gtpKeyring p)
  assertEq "stamp" "/tmp/xdg/mndz/overlay-manager/gentoo.last-sync-check" (gtpStamp p)
  assertEq "lock" "/tmp/xdg/mndz/overlay-manager/gentoo.lock" (gtpLock p)

testPathsHome :: IO ()
testPathsHome = do
  assertEq
    "unset"
    "/home/op/.cache/mndz/overlay-manager/gentoo"
    (gtpTree (gentooTreePathsFromEnv Nothing "/home/op"))
  assertEq
    "empty"
    "/home/op/.cache/mndz/overlay-manager/gentoo"
    (gtpTree (gentooTreePathsFromEnv (Just "") "/home/op"))

------------------------------------------------------------------------
-- Pure helpers

testPackagesTimestamp :: IO ()
testPackagesTimestamp = do
  assertEq "header" (Just binhostTime) (parsePackagesTimestamp (T.pack (L8.unpack (packagesBody binhostTime))))
  assertEq "missing" Nothing (parsePackagesTimestamp "ARCH: amd64\n\nTIMESTAMP: 1\n")
  assertEq "garbage" Nothing (parsePackagesTimestamp "TIMESTAMP: soon\n")
  assertEq "amd64 binhost" (Just "https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/Packages") (binhostPackagesUrl "x86_64")
  assertEq "unmapped" Nothing (binhostPackagesUrl "s390x")

testSpikeSelection :: IO ()
testSpikeSelection =
  assertEq
    "11:16"
    (Just "c1116")
    (mcSha <$> selectTargetCommit binhostTime (parseGitLogListing spikeListing))

testDeveloperSkipped :: IO ()
testDeveloperSkipped = do
  let listing =
        T.unlines
          [ developerCommitLine "dev1130" "2026-11-14T11:30:00Z",
            mirrorCommitLine "c1116" "2026-11-14T11:16:00Z"
          ]
      commits = parseGitLogListing listing
  assertEq "mirror commit chosen" (Just "c1116") (mcSha <$> selectTargetCommit binhostTime commits)
  assertTrue "developer is not metadata" (not (any isMirrorMetadataCommit (take 1 commits)))
  assertEq "none eligible" Nothing (selectTargetCommit binhostTime (take 1 commits))

testSigAccepted :: IO ()
testSigAccepted = assertEq "accepted" SigAccepted (parseVerifyCommitRaw mirrorSig)

testSigNoPubkey :: IO ()
testSigNoPubkey = do
  let raw = "[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 0123456789ABCDEF 1 10 00 1763120000 9 -\n[GNUPG:] NO_PUBKEY 0123456789ABCDEF\n"
  case parseVerifyCommitRaw raw of
    SigRejected _ -> pure ()
    SigAccepted -> assertTrue "NO_PUBKEY must reject" False
  case parseVerifyCommitRaw "" of
    SigRejected _ -> pure ()
    SigAccepted -> assertTrue "unsigned must reject" False

testSigWrongPrimary :: IO ()
testSigWrongPrimary =
  case parseVerifyCommitRaw (validSig "0000111122223333444455556666777788889999") of
    SigRejected why -> assertTrue "names the key" ("0000111122223333444455556666777788889999" `T.isInfixOf` why)
    SigAccepted -> assertTrue "wrong primary must reject" False

testSigRevokedExpired :: IO ()
testSigRevokedExpired = do
  let swap kw = T.replace "GOODSIG" kw mirrorSig
  assertEq "revoked" (SigRejected "signing key is revoked") (parseVerifyCommitRaw (swap "REVKEYSIG"))
  assertEq "expired" (SigRejected "signing key is expired") (parseVerifyCommitRaw (swap "EXPKEYSIG"))

testColonFingerprints :: IO ()
testColonFingerprints =
  assertEq "primary" [mirrorKeyFingerprint] (parseColonPrimaryFingerprints (T.pack (colonsFor mirrorKeyFingerprint)))

------------------------------------------------------------------------
-- Mirror key

gpgVerbs :: Harness -> IO [String]
gpgVerbs h = do
  cs <- calls h
  pure [unwords (filter (\a -> not ("/" `isPrefixOf` a)) (drop 6 c)) | c@("gpg" : _) <- cs]

testKeyFirstFetch :: IO ()
testKeyFirstFetch =
  withHarness defaultWorld {wHasKey = False} $ \h -> do
    seedTree h "c1116" Nothing
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    verbs <- gpgVerbs h
    assertTrue "show-only before import" ("--with-colons --import-options show-only --import" `elem` verbs)
    assertTrue "imported" ("--import" `elem` verbs)
    assertTrue "no keyserver receive" (not (any ("--recv-keys" `isInfixOf`) verbs))
    httpCalls <- wHttpCalls <$> readIORef (hWorld h)
    assertTrue "WKD fetched" (any ("openpgpkey" `isInfixOf`) httpCalls)
    kr <- doesDirectoryExist (gtpKeyring (hPaths h))
    assertTrue "keyring created" kr

testKeyMismatch :: IO ()
testKeyMismatch =
  withHarness defaultWorld {wHasKey = False, wWkdFpr = "0000111122223333444455556666777788889999", wRecvOk = False} $ \h -> do
    err <- assertLeft "no tree, no key" =<< syncGentooTree (hEnv h)
    assertTrue "names mismatch" ("does not match" `T.isInfixOf` err)
    verbs <- gpgVerbs h
    assertTrue "mismatched key never imported" ("--import" `notElem` verbs)
    verbsGit <- gitVerbs h
    assertEq "no clone without a key" [] (filter (== "clone") verbsGit)

testKeyKeyserverFallback :: IO ()
testKeyKeyserverFallback =
  withHarness defaultWorld {wHasKey = False, wWkdUp = False} $ \h -> do
    seedTree h "c1116" Nothing
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    verbs <- gpgVerbs h
    assertTrue "recv by fingerprint" (("--keyserver hkps://keys.gentoo.org --recv-keys " <> T.unpack mirrorKeyFingerprint) `elem` verbs)

testKeyRefreshWarns :: IO ()
testKeyRefreshWarns =
  withHarness defaultWorld {wRefreshOk = False} $ \h -> do
    seedTree h "c1116" Nothing
    _ <- assertRight "sync proceeds" =<< syncGentooTree (hEnv h)
    ws <- warnings h
    assertTrue "warns about refresh" (anyWarning "refresh" ws)
    stamp <- doesFileExist (gtpStamp (hPaths h))
    assertTrue "stamp written" stamp

testKeyRevoked :: IO ()
testKeyRevoked =
  withHarness defaultWorld {wVerify = const (T.replace "GOODSIG" "REVKEYSIG" mirrorSig)} $ \h -> do
    seedTree h "c0900" Nothing
    err <- assertLeft "revoked fails" =<< syncGentooTree (hEnv h)
    assertTrue "names revocation" ("revoked" `T.isInfixOf` err)
    assertEq "tree unchanged" (Just "c0900") =<< headOf h

------------------------------------------------------------------------
-- Sync

testFreshClone :: IO ()
testFreshClone =
  withHarness defaultWorld $ \h -> do
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    verbs <- gitVerbs h
    assertEq "one clone" 1 (length (filter (== "clone") verbs))
    cs <- calls h
    assertTrue
      "shallow stable clone"
      (any (\c -> all (`elem` c) ["--depth", "1", "--branch", "stable", mirrorRemoteUrl]) cs)
    assertEq "aligned commit" (Just "c1116") =<< headOf h
    present <- doesDirectoryExist (gtpTree (hPaths h) </> ".git")
    assertTrue "moved into place" present
    partial <- doesDirectoryExist (gtpTree (hPaths h) <> ".partial")
    assertTrue "no partial left" (not partial)
    ignore <- readFile (gtpTree (hPaths h) </> ".dockerignore")
    assertTrue ".dockerignore lists .git" (".git" `elem` lines ignore)
    exclude <- readFile (gtpTree (hPaths h) </> ".git" </> "info" </> "exclude")
    assertTrue "exclude lists .dockerignore" (".dockerignore" `elem` lines exclude)
    stamp <- doesFileExist (gtpStamp (hPaths h))
    assertTrue "stamp written" stamp

testExistingFetch :: IO ()
testExistingFetch =
  withHarness defaultWorld $ \h -> do
    seedTree h "c0900" Nothing
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    verbs <- gitVerbs h
    assertEq "no clone" [] (filter (== "clone") verbs)
    cs <- calls h
    let since = "--shallow-since=" <> iso8601Show (addUTCTime (-(6 * 60 * 60)) binhostTime)
    assertTrue "fetch since T-6h" (any (elem since) cs)
    assertEq "moved to aligned" (Just "c1116") =<< headOf h
    assertTrue "verified before checkout" (takeWhile (/= "checkout") verbs /= verbs && "verify-commit" `elem` takeWhile (/= "checkout") verbs)

testNoChangeStamp :: IO ()
testNoChangeStamp =
  withHarness defaultWorld $ \h -> do
    seedTree h "c1116" Nothing
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    verbs <- gitVerbs h
    assertEq "no checkout" [] (filter (== "checkout") verbs)
    stamp <- doesFileExist (gtpStamp (hPaths h))
    assertTrue "stamp written on no change" stamp

testBinhostDownExisting :: IO ()
testBinhostDownExisting =
  withHarness defaultWorld {wBinhost = Nothing} $ \h -> do
    seedTree h "c0900" Nothing
    _ <- assertRight "sync soft" =<< syncGentooTree (hEnv h)
    assertEq "tree stays" (Just "c0900") =<< headOf h
    ws <- warnings h
    assertTrue "names binhost" (anyWarning "binhost" ws)
    verbs <- gitVerbs h
    assertEq "no fetch" [] (filter (== "fetch") verbs)

testBinhostDownFresh :: IO ()
testBinhostDownFresh =
  withHarness defaultWorld {wBinhost = Nothing} $ \h -> do
    _ <- assertRight "sync" =<< syncGentooTree (hEnv h)
    assertEq "verified tip" (Just "c2031") =<< headOf h
    verbs <- gitVerbs h
    assertTrue "tip verified" ("verify-commit" `elem` verbs)
    ws <- warnings h
    assertTrue "warns about source builds" (anyWarning "compile from source" ws)

testStalled :: IO ()
testStalled =
  withHarness defaultWorld {wListing = T.unlines [mirrorCommitLine "c2031" "2026-11-14T20:31:00Z"]} $ \h -> do
    seedTree h "c0900" Nothing
    _ <- assertRight "sync soft" =<< syncGentooTree (hEnv h)
    assertEq "tree stays" (Just "c0900") =<< headOf h
    ws <- warnings h
    assertTrue "stalled warning" (anyWarning "appears stalled" ws)
    cs <- calls h
    let deepest = "--shallow-since=" <> iso8601Show (addUTCTime (-(7 * 24 * 60 * 60)) binhostTime)
    assertTrue "deepened to T-7d" (any (elem deepest) cs)

testOfflineWithTree :: IO ()
testOfflineWithTree =
  withHarness defaultWorld {wFetchOk = False, wRefreshOk = False} $ \h -> do
    seedTree h "c0900" Nothing
    _ <- assertRight "continues" =<< syncGentooTree (hEnv h)
    assertEq "tree stays" (Just "c0900") =<< headOf h
    ws <- warnings h
    assertTrue "warns about the mirror" (anyWarning "Gentoo mirror" ws)
    stamp <- doesFileExist (gtpStamp (hPaths h))
    assertTrue "no stamp on failure" (not stamp)

testOfflineNoTree :: IO ()
testOfflineNoTree =
  withHarness defaultWorld {wCloneOk = False} $ \h -> do
    err <- assertLeft "hard fail" =<< syncGentooTree (hEnv h)
    assertTrue "names the clone" ("failed to clone" `T.isInfixOf` err)
    present <- doesDirectoryExist (gtpTree (hPaths h))
    assertTrue "no tree" (not present)

testVerifyFailKeeps :: IO ()
testVerifyFailKeeps =
  withHarness defaultWorld {wVerify = const (validSig "0000111122223333444455556666777788889999")} $ \h -> do
    seedTree h "c0900" Nothing
    err <- assertLeft "hard fail" =<< syncGentooTree (hEnv h)
    assertTrue "names verification" ("signature verification" `T.isInfixOf` err)
    assertTrue "names expected fingerprint" (mirrorKeyFingerprint `T.isInfixOf` err)
    assertEq "tree unchanged" (Just "c0900") =<< headOf h
    verbs <- gitVerbs h
    assertEq "no checkout" [] (filter (== "checkout") verbs)

testCloneSpace :: IO ()
testCloneSpace =
  withHarness defaultWorld $ \h -> do
    let env = (hEnv h) {teProbe = DiskSpaceProbe (\_ -> pure (Right (500 * 1024 * 1024))) (\_ -> pure (Right 1))}
    err <- assertLeft "hard fail" =<< syncGentooTree env
    assertTrue "names need" ("need" `T.isInfixOf` err && "free" `T.isInfixOf` err)
    assertTrue "names path" (T.pack (gtpRoot (hPaths h)) `T.isInfixOf` err)
    verbs <- gitVerbs h
    assertEq "no clone" [] (filter (== "clone") verbs)

------------------------------------------------------------------------
-- Resolver

testResolveFresh :: IO ()
testResolveFresh =
  withHarness defaultWorld $ \h -> do
    seedTree h "c1116" (Just (60 * 60))
    tree <- assertRight "resolve" =<< resolveGentooTree (hEnv h)
    assertEq "path" (gtpTree (hPaths h)) (gentooTreePath tree)
    assertEq "commit" "c1116" (gentooTreeCommit tree)
    releaseGentooTree tree
    verbs <- gitVerbs h
    assertEq "only rev-parse" ["rev-parse"] verbs
    httpCalls <- wHttpCalls <$> readIORef (hWorld h)
    assertEq "no network" [] httpCalls

testResolveDue :: IO ()
testResolveDue =
  withHarness defaultWorld $ \h -> do
    seedTree h "c0900" (Just (7 * 60 * 60))
    tree <- assertRight "resolve" =<< resolveGentooTree (hEnv h)
    assertEq "synced commit" "c1116" (gentooTreeCommit tree)
    releaseGentooTree tree
    verbs <- gitVerbs h
    assertTrue "fetched" ("fetch" `elem` verbs)

testResolveRefresh :: IO ()
testResolveRefresh =
  withHarness defaultWorld $ \h -> do
    seedTree h "c0900" (Just (10 * 60))
    tree <- assertRight "resolve" =<< resolveGentooTree (hEnv h) {teRefresh = True}
    assertEq "synced commit" "c1116" (gentooTreeCommit tree)
    releaseGentooTree tree
    verbs <- gitVerbs h
    assertTrue "fetched" ("fetch" `elem` verbs)

testResolveWaits :: IO ()
testResolveWaits =
  withHarness defaultWorld $ \h -> do
    seedTree h "c0900" (Just (7 * 60 * 60))
    other <- acquireFileLock SharedLock (gtpLock (hPaths h))
    done <- newEmptyMVar
    _ <- forkIO (resolveGentooTree (hEnv h) >>= putMVar done)
    threadDelay 200000
    early <- tryReadMVar done
    assertTrue "sync waits" (isNothing early)
    infos <- readIORef (hInfos h)
    assertTrue "logs the wait" (any ("waiting for another run to release the Gentoo tree" `T.isInfixOf`) infos)
    verbs <- gitVerbs h
    assertEq "no fetch while held" [] (filter (== "fetch") verbs)
    releaseFileLock other
    res <- timeout 5000000 (takeMVar done)
    case res of
      Just (Right tree) -> do
        assertEq "synced after release" "c1116" (gentooTreeCommit tree)
        releaseGentooTree tree
      Just (Left err) -> assertTrue ("resolve failed: " <> T.unpack err) False
      Nothing -> assertTrue "resolve never finished" False
