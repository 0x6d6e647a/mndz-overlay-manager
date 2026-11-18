{-# LANGUAGE OverloadedStrings #-}

-- | The @update@ smoke gate scheduler: dependency waits between units,
-- cycle detection, and the smoke lane that runs one unit's gated runs at a
-- time in arrival order. A unit releases its package job slot while it is
-- at its gate (waiting or running) and takes it back afterwards.
module Update.Gate
  ( -- * Requests and results
    GateRequest (..),
    GateResult (..),
    GateFailure (..),

    -- * Handle
    GateHandle (..),
    passThroughGate,

    -- * Scheduler
    GateWait (..),
    GateConfig (..),
    newGateScheduler,

    -- * Statuses
    waitingForSmokeLane,
    waitingForDependency,

    -- * Dependencies
    md5CacheDependencies,
    md5CacheEntryPath,
  )
where

import Control.Concurrent.MVar (newMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    retry,
    writeTVar,
  )
import Control.Exception (bracket, bracket_)
import Control.Monad (join)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Discovery (parseEbuildFileName)
import System.FilePath ((</>))
import Update.Held (GateRunRecord (..), HeldReason (..))
import Update.Types (PackageKey, mkPackageKey, packageKeyText, splitPackageKey)

-- | One unit at its gate.
data GateRequest = GateRequest
  { grKey :: PackageKey,
    -- | Version of the new ebuild (@PVR@, as in its file name).
    grPv :: Text,
    -- | Built, unpublished distfiles to stage (absolute). Empty for GitMv
    -- and reuse-path units.
    grStaged :: [FilePath],
    -- | Assets repository release download prefix (the shim's prefix).
    grAssetsPrefix :: Text,
    -- | Show a status on the unit's package row.
    grStatus :: Text -> IO ()
  }

data GateFailure = GateFailure
  { -- | 'HeldGate' or 'HeldCycle'.
    gfReason :: HeldReason,
    -- | One-line operator message.
    gfMessage :: Text,
    gfRuns :: [GateRunRecord],
    -- | Gated runs' log directories, for the held entry.
    gfLogDirs :: [FilePath]
  }
  deriving (Eq, Show)

data GateResult
  = -- | Every run passed; the runs and their log directories.
    GatePassed [GateRunRecord] [FilePath]
  | GateFailed GateFailure
  deriving (Eq, Show)

data GateHandle = GateHandle
  { -- | Wait for dependencies and the lane, then run the unit's gate.
    ghGate :: GateRequest -> IO GateResult,
    -- | A selected package reached its outcome (committed, failed, held, or
    -- skipped); units waiting on it may gate.
    ghTerminal :: PackageKey -> IO (),
    -- | Release and re-acquire the caller's package job slot.
    ghWireSlots :: IO () -> IO () -> IO ()
  }

-- | A gate that passes at once (tests that do not exercise gating).
passThroughGate :: GateHandle
passThroughGate =
  GateHandle
    { ghGate = \_ -> pure (GatePassed [] []),
      ghTerminal = \_ -> pure (),
      ghWireSlots = \_ _ -> pure ()
    }

-- | What a unit at its gate is waiting for.
data GateWait
  = WaitDependency PackageKey
  | WaitLane
  deriving (Eq, Show)

data GateConfig = GateConfig
  { -- | Packages that still have work in this run. Every other package is
    -- terminal from the start.
    gcSelected :: Set PackageKey,
    -- | Overlay packages the unit's new ebuild depends on.
    gcDependencies :: GateRequest -> IO [PackageKey],
    -- | Wait until the smoke session is ready; 'Left' names what is missing.
    gcReady :: IO (Either Text ()),
    -- | The unit's gated runs, holding the smoke lane.
    gcRun :: GateRequest -> IO GateResult,
    -- | Around each wait (status and @slot.wait@ span).
    gcAroundWait :: forall a. PackageKey -> GateWait -> IO a -> IO a
  }

data SchedulerState = SchedulerState
  { ssTerminal :: TVar (Set PackageKey),
    -- | Package → selected packages its unit is waiting on.
    ssWaitFor :: TVar (Map PackageKey (Set PackageKey)),
    -- | Package → the cycle it was found in.
    ssCycles :: TVar (Map PackageKey [PackageKey])
  }

newGateScheduler :: GateConfig -> IO GateHandle
newGateScheduler cfg = do
  st <- SchedulerState <$> newTVarIO Set.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty
  lane <- newMVar ()
  release <- newIORef (pure ())
  acquire <- newIORef (pure ())
  let outsideSlot :: IO a -> IO a
      outsideSlot = bracket_ (join' release) (join' acquire)
      gate req = outsideSlot $ do
        deps <- gcDependencies cfg req
        waited <- awaitDependencies cfg st req deps
        case waited of
          Just failure -> pure (GateFailed failure)
          Nothing -> do
            ready <- gcReady cfg
            case ready of
              Left err ->
                pure (GateFailed (GateFailure HeldGate ("smoke gate prerequisites are not ready: " <> err) [] []))
              Right () ->
                bracket
                  (grStatus req waitingForSmokeLane >> gcAroundWait cfg (grKey req) WaitLane (takeMVar lane))
                  (putMVar lane)
                  (\() -> gcRun cfg req)
  pure
    GateHandle
      { ghGate = gate,
        ghTerminal = atomically . modifyTVar' (ssTerminal st) . Set.insert,
        ghWireSlots = \r a -> writeIORef release r >> writeIORef acquire a
      }
  where
    join' :: IORef (IO ()) -> IO ()
    join' = join . readIORef

-- | Add the unit's wait edges (failing every unit on a cycle the new edges
-- close), then wait until each dependency is terminal. 'Just' is a cycle
-- failure.
awaitDependencies :: GateConfig -> SchedulerState -> GateRequest -> [PackageKey] -> IO (Maybe GateFailure)
awaitDependencies cfg st req deps = do
  let key = grKey req
      selectedDeps = Set.fromList [d | d <- nub deps, d /= key, d `Set.member` gcSelected cfg]
  pending <- atomically $ do
    terminal <- readTVar (ssTerminal st)
    let open = selectedDeps `Set.difference` terminal
    if Set.null open
      then pure Nothing
      else do
        graph <- Map.insert key open <$> readTVar (ssWaitFor st)
        case findCycle graph key of
          Just cycle' -> do
            modifyTVar' (ssCycles st) (\m -> foldr (`Map.insert` cycle') m cycle')
            writeTVar (ssWaitFor st) (Map.delete key graph)
            pure (Just (Left cycle'))
          Nothing -> do
            writeTVar (ssWaitFor st) graph
            pure (Just (Right open))
  case pending of
    Nothing -> pure Nothing
    Just (Left cycle') -> pure (Just (cycleFailure cycle'))
    Just (Right open) -> do
      let waitOn = Set.toAscList open
      grStatus req (waitingForDependency (head' waitOn))
      outcome <-
        gcAroundWait cfg key (WaitDependency (head' waitOn)) $
          atomically $ do
            cycles <- readTVar (ssCycles st)
            case Map.lookup key cycles of
              Just cycle' -> do
                modifyTVar' (ssWaitFor st) (Map.delete key)
                pure (Just cycle')
              Nothing -> do
                terminal <- readTVar (ssTerminal st)
                if open `Set.isSubsetOf` terminal
                  then do
                    modifyTVar' (ssWaitFor st) (Map.delete key)
                    pure Nothing
                  else retry'
      pure (cycleFailure <$> outcome)
  where
    head' = \case
      k : _ -> k
      [] -> grKey req
    retry' :: STM a
    retry' = retry

cycleFailure :: [PackageKey] -> GateFailure
cycleFailure cycle' =
  GateFailure
    { gfReason = HeldCycle,
      gfMessage = "smoke gate dependency cycle: " <> T.intercalate " -> " (map packageKeyText (cycle' <> take 1 cycle')),
      gfRuns = [],
      gfLogDirs = []
    }

waitingForSmokeLane :: Text
waitingForSmokeLane = "waiting for the smoke lane"

waitingForDependency :: PackageKey -> Text
waitingForDependency dep = "waiting at gate for " <> packageKeyText dep

-- | A path from @start@ back to itself, as the packages on it in order.
findCycle :: Map PackageKey (Set PackageKey) -> PackageKey -> Maybe [PackageKey]
findCycle graph start = go Set.empty [start] start
  where
    go seen path node =
      firstJust
        [ if next == start then Just (reverse path) else if next `Set.member` seen then Nothing else go (Set.insert next seen) (next : path) next
        | next <- Set.toAscList (Map.findWithDefault Set.empty node graph)
        ]
    firstJust = \case
      [] -> Nothing
      Just x : _ -> Just x
      Nothing : rest -> firstJust rest

------------------------------------------------------------------------
-- Dependencies

-- | @metadata/md5-cache/\<category\>/\<pn\>-\<pvr\>@ under the overlay.
md5CacheEntryPath :: FilePath -> PackageKey -> Text -> Maybe FilePath
md5CacheEntryPath overlay key pvr = do
  (cat, pn) <- splitPackageKey key
  pure (overlay </> "metadata" </> "md5-cache" </> T.unpack cat </> T.unpack (pn <> "-" <> pvr))

-- | Packages named by the @DEPEND@, @BDEPEND@, @RDEPEND@, @IDEPEND@, and
-- @PDEPEND@ lines of an md5-cache entry. Blockers are not dependencies.
md5CacheDependencies :: Text -> [PackageKey]
md5CacheDependencies body =
  nub
    [ k
    | line <- T.lines body,
      let (name, rest) = T.breakOn "=" line,
      name `elem` ["DEPEND", "BDEPEND", "RDEPEND", "IDEPEND", "PDEPEND"],
      tok <- T.words (T.drop 1 rest),
      Just k <- [atomPackage tok]
    ]

atomPackage :: Text -> Maybe PackageKey
atomPackage tok
  | "!" `T.isPrefixOf` tok = Nothing
  | otherwise =
      let (ops, rest) = T.span (`elem` ("<>=~" :: String)) tok
          bare = T.takeWhile (\c -> c /= ':' && c /= '[') rest
          noStar = T.dropWhileEnd (== '*') bare
       in case T.breakOn "/" noStar of
            (cat, slashPkg)
              | not (T.null cat),
                Just ('/', pkgVer) <- T.uncons slashPkg,
                not (T.null pkgVer),
                T.all (\c -> c /= '(' && c /= ')' && c /= '|' && c /= '?') cat ->
                  let pkg
                        | T.null ops = pkgVer
                        | otherwise = maybe pkgVer (T.pack . fst) (parseEbuildFileName (T.unpack pkgVer <> ".ebuild"))
                   in Just (mkPackageKey cat pkg)
            _ -> Nothing
