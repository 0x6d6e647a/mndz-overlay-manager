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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion, renderPV)
import System.Directory (doesFileExist, listDirectory, removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit (egencacheAndSignedCommit, unitCommitMessage)
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.Assets.Hash (FileDigests (..))
import Update.AtomClosure (ensureAtomClosedForWrite)
import Update.Check (PackageEntry (..))
import Update.EbuildEdit
  ( ebuildFileNameWithRev,
    ebuildHasDevLangGoBdepend,
    ensureBunBdependFor,
    ensureCargoAssetsSrcUriFor,
    ensureCodexV8Overlay,
    ensureEmptyCrates,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureRustMinVer,
    ensureSbclAtom,
    parameterizeAssetsSrcUri,
    setKeywords,
  )
import Update.EbuildSelection
  ( InventoryFile (..),
    selectCanonicalSamePV,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Manifest.Dist (exactDistSHA512)
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

applyCodexV8 :: PackageKey -> Maybe CodexV8Overlay -> Text -> Text
applyCodexV8 (PackageKey "dev-util/codex") (Just ov) content =
  ensureCodexV8Overlay (cvoVer ov) (cvoClangDist ov) (cvoRustTcDist ov) content
applyCodexV8 _ _ content = content

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
  templatePath <- findTemplate pkgDir pn targetVer oldPath
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
          templateContent <- TIO.readFile templatePath
          let content = fromMaybe templateContent mEbuildBody
              -- Empty CRATES first so list-era detection does not treat
              -- pycargoebuild's multiline CRATES="\\n" as a crate list.
              withAssets = case eco of
                Cargo {} ->
                  ensureCargoAssetsSrcUriFor
                    (cargoSource eco)
                    pn
                    (ensureEmptyCrates content)
                _ -> parameterizeAssetsSrcUri pn content
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
            (Bun, Just ver) -> pure (ensureBunBdependFor key ver withKw)
            (Bun, Nothing) ->
              pure (Left "could not obtain engines.bun for BDEPEND alignment")
            (Cargo {}, Just msrv) ->
              pure (fmap (applyCodexV8 key mCodexV8) (ensureRustMinVer msrv withKw))
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
            Right fixed -> do
              closed <-
                ensureAtomClosedForWrite
                  (aeAtomClosure env)
                  (aeMulti env)
                  overlayRoot
                  key
                  fixed
              case closed of
                Left err ->
                  pure $ applyUnitHardFail key (ApplyAtomClosure err) False orphan
                Right () -> do
                  let newName = ebuildFileNameWithRev pn targetVer
                      newPath = pkgDir </> newName
                  TIO.writeFile newPath fixed
                  removedTemplate <-
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
                          then removeFile templatePath >> pure True
                          else pure False
                      else pure False
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

findTemplate :: FilePath -> Text -> EbuildVersion -> FilePath -> IO FilePath
findTemplate pkgDir pn targetVer fallback = do
  names <- listDirectory pkgDir
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
