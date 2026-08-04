{-# LANGUAGE OverloadedStrings #-}

-- | Post-asset overlay ebuild write, KEYWORDS/BDEPEND alignment, and template selection.
module Update.Apply.OverlayWrite
  ( overlayAfterAssets,
    findTemplate,
  )
where

import Data.Containers.ListUtils (nubOrd)
import Data.Maybe (fromMaybe)
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
import Update.Check (PackageEntry (..))
import Update.EbuildEdit
  ( ebuildFileNameWithRev,
    ebuildHasDevLangGoBdepend,
    ensureBunBdepend,
    ensureCargoAssetsSrcUri,
    ensureEmptyCrates,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureRustMinVer,
    ensureSbclAtom,
    parameterizeAssetsSrcUri,
    parseManifestVendorSHA512,
    setKeywords,
  )
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Types
  ( ApplyOutcome (..),
    EcosystemSpec (..),
    SuccessLine,
  )

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
  IO ApplyOutcome
overlayAfterAssets env overlayRoot entry eco keywords lines_ targetVer distDigests mReqVer mEbuildBody = do
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
              withAssets = case eco of
                Cargo {} ->
                  ensureEmptyCrates (ensureCargoAssetsSrcUri pn content)
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
            (Bun, Just ver) -> pure (ensureBunBdepend ver withKw)
            (Bun, Nothing) ->
              pure (Left "could not obtain engines.bun for BDEPEND alignment")
            (Cargo {}, Just msrv) -> pure (ensureRustMinVer msrv withKw)
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
  let same =
        [ pkgDir </> n
        | n <- names,
          Just (pkg, verStr) <- [parseEbuildFileName n],
          T.pack pkg == pn,
          case comparePV (parseEbuildVersion (T.pack verStr)) targetVer of
            Just EQ -> True
            _ -> False
        ]
  pure $ case same of
    (p : _) -> p
    [] -> fallback

-- | Every published distfile's SHA512 must appear in Manifest.
verifyManifestDigests :: Text -> [(FilePath, FileDigests)] -> Either Text ()
verifyManifestDigests _ [] =
  Left "no distfile digests provided for Manifest verification"
verifyManifestDigests manText distDigests =
  case [name | (name, digests) <- distDigests, not (shaMatches name digests)] of
    [] -> Right ()
    missing ->
      Left $
        "Manifest SHA512 does not match published distfile(s): "
          <> T.intercalate ", " (map (T.pack . takeFileName) missing)
  where
    shaMatches name digests =
      case parseManifestVendorSHA512 manText name of
        Just manSha -> manSha == digestSHA512 digests
        Nothing -> False
