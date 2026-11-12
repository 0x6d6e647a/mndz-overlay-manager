{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Build identity recorded in run metrics headers.
--
-- CPP is confined to this module: @scripts/with-flavor@ passes
-- @-DMNDZ_FLAVOR_<NAME>@, and builds outside it record flavor @unknown@.
module Build.Info
  ( BuildInfo (..),
    buildInfo,
    flavorFromDefine,
    sha256File,
    exeSha256,
  )
where

import Build.GitRev (gitRevisionQ)
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Paths_mndz_overlay_manager (version)
import System.Info (fullCompilerVersion)

-- | Identity of the running binary, fixed at compile time.
data BuildInfo = BuildInfo
  { biVersion :: Text,
    -- | Full commit hash, or @unknown@ without git at build time.
    biGitRev :: Text,
    -- | Tracked files differed from 'biGitRev' when the splice ran.
    biGitDirty :: Bool,
    -- | @dev@, @release@, @coverage-dev@, @coverage-release@, or @unknown@.
    biFlavor :: Text,
    biGhcVersion :: Text
  }
  deriving (Eq, Show)

buildInfo :: BuildInfo
buildInfo =
  BuildInfo
    { biVersion = T.pack (showVersion version),
      biGitRev = T.pack rev,
      biGitDirty = dirty,
      biFlavor = flavorFromDefine flavorDefine,
      biGhcVersion = T.pack (showVersion fullCompilerVersion)
    }
  where
    (rev, dirty) = gitRevision

gitRevision :: (String, Bool)
gitRevision = $(gitRevisionQ)

-- | Suffix of the @MNDZ_FLAVOR_*@ define this module was compiled with.
flavorDefine :: String
#if defined(MNDZ_FLAVOR_DEV)
flavorDefine = "DEV"
#elif defined(MNDZ_FLAVOR_RELEASE)
flavorDefine = "RELEASE"
#elif defined(MNDZ_FLAVOR_COVERAGE_DEV)
flavorDefine = "COVERAGE_DEV"
#elif defined(MNDZ_FLAVOR_COVERAGE_RELEASE)
flavorDefine = "COVERAGE_RELEASE"
#else
flavorDefine = ""
#endif

-- | Map a @MNDZ_FLAVOR_*@ suffix to the recorded flavor name.
flavorFromDefine :: String -> Text
flavorFromDefine = \case
  "DEV" -> "dev"
  "RELEASE" -> "release"
  "COVERAGE_DEV" -> "coverage-dev"
  "COVERAGE_RELEASE" -> "coverage-release"
  _ -> "unknown"

-- | Lowercase hex SHA-256 of a file's contents.
sha256File :: FilePath -> IO Text
sha256File path = do
  bytes <- BL.readFile path
  let digest = hashlazy bytes :: Digest SHA256
  pure (T.pack (show digest))

-- | SHA-256 of the running executable (@/proc/self/exe@), or @unknown@.
exeSha256 :: IO Text
exeSha256 = do
  r <- try @IOException (sha256File "/proc/self/exe")
  pure (fromRight "unknown" r)
