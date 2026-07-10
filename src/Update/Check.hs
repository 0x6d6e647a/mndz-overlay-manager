{-# LANGUAGE OverloadedStrings #-}
module Update.Check
  ( groupNewest
  , PackageEntry (..)
  , checkOverlay
  , checkPackage
  , productionFetcher
  ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Overlay.Types (Ebuild (..))
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import System.Environment (lookupEnv)
import Update.GitHub (fetchGitHubWith)
import Update.Http (fetchHttpWith)
import Update.Npm (fetchNpmWith)
import Update.Resolve (resolveSource)
import Update.Types
  ( Fetcher
  , PackageKey (..)
  , UpdateReport (..)
  , UpdateSource (..)
  , UpdateStatus (..)
  , mkPackageKey
  , packageKeyText
  )

-- | One package's newest local ebuild used for checks.
data PackageEntry = PackageEntry
  { peKey   :: PackageKey
  , pePN    :: Text
  , peLocal :: EbuildVersion
  , pePath  :: FilePath
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
              { peKey = key
              , pePN = ebuildPackage e
              , peLocal = local
              , pePath = ebuildPath e
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

-- | Run update checks for all packages with the given fetcher.
checkOverlay :: Fetcher -> [Ebuild] -> IO [UpdateReport]
checkOverlay fetch ebuilds = do
  let entries = sortOn (packageKeyText . peKey) (groupNewest ebuilds)
  mapM (checkPackage fetch) entries

-- | Resolve, fetch, and compare one package.
checkPackage :: Fetcher -> PackageEntry -> IO UpdateReport
checkPackage fetch entry = do
  let key = peKey entry
      local = peLocal entry
      pn = pePN entry
      pvText = renderPVNoRev local
  mSrc <- resolveSource key pn pvText (pePath entry)
  case mSrc of
    Nothing ->
      pure UpdateReport { reportKey = key, reportStatus = Unconfigured }
    Just src -> do
      result <- fetch src
      pure $ case result of
        Left err ->
          UpdateReport { reportKey = key, reportStatus = FetchError err }
        Right remote ->
          UpdateReport
            { reportKey = key
            , reportStatus = statusFromCompare local remote
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
productionFetcher = do
  mgr <- newManager tlsManagerSettings
  token <- lookupEnv "GITHUB_TOKEN"
  pure $ \src -> case src of
    Http {}   -> fetchHttpWith mgr src
    GitHub {} -> fetchGitHubWith mgr token src
    Npm {}    -> fetchNpmWith mgr src
