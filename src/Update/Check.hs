{-# LANGUAGE OverloadedStrings #-}

module Update.Check
  ( groupNewest,
    PackageEntry (..),
    checkOverlay,
    checkOverlayWith,
    checkPackage,
    productionFetcher,
    productionFetcherWithToken,
    statusFromCompare,
    renderPVNoRev,
  )
where

import CLI.Jobs (mapConcurrentlyN)
import CLI.Progress (MultiHandle (..))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import Update.GitHub (fetchGitHubWith)
import Update.Http (fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.Resolve (resolveSource)
import Update.Types
  ( Fetcher,
    PackageKey (..),
    UpdateReport (..),
    UpdateSource (..),
    UpdateStatus (..),
    mkPackageKey,
    packageKeyText,
  )

-- | One package's newest local ebuild used for checks.
data PackageEntry = PackageEntry
  { peKey :: PackageKey,
    pePN :: Text,
    peLocal :: EbuildVersion,
    pePath :: FilePath
  }
  deriving (Eq, Show)

-- | Group ebuilds by category/package; keep newest PV (revision as tiebreak).
groupNewest :: [Ebuild] -> [PackageEntry]
groupNewest ebuilds =
  Map.elems $ foldl' insert Map.empty ebuilds
  where
    insert acc e =
      let key = mkPackageKey (ebuildCategory e) (ebuildPackage e)
          local = parseEbuildVersion (ebuildVersion e)
          entry =
            PackageEntry
              { peKey = key,
                pePN = ebuildPackage e,
                peLocal = local,
                pePath = ebuildPath e
              }
       in Map.insertWith preferNewer key entry acc

    preferNewer new old =
      case compareForNewest (peLocal new) (peLocal old) of
        GT -> new
        LT -> old
        EQ ->
          case (peLocal new, peLocal old) of
            (Numeric _ (Just r1), Numeric _ (Just r2))
              | r1 > r2 -> new
              | otherwise -> old
            (Numeric _ (Just _), Numeric _ Nothing) -> new
            _ -> old

compareForNewest :: EbuildVersion -> EbuildVersion -> Ordering
compareForNewest a b =
  case comparePV a b of
    Just o -> o
    Nothing -> compare (show a) (show b)

-- | Run update checks concurrently with a jobs limit (no progress UI).
checkOverlay :: Int -> Fetcher -> [Ebuild] -> IO [UpdateReport]
checkOverlay jobs = checkOverlayWith jobs noopMulti
  where
    noopMulti =
      MultiHandle
        { mhStart = \_ -> pure (),
          mhStatus = \_ _ -> pure (),
          mhSuccess = \_ -> pure (),
          mhFail = \_ _ -> pure ()
        }

-- | Concurrent checks with multi-progress callbacks.
checkOverlayWith ::
  Int ->
  MultiHandle ->
  Fetcher ->
  [Ebuild] ->
  IO [UpdateReport]
checkOverlayWith jobs mh fetch ebuilds = do
  let entries = sortOn (packageKeyText . peKey) (groupNewest ebuilds)
  mapConcurrentlyN jobs (checkOne mh fetch) entries

checkOne :: MultiHandle -> Fetcher -> PackageEntry -> IO UpdateReport
checkOne mh fetch entry = do
  let key = peKey entry
  mhStart mh key
  mhStatus mh key "fetching"
  report <- checkPackage fetch entry
  case reportStatus report of
    Outdated _ _ -> mhSuccess mh key
    Ok _ -> mhSuccess mh key
    Ahead _ _ -> mhFail mh key "ahead of upstream"
    Unconfigured -> mhFail mh key "unconfigured"
    FetchError err -> mhFail mh key (shortReason err)
  pure report

shortReason :: Text -> Text
shortReason t =
  let oneLine = T.unwords (T.words t)
   in if T.length oneLine > 60
        then T.take 57 oneLine <> "..."
        else oneLine

-- | Resolve, fetch, and compare one package.
checkPackage :: Fetcher -> PackageEntry -> IO UpdateReport
checkPackage fetch entry = do
  let key = peKey entry
      local = peLocal entry
  case resolveSource key of
    Nothing ->
      pure UpdateReport {reportKey = key, reportStatus = Unconfigured}
    Just src -> do
      result <- fetch src
      pure $ case result of
        Left err ->
          UpdateReport {reportKey = key, reportStatus = FetchError err}
        Right remote ->
          UpdateReport
            { reportKey = key,
              reportStatus = statusFromCompare local remote
            }

statusFromCompare :: EbuildVersion -> EbuildVersion -> UpdateStatus
statusFromCompare local remote =
  case comparePV local remote of
    Just LT -> Outdated local remote
    Just EQ -> Ok local
    Just GT -> Ahead local remote
    Nothing ->
      FetchError
        ( "incomparable versions: local="
            <> T.pack (show local)
            <> " remote="
            <> T.pack (show remote)
        )

renderPVNoRev :: EbuildVersion -> Text
renderPVNoRev (Raw t) = t
renderPVNoRev (Numeric comps _) =
  T.intercalate "." (map (T.pack . show) comps)

-- | Production fetcher dispatching to Http / GitHub / npm clients.
productionFetcher :: IO Fetcher
productionFetcher = productionFetcherWithToken Nothing

-- | Like 'productionFetcher' with an optional resolved GitHub token.
productionFetcherWithToken :: Maybe T.Text -> IO Fetcher
productionFetcherWithToken mToken = do
  mgr <- newManager tlsManagerSettings
  pure $ \src -> case src of
    Http {} -> fetchHttpWith mgr src
    GitHub {} -> fetchGitHubWith mgr mToken src
    Npm {} -> fetchNpmWith mgr src
