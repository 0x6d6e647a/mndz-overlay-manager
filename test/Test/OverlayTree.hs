{-# LANGUAGE OverloadedStrings #-}

module Test.OverlayTree (tests) where

import Control.Concurrent.Async (concurrently_)
import Control.Exception (try)
import Control.Monad (unless)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.OverlayTree
  ( ReentrantTreeLock (..),
    newTreeLock,
    readEbuild,
    withOverlayTree,
    writeEbuild,
  )

tests :: TestTree
tests =
  testGroup
    "Overlay tree lock"
    [ testCase "reader sees a complete old or new ebuild body" testCoherentBody,
      testCase "nested withOverlayTree throws ReentrantTreeLock" testReentrant,
      testCase "apply cannot bypass overlay ebuild IO" testNoPrivateEbuildIO
    ]

testCoherentBody :: IO ()
testCoherentBody =
  withSystemTempDirectory "om-tree-body-" $ \dir -> do
    let path = dir </> "pkg-1.0.ebuild"
        oldBody = T.replicate 4000 "old-line\n"
        newBody = T.replicate 4000 "new-line\n"
    lock <- newTreeLock
    withOverlayTree lock $ \tree -> writeEbuild tree path oldBody
    stop <- newIORef False
    let writer =
          mapM_ (publish . bodyFor) [1 .. 30 :: Int]
            >> writeIORef stop True
        bodyFor i
          | odd i = newBody
          | otherwise = oldBody
        publish body = withOverlayTree lock $ \tree -> writeEbuild tree path body
        reader = do
          body <- withOverlayTree lock $ \tree -> readEbuild tree path
          assertTrue
            "body is entirely old or entirely new"
            (body == oldBody || body == newBody)
          done <- readIORef stop
          unless done reader
    concurrently_ writer reader

testReentrant :: IO ()
testReentrant = do
  lock <- newTreeLock
  result <-
    timeout 2000000 $
      try @ReentrantTreeLock $
        withOverlayTree lock $ \_ ->
          withOverlayTree lock $ \_ -> pure ()
  case result of
    Nothing -> assertFailure "nested withOverlayTree blocked on the same thread"
    Just (Left ReentrantTreeLock) -> pure ()
    Just (Right ()) -> assertFailure "nested withOverlayTree returned"

-- | Apply and atom closure must not build a private lock, and overlay ebuild
-- syscalls stay in Update.OverlayTree except an explicit non-ebuild allowlist.
testNoPrivateEbuildIO :: IO ()
testNoPrivateEbuildIO = do
  files <- haskellSources "src"
  violations <- concat <$> mapM scanFile files
  assertEq "no private overlay ebuild IO" [] violations

haskellSources :: FilePath -> IO [FilePath]
haskellSources dir = do
  entries <- listDirectory dir
  concat <$> mapM one entries
  where
    one name = do
      let path = dir </> name
      isDir <- doesDirectoryExist path
      if isDir
        then haskellSources path
        else
          pure [path | ".hs" `isInfixOf` name]

scanFile :: FilePath -> IO [String]
scanFile path
  | path == "src/Update/OverlayTree.hs" = pure []
  | otherwise = do
      ls <- lines <$> readFile path
      pure $ concat $ zipWith (scanLine path) [1 :: Int ..] ls

scanLine :: FilePath -> Int -> String -> [String]
scanLine path n raw =
  let code = stripComment raw
      here = path <> ":" <> show n
      lockHit =
        strictLock path && mentionsNewTreeLock code
      ioHit =
        isIoCall code
          && not (allowedIoLine path raw)
   in [here <> " mentions newTreeLock" | lockHit]
        <> [here <> " raw ebuild IO: " <> strip code | ioHit]

-- | Whole word, so a longer name is not a hit. The task also treats the
-- substring as a bypass, so 'withNewTreeLock' counts.
mentionsNewTreeLock :: String -> Bool
mentionsNewTreeLock = isInfixOf "newTreeLock"

strictLock :: FilePath -> Bool
strictLock path =
  "src/Update/Apply/" `isInfixOf` path
    || path == "src/Update/AtomClosure.hs"

strictIo :: FilePath -> Bool
strictIo path =
  strictLock path
    || path
      `elem` [ "src/Update/Check.hs",
               "src/Update/CheckCache.hs",
               "src/Update/Md5Cache.hs",
               "src/Update/Runtime/Ceilings.hs"
             ]

allowedIoLine :: FilePath -> String -> Bool
allowedIoLine path code
  | not (isIoCall code) = True
  | strictIo path =
      any
        (`isInfixOf` code)
        ["Manifest", "Cargo.lock", "allow-non-ebuild"]
  | otherwise = path `elem` nonEbuildAllowlist

isIoCall :: String -> Bool
isIoCall code =
  any (`followedByArg` code) ["readFile", "writeFile", "renameFile", "removeFile"]

followedByArg :: String -> String -> Bool
followedByArg verb text = go text
  where
    go [] = False
    go rest
      | verb `isPrefixOf` rest && boundary (before rest) && argAfter rest = True
      | otherwise = go (drop 1 rest)
    before rest = take (length text - length rest) text
    boundary prefix =
      case reverse prefix of
        [] -> True
        (c : _) -> not (isIdent c)
    argAfter rest =
      case drop (length verb) rest of
        (c : _) -> c == ' ' || c == '\t'
        _ -> False

isIdent :: Char -> Bool
isIdent c = c == '_' || isAsciiUpper c || isAsciiLower c || isDigit c

nonEbuildAllowlist :: [FilePath]
nonEbuildAllowlist =
  [ "src/Config/Loader.hs",
    "src/Overlay/Validation.hs",
    "src/Update/Assets/Hash.hs",
    "src/Update/Assets/Release.hs",
    "src/Update/Bun/Cache.hs",
    "src/Update/Cargo/Crates.hs",
    "src/Update/Cargo/Msrv.hs",
    "src/Update/DiskSpace.hs",
    "src/Update/Distfiles.hs",
    "src/Update/GitHubToken.hs",
    "src/Update/Go/Vendor.hs",
    "src/Update/Materialize/Ensure.hs",
    "src/Update/Npm/Cache.hs",
    "src/Update/Pack/XzTar.hs",
    "src/Update/Sbcl/Deps.hs",
    "src/Update/SshAgent.hs"
  ]

stripComment :: String -> String
stripComment = go False
  where
    go _ [] = []
    go False ('-' : '-' : _) = []
    go False ('"' : rest) = '"' : go True rest
    go True ('"' : rest) = '"' : go False rest
    go inString (c : rest) = c : go inString rest

strip :: String -> String
strip = dropWhile (`elem` [' ', '\t'])
