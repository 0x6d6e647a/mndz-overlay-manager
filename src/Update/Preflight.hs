{-# LANGUAGE OverloadedStrings #-}

module Update.Preflight
  ( updateRequiredTools,
    assetsRequiredTools,
    goRequiredTools,
    npmRequiredTools,
    bunRequiredTools,
    cargoRequiredTools,
    cargoFetcherTools,
    goAssetsRequiredTools,
    checkToolsOnPath,
    preflightUpdateTools,
    preflightUpdateToolsWith,
    validateAssetsPath,
    validateAssetsPathWith,
    AssetsPreflight (..),
    buildUnitPlansForPackages,
  )
where

import Data.Maybe (catMaybes, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable)
import System.FilePath (takeDirectory, (</>))
import Update.Assets.Layout
  ( DistfileKind (..),
    distfileKindForEcosystem,
  )
import Update.Check (PackageEntry (..))
import Update.DiskSpace
  ( MaterializeClass (..),
    UnitDiskPlan (..),
    estimateNeedBytes,
    lookupManifestBaselineForClass,
    materializeClassFull,
    mdeName,
    mdeSize,
    parseManifestDistEntries,
    presentDistfileNeed,
    readManifestMaybe,
  )
import Update.Git (isGitWorkTree)
import Update.Hardcoded (lookupPolicy)
import Update.Types
  ( PackagePolicy (..),
    UpdateTechnique (..),
    splitPackageKey,
  )

-- | External tools required on PATH for every @update@ run.
updateRequiredTools :: [String]
updateRequiredTools = ["git", "ebuild", "egencache", "gpg"]

-- | Tools always required when any DepsAndAssets assets work is in scope.
assetsRequiredTools :: [String]
assetsRequiredTools = ["xz"]

goRequiredTools :: [String]
goRequiredTools = ["go"]

npmRequiredTools :: [String]
npmRequiredTools = ["npm"]

bunRequiredTools :: [String]
bunRequiredTools = ["bun"]

-- | Always required when any Cargo DepsAndAssets package is selected (P1).
cargoRequiredTools :: [String]
cargoRequiredTools = ["pycargoebuild"]

-- | At least one of these must be present for cargo full path (pycargoebuild fetch).
cargoFetcherTools :: [String]
cargoFetcherTools = ["wget", "aria2c", "aria2"]

-- | Legacy combined Go + xz tools (full-path Go materialize).
goAssetsRequiredTools :: [String]
goAssetsRequiredTools = goRequiredTools <> assetsRequiredTools

-- | Which language tools and assets extras to require.
data AssetsPreflight = AssetsPreflight
  { apNeedAssets :: Bool,
    apNeedGo :: Bool,
    apNeedNpm :: Bool,
    apNeedBun :: Bool,
    apNeedCargo :: Bool
  }
  deriving (Eq, Show)

-- | Check that each tool name is findable on PATH.
-- Returns missing tool names (empty list means success).
checkToolsOnPath :: (String -> IO (Maybe FilePath)) -> [String] -> IO [String]
checkToolsOnPath findTool tools = do
  results <- mapM (\t -> (t,) <$> findTool t) tools
  pure [name | (name, path) <- results, isNothing path]

-- | Preflight with per-ecosystem tool requirements (production PATH lookup).
preflightUpdateTools :: AssetsPreflight -> IO (Either Text ())
preflightUpdateTools = preflightUpdateToolsWith findExecutable

-- | Preflight with an injectable executable finder (for Unit tests).
preflightUpdateToolsWith ::
  (String -> IO (Maybe FilePath)) ->
  AssetsPreflight ->
  IO (Either Text ())
preflightUpdateToolsWith findTool ap = do
  let baseTools =
        updateRequiredTools
          <> [t | apNeedAssets ap, t <- assetsRequiredTools]
          <> [t | apNeedGo ap, t <- goRequiredTools]
          <> [t | apNeedNpm ap, t <- npmRequiredTools]
          <> [t | apNeedBun ap, t <- bunRequiredTools]
          <> [t | apNeedCargo ap, t <- cargoRequiredTools]
  missingBase <- checkToolsOnPath findTool baseTools
  missingFetchers <-
    if apNeedCargo ap
      then do
        foundAny <- checkToolsOnPath findTool cargoFetcherTools
        -- missing all fetchers → report the group
        pure
          [ "wget or aria2c"
          | length foundAny == length cargoFetcherTools
          ]
      else pure []
  let missing = missingBase <> missingFetchers
  pure $ case missing of
    [] -> Right ()
    ms ->
      Left $
        "update requires the following tools on PATH: "
          <> T.intercalate ", " (map T.pack ms)

-- | Validate assets worktree path when assets publish is required.
validateAssetsPath :: Maybe FilePath -> IO (Either Text FilePath)
validateAssetsPath = validateAssetsPathWith doesDirectoryExist isGitWorkTree

-- | Validate assets path with injectable directory / git-tree predicates.
validateAssetsPathWith ::
  (FilePath -> IO Bool) ->
  (FilePath -> IO Bool) ->
  Maybe FilePath ->
  IO (Either Text FilePath)
validateAssetsPathWith dirExists isGitTree = \case
  Nothing ->
    pure $
      Left
        "assets-path is required for packages that publish vendor/deps assets"
  Just path -> do
    exists <- dirExists path
    if not exists
      then pure $ Left ("assets-path is not a directory: " <> T.pack path)
      else do
        isGit <- isGitTree path
        pure $
          if isGit
            then Right path
            else Left ("assets-path is not a git work tree: " <> T.pack path)

-- | Conservative disk unit plans for selected packages (full-path overestimate
-- when reuse is unknown; Manifest baseline when present).
buildUnitPlansForPackages ::
  FilePath ->
  FilePath ->
  [PackageEntry] ->
  IO [UnitDiskPlan]
buildUnitPlansForPackages overlayRoot distDir entries =
  catMaybes <$> mapM (planOne overlayRoot distDir) entries

planOne :: FilePath -> FilePath -> PackageEntry -> IO (Maybe UnitDiskPlan)
planOne overlayRoot distDir entry =
  case lookupPolicy (peKey entry) of
    Nothing -> pure Nothing
    Just (PackagePolicy _ (Unsupported _)) -> pure Nothing
    Just (PackagePolicy _ GitMvAndManifest) -> do
      mContent <- readManifestMaybe (pkgDir entry)
      let mBase = mContent >>= (`lookupManifestBaselineForClass` GitMvFetch)
          rawNeed = estimateNeedBytes GitMvFetch mBase
      distNeed <- case mContent of
        Just content -> do
          let dists = parseManifestDistEntries content
          needs <-
            mapM
              ( \e ->
                  presentDistfileNeed
                    doesFileExist
                    distDir
                    (T.unpack (mdeName e))
                    (mdeSize e)
              )
              dists
          pure $
            if null dists
              then rawNeed
              else sum needs
        Nothing -> pure rawNeed
      pure $
        if distNeed <= 0
          then Nothing
          else
            Just
              UnitDiskPlan
                { udpKey = peKey entry,
                  udpClass = GitMvFetch,
                  udpTempNeed = 0,
                  udpDistNeed = distNeed
                }
    Just (PackagePolicy _ (DepsAndAssets eco)) -> do
      let cls = materializeClassFull eco
      mContent <- readManifestMaybe (pkgDir entry)
      let mBase = mContent >>= (`lookupManifestBaselineForClass` cls)
          tempNeed = estimateNeedBytes cls mBase
          kind = distfileKindForEcosystem eco
          suffix = case kind of
            VendorDist -> "-vendor.tar.xz"
            DepsDist -> "-deps.tar.xz"
            CratesDist -> "-crates.tar.xz"
      distNeed <- case mBase of
        Just b -> do
          names <-
            case mContent of
              Just c ->
                pure
                  [ T.unpack (mdeName e)
                  | e <- parseManifestDistEntries c,
                    suffix `T.isInfixOf` mdeName e
                  ]
              Nothing -> pure []
          if null names
            then pure (estimateNeedBytes GitMvFetch (Just b))
            else do
              needs <-
                mapM
                  ( \n ->
                      presentDistfileNeed doesFileExist distDir n b
                  )
                  names
              pure (maximum (0 : needs))
        Nothing -> pure (estimateNeedBytes GitMvFetch Nothing)
      pure $
        Just
          UnitDiskPlan
            { udpKey = peKey entry,
              udpClass = cls,
              udpTempNeed = tempNeed,
              udpDistNeed = distNeed
            }
  where
    pkgDir e = case splitPackageKey (peKey e) of
      Just (cat, pn) -> overlayRoot </> T.unpack cat </> T.unpack pn
      Nothing -> takeDirectory (pePath e)
