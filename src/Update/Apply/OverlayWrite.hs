{-# LANGUAGE OverloadedStrings #-}

-- | Post-asset overlay ebuild write, KEYWORDS/BDEPEND alignment, and template selection.
module Update.Apply.OverlayWrite
  ( overlayAfterAssets,
    findTemplate,
    CodexV8Overlay (..),
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion, renderPV)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit (egencacheAndSignedCommit, unitCommitMessage)
import Update.Apply.Env (ApplyEnv (..), EbuildRunner)
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.Assets.Hash (FileDigests (..))
import Update.AtomClosure
  ( AtomClosureObserve (..),
    awaitAtomProvider,
    observeAtomClosure,
  )
import Update.Bun.Cache (isBunCompilePinPackage)
import Update.Check (PackageEntry (..))
import Update.EbuildEdit
  ( AssetsHost (..),
    assetsOwnedTagCollisionFor,
    ebuildFileNameWithRev,
    ebuildHasDevLangGoBdepend,
    ensureBunBdependFor,
    ensureCargoAssetsSrcUriForHost,
    ensureCodexV8OverlayFor,
    ensureEmptyCrates,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureRustMinVer,
    ensureSbclAtom,
    parameterizeAssetsSrcUriFor,
    rewriteBunExactInvocations,
    setKeywords,
  )
import Update.EbuildSelection
  ( InventoryFile (..),
    selectCanonicalSamePV,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Manifest.Dist (exactDistSHA512)
import Update.OverlayTree
  ( InTree,
    listEbuildNames,
    readEbuild,
    removeEbuild,
    withOverlayTreeChecked,
    writeEbuild,
  )
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    PackageKey (..),
    SuccessLine,
    cargoSource,
  )

-- | Overlay writes for Codex rusty_v8 pin / Chromium GCS distfile names.
data CodexV8Overlay = CodexV8Overlay
  { cvoVer :: Text,
    -- | @Nothing@ copies donor @CLANG_DIST@ / @RUST_TC_DIST@.
    cvoClangDist :: Maybe Text,
    cvoRustTcDist :: Maybe Text
  }
  deriving (Eq, Show)

applyCodexV8 :: AssetsHost -> PackageKey -> Maybe CodexV8Overlay -> Text -> Text
applyCodexV8 host (PackageKey "dev-util/codex") (Just ov) content =
  ensureCodexV8OverlayFor host (cvoVer ov) (cvoClangDist ov) (cvoRustTcDist ov) content
applyCodexV8 _ _ _ content = content

overlayAfterAssets ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  EcosystemSpec ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  -- | Distfile basename + digests pairs (primary first; may include companions).
  [(FilePath, FileDigests)] ->
  Maybe Text ->
  -- | Optional ebuild body after full-path materialize (cargo pycargoebuild).
  Maybe Text ->
  -- | Codex rusty_v8 pin write; 'Nothing' for every other package.
  Maybe CodexV8Overlay ->
  IO ApplyOutcome
overlayAfterAssets env overlayRoot entry eco keywords lines_ targetVer distDigests mReqVer mEbuildBody mCodexV8 = do
  let key = peKey entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      orphan = True
  eTemplate <-
    withOverlayTreeChecked (aeTreeLock env) $ \tree ->
      findTemplate tree pkgDir pn targetVer oldPath
  case eTemplate of
    Left err -> pure $ ApplyHardFail key err False orphan
    Right templatePath -> do
      templateExists <- doesFileExist templatePath
      if not templateExists
        then
          pure $
            applyUnitHardFail
              key
              ( ApplyMissingDonorTemplate
                  key
                  (renderPV targetVer)
                  templatePath
              )
              False
              orphan
        else do
          ebuildRel <- relativeOverlayPath overlayRoot templatePath
          manRel0 <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
          dirty <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
          case dirty of
            Left err -> pure $ ApplyHardFail key err False orphan
            Right True ->
              pure $ applyUnitHardFail key ApplyDirtyInvolvedPaths False orphan
            Right False -> do
              eTemplateBody <-
                withOverlayTreeChecked (aeTreeLock env) $ \tree ->
                  readEbuild tree templatePath
              case eTemplateBody of
                Left err -> pure $ ApplyHardFail key err False orphan
                Right templateContent -> do
                  publishPrepared
                    env
                    overlayRoot
                    key
                    pn
                    pkgDir
                    templatePath
                    ebuildRel
                    orphan
                    eco
                    keywords
                    lines_
                    targetVer
                    distDigests
                    mReqVer
                    mEbuildBody
                    mCodexV8
                    templateContent
                    ebuildRun
                    gitOps

-- | Align the donor body, then publish under the tree lock.
publishPrepared ::
  ApplyEnv ->
  FilePath ->
  PackageKey ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  Bool ->
  EcosystemSpec ->
  [Text] ->
  [SuccessLine] ->
  EbuildVersion ->
  [(FilePath, FileDigests)] ->
  Maybe Text ->
  Maybe Text ->
  Maybe CodexV8Overlay ->
  Text ->
  EbuildRunner ->
  GitOps ->
  IO ApplyOutcome
publishPrepared
  env
  overlayRoot
  key
  pn
  pkgDir
  templatePath
  ebuildRel
  orphan
  eco
  keywords
  lines_
  targetVer
  distDigests
  mReqVer
  mEbuildBody
  mCodexV8
  templateContent
  ebuildRun
  _gitOps = do
    let content = fromMaybe templateContent mEbuildBody
        -- Empty CRATES first so list-era detection does not treat
        -- pycargoebuild's multiline CRATES="\\n" as a crate list.
        prepared = case eco of
          Cargo {} -> ensureEmptyCrates content
          _ -> content
    let assetsHost =
          AssetsHost
            { ahOwner = aeAssetsOwner env,
              ahRepo = aeAssetsRepo env
            }
    case assetsOwnedTagCollisionFor assetsHost pn prepared of
      Just err -> pure $ ApplyHardFail key err False orphan
      Nothing -> do
        let withAssets = case eco of
              Cargo {} ->
                ensureCargoAssetsSrcUriForHost
                  assetsHost
                  (cargoSource eco)
                  pn
                  prepared
              _ -> parameterizeAssetsSrcUriFor assetsHost pn prepared
            withKw = setKeywords keywords withAssets
        contentFixed <- case (eco, mReqVer) of
          (Go _, Just goVer) -> pure (ensureGoBdepend goVer withKw)
          (Go _, Nothing)
            | ebuildHasDevLangGoBdepend withKw -> pure (Right withKw)
            | otherwise ->
                pure $
                  Left
                    "could not obtain go.mod version required for BDEPEND alignment"
          (NpmEco, Just ver) -> pure (ensureNodejsBdepend ver withKw)
          (NpmEco, Nothing) ->
            pure (Left "could not obtain engines.node for BDEPEND alignment")
          (Bun, Just ver) ->
            pure $
              case ensureBunBdependFor key ver withKw of
                Left err -> Left err
                Right withBun
                  | isBunCompilePinPackage key ->
                      Right (rewriteBunExactInvocations ver withBun)
                  | otherwise -> Right withBun
          (Bun, Nothing) ->
            pure (Left "could not obtain engines.bun for BDEPEND alignment")
          (Cargo {}, Just msrv) ->
            pure (fmap (applyCodexV8 assetsHost key mCodexV8) (ensureRustMinVer msrv withKw))
          (Cargo {}, Nothing) ->
            pure
              ( Left
                  "could not determine RUST_MIN_VER (no package.rust-version, \
                  \dependency rust-version, or donor RUST_MIN_VER)"
              )
          (Sbcl, Just ver) -> pure (ensureSbclAtom ver withKw)
          (Sbcl, Nothing) ->
            pure (Left "could not obtain sbcl.version floor for SBCL atom alignment")
        case contentFixed of
          Left err -> pure $ ApplyHardFail key err False orphan
          Right fixed ->
            publishOverlayBody
              env
              overlayRoot
              key
              pn
              pkgDir
              templatePath
              ebuildRel
              orphan
              lines_
              targetVer
              distDigests
              fixed
              ebuildRun
              Set.empty

publishOverlayBody ::
  ApplyEnv ->
  FilePath ->
  PackageKey ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  Bool ->
  [SuccessLine] ->
  EbuildVersion ->
  [(FilePath, FileDigests)] ->
  Text ->
  EbuildRunner ->
  Set PackageKey ->
  IO ApplyOutcome
publishOverlayBody
  env
  overlayRoot
  key
  pn
  pkgDir
  templatePath
  ebuildRel
  orphan
  lines_
  targetVer
  distDigests
  fixed
  ebuildRun
  waited = do
    let newName = ebuildFileNameWithRev pn targetVer
        newPath = pkgDir </> newName
    eWrote <-
      withOverlayTreeChecked (aeTreeLock env) $ \tree -> do
        eObs <-
          observeAtomClosure
            tree
            (aeAtomClosure env)
            overlayRoot
            key
            fixed
            waited
        case eObs of
          Left err -> pure (Left err)
          Right (AtomClosureRefuse msg) -> pure (Left msg)
          Right (AtomClosureWait provider) -> pure (Right (Left provider))
          Right AtomClosureSatisfied -> do
            writeEbuild tree newPath fixed
            removedTemplate <- removeTemplateIfTarget tree templatePath newPath newName targetVer
            pure (Right (Right removedTemplate))
    case eWrote of
      Left err ->
        pure $ ApplyHardFail key err True orphan
      Right (Left err) ->
        pure $ applyUnitHardFail key (ApplyAtomClosure err) False orphan
      Right (Right (Left provider)) -> do
        waitedRes <-
          awaitAtomProvider (aeAtomClosure env) (aeMulti env) key provider
        case waitedRes of
          Left err ->
            pure $ applyUnitHardFail key (ApplyAtomClosure err) False orphan
          Right () ->
            publishOverlayBody
              env
              overlayRoot
              key
              pn
              pkgDir
              templatePath
              ebuildRel
              orphan
              lines_
              targetVer
              distDigests
              fixed
              ebuildRun
              (Set.insert provider waited)
      Right (Right (Right removedTemplate)) -> do
        manResult <- ebuildRun pkgDir newName
        case manResult of
          Left err -> pure $ ApplyHardFail key err True orphan
          Right () -> do
            manText <- TIO.readFile (pkgDir </> "Manifest")
            case verifyManifestDigests manText distDigests of
              Left err -> pure $ ApplyHardFail key err True orphan
              Right () -> do
                newRel <- relativeOverlayPath overlayRoot newPath
                manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
                let unitPaths =
                      nubOrd $
                        [newRel, manRel]
                          <> [ebuildRel | removedTemplate || templatePath /= newPath]
                    msg = unitCommitMessage key (renderPV targetVer)
                committed <-
                  egencacheAndSignedCommit
                    env
                    overlayRoot
                    key
                    unitPaths
                    msg
                pure $ case committed of
                  Right paths -> ApplySuccess key lines_ paths
                  Left err -> ApplyHardFail key err True orphan

removeTemplateIfTarget ::
  InTree ->
  FilePath ->
  FilePath ->
  FilePath ->
  EbuildVersion ->
  IO Bool
removeTemplateIfTarget tree templatePath newPath newName targetVer =
  if templatePath /= newPath && takeFileName templatePath /= newName
    then do
      let templateIsTarget =
            case parseEbuildFileName (takeFileName templatePath) of
              Just (_, verStr) ->
                case comparePV (parseEbuildVersion (T.pack verStr)) targetVer of
                  Just EQ -> True
                  _ -> False
              Nothing -> False
      if templateIsTarget
        then removeEbuild tree templatePath >> pure True
        else pure False
    else pure False

findTemplate :: InTree -> FilePath -> Text -> EbuildVersion -> FilePath -> IO FilePath
findTemplate tree pkgDir pn targetVer fallback = do
  names <- listEbuildNames tree pkgDir
  let files =
        [ InventoryFile (parseEbuildVersion (T.pack verStr)) (pkgDir </> n)
        | n <- names,
          Just (pkg, verStr) <- [parseEbuildFileName n],
          T.pack pkg == pn
        ]
  pure $ case selectCanonicalSamePV targetVer files of
    Right (Just f) -> invPath f
    _ -> fallback

-- | Every published distfile's SHA512 must appear in Manifest.
verifyManifestDigests :: Text -> [(FilePath, FileDigests)] -> Either Text ()
verifyManifestDigests _ [] =
  Left "no distfile digests provided for Manifest verification"
verifyManifestDigests manText distDigests =
  case mapM checkOne distDigests of
    Left err -> Left err
    Right names ->
      case catMaybes names of
        [] -> Right ()
        missing ->
          Left $
            "Manifest SHA512 does not match published distfile(s): "
              <> T.intercalate ", " (map (T.pack . takeFileName) missing)
  where
    checkOne (name, digests) =
      case exactDistSHA512 manText name of
        Left err -> Left err
        Right (Just manSha)
          | manSha == digestSHA512 digests -> Right Nothing
          | otherwise -> Right (Just name)
        Right Nothing -> Right (Just name)
