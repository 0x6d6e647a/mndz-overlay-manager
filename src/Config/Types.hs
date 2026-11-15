{-# LANGUAGE OverloadedStrings #-}

module Config.Types
  ( OverlayConfig (..),
    CheckCacheTtl (..),
    defaultCheckCacheTtl,
    parseCheckCacheTtl,
    defaultGentooTreeMaxAge,
    defaultMaterializeBaseCheckInterval,
  )
where

import Control.Monad ((>=>))
import Data.Char (isDigit, toLower)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime)
import GHC.Generics (Generic)
import Toml.Schema (FromValue (..), optKey, optKeyOf, parseTableFromValue, reqKey)

-- | Effective check-cache TTL after config load.
--
-- Omitted key → 'defaultCheckCacheTtl' (5 minutes). Zero duration disables
-- read and write for the run.
data CheckCacheTtl
  = CacheDisabled
  | CacheTtl NominalDiffTime
  deriving (Eq, Show)

-- | Default when @check-cache-ttl@ is omitted: five minutes.
defaultCheckCacheTtl :: CheckCacheTtl
defaultCheckCacheTtl = CacheTtl (5 * 60)

-- | Pure single-unit duration parser for @check-cache-ttl@.
--
-- Accepts a non-negative integer coefficient and one case-insensitive unit
-- among @s@ / @m@ / @h@ / @d@ (for example @30s@, @5m@, @1h@, @2d@). Bare
-- @0@ (no unit) and any zero coefficient disable the cache. Rejects empty
-- strings, bare non-zero integers, multi-unit strings, and unknown units.
parseCheckCacheTtl :: Text -> Either String CheckCacheTtl
parseCheckCacheTtl raw = toTtl <$> parseDurationFor "check-cache-ttl" raw
  where
    toTtl d
      | d == 0 = CacheDisabled
      | otherwise = CacheTtl d

-- | Default when @gentoo-tree-max-age@ is omitted: six hours.
defaultGentooTreeMaxAge :: NominalDiffTime
defaultGentooTreeMaxAge = 6 * 60 * 60

-- | Default when @materialize-base-check-interval@ is omitted: three days.
defaultMaterializeBaseCheckInterval :: NominalDiffTime
defaultMaterializeBaseCheckInterval = 3 * 24 * 60 * 60

-- | Single-unit duration parser shared by every duration key. Same syntax as
-- 'parseCheckCacheTtl'; bare @0@ and zero coefficients parse as zero. Errors
-- name @key@.
parseDurationFor :: String -> Text -> Either String NominalDiffTime
parseDurationFor key raw =
  let t = T.strip raw
   in if T.null t
        then Left $ key <> ": empty duration"
        else
          if t == "0"
            then Right 0
            else parseWithUnit key t

parseWithUnit :: String -> Text -> Either String NominalDiffTime
parseWithUnit key t =
  let s = T.unpack t
      (digits, unitStr) = span isDigit s
   in if null digits
        then Left $ key <> ": invalid duration " <> show (T.unpack t)
        else case unitStr of
          [] ->
            Left $
              key
                <> ": bare integer without unit "
                <> show (T.unpack t)
                <> " (use e.g. 5m, or 0 / 0s for zero)"
          [u] ->
            case toLower u of
              's' -> finish (read digits :: Integer) 1
              'm' -> finish (read digits :: Integer) 60
              'h' -> finish (read digits :: Integer) (60 * 60)
              'd' -> finish (read digits :: Integer) (24 * 60 * 60)
              _ ->
                Left $
                  key
                    <> ": unknown unit in "
                    <> show (T.unpack t)
                    <> " (expected s, m, h, or d)"
          _ ->
            Left $
              key
                <> ": multi-unit or invalid duration "
                <> show (T.unpack t)
                <> " (single unit only, e.g. 1h not 1h30m)"
  where
    finish n mult
      | n < 0 =
          Left $ key <> ": negative duration " <> show (T.unpack t)
      | otherwise =
          Right (fromInteger (n * mult) :: NominalDiffTime)

instance FromValue CheckCacheTtl where
  fromValue v = do
    txt <- fromValue v
    case parseCheckCacheTtl txt of
      Left err -> fail err
      Right ttl -> pure ttl

data OverlayConfig = OverlayConfig
  { overlayPath :: FilePath,
    assetsPath :: Maybe FilePath,
    githubToken :: Maybe Text,
    -- | Optional private Portage DISTDIR for @ebuild … manifest@ (see @--distfiles-path@).
    distfilesPath :: Maybe FilePath,
    -- | Check-cache TTL (default 5m when omitted; zero disables).
    checkCacheTtl :: CheckCacheTtl,
    -- | Private key for an assets git push. Stored as written: no @~@ expansion
    -- and no disk access at parse. Omitted stays 'Nothing'.
    sshIdentity :: Maybe FilePath,
    -- | Managed Gentoo tree max age (default 6h). Zero makes every run sync.
    gentooTreeMaxAge :: NominalDiffTime,
    -- | Materialize stage3 base check interval (default 3d).
    materializeBaseCheckInterval :: NominalDiffTime
  }
  deriving (Eq, Show, Generic)

instance FromValue OverlayConfig where
  fromValue =
    parseTableFromValue $
      OverlayConfig
        <$> reqKey "overlay-path"
        <*> optKey "assets-path"
        <*> optKey "github-token"
        <*> optKey "distfiles-path"
        <*> (fromMaybe defaultCheckCacheTtl <$> optKey "check-cache-ttl")
        <*> optKey "ssh-identity"
        <*> durationKey "gentoo-tree-max-age" defaultGentooTreeMaxAge
        <*> durationKey "materialize-base-check-interval" defaultMaterializeBaseCheckInterval
    where
      durationKey key def =
        fromMaybe def
          <$> optKeyOf key (fromValue >=> either fail pure . parseDurationFor (T.unpack key))
