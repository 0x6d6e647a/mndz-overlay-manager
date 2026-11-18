{-# LANGUAGE OverloadedStrings #-}

-- | Held units: an @update@ unit's uncommitted work, saved under the
-- manager cache before its overlay changes are rolled back.
--
-- An entry is written to @\<entry\>.tmp@ and renamed into place only when
-- complete, so a partial entry never looks complete. Rollback runs only
-- after that rename. Capture adds and removes intent-to-add index entries,
-- so callers hold the overlay critical section around 'holdUnit'.
module Update.Held
  ( -- * Metadata
    HeldReason (..),
    renderHeldReason,
    GateRunRecord (..),
    AssetRecord (..),
    HeldMeta (..),
    heldSchemaVersion,

    -- * Location
    heldRootFromEnv,
    defaultHeldRoot,
    heldEntryPath,

    -- * Capture and rollback
    HeldInput (..),
    heldPatchName,
    captureHeld,
    rollbackUnit,
    holdUnit,
  )
where

import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.Directory
  ( copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesPathExist,
    getHomeDirectory,
    listDirectory,
    removeFile,
    removePathForcibly,
    renamePath,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Types (PackageKey, packageKeyText)

------------------------------------------------------------------------
-- Metadata

heldSchemaVersion :: Int
heldSchemaVersion = 1

-- | Why a unit was held.
data HeldReason
  = HeldGate
  | HeldVerify
  | HeldInterrupted
  | HeldHalted
  | HeldCycle
  deriving (Eq, Show, Enum, Bounded)

renderHeldReason :: HeldReason -> Text
renderHeldReason = \case
  HeldGate -> "gate"
  HeldVerify -> "verify"
  HeldInterrupted -> "interrupted"
  HeldHalted -> "halted"
  HeldCycle -> "cycle"

-- | One gated run: its lane label when it has one, and its outcome
-- (@pass@, @fail: \<stage\>@, or @skip: \<reason\>@).
data GateRunRecord = GateRunRecord
  { grLane :: Maybe Text,
    grOutcome :: Text
  }
  deriving (Eq, Show)

-- | One planned assets distfile and whether it was published.
data AssetRecord = AssetRecord
  { arName :: Text,
    arPublished :: Bool
  }
  deriving (Eq, Show)

data HeldMeta = HeldMeta
  { hmPackage :: PackageKey,
    hmPv :: Text,
    -- | Policy technique, as @update@ names it.
    hmTechnique :: Text,
    -- | @full@ or @reuse@ for a DepsAndAssets unit.
    hmPath :: Maybe Text,
    -- | Gated runs, in order; empty when no run happened.
    hmRuns :: [GateRunRecord],
    hmReason :: HeldReason,
    -- | One-line cause, as logged.
    hmDetail :: Text,
    hmBaseHead :: Text,
    -- | Planned release tag, when the unit publishes.
    hmRelease :: Maybe Text,
    hmAssets :: [AssetRecord],
    -- | Overlay-relative paths the unit changed.
    hmPaths :: [FilePath],
    hmRunId :: Text,
    hmTime :: UTCTime
  }
  deriving (Eq, Show)

instance ToJSON HeldMeta where
  toJSON m =
    object
      [ "version" .= heldSchemaVersion,
        "package" .= packageKeyText (hmPackage m),
        "pv" .= hmPv m,
        "technique" .= hmTechnique m,
        "path" .= hmPath m,
        "runs" .= [object ["lane" .= grLane r, "outcome" .= grOutcome r] | r <- hmRuns m],
        "reason" .= renderHeldReason (hmReason m),
        "detail" .= hmDetail m,
        "base_head" .= hmBaseHead m,
        "release" .= hmRelease m,
        "assets" .= [object ["name" .= arName a, "published" .= arPublished a] | a <- hmAssets m],
        "paths" .= hmPaths m,
        "run_id" .= hmRunId m,
        "time" .= iso8601Show (hmTime m)
      ]

------------------------------------------------------------------------
-- Location

-- | @${XDG_CACHE_HOME}/mndz/overlay-manager/held@ when set and non-empty,
-- else @${HOME}/.cache/mndz/overlay-manager/held@.
heldRootFromEnv :: Maybe FilePath -> FilePath -> FilePath
heldRootFromEnv mXdgCache home =
  case mXdgCache of
    Just dir | not (null dir) -> dir </> "mndz" </> "overlay-manager" </> "held"
    _ -> home </> ".cache" </> "mndz" </> "overlay-manager" </> "held"

defaultHeldRoot :: IO FilePath
defaultHeldRoot = heldRootFromEnv <$> lookupEnv "XDG_CACHE_HOME" <*> getHomeDirectory

-- | @\<root\>/\<run-id\>/\<category\>/\<pn\>-\<pv\>@.
heldEntryPath :: FilePath -> Text -> PackageKey -> Text -> FilePath
heldEntryPath root runId key pv =
  let (cat, pn) = T.breakOn "/" (packageKeyText key)
   in root </> T.unpack runId </> T.unpack cat </> T.unpack (T.drop 1 pn <> "-" <> pv)

------------------------------------------------------------------------
-- Capture and rollback

data HeldInput = HeldInput
  { hiOverlay :: FilePath,
    -- | Final entry directory ('heldEntryPath').
    hiEntry :: FilePath,
    hiMeta :: HeldMeta,
    -- | Built distfiles to keep (absolute).
    hiDistfiles :: [FilePath],
    -- | Gated runs' log directories (absolute).
    hiLogDirs :: [FilePath]
  }

heldPatchName :: FilePath
heldPatchName = "overlay.patch"

-- | Write the entry: the patch of the unit's paths against @HEAD@, the
-- distfiles, the logs, then @held.json@, all under @\<entry\>.tmp@, then
-- rename it into place. On failure nothing complete-looking remains.
captureHeld :: CommandRunner -> HeldInput -> IO (Either Text ())
captureHeld run input = do
  let tmp = hiEntry input <> ".tmp"
      overlay = hiOverlay input
      paths = hmPaths (hiMeta input)
  exists <- doesPathExist (hiEntry input)
  if exists
    then pure (Left ("held entry " <> T.pack (hiEntry input) <> " already exists"))
    else do
      _ <- try @IOException (removePathForcibly tmp)
      patch <- unitPatch run overlay paths
      result <- case patch of
        Left err -> pure (Left err)
        Right body -> do
          written <- try @SomeException $ do
            createDirectoryIfMissing True tmp
            writeFile (tmp </> heldPatchName) body
            unless (null (hiDistfiles input)) $ do
              createDirectoryIfMissing True (tmp </> "distfiles")
              forM_ (hiDistfiles input) $ \f -> copyFile f (tmp </> "distfiles" </> takeFileName f)
            forM_ (hiLogDirs input) $ \d -> do
              isDir <- doesDirectoryExist d
              when isDir (copyTree d (tmp </> "logs" </> takeFileName d))
            BL.writeFile (tmp </> "held.json") (A.encode (hiMeta input) <> "\n")
            renamePath tmp (hiEntry input)
          pure $ case written of
            Left err -> Left (T.pack (show err))
            Right () -> Right ()
      case result of
        Left _ -> do
          _ <- try @IOException (removePathForcibly tmp)
          pure ()
        Right () -> pure ()
      pure result

-- | @git diff --binary -M HEAD@ of @paths@, with untracked files among them
-- briefly marked intent-to-add so new files and renames are included.
unitPatch :: CommandRunner -> FilePath -> [FilePath] -> IO (Either Text String)
unitPatch run overlay paths = do
  listed <- git run overlay (["ls-files", "--others", "--exclude-standard", "--"] <> paths)
  case listed of
    Left err -> pure (Left err)
    Right out -> do
      let untracked = filter (not . null) (lines out)
      added <- if null untracked then pure (Right "") else git run overlay (["add", "--intent-to-add", "--"] <> untracked)
      diff <- case added of
        Left err -> pure (Left err)
        Right _ -> git run overlay (["diff", "--binary", "-M", "HEAD", "--"] <> paths)
      undo <- if null untracked then pure (Right "") else git run overlay (["reset", "-q", "--"] <> untracked)
      pure $ case (diff, undo) of
        (Left err, _) -> Left err
        (_, Left err) -> Left ("could not undo intent-to-add entries: " <> err)
        (Right body, Right _) -> Right body

-- | Restore exactly @paths@ to @HEAD@ in the index and worktree, and
-- remove files among them that @HEAD@ does not have.
rollbackUnit :: CommandRunner -> FilePath -> [FilePath] -> IO (Either Text ())
rollbackUnit run overlay paths = do
  reset <- git run overlay (["reset", "-q", "--"] <> paths)
  atHead <- either (pure . Left) (const (git run overlay (["ls-tree", "-r", "--name-only", "HEAD", "--"] <> paths))) reset
  case atHead of
    Left err -> pure (Left err)
    Right out -> do
      let tracked = filter (not . null) (lines out)
      restored <-
        if null tracked
          then pure (Right "")
          else git run overlay (["restore", "--source=HEAD", "--staged", "--worktree", "--"] <> tracked)
      untracked <- either (pure . Left) (const (git run overlay (["ls-files", "--others", "--exclude-standard", "--"] <> paths))) restored
      case untracked of
        Left err -> pure (Left err)
        Right listed -> do
          removed <- try @IOException (mapM_ (removeFile . (overlay </>)) (filter (not . null) (lines listed)))
          pure $ case removed of
            Left err -> Left (T.pack (show err))
            Right () -> Right ()

-- | Capture, then roll back only when the capture is complete. The error
-- says whether the work was rolled back and names the unit's paths.
holdUnit :: CommandRunner -> HeldInput -> IO (Either Text FilePath)
holdUnit run input = do
  captured <- captureHeld run input
  let paths = T.intercalate ", " (map T.pack (hmPaths (hiMeta input)))
  case captured of
    Left err ->
      pure . Left $
        "could not save held entry "
          <> T.pack (hiEntry input)
          <> " ("
          <> err
          <> "); the work was not rolled back and remains in: "
          <> paths
    Right () -> do
      rolled <- rollbackUnit run (hiOverlay input) (hmPaths (hiMeta input))
      pure $ case rolled of
        Right () -> Right (hiEntry input)
        Left err ->
          Left $
            "saved held entry "
              <> T.pack (hiEntry input)
              <> " but could not roll back "
              <> paths
              <> ": "
              <> err

git :: CommandRunner -> FilePath -> [String] -> IO (Either Text String)
git run overlay args = do
  res <-
    run
      ProcessRequest
        { prMode = ExecCmd "git" (["-C", overlay] <> args),
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  pure $
    if prExitCode res == ExitSuccess
      then Right (prStdout res)
      else Left ("git " <> T.pack (unwords (take 2 args)) <> " failed: " <> T.strip (T.pack (prStderr res)))

copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
  createDirectoryIfMissing True dst
  names <- listDirectory src
  forM_ names $ \name -> do
    isDir <- doesDirectoryExist (src </> name)
    if isDir then copyTree (src </> name) (dst </> name) else copyFile (src </> name) (dst </> name)
