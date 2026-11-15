{-# LANGUAGE OverloadedStrings #-}

-- | The manager-owned Gentoo tree: a shallow clone of the Gentoo git mirror
-- under the manager cache, verified against the pinned mirror key and moved
-- to the newest mirror metadata commit the Gentoo binhost index covers.
--
-- Every tree reader takes the path from 'resolveGentooTree'. The resolver
-- holds a shared lock on @gentoo.lock@ until the process exits; a due sync
-- takes it exclusively, syncs, and downgrades. git, gpg, HTTP, the clock, the
-- disk probe, and the lock are all injected through 'TreeEnv'.
module Update.GentooTree
  ( -- * Paths
    GentooTreePaths (..),
    gentooTreePathsFromEnv,
    defaultGentooTreePaths,

    -- * Resolver
    TreeEnv (..),
    TreeLockOps (..),
    HeldLock (..),
    fileTreeLockOps,
    GentooTree,
    resolveGentooTree,
    gentooTreePath,
    gentooTreeCommit,
    releaseGentooTree,
    productionTreeEnv,

    -- * Sync
    syncGentooTree,

    -- * Constants
    mirrorRemoteUrl,
    mirrorKeyFingerprint,
    mirrorKeyServer,
    mirrorKeyWkdUrls,
    cloneFreeBytesNeed,
    binhostPackagesUrl,

    -- * Pure helpers
    parsePackagesTimestamp,
    MirrorCommit (..),
    parseGitLogListing,
    isMirrorMetadataCommit,
    selectTargetCommit,
    SigVerdict (..),
    parseVerifyCommitRaw,
    parseColonPrimaryFingerprints,
  )
where

import Control.Exception (onException)
import Control.Monad (unless, void, when)
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.Char (isDigit)
import Data.List (find)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( NominalDiffTime,
    UTCTime,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
  )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Metrics.Core (Metrics)
import Metrics.Process (timedRunner)
import Network.HTTP.Client
  ( parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
    removeDirectoryRecursive,
    removeFile,
    renameDirectory,
    renameFile,
  )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Unistd (getSystemID, machine)
import Update.DiskSpace (DiskSpaceProbe (..), formatBytesHuman, productionDiskSpaceProbe)
import Update.FileLock
  ( LockMode (..),
    acquireFileLock,
    downgradeFileLock,
    releaseFileLock,
    tryAcquireFileLock,
  )
import Update.Http (HttpLbs, httpLbsEither, newMetricsManager)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    productionCommandRunner,
  )

------------------------------------------------------------------------
-- Paths

-- | Files of the managed tree under @…/mndz/overlay-manager@.
data GentooTreePaths = GentooTreePaths
  { -- | Cache root holding the tree, keyring, stamp, and lock.
    gtpRoot :: FilePath,
    -- | The git checkout (@gentoo@).
    gtpTree :: FilePath,
    -- | Isolated GnuPG home (@gentoo-keyring@, mode 0700).
    gtpKeyring :: FilePath,
    -- | Last successful sync check (@gentoo.last-sync-check@).
    gtpStamp :: FilePath,
    -- | @flock@ file (@gentoo.lock@).
    gtpLock :: FilePath
  }
  deriving (Eq, Show)

-- | Paths from @XDG_CACHE_HOME@ (when set and non-empty) and @HOME@.
gentooTreePathsFromEnv :: Maybe String -> FilePath -> GentooTreePaths
gentooTreePathsFromEnv mXdg home =
  GentooTreePaths
    { gtpRoot = root,
      gtpTree = root </> "gentoo",
      gtpKeyring = root </> "gentoo-keyring",
      gtpStamp = root </> "gentoo.last-sync-check",
      gtpLock = root </> "gentoo.lock"
    }
  where
    root = case mXdg of
      Just dir | not (null dir) -> dir </> "mndz" </> "overlay-manager"
      _ -> home </> ".cache" </> "mndz" </> "overlay-manager"

defaultGentooTreePaths :: IO GentooTreePaths
defaultGentooTreePaths = do
  xdg <- lookupEnv "XDG_CACHE_HOME"
  gentooTreePathsFromEnv xdg <$> getHomeDirectory

------------------------------------------------------------------------
-- Constants

mirrorRemoteUrl :: String
mirrorRemoteUrl = "https://github.com/gentoo-mirror/gentoo.git"

mirrorBranch :: String
mirrorBranch = "stable"

-- | Primary fingerprint of the Gentoo repository-mirror key
-- (@repomirrorci\@gentoo.org@).
mirrorKeyFingerprint :: Text
mirrorKeyFingerprint = "EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72"

mirrorKeyServer :: String
mirrorKeyServer = "hkps://keys.gentoo.org"

-- | Web Key Directory URLs for @repomirrorci\@gentoo.org@ (advanced, then
-- direct). The hash is z-base-32 of SHA-1 of the local part.
mirrorKeyWkdUrls :: [String]
mirrorKeyWkdUrls =
  [ "https://openpgpkey.gentoo.org/.well-known/openpgpkey/gentoo.org/hu/" <> wkdHash <> "?l=repomirrorci",
    "https://gentoo.org/.well-known/openpgpkey/hu/" <> wkdHash <> "?l=repomirrorci"
  ]
  where
    wkdHash = "9tik1tjkx1fe3wke63tpd7iikyogfbtq"

-- | Free space the cache filesystem needs before the first clone (1 GiB).
cloneFreeBytesNeed :: Integer
cloneFreeBytesNeed = 1024 * 1024 * 1024

-- | Margin between the binhost index time and the newest eligible commit.
alignmentMargin :: NominalDiffTime
alignmentMargin = 60 * 60

-- | Fetch windows before the binhost time: 6h first, deepening to 7 days.
fetchWindows :: [NominalDiffTime]
fetchWindows = [6 * hour, 24 * hour, 3 * 24 * hour, 7 * 24 * hour]
  where
    hour = 60 * 60

-- | Host-architecture binhost @Packages@ index (@uname -m@). 'Nothing' for
-- hosts without a mapped Gentoo binhost.
binhostPackagesUrl :: String -> Maybe String
binhostPackagesUrl uname = (\p -> base <> p <> "/Packages") <$> profile
  where
    base = "https://distfiles.gentoo.org/releases/"
    profile = case uname of
      "x86_64" -> Just "amd64/binpackages/23.0/x86-64"
      "amd64" -> Just "amd64/binpackages/23.0/x86-64"
      "aarch64" -> Just "arm64/binpackages/23.0/arm64"
      "arm64" -> Just "arm64/binpackages/23.0/arm64"
      _ -> Nothing

------------------------------------------------------------------------
-- Pure helpers

-- | @TIMESTAMP: <epoch>@ from the header block of a binhost @Packages@ index.
parsePackagesTimestamp :: Text -> Maybe UTCTime
parsePackagesTimestamp body =
  listToMaybe (mapMaybe stamp headerLines)
  where
    headerLines = takeWhile (not . T.null . T.strip) (T.lines body)
    stamp line = do
      rest <- T.stripPrefix "TIMESTAMP:" line
      let digits = T.strip rest
      if not (T.null digits) && T.all isDigit digits
        then Just (posixSecondsToUTCTime (fromInteger (read (T.unpack digits))))
        else Nothing

-- | One commit from 'gitLogFormat' output.
data MirrorCommit = MirrorCommit
  { mcSha :: Text,
    mcTime :: UTCTime,
    mcCommitter :: Text,
    mcSubject :: Text
  }
  deriving (Eq, Show)

-- | @%H TAB %ct TAB %cn TAB %s@.
gitLogFormat :: String
gitLogFormat = "--format=%H%x09%ct%x09%cn%x09%s"

-- | Parse 'gitLogFormat' lines, skipping malformed ones.
parseGitLogListing :: Text -> [MirrorCommit]
parseGitLogListing = mapMaybe parseLine . T.lines
  where
    parseLine line = case T.splitOn "\t" line of
      (sha : ct : cn : subjectParts)
        | not (T.null sha),
          not (T.null ct),
          T.all isDigit ct ->
            Just
              MirrorCommit
                { mcSha = sha,
                  mcTime = posixSecondsToUTCTime (fromInteger (read (T.unpack ct))),
                  mcCommitter = cn,
                  mcSubject = T.intercalate "\t" subjectParts
                }
      _ -> Nothing

-- | Mirror metadata commits: committed by the mirror bot with a
-- @YYYY-MM-DD HH:MM:SS UTC@ subject.
isMirrorMetadataCommit :: MirrorCommit -> Bool
isMirrorMetadataCommit c =
  mcCommitter c == "Repository mirror & CI" && subjectIsStamp (mcSubject c)
  where
    subjectIsStamp s =
      T.length s == 23
        && T.all isDigit (T.concat [T.take 4 s, T.take 2 (T.drop 5 s), T.take 2 (T.drop 8 s)])
        && T.all isDigit (T.concat [T.take 2 (T.drop 11 s), T.take 2 (T.drop 14 s), T.take 2 (T.drop 17 s)])
        && T.index s 4 == '-'
        && T.index s 7 == '-'
        && T.index s 10 == ' '
        && T.index s 13 == ':'
        && T.index s 16 == ':'
        && T.drop 19 s == " UTC"

-- | Newest mirror metadata commit at most one hour before the binhost time.
selectTargetCommit :: UTCTime -> [MirrorCommit] -> Maybe MirrorCommit
selectTargetCommit binhostTime commits =
  case filter eligible commits of
    [] -> Nothing
    cs -> Just (foldr1 newer cs)
  where
    cutoff = addUTCTime (negate alignmentMargin) binhostTime
    eligible c = isMirrorMetadataCommit c && mcTime c <= cutoff
    newer a b = if mcTime a >= mcTime b then a else b

-- | Outcome of @git verify-commit --raw@ status lines.
data SigVerdict
  = SigAccepted
  | SigRejected Text
  deriving (Eq, Show)

-- | Accept only a good, valid signature whose primary key fingerprint is
-- 'mirrorKeyFingerprint'. Revoked, expired, bad, or missing keys reject.
parseVerifyCommitRaw :: Text -> SigVerdict
parseVerifyCommitRaw raw
  | Just bad <- find (`elem` rejecting) keywords = SigRejected (describe bad)
  | "GOODSIG" `notElem` keywords = SigRejected "no good signature"
  | otherwise = case validPrimaries of
      [] -> SigRejected "no valid signature"
      prims
        | mirrorKeyFingerprint `elem` prims -> SigAccepted
        | otherwise ->
            SigRejected ("signed by key " <> T.intercalate ", " prims <> ", not the Gentoo repository mirror key")
  where
    statusFields =
      [ T.words rest
      | line <- T.lines raw,
        Just rest <- [T.stripPrefix "[GNUPG:] " line]
      ]
    keywords = mapMaybe listToMaybe statusFields
    validPrimaries =
      [ T.toUpper (last fs)
      | ("VALIDSIG" : fs) <- statusFields,
        not (null fs)
      ]
    rejecting = ["NO_PUBKEY", "BADSIG", "ERRSIG", "REVKEYSIG", "EXPKEYSIG", "EXPSIG", "KEYREVOKED"]
    describe = \case
      "NO_PUBKEY" -> "signing key not in the Gentoo keyring (unsigned by the mirror)"
      "BADSIG" -> "bad signature"
      "ERRSIG" -> "signature could not be checked"
      "REVKEYSIG" -> "signing key is revoked"
      "KEYREVOKED" -> "signing key is revoked"
      "EXPKEYSIG" -> "signing key is expired"
      "EXPSIG" -> "signature is expired"
      other -> other

-- | Primary key fingerprints from @gpg --with-colons@ output: the @fpr@
-- record that follows each @pub@ record.
parseColonPrimaryFingerprints :: Text -> [Text]
parseColonPrimaryFingerprints = go . map (T.splitOn ":") . T.lines
  where
    go (("pub" : _) : rest) = case dropWhile (not . isFpr) rest of
      (fpr : more) | Just f <- fprOf fpr -> T.toUpper f : go more
      more -> go more
    go (_ : rest) = go rest
    go [] = []
    isFpr ("fpr" : _) = True
    isFpr ("pub" : _) = True
    isFpr _ = False
    fprOf fs = case fs of
      ("fpr" : _) | length fs > 9, not (T.null (fs !! 9)) -> Just (fs !! 9)
      _ -> Nothing

------------------------------------------------------------------------
-- Environment

-- | A held tree lock.
data HeldLock = HeldLock
  { -- | Exclusive → shared on the same holder.
    hlDowngrade :: IO (),
    hlRelease :: IO ()
  }

-- | Injectable tree lock.
data TreeLockOps = TreeLockOps
  { tloTryAcquire :: LockMode -> IO (Maybe HeldLock),
    tloAcquire :: LockMode -> IO HeldLock
  }

-- | @flock@ on a lock file.
fileTreeLockOps :: FilePath -> TreeLockOps
fileTreeLockOps lockPath =
  TreeLockOps
    { tloTryAcquire = fmap (fmap held) . (`tryAcquireFileLock` lockPath),
      tloAcquire = fmap held . (`acquireFileLock` lockPath)
    }
  where
    held l = HeldLock {hlDowngrade = downgradeFileLock l, hlRelease = releaseFileLock l}

-- | Everything the resolver and sync touch.
data TreeEnv = TreeEnv
  { tePaths :: GentooTreePaths,
    -- | git and gpg.
    teRun :: CommandRunner,
    -- | WKD key and binhost index.
    teHttp :: HttpLbs,
    teNow :: IO UTCTime,
    teLock :: TreeLockOps,
    teProbe :: DiskSpaceProbe,
    -- | Host @uname -m@ (binhost choice).
    teUname :: String,
    -- | Environment for git calls that need @GNUPGHOME@ or no prompts.
    teBaseEnv :: [(String, String)],
    teMaxAge :: NominalDiffTime,
    -- | Force a sync regardless of age (@--refresh@).
    teRefresh :: Bool,
    teInfo :: Text -> IO (),
    teWarn :: Text -> IO ()
  }

-- | Production environment: timed git/gpg spans, metrics HTTP manager.
productionTreeEnv ::
  Metrics ->
  NominalDiffTime ->
  Bool ->
  (Text -> IO ()) ->
  (Text -> IO ()) ->
  IO TreeEnv
productionTreeEnv m maxAge refresh info warn = do
  paths <- defaultGentooTreePaths
  mgr <- newMetricsManager m
  uname <- machine <$> getSystemID
  baseEnv <- getEnvironment
  pure
    TreeEnv
      { tePaths = paths,
        teRun = timedRunner m productionCommandRunner,
        teHttp = httpLbsEither mgr,
        teNow = getCurrentTime,
        teLock = fileTreeLockOps (gtpLock paths),
        teProbe = productionDiskSpaceProbe,
        teUname = uname,
        teBaseEnv = baseEnv,
        teMaxAge = maxAge,
        teRefresh = refresh,
        teInfo = info,
        teWarn = warn
      }

------------------------------------------------------------------------
-- Resolver

-- | The managed tree as resolved for this run. Holds a shared lock.
data GentooTree = GentooTree
  { gtPath :: FilePath,
    gtCommit :: Text,
    gtLock :: HeldLock
  }

gentooTreePath :: GentooTree -> FilePath
gentooTreePath = gtPath

-- | Full commit id checked out in the tree.
gentooTreeCommit :: GentooTree -> Text
gentooTreeCommit = gtCommit

-- | Drop the shared lock early (tests; production holds it to exit).
releaseGentooTree :: GentooTree -> IO ()
releaseGentooTree = hlRelease . gtLock

-- | Ensure the tree exists, sync it when due or refreshed, and hold it
-- shared. Waits for other runs' syncs and, before syncing, for other runs
-- using the tree.
resolveGentooTree :: TreeEnv -> IO (Either Text GentooTree)
resolveGentooTree env = do
  createDirectoryIfMissing True (gtpRoot paths)
  sh <- acquireNoting SharedLock "waiting for a Gentoo tree sync in another run to finish"
  due <- treeDue env
  eHeld <-
    if not due
      then pure (Right sh)
      else do
        hlRelease sh
        ex <- acquireNoting ExclusiveLock "waiting for another run to release the Gentoo tree"
        stillDue <- if teRefresh env then pure True else treeDue env
        res <-
          (if stillDue then syncGentooTree env else pure (Right ()))
            `onException` hlRelease ex
        case res of
          Left err -> Left err <$ hlRelease ex
          Right () -> Right ex <$ hlDowngrade ex
  case eHeld of
    Left err -> pure (Left err)
    Right held -> do
      eCommit <- revParseHead env (gtpTree paths)
      case eCommit of
        Left err -> Left err <$ hlRelease held
        Right commit ->
          pure (Right GentooTree {gtPath = gtpTree paths, gtCommit = commit, gtLock = held})
  where
    paths = tePaths env
    acquireNoting mode notice = do
      mHeld <- tloTryAcquire (teLock env) mode
      case mHeld of
        Just held -> pure held
        Nothing -> do
          teInfo env notice
          tloAcquire (teLock env) mode

treeExists :: GentooTreePaths -> IO Bool
treeExists paths = doesDirectoryExist (gtpTree paths </> ".git")

-- | Missing tree, refresh, missing or unreadable stamp, or stamp at least
-- max age old.
treeDue :: TreeEnv -> IO Bool
treeDue env = do
  exists <- treeExists (tePaths env)
  if not exists || teRefresh env
    then pure True
    else do
      mStamp <- readStamp (gtpStamp (tePaths env))
      case mStamp of
        Nothing -> pure True
        Just stamp -> do
          now <- teNow env
          pure (diffUTCTime now stamp >= teMaxAge env)

readStamp :: FilePath -> IO (Maybe UTCTime)
readStamp path = do
  present <- doesFileExist path
  if not present
    then pure Nothing
    else iso8601ParseM . T.unpack . T.strip . T.pack <$> readFileStrict path
  where
    readFileStrict p = do
      s <- readFile p
      length s `seq` pure s

writeStamp :: TreeEnv -> IO ()
writeStamp env = do
  now <- teNow env
  let path = gtpStamp (tePaths env)
  writeFile (path <> ".tmp") (iso8601Show now <> "\n")
  renameFile (path <> ".tmp") path

------------------------------------------------------------------------
-- Sync

-- | Where alignment landed.
data Alignment
  = Aligned MirrorCommit
  | AlignStalled
  | AlignFetchFailed Text

-- | Sync under the exclusive lock. 'Left' is a hard failure; soft failures
-- warn, keep an existing tree, and leave the stamp unwritten.
syncGentooTree :: TreeEnv -> IO (Either Text ())
syncGentooTree env = do
  exists <- treeExists (tePaths env)
  eKey <- ensureMirrorKey env
  case eKey of
    Left err
      | exists -> do
          teWarn env ("Gentoo mirror key unavailable (" <> err <> "); continuing with the existing Gentoo tree")
          pure (Right ())
      | otherwise -> pure (Left ("Gentoo mirror key unavailable: " <> err))
    Right () -> do
      result <- if exists then syncExisting env else syncFresh env
      killKeyringDaemons env
      pure result

syncExisting :: TreeEnv -> IO (Either Text ())
syncExisting env = do
  let tree = gtpTree (tePaths env)
  eTime <- fetchBinhostTime env
  case eTime of
    Left err -> do
      teWarn env ("Gentoo binhost index unavailable (" <> err <> "); keeping the Gentoo tree at its current commit")
      pure (Right ())
    Right binhostTime -> do
      aligned <- alignTarget env tree binhostTime
      case aligned of
        AlignFetchFailed err -> do
          teWarn env ("could not fetch the Gentoo mirror (" <> err <> "); continuing with the existing Gentoo tree")
          pure (Right ())
        AlignStalled -> do
          teWarn env (stalledMessage binhostTime <> "; keeping the Gentoo tree at its current commit")
          pure (Right ())
        Aligned target -> do
          eHead <- revParseHead env tree
          case eHead of
            Left err -> pure (Left err)
            Right headSha
              | headSha == mcSha target -> finishSync env tree
              | otherwise -> do
                  eMoved <- verifyAndCheckout env tree (mcSha target)
                  case eMoved of
                    Left err -> pure (Left err)
                    Right () -> do
                      teInfo env ("Gentoo tree at " <> mcSha target <> " (" <> mcSubject target <> ")")
                      finishSync env tree

-- | Clone into a sibling partial directory and move it into place only after
-- the target verifies.
syncFresh :: TreeEnv -> IO (Either Text ())
syncFresh env = do
  let paths = tePaths env
      partial = gtpTree paths <> ".partial"
  eSpace <- checkCloneSpace env
  case eSpace of
    Left err -> pure (Left err)
    Right () -> do
      stale <- doesDirectoryExist partial
      when stale (removeDirectoryRecursive partial)
      teInfo env ("cloning the Gentoo tree into " <> T.pack (gtpTree paths))
      cloned <-
        gitIn env Nothing (Just noPromptEnv) ["clone", "--quiet", "--depth", "1", "--branch", mirrorBranch, "--single-branch", mirrorRemoteUrl, partial]
      case cloned of
        Left err ->
          pure (Left ("failed to clone the Gentoo tree from " <> T.pack mirrorRemoteUrl <> ": " <> err))
        Right _ -> do
          eTarget <- freshTarget partial
          result <- case eTarget of
            Left err -> pure (Left err)
            Right (target, aligned) -> do
              eMoved <- verifyAndCheckout env partial target
              case eMoved of
                Left err -> pure (Left err)
                Right () -> do
                  writeIgnoreFiles partial
                  renameDirectory partial (gtpTree paths)
                  -- A tip fallback leaves the stamp unwritten so the next
                  -- run aligns.
                  when aligned (writeStamp env)
                  pure (Right ())
          case result of
            Left _ -> removeIfPresent partial
            Right () -> pure ()
          pure result
  where
    noPromptEnv = ("GIT_TERMINAL_PROMPT", "0") : teBaseEnv env
    tipWarning why =
      teWarn env (why <> "; using the Gentoo mirror branch tip, so image builds may compile from source")
    freshTarget partial = do
      eTime <- fetchBinhostTime env
      case eTime of
        Left err -> do
          tipWarning ("Gentoo binhost index unavailable (" <> err <> ")")
          tip partial
        Right binhostTime -> do
          aligned <- alignTarget env partial binhostTime
          case aligned of
            Aligned target -> pure (Right (mcSha target, True))
            AlignStalled -> do
              tipWarning (stalledMessage binhostTime)
              tip partial
            AlignFetchFailed err -> do
              tipWarning ("could not deepen the Gentoo mirror clone (" <> err <> ")")
              tip partial
    tip partial = fmap (,False) <$> revParseHead env partial

stalledMessage :: UTCTime -> Text
stalledMessage binhostTime =
  "Gentoo binhost index appears stalled (no mirror metadata commit within seven days before its TIMESTAMP "
    <> T.pack (iso8601Show binhostTime)
    <> ")"

finishSync :: TreeEnv -> FilePath -> IO (Either Text ())
finishSync env tree = do
  writeIgnoreFiles tree
  writeStamp env
  pure (Right ())

checkCloneSpace :: TreeEnv -> IO (Either Text ())
checkCloneSpace env = do
  let root = gtpRoot (tePaths env)
  eFree <- dspFreeBytes (teProbe env) root
  pure $ case eFree of
    Left err -> Left ("cannot measure free space at " <> T.pack root <> ": " <> err)
    Right free
      | free < cloneFreeBytesNeed ->
          Left
            ( "insufficient free space to clone the Gentoo tree:\n  "
                <> T.pack root
                <> "  free: "
                <> formatBytesHuman free
                <> "  need: "
                <> formatBytesHuman cloneFreeBytesNeed
            )
      | otherwise -> Right ()

-- | Fetch progressively deeper history until a target appears.
alignTarget :: TreeEnv -> FilePath -> UTCTime -> IO Alignment
alignTarget env tree binhostTime = go fetchWindows
  where
    go [] = pure AlignStalled
    go (window : rest) = do
      let since = addUTCTime (negate window) binhostTime
      fetched <-
        gitIn env (Just tree) (Just (("GIT_TERMINAL_PROMPT", "0") : teBaseEnv env)) ["fetch", "--quiet", "--shallow-since=" <> iso8601Show since, "origin", mirrorBranch]
      case fetched of
        Left err -> pure (AlignFetchFailed err)
        Right _ -> do
          listed <- gitIn env (Just tree) Nothing ["log", gitLogFormat, "FETCH_HEAD"]
          case listed of
            Left err -> pure (AlignFetchFailed err)
            Right out -> case selectTargetCommit binhostTime (parseGitLogListing out) of
              Just target -> pure (Aligned target)
              Nothing -> go rest

verifyAndCheckout :: TreeEnv -> FilePath -> Text -> IO (Either Text ())
verifyAndCheckout env tree sha = do
  verdict <- verifyCommit env tree sha
  case verdict of
    SigRejected why ->
      pure (Left ("Gentoo tree commit " <> sha <> " failed signature verification: " <> why <> " (expected primary key " <> mirrorKeyFingerprint <> ")"))
    SigAccepted -> do
      checked <- gitIn env (Just tree) Nothing ["checkout", "--quiet", "--detach", T.unpack sha]
      pure (void checked)

verifyCommit :: TreeEnv -> FilePath -> Text -> IO SigVerdict
verifyCommit env tree sha = do
  res <-
    teRun env $
      gitRequest
        (Just tree)
        (Just (("GNUPGHOME", gtpKeyring (tePaths env)) : filter ((/= "GNUPGHOME") . fst) (teBaseEnv env)))
        ["-c", "gpg.program=gpg", "verify-commit", "--raw", T.unpack sha]
  pure (parseVerifyCommitRaw (T.pack (prStderr res <> prStdout res)))

-- | @.dockerignore@ keeps @.git@ out of the build context; git ignores the
-- @.dockerignore@ itself through @.git/info/exclude@.
writeIgnoreFiles :: FilePath -> IO ()
writeIgnoreFiles tree = do
  writeFile (tree </> ".dockerignore") ".git\n.dockerignore\n"
  let infoDir = tree </> ".git" </> "info"
      exclude = infoDir </> "exclude"
  createDirectoryIfMissing True infoDir
  present <- doesFileExist exclude
  existing <-
    if present
      then do
        s <- readFile exclude
        length s `seq` pure s
      else pure ""
  unless (".dockerignore" `elem` lines existing) $
    writeFile exclude (existing <> (if null existing || last existing == '\n' then "" else "\n") <> ".dockerignore\n")

revParseHead :: TreeEnv -> FilePath -> IO (Either Text Text)
revParseHead env tree = do
  r <- gitIn env (Just tree) Nothing ["rev-parse", "HEAD"]
  pure $ case r of
    Left err -> Left ("cannot read the Gentoo tree commit: " <> err)
    Right out -> case T.strip out of
      sha | T.null sha -> Left "cannot read the Gentoo tree commit: empty output"
      sha -> Right sha

------------------------------------------------------------------------
-- Binhost

fetchBinhostTime :: TreeEnv -> IO (Either Text UTCTime)
fetchBinhostTime env =
  case binhostPackagesUrl (teUname env) of
    Nothing -> pure (Left ("no Gentoo binhost mapped for host architecture " <> T.pack (teUname env)))
    Just url -> do
      req0 <- parseRequest url
      let req = req0 {requestHeaders = [("Range", "bytes=0-8191"), ("User-Agent", "mndz-overlay-manager")]}
      eres <- teHttp env req
      pure $ case eres of
        Left err -> Left (T.pack url <> ": " <> err)
        Right resp
          | code <- statusCode (responseStatus resp),
            code /= 200 && code /= 206 ->
              Left (T.pack url <> ": HTTP " <> T.pack (show code))
          | otherwise ->
              case parsePackagesTimestamp (T.pack (L8.unpack (responseBody resp))) of
                Nothing -> Left (T.pack url <> ": no TIMESTAMP in the index header")
                Just t -> Right t

------------------------------------------------------------------------
-- Mirror key

-- | Import the pinned key when the keyring lacks it, then refresh it.
ensureMirrorKey :: TreeEnv -> IO (Either Text ())
ensureMirrorKey env = do
  let keyring = gtpKeyring (tePaths env)
  createDirectoryIfMissing True keyring
  setFileMode keyring 0o700
  have <- keyringHasMirrorKey env
  eHave <-
    if have
      then pure (Right ())
      else importMirrorKey env
  case eHave of
    Left err -> pure (Left err)
    Right () -> do
      refreshed <- gpgIn env ["--keyserver", mirrorKeyServer, "--refresh-keys", T.unpack mirrorKeyFingerprint]
      case refreshed of
        Left err ->
          teWarn env ("Gentoo mirror key refresh from " <> T.pack mirrorKeyServer <> " failed (" <> err <> "); using the cached key")
        Right _ -> pure ()
      pure (Right ())

keyringHasMirrorKey :: TreeEnv -> IO Bool
keyringHasMirrorKey env = do
  r <- gpgIn env ["--with-colons", "--list-keys", T.unpack mirrorKeyFingerprint]
  pure $ case r of
    Right out -> mirrorKeyFingerprint `elem` parseColonPrimaryFingerprints out
    Left _ -> False

-- | WKD first, then the keyserver by fingerprint. A WKD key is imported only
-- when every primary key in it is the pinned one.
importMirrorKey :: TreeEnv -> IO (Either Text ())
importMirrorKey env = tryWkd mirrorKeyWkdUrls []
  where
    keyring = gtpKeyring (tePaths env)
    keyFile = keyring </> "wkd-download.gpg"
    tryWkd [] errs = do
      received <- gpgIn env ["--keyserver", mirrorKeyServer, "--recv-keys", T.unpack mirrorKeyFingerprint]
      have <- keyringHasMirrorKey env
      pure $ case received of
        Right _ | have -> Right ()
        Right _ -> Left (T.intercalate "; " (reverse ("keyserver did not return the pinned key" : errs)))
        Left err -> Left (T.intercalate "; " (reverse (("keyserver: " <> err) : errs)))
    tryWkd (url : rest) errs = do
      eBody <- httpGet url
      case eBody of
        Left err -> tryWkd rest (err : errs)
        Right body -> do
          LBS.writeFile keyFile body
          shown <- gpgIn env ["--with-colons", "--import-options", "show-only", "--import", keyFile]
          case parseColonPrimaryFingerprints <$> shown of
            Right fprs
              | not (null fprs) && all (== mirrorKeyFingerprint) fprs -> do
                  imported <- gpgIn env ["--import", keyFile]
                  removeIfPresentFile keyFile
                  have <- keyringHasMirrorKey env
                  case imported of
                    Right _ | have -> pure (Right ())
                    Right _ -> tryWkd rest ((T.pack url <> ": import did not add the pinned key") : errs)
                    Left err -> tryWkd rest ((T.pack url <> ": " <> err) : errs)
              | otherwise -> do
                  removeIfPresentFile keyFile
                  tryWkd rest ((T.pack url <> ": key fingerprint " <> T.intercalate ", " fprs <> " does not match " <> mirrorKeyFingerprint) : errs)
            Left err -> do
              removeIfPresentFile keyFile
              tryWkd rest ((T.pack url <> ": " <> err) : errs)
    httpGet url = do
      req0 <- parseRequest url
      let req = req0 {requestHeaders = [("User-Agent", "mndz-overlay-manager")]}
      eres <- teHttp env req
      pure $ case eres of
        Left err -> Left (T.pack url <> ": " <> err)
        Right resp
          | statusCode (responseStatus resp) == 200 -> Right (responseBody resp)
          | otherwise -> Left (T.pack url <> ": HTTP " <> T.pack (show (statusCode (responseStatus resp))))

-- | Stop the keyring's dirmngr/agent so no daemon outlives the sync.
killKeyringDaemons :: TreeEnv -> IO ()
killKeyringDaemons env = do
  _ <-
    teRun env $
      ProcessRequest
        { prMode = ExecCmd "gpgconf" ["--homedir", gtpKeyring (tePaths env), "--kill", "all"],
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  pure ()

------------------------------------------------------------------------
-- Process helpers

gitRequest :: Maybe FilePath -> Maybe [(String, String)] -> [String] -> ProcessRequest
gitRequest mDir env args =
  ProcessRequest
    { prMode = ExecCmd "git" (maybe [] (\d -> ["-C", d]) mDir <> args),
      prCwd = Nothing,
      prEnv = env,
      prStdin = "",
      prMeasure = Timed
    }

gitIn :: TreeEnv -> Maybe FilePath -> Maybe [(String, String)] -> [String] -> IO (Either Text Text)
gitIn env mDir childEnv args = do
  res <- teRun env (gitRequest mDir childEnv args)
  pure $ case prExitCode res of
    ExitSuccess -> Right (T.pack (prStdout res))
    ExitFailure _ -> Left (describeFailure ("git " <> unwords (take 1 args)) res)

gpgIn :: TreeEnv -> [String] -> IO (Either Text Text)
gpgIn env args = do
  res <-
    teRun env $
      ProcessRequest
        { prMode =
            ExecCmd "gpg" (["--homedir", gtpKeyring (tePaths env), "--batch", "--no-tty", "--quiet"] <> args),
          prCwd = Nothing,
          prEnv = Nothing,
          prStdin = "",
          prMeasure = Timed
        }
  pure $ case prExitCode res of
    ExitSuccess -> Right (T.pack (prStdout res))
    ExitFailure _ -> Left (describeFailure ("gpg " <> unwords (take 1 args)) res)

describeFailure :: String -> ProcessResult -> Text
describeFailure what res =
  T.pack what
    <> " failed"
    <> case T.strip (T.pack (prStderr res)) of
      "" -> ""
      err -> ": " <> last (T.lines err)

removeIfPresent :: FilePath -> IO ()
removeIfPresent dir = do
  present <- doesDirectoryExist dir
  when present (removeDirectoryRecursive dir)

removeIfPresentFile :: FilePath -> IO ()
removeIfPresentFile path = do
  present <- doesFileExist path
  when present (removeFile path)
