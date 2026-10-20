{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TupleSections #-}

-- | PDM deps tarball materialize inside the full-path container.
--
-- Closure authority is @pdm sync -G dev --dry-run@. This module does not run
-- @pdm lock@, @pdm export@, or a PyPI @pdm sync@.
module Update.Pdm.Deps
  ( PdmDepsOps (..),
    PdmDepsProgress (..),
    productionPdmDepsOps,
    mkPdmDepsOps,
    buildPdmDepsTarball,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson (Value, eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, parseJSON, (.!=))
import Data.Bifunctor (first)
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removePathForcibly,
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Toml (forgetTableAnns, parse)
import Toml qualified
import Toml.Semantics.Types (Table' (MkTable), pattern Table, pattern Text)
import Update.Assets.Hash (FileDigests (..), hashFile)
import Update.DiskSpace
  ( MaterializeClass (FullPdm),
    checkPostCloneForClass,
  )
import Update.Go.Vendor (githubCloneUrl)
import Update.Pack.XzTar (packTarXz)
import Update.Pdm.Lock
  ( PdmFile (..),
    PdmLock (..),
    PdmPackage (..),
    parsePdmLock,
  )
import Update.Pdm.Pack
  ( BackendOffer (..),
    PackedFile (..),
    finalizePack,
    parsePdmDryRun,
    pdmArgsAvoidFetch,
    pdmDryRunArgs,
    pdmUseArgs,
    verifyFileHash,
  )
import Update.Process
  ( CommandRunner,
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )
import Update.Uv.Pack
  ( PyprojectBuild (NoBuildSystem),
    buildRequiresOf,
    classifyPyprojectBuild,
    requirementName,
  )

-- | Injectable container ops for PDM deps materialize.
data PdmDepsOps = PdmDepsOps
  { pdoClone :: Text -> Text -> FilePath -> IO (Either Text ()),
    pdoPdm :: FilePath -> [Text] -> IO (Either Text Text),
    pdoReadFile :: FilePath -> IO (Either Text Text),
    pdoDownload :: Text -> FilePath -> IO (Either Text ()),
    pdoUnpack :: FilePath -> FilePath -> IO (Either Text ()),
    pdoPack :: FilePath -> FilePath -> IO (Either Text ())
  }

-- | Clone and pack mark the shared materialize counter. Sync stays inside
-- the pack phase so the step budget matches the other ecosystems.
data PdmDepsProgress = PdmDepsProgress
  { pdpOnCloneStart :: IO (),
    pdpOnCloneDone :: IO (),
    pdpOnPackStart :: IO (),
    pdpOnPackDone :: IO ()
  }

mkPdmDepsOps :: CommandRunner -> PdmDepsOps
mkPdmDepsOps run =
  PdmDepsOps
    { pdoClone = gitCloneTag run,
      pdoPdm = pdmChecked run,
      pdoReadFile = readTextFile,
      pdoDownload = downloadFile run,
      pdoUnpack = unpackArchive run,
      pdoPack = packStage run
    }

productionPdmDepsOps :: PdmDepsOps
productionPdmDepsOps = mkPdmDepsOps productionCommandRunner

-- | Clone the raw tag, dry-run the dev set, and pack @dists/@.
buildPdmDepsTarball ::
  PdmDepsOps ->
  PdmDepsProgress ->
  Text ->
  Text ->
  -- | Raw git tag (not @v${PV}@).
  Text ->
  Maybe FilePath ->
  -- | Python slot the image interpreter is installed for.
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either Text FilePath)
buildPdmDepsTarball ops progress owner repo tag mSub slot workDir outDir tarballName = do
  createDirectoryIfMissing True outDir
  createDirectoryIfMissing True workDir
  let url = githubCloneUrl owner repo
      outPath = outDir </> tarballName
      cloneDir = workDir </> "src"
      stageDir = workDir </> "stage"
      projectDir = case mSub of
        Nothing -> cloneDir
        Just sub -> cloneDir </> sub
  pdpOnCloneStart progress
  cloned <- pdoClone ops url tag cloneDir
  case cloned of
    Left err -> pure (Left err)
    Right () -> do
      pdpOnCloneDone progress
      spaceOk <- checkPostCloneForClass FullPdm cloneDir
      case spaceOk of
        Left err -> pure (Left err)
        Right () -> do
          lockedE <- readLock ops (projectDir </> "pdm.lock")
          case lockedE of
            Left err -> pure (Left err)
            Right lock -> do
              pyE <- pdoReadFile ops (projectDir </> "pyproject.toml")
              case pyE of
                Left err -> pure (Left err)
                Right pyBody ->
                  case projectMeta pyBody of
                    Left err -> pure (Left err)
                    Right (project, projectRequires) -> do
                      used <- pdoPdm ops projectDir (pdmUseArgs slot)
                      case used of
                        Left err -> pure (Left err)
                        Right _ -> do
                          dry <- pdoPdm ops projectDir pdmDryRunArgs
                          case dry of
                            Left err -> pure (Left err)
                            Right summary ->
                              case parsePdmDryRun summary of
                                Left err -> pure (Left err)
                                Right selected -> do
                                  pdpOnPackStart progress
                                  packed <-
                                    stagePack
                                      ops
                                      workDir
                                      stageDir
                                      lock
                                      project
                                      selected
                                      slot
                                      projectRequires
                                  case packed of
                                    Left err -> pure (Left err)
                                    Right () -> do
                                      tarred <- pdoPack ops stageDir outPath
                                      case tarred of
                                        Left err -> pure (Left err)
                                        Right () -> do
                                          pdpOnPackDone progress
                                          hasTar <- doesFileExist outPath
                                          pure $
                                            if hasTar
                                              then Right outPath
                                              else
                                                Left
                                                  ( "Pdm deps pack did not produce tarball at "
                                                      <> T.pack outPath
                                                  )

stagePack ::
  PdmDepsOps ->
  FilePath ->
  FilePath ->
  PdmLock ->
  Text ->
  [(Text, Text)] ->
  Text ->
  [Text] ->
  IO (Either Text ())
stagePack ops workDir stageDir lock project selected slot projectRequires = do
  catalog0 <- fetchCatalogs ops workDir lock Map.empty projectRequires
  case catalog0 of
    Left err -> pure (Left err)
    Right catalog ->
      walk 0 ops workDir stageDir lock project selected slot projectRequires Map.empty catalog Set.empty

walk ::
  Int ->
  PdmDepsOps ->
  FilePath ->
  FilePath ->
  PdmLock ->
  Text ->
  [(Text, Text)] ->
  Text ->
  [Text] ->
  Map Text [Text] ->
  Map Text [BackendOffer] ->
  Set Text ->
  IO (Either Text ())
walk n _ _ _ _ _ _ _ _ _ _ _
  | n > 8 = pure (Left "pdm pack walk did not finish")
walk n ops workDir stageDir lock project selected slot projectRequires sdistRequires catalog seen = do
  case finalizePack lock project selected slot sdistRequires projectRequires catalog of
    Left err -> pure (Left err)
    Right planned -> do
      let missing = [pk | pk <- planned, pkFile pk `Set.notMember` seen]
      if null missing
        then pure (Right ())
        else do
          fetched <- fetchMissing ops workDir stageDir lock catalog missing
          case fetched of
            Left err -> pure (Left err)
            Right () -> do
              grown <- growRequires ops workDir stageDir lock catalog sdistRequires missing
              case grown of
                Left err -> pure (Left err)
                Right (sdistRequires', catalog') ->
                  walk
                    (n + 1)
                    ops
                    workDir
                    stageDir
                    lock
                    project
                    selected
                    slot
                    projectRequires
                    sdistRequires'
                    catalog'
                    (seen `Set.union` Set.fromList (map pkFile missing))

fetchMissing ::
  PdmDepsOps ->
  FilePath ->
  FilePath ->
  PdmLock ->
  Map Text [BackendOffer] ->
  [PackedFile] ->
  IO (Either Text ())
fetchMissing ops workDir stageDir lock catalog =
  go Map.empty
  where
    go _ [] = pure (Right ())
    go cache (pk : rest) = do
      resolved <- resolveUrl ops workDir lock catalog cache pk
      case resolved of
        Left err -> pure (Left err)
        Right (url, cache') -> do
          let dest = stageDir </> pkPath pk
          createDirectoryIfMissing True (takeDirectory dest)
          got <- pdoDownload ops url dest
          case got of
            Left err -> pure (Left err)
            Right () -> do
              digests <- hashFile dest
              case verifyFileHash (pkHash pk) (digestSHA256 digests) of
                Left err -> pure (Left err)
                Right () -> go cache' rest

growRequires ::
  PdmDepsOps ->
  FilePath ->
  FilePath ->
  PdmLock ->
  Map Text [BackendOffer] ->
  Map Text [Text] ->
  [PackedFile] ->
  IO (Either Text (Map Text [Text], Map Text [BackendOffer]))
growRequires ops workDir stageDir lock catalog sdistRequires missing = do
  discovered <- mapM (sdistBuildRequires ops workDir stageDir) [pk | pk <- missing, isSdist pk]
  case sequence discovered of
    Left err -> pure (Left err)
    Right pairs -> do
      let sdistRequires' = Map.union (Map.fromList pairs) sdistRequires
          fresh =
            [ req
            | reqs <- Map.elems (Map.fromList pairs),
              req <- reqs,
              needsCatalog lock catalog req
            ]
      catalogE <- fetchCatalogs ops workDir lock catalog fresh
      pure $ (sdistRequires',) <$> catalogE

sdistBuildRequires ::
  PdmDepsOps ->
  FilePath ->
  FilePath ->
  PackedFile ->
  IO (Either Text (Text, [Text]))
sdistBuildRequires ops workDir stageDir pk = do
  let dest = stageDir </> pkPath pk
      unpackDir = workDir </> "unpack" </> fileKey (pkFile pk)
  createDirectoryIfMissing True unpackDir
  unpacked <- pdoUnpack ops dest unpackDir
  case unpacked of
    Left err -> pure (Left err)
    Right () -> do
      found <- findNamed "pyproject.toml" unpackDir 2
      case found of
        Nothing -> pure (Right (pkName pk, buildRequiresOf NoBuildSystem))
        Just path -> do
          bodyE <- pdoReadFile ops path
          pure $ case bodyE of
            Left err -> Left err
            Right body ->
              case classifyPyprojectBuild body of
                Left err -> Left err
                Right build -> Right (pkName pk, buildRequiresOf build)

needsCatalog :: PdmLock -> Map Text [BackendOffer] -> Text -> Bool
needsCatalog lock catalog req =
  let key = requirementName req
   in not (Map.member key catalog)
        && not (any (\pkg -> normName (ppName pkg) == key) (plPackages lock))

fetchCatalogs ::
  PdmDepsOps ->
  FilePath ->
  PdmLock ->
  Map Text [BackendOffer] ->
  [Text] ->
  IO (Either Text (Map Text [BackendOffer]))
fetchCatalogs _ _ _ catalog [] = pure (Right catalog)
fetchCatalogs ops workDir lock catalog (req : rest)
  | not (needsCatalog lock catalog req) =
      fetchCatalogs ops workDir lock catalog rest
  | otherwise = do
      let name = requirementName req
      bodyE <- fetchJson ops workDir (pypiProjectUrl name)
      case bodyE of
        Left err -> pure (Left err)
        Right body ->
          case parseProjectOffers body of
            Left err -> pure (Left err)
            Right offers ->
              fetchCatalogs
                ops
                workDir
                lock
                (Map.insert name offers catalog)
                rest

resolveUrl ::
  PdmDepsOps ->
  FilePath ->
  PdmLock ->
  Map Text [BackendOffer] ->
  Map Text Text ->
  PackedFile ->
  IO (Either Text (Text, Map Text Text))
resolveUrl ops workDir lock catalog cache pk =
  case Map.lookup (pkFile pk) cache <|> directUrl lock catalog pk of
    Just url -> pure (Right (url, Map.insert (pkFile pk) url cache))
    Nothing ->
      case fileIdentity lock catalog pk of
        Nothing ->
          pure (Left ("no download url for " <> pkFile pk))
        Just (name, ver) -> do
          bodyE <- fetchJson ops workDir (pypiVersionUrl name ver)
          case bodyE of
            Left err -> pure (Left err)
            Right body ->
              case parseVersionFiles body of
                Left err -> pure (Left err)
                Right files ->
                  let cache' = remember files cache
                   in case Map.lookup (pkFile pk) cache' of
                        Just url -> pure (Right (url, cache'))
                        Nothing ->
                          pure (Left ("pypi has no file " <> pkFile pk))

directUrl :: PdmLock -> Map Text [BackendOffer] -> PackedFile -> Maybe Text
directUrl lock catalog pk =
  firstUrl
    ( [ f
      | pkg <- plPackages lock,
        f <- ppFiles pkg,
        pfFile f == pkFile pk
      ]
        ++ [ f
           | offers <- Map.elems catalog,
             offer <- offers,
             f <- boFiles offer,
             pfFile f == pkFile pk
           ]
    )

firstUrl :: [PdmFile] -> Maybe Text
firstUrl files =
  case mapMaybe pfUrl files of
    (url : _) -> Just url
    [] -> Nothing

fileIdentity :: PdmLock -> Map Text [BackendOffer] -> PackedFile -> Maybe (Text, Text)
fileIdentity lock catalog pk =
  case find (any (\f -> pfFile f == pkFile pk) . ppFiles) (plPackages lock) of
    Just pkg -> Just (ppName pkg, ppVersion pkg)
    Nothing ->
      case [ (name, boVersion offer)
           | (name, offers) <- Map.toList catalog,
             offer <- offers,
             f <- boFiles offer,
             pfFile f == pkFile pk
           ] of
        (hit : _) -> Just hit
        [] -> Nothing

remember :: [PdmFile] -> Map Text Text -> Map Text Text
remember files cache =
  foldl'
    ( \acc file ->
        maybe acc (\url -> Map.insert (pfFile file) url acc) (pfUrl file)
    )
    cache
    files

fetchJson :: PdmDepsOps -> FilePath -> Text -> IO (Either Text Text)
fetchJson ops workDir url = do
  let dest = workDir </> "pypi-last.json"
  createDirectoryIfMissing True workDir
  got <- pdoDownload ops url dest
  case got of
    Left err -> pure (Left err)
    Right () -> pdoReadFile ops dest

pypiProjectUrl :: Text -> Text
pypiProjectUrl name = "https://pypi.org/pypi/" <> name <> "/json"

pypiVersionUrl :: Text -> Text -> Text
pypiVersionUrl name ver =
  "https://pypi.org/pypi/" <> name <> "/" <> ver <> "/json"

parseVersionFiles :: Text -> Either Text [PdmFile]
parseVersionFiles body = do
  value <- decodeJson body
  pairs <- first T.pack $ parseEither (withObject "version" (\o -> o .: "urls" >>= mapM parseOne)) value
  pure [file | (yanked, _, file) <- pairs, not yanked]

parseProjectOffers :: Text -> Either Text [BackendOffer]
parseProjectOffers body = do
  value <- decodeJson body
  first T.pack $
    parseEither
      ( withObject "project" $ \o -> do
          rels <- o .: "releases"
          mapM (uncurry oneRelease) (KM.toList rels)
      )
      value
  where
    oneRelease key val = do
      pairs <- mapM parseOne =<< parseJSON val
      let kept = [(req, file) | (yanked, req, file) <- pairs, not yanked]
      pure
        BackendOffer
          { boVersion = Key.toText key,
            boRequiresPython = firstRequires kept,
            boFiles = map snd kept
          }

parseOne :: Value -> Parser (Bool, Maybe Text, PdmFile)
parseOne = withObject "pypi file" $ \o -> do
  filename <- o .: "filename"
  url <- o .: "url"
  yanked <- o .:? "yanked" .!= False
  req <- o .:? "requires_python"
  digests <- o .: "digests"
  sha <- digests .: "sha256"
  pure (yanked, emptyToNothing req, PdmFile filename ("sha256:" <> sha) (Just url))

firstRequires :: [(Maybe Text, PdmFile)] -> Maybe Text
firstRequires pairs =
  case [req | (Just req, _) <- pairs] of
    (req : _) -> Just req
    [] -> Nothing

emptyToNothing :: Maybe Text -> Maybe Text
emptyToNothing = \case
  Just t | not (T.null (T.strip t)) -> Just t
  _ -> Nothing

decodeJson :: Text -> Either Text Value
decodeJson body =
  first (\err -> "unreadable pypi json: " <> T.pack err) $
    eitherDecodeStrict (TE.encodeUtf8 body)

projectMeta :: Text -> Either Text (Text, [Text])
projectMeta body = do
  name <- projectName body
  reqs <- case classifyPyprojectBuild body of
    Left err -> Left err
    Right build -> Right (buildRequiresOf build)
  pure (name, reqs)

projectName :: Text -> Either Text Text
projectName body =
  case parse body of
    Left _ -> Left "unreadable pyproject.toml"
    Right tab' ->
      case tableLookup "project" (forgetTableAnns tab') of
        Just (Table proj) ->
          case tableLookup "name" proj of
            Just (Text name) | not (T.null name) -> Right name
            _ -> Left "pyproject.toml has no project name"
        _ -> Left "pyproject.toml has no project name"

tableLookup :: Text -> Toml.Table -> Maybe Toml.Value
tableLookup key (MkTable m) = snd <$> Map.lookup key m

isSdist :: PackedFile -> Bool
isSdist pk = ".tar.gz" `T.isSuffixOf` T.toLower (pkFile pk)

fileKey :: Text -> FilePath
fileKey name =
  T.unpack $
    T.map
      (\c -> if isAlphaNum c then c else '_')
      (T.take 80 name)

normName :: Text -> Text
normName = T.toLower . T.replace "_" "-"

findNamed :: FilePath -> FilePath -> Int -> IO (Maybe FilePath)
findNamed name dir depth
  | depth < 0 = pure Nothing
  | otherwise = do
      let candidate = dir </> name
      here <- doesFileExist candidate
      if here
        then pure (Just candidate)
        else do
          isDir <- doesDirectoryExist dir
          if not isDir
            then pure Nothing
            else do
              kids <- listDirectory dir
              search kids
  where
    search [] = pure Nothing
    search (kid : rest) = do
      let path = dir </> kid
      isDir <- doesDirectoryExist path
      if not isDir
        then search rest
        else do
          found <- findNamed name path (depth - 1)
          case found of
            Just hit -> pure (Just hit)
            Nothing -> search rest

readLock :: PdmDepsOps -> FilePath -> IO (Either Text PdmLock)
readLock ops path = do
  bodyE <- pdoReadFile ops path
  pure $ case bodyE of
    Left err -> Left err
    Right body -> parsePdmLock body

readTextFile :: FilePath -> IO (Either Text Text)
readTextFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("file is missing: " <> T.pack path))
    else do
      bodyE <- try @IOException (TIO.readFile path)
      pure $ case bodyE of
        Left err -> Left (T.pack (show err))
        Right body -> Right body

pdmChecked :: CommandRunner -> FilePath -> [Text] -> IO (Either Text Text)
pdmChecked run cwd args
  | not (pdmArgsAvoidFetch args) =
      pure (Left "pdm arguments would fetch or refresh a lock")
  | otherwise = do
      res <-
        run
          ProcessRequest
            { prMode = ExecCmd "pdm" (map T.unpack args),
              prCwd = Just cwd,
              prEnv = Nothing,
              prStdin = ""
            }
      let out = T.pack (prStdout res)
          err = T.pack (prStderr res)
      pure $
        if prExitCode res == ExitSuccess
          then
            Right $
              if T.null (T.strip out)
                then err
                else out
          else
            Left
              ( "pdm "
                  <> T.unwords args
                  <> " failed: "
                  <> T.strip (if T.null err then out else err)
              )

gitCloneTag :: CommandRunner -> Text -> Text -> FilePath -> IO (Either Text ())
gitCloneTag run url tag dest = do
  removePathForcibly dest
  runChecked
    run
    "git clone failed"
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

downloadFile :: CommandRunner -> Text -> FilePath -> IO (Either Text ())
downloadFile run url dest =
  runChecked
    run
    "pdm dist download failed"
    ProcessRequest
      { prMode = ExecCmd "wget" ["-O", dest, T.unpack url],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

unpackArchive :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
unpackArchive run archive dest =
  runChecked
    run
    "sdist unpack failed"
    ProcessRequest
      { prMode = ExecCmd "tar" ["-xzf", archive, "-C", dest],
        prCwd = Nothing,
        prEnv = Nothing,
        prStdin = ""
      }

packStage :: CommandRunner -> FilePath -> FilePath -> IO (Either Text ())
packStage run stageDir =
  packTarXz run "tar pack failed" Nothing (Just stageDir) ["dists"]

runChecked :: CommandRunner -> Text -> ProcessRequest -> IO (Either Text ())
runChecked run prefix req = do
  res <- run req
  pure $
    if prExitCode res == ExitSuccess
      then Right ()
      else
        Left
          ( prefix
              <> ": "
              <> T.strip (T.pack (prStderr res))
          )
