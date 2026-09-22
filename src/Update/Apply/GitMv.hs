{-# LANGUAGE OverloadedStrings #-}

-- | GitMvAndManifest apply path and md5-cache gate before mutation.
module Update.Apply.GitMv
  ( applyGitMv,
    applyGitMvWithRemote,
    applyGitMvFilesWithRemote,
    commitPendingGitMv,
    PendingGitMvCommit (..),
    requirePackageMd5Cache,
    newEbuildFileName,
  )
where

import CLI.Progress (MultiHandle (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, comparePV, prettyVersion, renderPV, renderPVNoRev)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, takeFileName, (</>))
import Update.Apply.Commit
  ( egencacheUnitPaths,
    signedOverlayCommit,
    unitCommitMessage,
  )
import Update.Apply.Env (ApplyEnv (..))
import Update.Apply.Errors
  ( ApplyUnitError (..),
    applyUnitHardFail,
  )
import Update.AtomClosure
  ( AtomClosureObserve (..),
    GitMvRenamePlan (..),
    awaitAtomProvider,
    guardGitMvRenameAway,
    observeAtomClosure,
  )
import Update.Check (PackageEntry (..))
import Update.CheckCache
  ( computeFingerprintFromDir,
    lookupLatest,
    recordFetch,
    recordHit,
    storeLatest,
  )
import Update.EbuildEdit (setSlotField)
import Update.Git (GitOps (..), relativeOverlayPath)
import Update.Md5Cache (inspectPackageCache)
import Update.OverlayTree
  ( InTree,
    readEbuildEither,
    renameEbuild,
    withOverlayTreeChecked,
    writeEbuild,
  )
import Update.OverlayWaves
  ( committingOverlayStatus,
    regeneratingManifestStatus,
  )
import Update.Types
  ( ApplyOutcome (..),
    PackageKey (..),
    SuccessLine (..),
    UpdateSource,
    packageKeyText,
    splitPackageKey,
  )

-- | GitMv file work finished; signed overlay commit not yet created.
data PendingGitMvCommit = PendingGitMvCommit
  { pgcKey :: PackageKey,
    pgcLines :: [SuccessLine],
    pgcPaths :: [FilePath],
    pgcMessage :: Text
  }
  deriving (Eq, Show)

-- | Hard-fail without mutation when package md5-cache is incomplete or mismatched.
requirePackageMd5Cache ::
  InTree ->
  FilePath ->
  PackageKey ->
  FilePath ->
  IO (Either ApplyUnitError ())
requirePackageMd5Cache tree overlayRoot key pkgDir =
  case splitPackageKey key of
    Nothing ->
      pure (Left (ApplyInvalidPackageKey (Just (packageKeyText key))))
    Just (category, pn) -> do
      inspected <- inspectPackageCache tree overlayRoot category pn pkgDir
      pure $ case inspected of
        Right () -> Right ()
        Left issue -> Left (ApplyMd5CacheGate key issue)

newEbuildFileName :: Text -> EbuildVersion -> FilePath
newEbuildFileName pn remote =
  T.unpack pn <> "-" <> T.unpack (renderPVNoRev remote) <> ".ebuild"

applyGitMv ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  IO ApplyOutcome
applyGitMv env overlayRoot entry src = do
  let key = peKey entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      mh = aeMulti env
      cache = aeCheckCache env
  mhStatus mh key "fetching"
  eFp <-
    withOverlayTreeChecked (aeTreeLock env) $ \tree ->
      computeFingerprintFromDir tree src pkgDir pn
  case eFp of
    Left err -> pure $ ApplyHardFail key err False False
    Right fp -> do
      mCached <- lookupLatest cache key fp
      fetched <- case mCached of
        Just remote -> do
          recordHit cache
          pure (Right remote)
        Nothing -> do
          recordFetch cache
          result <- aeFetcher env src
          case result of
            Right remote -> do
              storeLatest cache key fp remote
              pure (Right remote)
            Left err -> pure (Left err)
      case fetched of
        Left err ->
          pure $ ApplyHardFail key ("fetch failed: " <> err) False False
        Right remote -> applyGitMvWithRemote env overlayRoot entry src remote

-- | Mutate using a plan-phase remote version (skip re-fetch).
applyGitMvWithRemote ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EbuildVersion ->
  IO ApplyOutcome
applyGitMvWithRemote env overlayRoot entry src remote = do
  result <- applyGitMvFilesWithRemote env overlayRoot entry src remote
  case result of
    Left outcome -> pure outcome
    Right pending -> commitPendingGitMv env overlayRoot pending

-- | Rename, @ebuild … manifest@, and package @egencache@ without committing.
--
-- 'Left' is a terminal skip/fail (or incomparable). 'Right' is emergeable
-- on disk; call 'commitPendingGitMv' for the signed overlay commit.
applyGitMvFilesWithRemote ::
  ApplyEnv ->
  FilePath ->
  PackageEntry ->
  UpdateSource ->
  EbuildVersion ->
  IO (Either ApplyOutcome PendingGitMvCommit)
applyGitMvFilesWithRemote env overlayRoot entry src remote = do
  let key = peKey entry
      local = peLocal entry
      oldPath = pePath entry
      pkgDir = takeDirectory oldPath
      pn = pePN entry
      mh = aeMulti env
      cache = aeCheckCache env
  case comparePV local remote of
    Just LT -> do
      mhStatus mh key "applying"
      result <- gitMvFiles env key local remote oldPath pkgDir pn overlayRoot
      case result of
        Right pending -> do
          eFp' <-
            withOverlayTreeChecked (aeTreeLock env) $ \tree ->
              computeFingerprintFromDir tree src pkgDir pn
          case eFp' of
            Left err ->
              pure (Left (ApplyHardFail key err True False))
            Right fp' -> do
              storeLatest cache key fp' remote
              pure (Right pending)
        Left outcome -> pure (Left outcome)
    Just EQ ->
      pure $ Left $ ApplySoftSkip key "already at latest upstream version"
    Just GT ->
      pure $
        Left $
          ApplySoftSkip
            key
            ( "local version is ahead of upstream ("
                <> prettyVersion local
                <> " > "
                <> prettyVersion remote
                <> ")"
            )
    Nothing ->
      pure $
        Left $
          ApplyHardFail
            key
            ( "incomparable versions: local="
                <> T.pack (show local)
                <> " remote="
                <> T.pack (show remote)
            )
            False
            False

-- | Create the signed overlay commit for previously finished GitMv file work.
commitPendingGitMv ::
  ApplyEnv ->
  FilePath ->
  PendingGitMvCommit ->
  IO ApplyOutcome
commitPendingGitMv env overlayRoot pending = do
  let key = pgcKey pending
      mh = aeMulti env
  mhStatus mh key committingOverlayStatus
  committed <-
    signedOverlayCommit env overlayRoot (pgcPaths pending) (pgcMessage pending)
  pure $ case committed of
    Right () -> ApplySuccess key (pgcLines pending) (pgcPaths pending)
    Left err -> ApplyHardFail key err True False

gitMvFiles ::
  ApplyEnv ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  Text ->
  FilePath ->
  IO (Either ApplyOutcome PendingGitMvCommit)
gitMvFiles env key local remote oldPath pkgDir pn overlayRoot = do
  let gitOps = aeGitOps env
  eGate <-
    withOverlayTreeChecked (aeTreeLock env) $ \tree ->
      requirePackageMd5Cache tree overlayRoot key pkgDir
  case eGate of
    Left err ->
      pure $ Left $ ApplyHardFail key err False False
    Right (Left unitErr) ->
      pure $ Left $ applyUnitHardFail key unitErr False False
    Right (Right ()) -> do
      ebuildRel <- relativeOverlayPath overlayRoot oldPath
      let manifestAbs = pkgDir </> "Manifest"
      manRel0 <- relativeOverlayPath overlayRoot manifestAbs
      dirty' <- goPathsDirty gitOps overlayRoot [ebuildRel, manRel0]
      case dirty' of
        Left err -> pure $ Left $ ApplyHardFail key err False False
        Right True ->
          pure $ Left $ applyUnitHardFail key ApplyDirtyInvolvedPaths False False
        Right False ->
          publishGitMv env key local remote oldPath pkgDir pn overlayRoot ebuildRel Set.empty

-- | Observation plus the ebuild rename or add-keep writes, then manifest outside the lock.
publishGitMv ::
  ApplyEnv ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  Text ->
  FilePath ->
  FilePath ->
  Set PackageKey ->
  IO (Either ApplyOutcome PendingGitMvCommit)
publishGitMv env key local remote oldPath pkgDir pn overlayRoot ebuildRel waited = do
  let mh = aeMulti env
      newName = newEbuildFileName pn remote
      newPath = pkgDir </> newName
  eStep <-
    withOverlayTreeChecked (aeTreeLock env) $ \tree -> do
      existsNew <- doesFileExist newPath
      if existsNew && takeFileName oldPath /= newName
        then
          pure $
            GitMvTreePlainFail ("target ebuild already exists: " <> T.pack newName)
        else do
          ePlan <-
            guardGitMvRenameAway
              tree
              (aeAtomClosure env)
              overlayRoot
              key
              local
              remote
          case ePlan of
            Left err -> pure (GitMvTreeAtomFail err)
            Right plan -> do
              eBody <- readEbuildEither tree oldPath
              case eBody of
                Left err -> pure (GitMvTreePlainFail err)
                Right body -> do
                  eObs <-
                    observeAtomClosure
                      tree
                      (aeAtomClosure env)
                      overlayRoot
                      key
                      body
                      waited
                  case eObs of
                    Left err -> pure (GitMvTreeAtomFail err)
                    Right (AtomClosureRefuse msg) -> pure (GitMvTreeAtomFail msg)
                    Right (AtomClosureWait provider) -> pure (GitMvTreeWait provider)
                    Right AtomClosureSatisfied ->
                      case plan of
                        GitMvRenameNewest -> do
                          includeOld <-
                            if takeFileName oldPath == newName
                              then pure False
                              else do
                                renameEbuild tree oldPath newPath
                                pure True
                          pure $
                            GitMvTreeWrote
                              GitMvWrote
                                { gwIncludeOld = includeOld,
                                  gwNewName = newName,
                                  gwNewPath = newPath
                                }
                        GitMvAddKeepPin -> do
                          let pinSlot = renderPVNoRev local
                          writeEbuild tree newPath (setSlotField "0" body)
                          writeEbuild tree oldPath (setSlotField pinSlot body)
                          pure $
                            GitMvTreeWrote
                              GitMvWrote
                                { gwIncludeOld = True,
                                  gwNewName = newName,
                                  gwNewPath = newPath
                                }
  case eStep of
    Left err ->
      pure $ Left $ ApplyHardFail key err True False
    Right (GitMvTreePlainFail msg) ->
      pure $ Left $ ApplyHardFail key msg False False
    Right (GitMvTreeAtomFail msg) ->
      pure $ Left $ applyUnitHardFail key (ApplyAtomClosure msg) False False
    Right (GitMvTreeWait provider) -> do
      waitedRes <- awaitAtomProvider (aeAtomClosure env) mh key provider
      case waitedRes of
        Left err ->
          pure $ Left $ applyUnitHardFail key (ApplyAtomClosure err) False False
        Right () ->
          publishGitMv
            env
            key
            local
            remote
            oldPath
            pkgDir
            pn
            overlayRoot
            ebuildRel
            (Set.insert provider waited)
    Right (GitMvTreeWrote wrote) ->
      finishGitMvManifest env key local remote pkgDir overlayRoot ebuildRel wrote

data GitMvTreeStep
  = GitMvTreeWait PackageKey
  | GitMvTreeAtomFail Text
  | GitMvTreePlainFail Text
  | GitMvTreeWrote GitMvWrote

data GitMvWrote = GitMvWrote
  { gwIncludeOld :: Bool,
    gwNewName :: FilePath,
    gwNewPath :: FilePath
  }

finishGitMvManifest ::
  ApplyEnv ->
  PackageKey ->
  EbuildVersion ->
  EbuildVersion ->
  FilePath ->
  FilePath ->
  FilePath ->
  GitMvWrote ->
  IO (Either ApplyOutcome PendingGitMvCommit)
finishGitMvManifest env key local remote pkgDir overlayRoot ebuildRel wrote = do
  let mh = aeMulti env
      ebuildRun = aeEbuildRunner env
      newName = gwNewName wrote
      newPath = gwNewPath wrote
  mhStatus mh key regeneratingManifestStatus
  manResult <- ebuildRun pkgDir newName
  case manResult of
    Left err ->
      pure $ Left $ ApplyHardFail key err True False
    Right () -> do
      newRel <- relativeOverlayPath overlayRoot newPath
      manRel <- relativeOverlayPath overlayRoot (pkgDir </> "Manifest")
      let unitPaths =
            if gwIncludeOld wrote
              then [ebuildRel, newRel, manRel]
              else [newRel, manRel]
          lines_ =
            [ SuccessLine
                { slFrom = local,
                  slTo = remote,
                  slLabel = Nothing,
                  slAssetsReused = False
                }
            ]
          msg = unitCommitMessage key (renderPV remote)
      ePaths <- egencacheUnitPaths env overlayRoot key unitPaths
      case ePaths of
        Left err ->
          pure $ Left $ ApplyHardFail key err True False
        Right paths ->
          pure $
            Right
              PendingGitMvCommit
                { pgcKey = key,
                  pgcLines = lines_,
                  pgcPaths = paths,
                  pgcMessage = msg
                }
