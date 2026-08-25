{-# LANGUAGE OverloadedStrings #-}

-- | Autolith-style SBCL deps tarball materialize (@.qlot/@ + vendored fff).
module Update.Sbcl.Deps
  ( SbclDepsOps (..),
    SbclDepsProgress (..),
    productionSbclDepsOps,
    mkSbclDepsOps,
    buildSbclDepsTarball,
    parseSbclVersionFloor,
    materializeHome,
    sanitizeQlotConfs,
    stripUnusedFffTrees,
    materializeFff,
    qlotInstall,
  )
where

import Control.Monad (foldM, when)
import Data.Char (isDigit)
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removePathForcibly,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.DiskSpace
  ( MaterializeClass (FullSbcl),
    checkPostCloneForClass,
  )
import Update.Go.Vendor (githubCloneUrl, versionTag)
import Update.Pack.XzTar (packTarXz)
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

-- | Injectable host ops for SBCL deps materialize.
data SbclDepsOps = SbclDepsOps
  { sdoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    sdoQlotInstall :: FilePath -> IO (Either Text ()),
    -- | Copy @src/.qlot@ into @stage/.qlot@ (dereference symlinks).
    sdoCopyQlot :: FilePath -> FilePath -> IO (Either Text ()),
    sdoMaterializeFff :: FilePath -> FilePath -> IO (Either Text ()),
    sdoPackTarball :: FilePath -> FilePath -> IO (Either Text ())
  }

data SbclDepsProgress = SbclDepsProgress
  { sdpOnCloneStart :: IO (),
    sdpOnCloneDone :: IO (),
    sdpOnQlotStart :: IO (),
    sdpOnQlotDone :: IO (),
    sdpOnFffStart :: IO (),
    sdpOnFffDone :: IO (),
    sdpOnCompressStart :: IO (),
    sdpOnCompressDone :: IO ()
  }

mkSbclDepsOps :: CommandRunner -> SbclDepsOps
mkSbclDepsOps run =
  SbclDepsOps
    { sdoClone = gitCloneTag run,
      sdoQlotInstall = qlotInstall run,
      sdoCopyQlot = copyQlotTree run,
      sdoMaterializeFff = materializeFff run,
      sdoPackTarball = packDepsTarball run
    }

productionSbclDepsOps :: SbclDepsOps
productionSbclDepsOps = mkSbclDepsOps productionCommandRunner

-- | Generic home used for qlot (container @HOME@, not the operator).
materializeHome :: FilePath
materializeHome = "/home/builder"

-- | Parse trimmed @sbcl.version@ content as a dotted numeric floor.
parseSbclVersionFloor :: Text -> Maybe Text
parseSbclVersionFloor body =
  let t = T.strip body
   in if validDottedVersion t then Just t else Nothing
  where
    validDottedVersion v =
      let parts = T.splitOn "." v
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts

-- | Clone tag → qlot install → fff vendor → pack @{pn}-{pv}-deps.tar.xz@.
-- Clone and stage live under unit @workDir@; tarball under @outDir@.
buildSbclDepsTarball ::
  SbclDepsOps ->
  SbclDepsProgress ->
  Text ->
  Text ->
  Text ->
  Text ->
  -- | Unit @work/@ (clone + stage).
  FilePath ->
  -- | Unit @out/@ (staged tarball).
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildSbclDepsTarball
  ops
  progress
  owner
  repo
  prefix
  pv
  workDir
  outDir
  tarballName = do
    createDirectoryIfMissing True outDir
    createDirectoryIfMissing True workDir
    let tag = versionTag prefix pv
        url = githubCloneUrl owner repo
        outPath = outDir </> tarballName
        cloneDir = workDir </> "src"
        stageDir = workDir </> "stage"
    createDirectoryIfMissing True stageDir
    sdpOnCloneStart progress
    cloned <- sdoClone ops url tag cloneDir
    case cloned of
      Left err -> pure (Left err)
      Right () -> do
        sdpOnCloneDone progress
        spaceOk <- checkPostCloneForClass FullSbcl cloneDir
        case spaceOk of
          Left err -> pure (Left err)
          Right () ->
            preflightClone cloneDir >>= \case
              Left err -> pure (Left err)
              Right () -> do
                sdpOnQlotStart progress
                qlot <- sdoQlotInstall ops cloneDir
                case qlot of
                  Left err -> pure (Left err)
                  Right () -> do
                    sdpOnQlotDone progress
                    qlotOk <- sdoCopyQlot ops cloneDir stageDir
                    case qlotOk of
                      Left err -> pure (Left err)
                      Right () -> do
                        sanitized <- sanitizeQlotConfs stageDir
                        case sanitized of
                          Left err -> pure (Left err)
                          Right () -> do
                            sdpOnFffStart progress
                            fff <- sdoMaterializeFff ops cloneDir stageDir
                            case fff of
                              Left err -> pure (Left err)
                              Right () -> do
                                sdpOnFffDone progress
                                sdpOnCompressStart progress
                                packed <- sdoPackTarball ops stageDir outPath
                                case packed of
                                  Left err -> pure (Left err)
                                  Right () -> do
                                    sdpOnCompressDone progress
                                    hasTar <- doesFileExist outPath
                                    pure $
                                      if hasTar
                                        then Right outPath
                                        else
                                          Left
                                            ( "SBCL deps pack did not produce tarball at "
                                                <> T.pack outPath
                                            )

preflightClone :: FilePath -> IO (Either Text ())
preflightClone root = do
  hasQlfile <- doesFileExist (root </> "qlfile")
  hasLock <- doesFileExist (root </> "qlfile.lock")
  hasFffPin <- doesFileExist (root </> "native" </> "fff" </> "commit")
  pure $
    if not hasQlfile || not hasLock
      then
        Left
          ( "qlfile / qlfile.lock not found under "
              <> T.pack root
              <> " (DepsAndAssets Sbcl requires a locked Autolith-style tree)"
          )
      else
        if not hasFffPin
          then
            Left
              ( "native/fff/commit not found under "
                  <> T.pack root
              )
          else Right ()

copyQlotTree :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
copyQlotTree run cloneDir stageDir = do
  let src = cloneDir </> ".qlot"
      dest = stageDir </> ".qlot"
  exists <- doesDirectoryExist src
  if not exists
    then pure (Left "qlot install did not create .qlot/")
    else do
      removePathForcibly dest
      -- Dereference symlinks so the tarball is self-contained (qlot cache links).
      env0 <- getEnvironment
      res <-
        run
          ProcessRequest
            { prMode = ExecCmd "cp" ["-aL", src, dest],
              prCwd = Nothing,
              prEnv = Just env0,
              prStdin = ""
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right ()
          else Left ("copy .qlot failed: " <> T.pack (prStderr res))

-- | Drop builder qlot-source keys from packed confs; hard-fail on leftover @/home/@.
sanitizeQlotConfs :: FilePath -> IO (Either Text ())
sanitizeQlotConfs stageDir = do
  let confs =
        [ stageDir </> ".qlot" </> "qlot.conf",
          stageDir </> ".qlot" </> "source-registry.conf"
        ]
  foldM
    ( \acc path ->
        case acc of
          Left err -> pure (Left err)
          Right () -> sanitizeOne path
    )
    (Right ())
    confs

sanitizeOne :: FilePath -> IO (Either Text ())
sanitizeOne path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right ())
    else do
      body <- TIO.readFile path
      let rewritten = rewriteQlotConf path body
      when (rewritten /= body) (TIO.writeFile path rewritten)
      leftover <- TIO.readFile path
      pure (qlotConfLeftoverError path leftover)

rewriteQlotConf :: FilePath -> Text -> Text
rewriteQlotConf path body
  | "qlot.conf" `T.isSuffixOf` T.pack path =
      dropKeywordAndValue ":setup-file" $
        dropKeywordAndValue ":qlot-source-directory" body
  | "source-registry.conf" `T.isSuffixOf` T.pack path =
      dropDirectoryForms body
  | otherwise = body

qlotConfLeftoverError :: FilePath -> Text -> Either Text ()
qlotConfLeftoverError path leftover
  | "/home/" `T.isInfixOf` leftover =
      Left
        ( "packed qlot config still contains a /home/ pathname ("
            <> T.pack path
            <> ")"
        )
  | isQlotConf && ":qlot-source-directory" `T.isInfixOf` leftover =
      Left
        ( "packed qlot.conf still contains :qlot-source-directory ("
            <> T.pack path
            <> ")"
        )
  | isQlotConf && ":setup-file" `T.isInfixOf` leftover =
      Left
        ( "packed qlot.conf still contains :setup-file ("
            <> T.pack path
            <> ")"
        )
  | isSrcReg && ":directory" `T.isInfixOf` leftover =
      Left
        ( "packed source-registry.conf still contains a :directory entry ("
            <> T.pack path
            <> ")"
        )
  | otherwise = Right ()
  where
    name = T.pack path
    isQlotConf = "qlot.conf" `T.isSuffixOf` name
    isSrcReg = "source-registry.conf" `T.isSuffixOf` name

isLispSpace :: Char -> Bool
isLispSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

dropKeywordAndValue :: Text -> Text -> Text
dropKeywordAndValue kw = go
  where
    go t =
      case T.breakOn kw t of
        (_, rest) | T.null rest -> t
        (pre, rest) ->
          let afterWs = T.dropWhile isLispSpace (T.drop (T.length kw) rest)
           in case takeLispValue afterWs of
                Nothing -> t
                Just (_val, afterVal) ->
                  go (pre <> T.dropWhile isLispSpace afterVal)

dropDirectoryForms :: Text -> Text
dropDirectoryForms t =
  case T.breakOn "(:directory" t of
    (_, rest) | T.null rest -> t
    (pre, rest) ->
      case takeLispValue rest of
        Nothing -> t
        Just (_form, after) ->
          dropDirectoryForms (pre <> T.dropWhile isLispSpace after)

takeLispValue :: Text -> Maybe (Text, Text)
takeLispValue t
  | T.null t = Nothing
  | T.head t == '"' = splitDoubleQuoted 0 t
  | "#P\"" `T.isPrefixOf` t || "#p\"" `T.isPrefixOf` t =
      splitDoubleQuoted 2 t
  | T.head t == '(' = splitBalanced t
  | otherwise =
      let (atom, rest) = T.break (\c -> isLispSpace c || c == ')') t
       in if T.null atom then Nothing else Just (atom, rest)

-- | Split a Lisp double-quoted string starting at the quote, optionally
-- preceded by @prefixLen@ characters (e.g. @#P@ before @\"...\"@).
splitDoubleQuoted :: Int -> Text -> Maybe (Text, Text)
splitDoubleQuoted prefixLen t =
  case T.uncons (T.drop prefixLen t) of
    Just ('"', more) -> go False more
    _ -> Nothing
  where
    go escaped remaining =
      case T.uncons remaining of
        Nothing -> Nothing
        Just ('\\', more) | not escaped -> go True more
        Just ('"', more)
          | not escaped ->
              let consumed = T.length t - T.length more
               in Just (T.take consumed t, more)
        Just (_c, more) -> go False more

splitBalanced :: Text -> Maybe (Text, Text)
splitBalanced t =
  case T.uncons t of
    Just ('(', more) -> go (1 :: Int) False False more
    _ -> Nothing
  where
    go :: Int -> Bool -> Bool -> Text -> Maybe (Text, Text)
    go depth inStr escaped remaining
      | depth <= 0 =
          let consumed = T.length t - T.length remaining
           in Just (T.take consumed t, remaining)
      | otherwise =
          case T.uncons remaining of
            Nothing -> Nothing
            Just (c, more)
              | escaped -> go depth inStr False more
              | inStr && c == '\\' -> go depth True True more
              | inStr && c == '"' -> go depth False False more
              | inStr -> go depth True False more
              | c == '"' -> go depth True False more
              | c == '(' -> go (depth + 1) False False more
              | c == ')' -> go (depth - 1) False False more
              | otherwise -> go depth False False more

-- | Omit neovim/lua/plugin/tests/GitHub/flake/node trees from packed @fff/@.
stripUnusedFffTrees :: FilePath -> IO ()
stripUnusedFffTrees fffDir =
  for_ unusedFffRelPaths $ \rel ->
    removePathForcibly (fffDir </> rel)

unusedFffRelPaths :: [FilePath]
unusedFffRelPaths =
  [ "plugin",
    "lua",
    "tests",
    ".github",
    "packages",
    "flake.nix",
    "flake.lock"
  ]

------------------------------------------------------------------------
-- Production command runners
------------------------------------------------------------------------

gitCloneTag :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag run url tag dest = do
  res <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "git"
              [ "clone",
                "--depth",
                "1",
                "--branch",
                T.unpack tag,
                T.unpack url,
                dest
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("git clone failed: " <> T.pack (prStderr res))

qlotInstall ::
  CommandRunner ->
  FilePath ->
  IO (Either Text ())
qlotInstall run root = do
  env0 <- getEnvironment
  let env = ("HOME", materializeHome) : filter ((/= "HOME") . fst) env0
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "qlot" ["install"],
          prCwd = Just root,
          prEnv = Just env,
          prStdin = ""
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else Left ("qlot install failed: " <> T.pack (prStderr res))

materializeFff :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
materializeFff run root stageDir = do
  commitRaw <- TIO.readFile (root </> "native" </> "fff" </> "commit")
  let commit = T.strip commitRaw
      fffDir = stageDir </> "fff"
  removePathForcibly fffDir
  createDirectoryIfMissing True fffDir
  cloneRes <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "git"
              [ "clone",
                "--filter=blob:none",
                "https://github.com/dmtrKovalenko/fff.git",
                fffDir
              ],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = ""
        }
  if prExitCode cloneRes /= ExitSuccess
    then pure (Left ("fff clone failed: " <> T.pack (prStderr cloneRes)))
    else do
      fetchRes <-
        run
          ProcessRequest
            { prMode =
                ExecCmd
                  "git"
                  ["-C", fffDir, "fetch", "--depth", "1", "origin", T.unpack commit],
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = ""
            }
      if prExitCode fetchRes /= ExitSuccess
        then pure (Left ("fff fetch failed: " <> T.pack (prStderr fetchRes)))
        else do
          coRes <-
            run
              ProcessRequest
                { prMode =
                    ExecCmd
                      "git"
                      [ "-C",
                        fffDir,
                        "checkout",
                        "--detach",
                        "--force",
                        "FETCH_HEAD"
                      ],
                  prCwd = Nothing,
                  prEnv = Nothing,
                  prStdin = ""
                }
          if prExitCode coRes /= ExitSuccess
            then pure (Left ("fff checkout failed: " <> T.pack (prStderr coRes)))
            else do
              headRes <-
                run
                  ProcessRequest
                    { prMode = ExecCmd "git" ["-C", fffDir, "rev-parse", "HEAD"],
                      prCwd = Nothing,
                      prEnv = Nothing,
                      prStdin = ""
                    }
              let actual = T.strip (T.pack (prStdout headRes))
              if prExitCode headRes /= ExitSuccess || actual /= commit
                then
                  pure $
                    Left
                      ( "fetched fff "
                          <> actual
                          <> ", expected "
                          <> commit
                      )
                else do
                  removePathForcibly (fffDir </> "vendor")
                  vendorRes <-
                    run
                      ProcessRequest
                        { prMode =
                            ExecCmd
                              "cargo"
                              ["vendor", "--locked", "--versioned-dirs", "vendor"],
                          prCwd = Just fffDir,
                          prEnv = Nothing,
                          prStdin = ""
                        }
                  if prExitCode vendorRes /= ExitSuccess
                    then
                      pure
                        ( Left
                            ( "cargo vendor failed: "
                                <> T.pack (prStderr vendorRes)
                            )
                        )
                    else finishFffStage run fffDir

finishFffStage :: CommandRunner -> FilePath -> IO (Either Text ())
finishFffStage run fffDir = do
  createDirectoryIfMissing True (fffDir </> ".cargo")
  TIO.writeFile (fffDir </> ".cargo" </> "config.toml") cargoVendorConfig
  removePathForcibly (fffDir </> ".git")
  removePathForcibly (fffDir </> "target")
  stripUnusedFffTrees fffDir
  smokeRes <-
    run
      ProcessRequest
        { prMode =
            ExecCmd
              "cargo"
              ["build", "--offline", "--locked", "-p", "fff-c"],
          prCwd = Just fffDir,
          prEnv = Nothing,
          prStdin = ""
        }
  if prExitCode smokeRes /= ExitSuccess
    then
      pure
        ( Left
            ( "offline cargo build -p fff-c failed on staged fff tree: "
                <> T.pack (prStderr smokeRes)
            )
        )
    else do
      removePathForcibly (fffDir </> "target")
      pure (Right ())

cargoVendorConfig :: Text
cargoVendorConfig =
  "# Generated by mndz-overlay-manager for offline Portage builds.\n\
  \[source.crates-io]\n\
  \replace-with = \"vendored-sources\"\n\
  \\n\
  \[source.vendored-sources]\n\
  \directory = \"vendor\"\n"

packDepsTarball :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
packDepsTarball run stageDir =
  packTarXz
    run
    "tar pack failed"
    Nothing
    (Just stageDir)
    [".qlot", "fff"]
