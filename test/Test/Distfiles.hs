{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for manager private distfiles path resolution, probe, env, and
-- sticky/EPERM messaging.
module Test.Distfiles (tests) where

import Data.Bits ((.&.))
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Assert (assertEq, assertLeft, assertRight, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)
import Update.Distfiles
  ( cleanManagerDistfiles,
    defaultDistfilesPathFromEnv,
    ebuildManifestEnv,
    enrichEbuildManifestError,
    ensureDistfilesDir,
    isSystemDistfilesPathWith,
    looksLikeStickyDistfilesError,
    probeDistfilesDir,
    resolveDistfilesPath,
    systemDistfilesFallback,
  )

tests :: TestTree
tests =
  testGroup
    "Distfiles"
    [ testCase "Default path with XDG_CACHE_HOME" testDefaultPathXdg,
      testCase "Default path without XDG_CACHE_HOME" testDefaultPathHome,
      testCase "Default path empty XDG_CACHE_HOME uses home" testDefaultPathEmptyXdg,
      testCase "Resolve path CLI over config over default" testResolveOrder,
      testCase "Ensure creates 0700 directory" testEnsure0700,
      testCase "System path detection" testSystemPath,
      testCase "Probe success and fail" testProbe,
      testCase "Ebuild env DISTDIR and empty GENTOO_MIRRORS" testEbuildEnv,
      testCase "Sticky error detection and guidance" testStickyMessages,
      testCase "Eclean refuse system and clean manager" testEclean
    ]

testDefaultPathXdg :: IO ()
testDefaultPathXdg =
  assertEq
    "xdg set"
    "/tmp/cache/mndz/overlay-manager/distfiles"
    (defaultDistfilesPathFromEnv (Just "/tmp/cache") "/home/op")

testDefaultPathHome :: IO ()
testDefaultPathHome =
  assertEq
    "xdg unset"
    "/home/op/.cache/mndz/overlay-manager/distfiles"
    (defaultDistfilesPathFromEnv Nothing "/home/op")

testDefaultPathEmptyXdg :: IO ()
testDefaultPathEmptyXdg =
  assertEq
    "xdg empty"
    "/home/op/.cache/mndz/overlay-manager/distfiles"
    (defaultDistfilesPathFromEnv (Just "") "/home/op")

testResolveOrder :: IO ()
testResolveOrder = do
  cli <- resolveDistfilesPath (Just "/cli/dist") (Just "/cfg/dist")
  assertEq "cli wins" "/cli/dist" cli
  cfg <- resolveDistfilesPath Nothing (Just "/cfg/dist")
  assertEq "config wins" "/cfg/dist" cfg

testEnsure0700 :: IO ()
testEnsure0700 =
  withSystemTempDirectory "om-dist-ensure" $ \tmp -> do
    let path = tmp </> "mndz" </> "overlay-manager" </> "distfiles"
    assertRight "ensure" =<< ensureDistfilesDir path
    assertTrue "exists" =<< doesDirectoryExist path
    mode <- fileMode <$> getFileStatus path
    -- owner rwx only (0700); mask off file type bits
    assertEq "mode 0700" 0o700 (mode .&. 0o777)
    -- second call is no-op success
    assertRight "ensure again" =<< ensureDistfilesDir path

testSystemPath :: IO ()
testSystemPath =
  withSystemTempDirectory "om-dist-sys" $ \tmp -> do
    let manager = tmp </> "manager-dist"
    createDirectoryIfMissing True manager
    isSys <- isSystemDistfilesPathWith [systemDistfilesFallback] systemDistfilesFallback
    assertTrue "system path" isSys
    isMgr <- isSystemDistfilesPathWith [systemDistfilesFallback] manager
    assertTrue "manager not system" (not isMgr)

testProbe :: IO ()
testProbe =
  withSystemTempDirectory "om-dist-probe" $ \tmp -> do
    let good = tmp </> "good"
    assertRight "probe ok" =<< probeDistfilesDir good
    assertTrue "dir exists after probe" =<< doesDirectoryExist good
    leftovers <- listDirectory good
    assertEq "probe cleaned up" [] leftovers
    -- Fail: point at a regular file path (cannot create directory there).
    let badFile = tmp </> "not-a-dir"
    writeFile badFile "x"
    err <- assertLeft "probe bad" =<< probeDistfilesDir badFile
    assertTrue
      "error mentions path or create failure"
      ( T.pack badFile `T.isInfixOf` err
          || "failed to create" `T.isInfixOf` err
          || "not usable" `T.isInfixOf` err
      )

testEbuildEnv :: IO ()
testEbuildEnv = do
  let parent =
        [ ("PATH", "/usr/bin"),
          ("HOME", "/home/op"),
          ("DISTDIR", "/var/cache/distfiles"),
          ("GENTOO_MIRRORS", "https://mirror.example/"),
          ("SSH_AUTH_SOCK", "/tmp/agent")
        ]
      env' = ebuildManifestEnv "/tmp/private-dist" parent
  assertEq "DISTDIR" (Just "/tmp/private-dist") (lookup "DISTDIR" env')
  assertEq "GENTOO_MIRRORS empty" (Just "") (lookup "GENTOO_MIRRORS" env')
  assertEq "PATH kept" (Just "/usr/bin") (lookup "PATH" env')
  assertEq "SSH kept" (Just "/tmp/agent") (lookup "SSH_AUTH_SOCK" env')
  assertEq "HOME kept" (Just "/home/op") (lookup "HOME" env')
  -- No duplicate keys for overridden vars
  assertEq
    "single DISTDIR"
    1
    (length [k | (k, _) <- env', k == "DISTDIR"])
  assertEq
    "single GENTOO_MIRRORS"
    1
    (length [k | (k, _) <- env', k == "GENTOO_MIRRORS"])

testStickyMessages :: IO ()
testStickyMessages = do
  let epermDl =
        "!!! Couldn't rename /var/cache/distfiles/.__download__/foo to foo: Operation not permitted"
      epermLayout =
        "Failed to move .layout.conf.mirror: Operation not permitted under distfiles"
      plain = "some other ebuild error"
  assertTrue "eperm download" (looksLikeStickyDistfilesError epermDl)
  assertTrue "eperm layout" (looksLikeStickyDistfilesError epermLayout)
  assertTrue "plain not sticky" (not (looksLikeStickyDistfilesError plain))
  let msg = enrichEbuildManifestError "/tmp/my-dist" epermDl
  assertTrue "base prefix" ("ebuild manifest failed" `T.isInfixOf` msg)
  assertTrue "sticky wording" ("sticky" `T.isInfixOf` T.toLower msg || "ownership" `T.isInfixOf` T.toLower msg)
  assertTrue "names path" ("/tmp/my-dist" `T.isInfixOf` msg)
  assertTrue "private path guidance" ("distfiles-path" `T.isInfixOf` msg)
  let plainMsg = enrichEbuildManifestError "/tmp/my-dist" plain
  assertTrue "plain no sticky" (not ("sticky" `T.isInfixOf` T.toLower plainMsg))

testEclean :: IO ()
testEclean =
  withSystemTempDirectory "om-dist-eclean" $ \tmp -> do
    let manager = tmp </> "cache"
    createDirectoryIfMissing True manager
    writeFile (manager </> "blob") "data"
    assertRight "clean" =<< cleanManagerDistfiles manager
    assertTrue "dir remains" =<< doesDirectoryExist manager
    left <- listDirectory manager
    assertEq "emptied" [] left
    -- missing is success
    assertRight "missing" =<< cleanManagerDistfiles (tmp </> "no-such-cache")
    -- refuse system path
    refuse <- assertLeft "refuse system" =<< cleanManagerDistfiles systemDistfilesFallback
    assertTrue "refuse message" ("refuses" `T.isInfixOf` refuse || "system" `T.isInfixOf` T.toLower refuse)
    -- system path must not have been deleted by us (if it exists on host, still there)
    -- We only assert the refuse outcome.
    pure ()
