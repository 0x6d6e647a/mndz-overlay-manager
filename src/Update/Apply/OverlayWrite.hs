{-# LANGUAGE OverloadedStrings #-}

-- | Post-asset overlay ebuild write, KEYWORDS/BDEPEND alignment, and template selection.
module Update.Apply.OverlayWrite
  ( overlayAfterAssets,
    findTemplate,
  )
where

import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion, renderPV)
import System.Directory (listDirectory, removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit (egencacheAndSignedCommit, unitCommitMessage)
import Update.Apply.Env (ApplyEnv (..))
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
  FileDigests ->
  FilePath ->
  Maybe Text ->
  -- | Optional ebuild body after full-path materialize (cargo pycargoebuild).
  Maybe Text ->
  IO ApplyOutcome
overlayAfterAssets env overlayRoot entry eco keywords lines_ targetVer digests tarballName mReqVer mEbuildBody = do
  let key = peKey entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      gitOps = aeGitOps env
      ebuildRun = aeEbuildRunner env
      orphan = True
  templatePath <- findTemplate pkgDir pn targetVer oldPath
  ebuildRel <- relativeOverlayPath overlayRoot templatePath
  manRel0 <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
  dirty <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
  case dirty of
    Left err -> pure $ ApplyHardFail key err False orphan
    Right True ->
      pure $
        ApplyHardFail
          key
          "involved paths are dirty (newest ebuild and/or Manifest)"
          False
          orphan
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
              case parseManifestVendorSHA512 manText tarballName of
                Nothing ->
                  pure $
                    ApplyHardFail
                      key
                      "could not parse distfile SHA512 from Manifest after ebuild manifest"
                      True
                      orphan
                Just manSha
                  | manSha == digestSHA512 digests -> do
                      newRel <- relativeOverlayPath overlayRoot newPath
                      manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
                      let unitPaths =
                            nub $
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
                  | otherwise ->
                      pure $
                        ApplyHardFail
                          key
                          "Manifest SHA512 does not match published distfile"
                          True
                          orphan

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
