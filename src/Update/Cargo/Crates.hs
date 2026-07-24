{-# LANGUAGE OverloadedStrings #-}

module Update.Cargo.Crates
  ( CargoOps (..),
    CargoProgress (..),
    CargoResult (..),
    productionCargoOps,
    noopCargoProgress,
    buildCargoCratesTarball,
    crateTarballPrefix,
    maxRustVersionInTree,
  )
where

import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Update.Cargo.Msrv
  ( combineMsrv,
    maxRustVersion,
    parseRustMinVerFromEbuild,
    parseRustVersionField,
  )
import Update.Go.Vendor (githubCloneUrl, versionTag)

-- | Internal tarball path prefix expected by cargo.eclass.
crateTarballPrefix :: Text
crateTarballPrefix = "cargo_home/gentoo"

data CargoResult = CargoResult
  { crTarballPath :: FilePath,
    -- | Combined MSRV written as RUST_MIN_VER.
    crMsrv :: Text,
    -- | Ebuild body after pycargoebuild inplace update (before manager SRC_URI patches).
    crEbuildBody :: Text
  }

data CargoOps = CargoOps
  { coClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    -- | Run pycargoebuild: ebuild path, lock root, tarball out path, temp distdir.
    coPycargoebuild :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
  }

data CargoProgress = CargoProgress
  { cgpOnCloneStart :: IO (),
    cgpOnCloneDone :: IO (),
    cgpOnPycargoStart :: IO (),
    cgpOnPycargoDone :: IO ()
  }

noopCargoProgress :: CargoProgress
noopCargoProgress =
  CargoProgress
    { cgpOnCloneStart = pure (),
      cgpOnCloneDone = pure (),
      cgpOnPycargoStart = pure (),
      cgpOnPycargoDone = pure ()
    }

productionCargoOps :: CargoOps
productionCargoOps =
  CargoOps
    { coClone = gitCloneTag,
      coPycargoebuild = runPycargoebuild
    }

-- | Clone @tag@, run @pycargoebuild -c -i -M -f@, return tarball + MSRV + ebuild body.
buildCargoCratesTarball ::
  CargoOps ->
  CargoProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe FilePath ->
  Maybe FilePath ->
  -- | Donor ebuild content (from overlay template).
  Text ->
  -- | Overlay package name (for ebuild filename in work dir).
  Text ->
  FilePath ->
  FilePath ->
  IO (Either Text CargoResult)
buildCargoCratesTarball
  ops
  progress
  owner
  repo
  prefix
  pv
  mLockSub
  mPkgSub
  donorContent
  pn
  outDir
  tarballName = do
    createDirectoryIfMissing True outDir
    let tag = versionTag prefix pv
        url = githubCloneUrl owner repo
        outPath = outDir </> tarballName
    withSystemTempDirectory "mndz-cargo-crates-" $ \tmp -> do
      let cloneDir = tmp </> "src"
          distDir = tmp </> "distdir"
          ebuildName = T.unpack pn <> "-" <> T.unpack pv <> ".ebuild"
          ebuildPath = tmp </> ebuildName
      createDirectoryIfMissing True distDir
      cgpOnCloneStart progress
      cloned <- coClone ops url tag cloneDir
      case cloned of
        Left err -> pure (Left err)
        Right () -> do
          cgpOnCloneDone progress
          let lockRoot = case mLockSub of
                Nothing -> cloneDir
                Just sub -> cloneDir </> sub
              pkgDir = case mPkgSub of
                Nothing -> lockRoot
                Just sub -> cloneDir </> sub
              -- pycargoebuild rejects workspace roots; run in the package member
              -- when set (e.g. usage's cli/). Cargo.lock is still resolved upward.
              pycargoDir = case mPkgSub of
                Just sub -> cloneDir </> sub
                Nothing -> lockRoot
          hasLock <- doesFileExist (lockRoot </> "Cargo.lock")
          if not hasLock
            then
              pure $
                Left
                  ( "Cargo.lock not found at "
                      <> T.pack lockRoot
                  )
            else do
              TIO.writeFile ebuildPath donorContent
              cgpOnPycargoStart progress
              tool <-
                coPycargoebuild
                  ops
                  ebuildPath
                  pycargoDir
                  outPath
                  distDir
              case tool of
                Left err -> pure (Left err)
                Right () -> do
                  cgpOnPycargoDone progress
                  hasTar <- doesFileExist outPath
                  if not hasTar
                    then
                      pure $
                        Left
                          ( "pycargoebuild did not produce crate tarball at "
                              <> T.pack outPath
                          )
                    else do
                      ebuildBody <- TIO.readFile ebuildPath
                      rootToml <- readOptionalToml (pkgDir </> "Cargo.toml")
                      let mRoot = parseRustVersionField =<< rootToml
                      mDeps <- maxRustVersionInTree lockRoot
                      let mDonor = parseRustMinVerFromEbuild donorContent
                      case combineMsrv mRoot mDeps mDonor of
                        Nothing ->
                          pure $
                            Left
                              "could not determine RUST_MIN_VER (no package.rust-version, \
                              \dependency rust-version, or donor RUST_MIN_VER)"
                        Just msrv ->
                          pure $
                            Right
                              CargoResult
                                { crTarballPath = outPath,
                                  crMsrv = msrv,
                                  crEbuildBody = ebuildBody
                                }

readOptionalToml :: FilePath -> IO (Maybe Text)
readOptionalToml path = do
  exists <- doesFileExist path
  if exists then Just <$> TIO.readFile path else pure Nothing

-- | Max declared @package.rust-version@ under a lock/workspace tree.
maxRustVersionInTree :: FilePath -> IO (Maybe Text)
maxRustVersionInTree root = do
  tomls <- findCargoTomls root
  vers <- mapM readVer tomls
  pure $
    case catMaybes vers of
      [] -> Nothing
      (x : xs) -> foldl' merge (Just x) xs
  where
    readVer path = do
      body <- TIO.readFile path
      pure (parseRustVersionField body)
    merge acc y = case acc of
      Nothing -> Just y
      Just a -> maxRustVersion a y

findCargoTomls :: FilePath -> IO [FilePath]
findCargoTomls root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else go root
  where
    go dir = do
      names <- listDirectory dir
      let here =
            [ dir </> n
            | n <- names,
              n == "Cargo.toml"
            ]
          skip =
            [ "target",
              ".git",
              "node_modules",
              "cargo_home"
            ]
      subs <-
        concat
          <$> mapM
            ( \n -> do
                let p = dir </> n
                isDir <- doesDirectoryExist p
                if isDir && n `notElem` skip
                  then go p
                  else pure []
            )
            names
      pure (here <> subs)

runPycargoebuild :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Text ())
runPycargoebuild ebuildPath lockRoot tarballPath distDir = do
  let args =
        [ "-c",
          "-i",
          ebuildPath,
          "-M",
          "-f",
          "--crate-tarball-path",
          tarballPath,
          "--crate-tarball-prefix",
          T.unpack crateTarballPrefix,
          "-d",
          distDir,
          lockRoot
        ]
  (code, out, err) <-
    readCreateProcessWithExitCode (proc "pycargoebuild" args) ""
  pure $
    if code == ExitSuccess
      then Right ()
      else
        Left
          ( "pycargoebuild failed: "
              <> T.strip (T.pack err)
              <> ( if T.null (T.strip (T.pack out))
                     then ""
                     else "\n" <> T.strip (T.pack out)
                 )
          )

gitCloneTag :: Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag url tag dest = do
  (code, _out, err) <-
    readCreateProcessWithExitCode
      ( proc
          "git"
          [ "clone",
            "--depth",
            "1",
            "--branch",
            T.unpack tag,
            T.unpack url,
            dest
          ]
      )
      ""
  pure $
    if code == ExitSuccess
      then Right ()
      else Left ("git clone failed: " <> T.pack err)
