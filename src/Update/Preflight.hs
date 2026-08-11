{-# LANGUAGE OverloadedStrings #-}

module Update.Preflight
  ( updateRequiredTools,
    assetsRequiredTools,
    goRequiredTools,
    npmRequiredTools,
    bunRequiredTools,
    cargoRequiredTools,
    cargoFetcherTools,
    cargoFetcherAria2Advisory,
    cargoFetcherAdvisories,
    goAssetsRequiredTools,
    checkToolsOnPath,
    preflightUpdateTools,
    preflightUpdateToolsWith,
    validateAssetsPath,
    validateAssetsPathWith,
    AssetsPreflight (..),
    assetsPreflightFromPlan,
    buildGitMvUnitPlans,
  )
where

import Data.Maybe (catMaybes, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable)
import System.FilePath ((</>))
import Update.Apply.Plan
  ( ClassifiedPvUnit (..),
    ClassifyPackageResult (..),
    PackagePlanResult (..),
    PlannedWork (..),
    needsWorkCargo,
    needsWorkDepsAssets,
  )
import Update.DiskSpace
  ( MaterializeClass (..),
    UnitDiskPlan (..),
    estimateNeedBytes,
    lookupManifestBaselineForClass,
    mdeName,
    mdeSize,
    parseManifestDistEntries,
    presentDistfileNeed,
    readManifestMaybe,
  )
import Update.Git (isGitWorkTree)
import Update.Types
  ( PackageKey (..),
    ecosystemIsBun,
    ecosystemIsCargo,
    ecosystemIsGo,
    ecosystemIsNpm,
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

-- | Always required when any Cargo DepsAndAssets package needs work (P1,
-- including reuse-only cargo units).
cargoRequiredTools :: [String]
cargoRequiredTools = ["pycargoebuild"]

-- | Hard fetcher PATH names for cargo P1 (any cargo needs work, including
-- reuse-only). At least one must be present; matches pycargoebuild 0.16
-- subprocess targets (@wget@ / @aria2c@ only — not bare @aria2@).
cargoFetcherTools :: [String]
cargoFetcherTools = ["wget", "aria2c"]

-- | Soft advisory when full-path cargo will fetch crates via wget because
-- @aria2c@ is absent. Exact text shared with tests and @usrWarnings@.
cargoFetcherAria2Advisory :: Text
cargoFetcherAria2Advisory =
  "pycargoebuild is using wget; install aria2 for faster crate fetches"

-- | Soft advisories for cargo fetchers after hard language preflight passed.
-- Emits when at least one classified unit is full-path cargo and @aria2c@ is
-- missing on PATH (injectable finder). Empty when reuse-only or @aria2c@ present.
cargoFetcherAdvisories ::
  (String -> IO (Maybe FilePath)) ->
  [ClassifyPackageResult] ->
  IO [Text]
cargoFetcherAdvisories findTool classifyResults = do
  let hasFullPathCargo =
        or
          [ ecosystemIsCargo (cpuEco u) && cpuClass u /= ReusePath
          | ClassifyOk _ us <- classifyResults,
            u <- us
          ]
  if not hasFullPathCargo
    then pure []
    else do
      mAria2c <- findTool "aria2c"
      pure $
        case mAria2c of
          Just _ -> []
          Nothing -> [cargoFetcherAria2Advisory]

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

-- | Derive tool/assets preflight from plan + classify results (A2).
--
-- Language tools only for full-path ecosystems among classified units;
-- cargo tools when any cargo package needs work (P1, including reuse-only);
-- assets/token/xz when any DepsAndAssets package needs work.
assetsPreflightFromPlan ::
  [PackagePlanResult] ->
  [ClassifyPackageResult] ->
  AssetsPreflight
assetsPreflightFromPlan planResults classifyResults =
  let needAssets = any needsWorkDepsAssets planResults
      needCargo = any needsWorkCargo planResults
      fullUnits =
        [ u
        | ClassifyOk _ us <- classifyResults,
          u <- us,
          cpuClass u /= ReusePath
        ]
      needGo = any (ecosystemIsGo . cpuEco) fullUnits
      needNpm = any (ecosystemIsNpm . cpuEco) fullUnits
      needBun = any (ecosystemIsBun . cpuEco) fullUnits
   in AssetsPreflight
        { apNeedAssets = needAssets,
          apNeedGo = needGo,
          apNeedNpm = needNpm,
          apNeedBun = needBun,
          apNeedCargo = needCargo
        }

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

-- | Dist-oriented units for GitMv packages that need work.
buildGitMvUnitPlans ::
  FilePath ->
  FilePath ->
  [PackagePlanResult] ->
  IO [UnitDiskPlan]
buildGitMvUnitPlans overlayRoot distDir planResults =
  catMaybes
    <$> mapM
      ( \case
          PlanNeedsWork key PlannedGitMv {} ->
            gitMvUnit overlayRoot distDir key
          _ -> pure Nothing
      )
      planResults

gitMvUnit :: FilePath -> FilePath -> PackageKey -> IO (Maybe UnitDiskPlan)
gitMvUnit overlayRoot distDir key = do
  let dir = case splitPackageKey key of
        Just (cat, pn) -> overlayRoot </> T.unpack cat </> T.unpack pn
        Nothing -> overlayRoot
  mContent <- readManifestMaybe dir
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
            { udpKey = key,
              udpClass = GitMvFetch,
              udpTempNeed = 0,
              udpDistNeed = distNeed
            }
