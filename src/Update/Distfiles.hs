{-# LANGUAGE OverloadedStrings #-}

-- | Manager private Portage distfiles cache: path resolution, ensure/probe,
-- system-DISTDIR detection, ebuild env, sticky/EPERM messaging, and eclean.
module Update.Distfiles
  ( defaultDistfilesPathFromEnv,
    defaultDistfilesPath,
    resolveDistfilesPath,
    ensureDistfilesDir,
    isSystemDistfilesPath,
    isSystemDistfilesPathWith,
    lookupPortageDistDir,
    probeDistfilesDir,
    cleanManagerDistfiles,
    ebuildManifestEnv,
    looksLikeStickyDistfilesError,
    stickyDistfilesGuidance,
    enrichEbuildManifestError,
    systemDistfilesFallback,
  )
where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    getHomeDirectory,
    listDirectory,
    makeAbsolute,
    removeFile,
    removePathForcibly,
    renameFile,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)

-- | Canonical system Portage DISTDIR when Portage is not queryable.
systemDistfilesFallback :: FilePath
systemDistfilesFallback = "/var/cache/distfiles"

-- | Pure default under XDG cache: @${XDG_CACHE_HOME}/mndz/overlay-manager/distfiles@
-- when @XDG_CACHE_HOME@ is set and non-empty; else
-- @${HOME}/.cache/mndz/overlay-manager/distfiles@.
defaultDistfilesPathFromEnv :: Maybe FilePath -> FilePath -> FilePath
defaultDistfilesPathFromEnv mXdgCache home =
  case mXdgCache of
    Just dir
      | not (null dir) ->
          dir </> "mndz" </> "overlay-manager" </> "distfiles"
    _ ->
      home </> ".cache" </> "mndz" </> "overlay-manager" </> "distfiles"

-- | Resolve default manager distfiles path from the live environment.
defaultDistfilesPath :: IO FilePath
defaultDistfilesPath = do
  xdg <- lookupEnv "XDG_CACHE_HOME"
  defaultDistfilesPathFromEnv xdg <$> getHomeDirectory

-- | Effective path: CLI override, else config @distfiles-path@, else XDG default.
resolveDistfilesPath :: Maybe FilePath -> Maybe FilePath -> IO FilePath
resolveDistfilesPath mCli mConfig =
  case mCli of
    Just p -> pure p
    Nothing -> maybe defaultDistfilesPath pure mConfig

-- | Create the directory if missing with mode @0700@. Existing dirs are left as-is.
ensureDistfilesDir :: FilePath -> IO (Either Text ())
ensureDistfilesDir path = do
  exists <- doesDirectoryExist path
  if exists
    then pure (Right ())
    else do
      result <- try @IOError $ do
        createDirectoryIfMissing True path
        setFileMode path 0o700
      pure $ case result of
        Left e ->
          Left $
            "failed to create distfiles directory "
              <> T.pack path
              <> ": "
              <> T.pack (show e)
        Right () -> Right ()

-- | Query live Portage @DISTDIR@ via @portageq envvar DISTDIR@ (best-effort).
lookupPortageDistDir :: IO (Maybe FilePath)
lookupPortageDistDir = do
  result <-
    try @IOError $
      readProcessWithExitCode "portageq" ["envvar", "DISTDIR"] ""
  pure $ case result of
    Left _ -> Nothing
    Right (ExitSuccess, out, _) ->
      let trimmed = dropWhileEnd isSpaceAscii (dropWhile isSpaceAscii out)
       in if null trimmed then Nothing else Just trimmed
    Right _ -> Nothing
  where
    isSpaceAscii c = c == ' ' || c == '\n' || c == '\r' || c == '\t'
    dropWhileEnd p = reverse . dropWhile p . reverse

-- | Whether @path@ is the system Portage DISTDIR (canonical fallback and/or live).
isSystemDistfilesPath :: FilePath -> IO Bool
isSystemDistfilesPath path = do
  mLive <- lookupPortageDistDir
  let systems = case mLive of
        Just live | live /= systemDistfilesFallback -> [systemDistfilesFallback, live]
        _ -> [systemDistfilesFallback]
  isSystemDistfilesPathWith systems path

-- | Compare @path@ to known system DISTDIR candidates after absolute form.
isSystemDistfilesPathWith :: [FilePath] -> FilePath -> IO Bool
isSystemDistfilesPathWith systemPaths path = do
  pathNorm <- normalizeForCompare path
  sysNorms <- mapM normalizeForCompare systemPaths
  pure (pathNorm `elem` sysNorms)

normalizeForCompare :: FilePath -> IO FilePath
normalizeForCompare = makeAbsolute

-- | Create-then-rename probe modeling Portage atomic distfile placement.
probeDistfilesDir :: FilePath -> IO (Either Text ())
probeDistfilesDir dir = do
  ensured <- ensureDistfilesDir dir
  case ensured of
    Left err -> pure (Left err)
    Right () -> do
      let probeA = dir </> ".mndz-om-distfiles-probe.tmp"
          probeB = dir </> ".mndz-om-distfiles-probe.renamed"
      result <- try @IOError $ do
        writeFile probeA ""
        renameFile probeA probeB
        removeFile probeB
      pure $ case result of
        Left e ->
          Left $
            "distfiles directory is not usable for ebuild manifest fetch (create-then-rename failed): "
              <> T.pack dir
              <> " ("
              <> T.pack (show e)
              <> "). Sticky or foreign-owned files under system DISTDIR often cause this; "
              <> "use the default private path under XDG cache or a user-owned "
              <> "distfiles-path / --distfiles-path."
        Right () -> Right ()

-- | Delete manager distfiles cache contents. Refuses system Portage DISTDIR.
-- Missing path is success (nothing to clean).
cleanManagerDistfiles :: FilePath -> IO (Either Text ())
cleanManagerDistfiles path = do
  system <- isSystemDistfilesPath path
  if system
    then
      pure $
        Left $
          "eclean refuses to delete the system Portage DISTDIR: "
            <> T.pack path
            <> ". Use the manager private cache (default under XDG cache "
            <> "mndz/overlay-manager/distfiles) or a non-system distfiles-path."
    else do
      exists <- doesDirectoryExist path
      if not exists
        then pure (Right ())
        else do
          -- Remove contents then leave an empty 0700 directory.
          entries <- listDirectory path
          mapM_ (\name -> removePathForcibly (path </> name)) entries
          setFileMode path 0o700
          pure (Right ())

-- | Merge parent env with @DISTDIR@ and empty @GENTOO_MIRRORS@ for ebuild manifest.
ebuildManifestEnv :: FilePath -> [(String, String)] -> [(String, String)]
ebuildManifestEnv distDir env0 =
  ("DISTDIR", distDir)
    : ("GENTOO_MIRRORS", "")
    : filter (\(k, _) -> k /= "DISTDIR" && k /= "GENTOO_MIRRORS") env0

-- | Detect sticky/EPERM/distfiles rename failure signatures in ebuild stderr.
looksLikeStickyDistfilesError :: Text -> Bool
looksLikeStickyDistfilesError err =
  let lower = T.toLower err
      hasEperm =
        "operation not permitted" `T.isInfixOf` lower
          || "eperm" `T.isInfixOf` lower
      hasDistfilesHint =
        "distfiles" `T.isInfixOf` lower
          || ".__download__" `T.isInfixOf` lower
          || ".layout.conf" `T.isInfixOf` lower
      failedMove =
        "failed to move" `T.isInfixOf` lower
          && ( "distfiles" `T.isInfixOf` lower
                 || ".__download__" `T.isInfixOf` lower
             )
   in (hasEperm && hasDistfilesHint) || failedMove

-- | Operator guidance for sticky / ownership DISTDIR failures.
stickyDistfilesGuidance :: FilePath -> Text
stickyDistfilesGuidance distDir =
  "DISTDIR may be sticky or not owned by the operator (path in use: "
    <> T.pack distDir
    <> "). Use the default private manager distfiles path under XDG cache "
    <> "(mndz/overlay-manager/distfiles) or set distfiles-path / --distfiles-path "
    <> "to a user-owned directory; do not share system sticky /var/cache/distfiles "
    <> "without fixing ownership."

-- | Prefix ebuild failure with sticky guidance when stderr matches known patterns.
enrichEbuildManifestError :: FilePath -> Text -> Text
enrichEbuildManifestError distDir stderrRaw =
  let base = "ebuild manifest failed: " <> stderrRaw
   in if looksLikeStickyDistfilesError stderrRaw
        then base <> " — " <> stickyDistfilesGuidance distDir
        else base
