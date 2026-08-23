{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Pure Portage atom selection for materialize-image toolchains.
module Update.Materialize.Resolve
  ( ResolvedToolchain (..),
    ToolchainKind (..),
    ResolvedInstall (..),
    GentooToolchainMetas (..),
    resolveToolchain,
    resolveNeededInstalls,
  )
where

import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion, comparePV, parseEbuildVersion)
import Update.Materialize.Floors (NeededFloors (..))
import Update.Runtime.Ceilings
  ( Arch,
    RuntimeEbuildMeta (..),
    keywordsHasBare,
    keywordsHasTildeOrBare,
  )

-- | One Portage atom chosen for a toolchain floor.
data ResolvedToolchain = ResolvedToolchain
  { rtAtom :: Text,
    -- | emerge argument (@>=cat/pkg-VER@, unversioned, or overlay @::repo@).
    rtEmergeSpec :: Text,
    -- | @package.accept_keywords@ line when the floor is not plain-visible.
    rtAcceptLine :: Maybe Text
  }
  deriving (Eq, Show)

-- | Toolchain RUN kind; recipe extras (pycargoebuild, Quicklisp, overlay bind)
-- are decided from this, not from the atom string.
data ToolchainKind
  = TkRust
  | TkSbcl
  | TkNode
  | TkGo
  | TkBun
  deriving (Eq, Ord, Show)

data ResolvedInstall = ResolvedInstall
  { riKind :: ToolchainKind,
    riResolved :: ResolvedToolchain
  }
  deriving (Eq, Show)

-- | Parsed gentoo ebuild metadata for each toolchain package directory.
-- Missing @-bin@ dirs are empty lists, not a load failure.
data GentooToolchainMetas = GentooToolchainMetas
  { gtmGo :: [RuntimeEbuildMeta],
    gtmGoBin :: [RuntimeEbuildMeta],
    gtmNode :: [RuntimeEbuildMeta],
    gtmNodeBin :: [RuntimeEbuildMeta],
    gtmRust :: [RuntimeEbuildMeta],
    gtmRustBin :: [RuntimeEbuildMeta],
    gtmSbcl :: [RuntimeEbuildMeta],
    gtmSbclBin :: [RuntimeEbuildMeta]
  }
  deriving (Eq, Show)

gentooRepoName :: Text
gentooRepoName = "gentoo"

mndzRepoName :: Text
mndzRepoName = "mndz"

rustBinAtom :: Text
rustBinAtom = "dev-lang/rust-bin"

rustAtom :: Text
rustAtom = "dev-lang/rust"

sbclBinAtom :: Text
sbclBinAtom = "dev-lisp/sbcl-bin"

sbclAtom :: Text
sbclAtom = "dev-lisp/sbcl"

nodejsBinAtom :: Text
nodejsBinAtom = "net-libs/nodejs-bin"

nodejsAtom :: Text
nodejsAtom = "net-libs/nodejs"

goBinAtom :: Text
goBinAtom = "dev-lang/go-bin"

goAtom :: Text
goAtom = "dev-lang/go"

bunBinAtom :: Text
bunBinAtom = "dev-lang/bun-bin"

-- | Prefer @-bin@ when a host-arch ebuild (plain or tilde) meets the floor;
-- otherwise the source package; otherwise a miss. Prefer @-bin@ even when that
-- forces @~arch@ and source would be plain-visible.
resolveToolchain ::
  -- | Host KEYWORDS token (@amd64@, @ppc64@, …).
  Arch ->
  -- | Floor token (@\"0\"@ / empty = any version).
  Text ->
  -- | @-bin@ cat/pkg.
  Text ->
  [RuntimeEbuildMeta] ->
  -- | Source cat/pkg.
  Text ->
  [RuntimeEbuildMeta] ->
  -- | Repo for accept_keywords and overlay emerge (@gentoo@ / @mndz@).
  Text ->
  Either Text ResolvedToolchain
resolveToolchain arch floorTok binAtom binMetas srcAtom srcMetas repo
  | hasHostArchMeeting floorTok arch binMetas =
      Right (chosenAtom arch floorTok binAtom binMetas repo)
  | hasHostArchMeeting floorTok arch srcMetas =
      Right (chosenAtom arch floorTok srcAtom srcMetas repo)
  | otherwise =
      Left
        ( "no host-arch ebuild for "
            <> binAtom
            <> " or "
            <> srcAtom
            <> " meets floor "
            <> displayFloor floorTok
        )

-- | Resolve every toolchain this image must install (needed floors only).
resolveNeededInstalls ::
  Arch ->
  NeededFloors ->
  GentooToolchainMetas ->
  -- | Overlay @dev-lang/bun-bin@ metas (empty if the dir is missing).
  [RuntimeEbuildMeta] ->
  Either Text [ResolvedInstall]
resolveNeededInstalls arch floors metas bunMetas = do
  rust <-
    forFloor (nfRust floors) $ \fl ->
      ResolvedInstall TkRust
        <$> resolveToolchain
          arch
          fl
          rustBinAtom
          (gtmRustBin metas)
          rustAtom
          (gtmRust metas)
          gentooRepoName
  sbcl <-
    forFloor (nfSbcl floors) $ \fl ->
      ResolvedInstall TkSbcl
        <$> resolveToolchain
          arch
          fl
          sbclBinAtom
          (gtmSbclBin metas)
          sbclAtom
          (gtmSbcl metas)
          gentooRepoName
  node <-
    forFloor (nfNode floors) $ \fl ->
      ResolvedInstall TkNode
        <$> resolveToolchain
          arch
          fl
          nodejsBinAtom
          (gtmNodeBin metas)
          nodejsAtom
          (gtmNode metas)
          gentooRepoName
  go <-
    forFloor (nfGo floors) $ \fl ->
      ResolvedInstall TkGo
        <$> resolveToolchain
          arch
          fl
          goBinAtom
          (gtmGoBin metas)
          goAtom
          (gtmGo metas)
          gentooRepoName
  bun <-
    forFloor (nfBun floors) $ \fl ->
      ResolvedInstall TkBun
        <$> resolveToolchain
          arch
          fl
          bunBinAtom
          bunMetas
          bunBinAtom
          []
          mndzRepoName
  pure (catMaybes [rust, sbcl, node, go, bun])

forFloor ::
  Maybe Text ->
  (Text -> Either Text ResolvedInstall) ->
  Either Text (Maybe ResolvedInstall)
forFloor Nothing _ = Right Nothing
forFloor (Just fl) f = Just <$> f fl

hasHostArchMeeting :: Text -> Arch -> [RuntimeEbuildMeta] -> Bool
hasHostArchMeeting floorTok arch =
  any $ \m ->
    keywordsHasTildeOrBare arch (remKeywords m)
      && pvMeetsFloor floorTok (remPV m)

chosenAtom ::
  Arch ->
  Text ->
  Text ->
  [RuntimeEbuildMeta] ->
  Text ->
  ResolvedToolchain
chosenAtom arch floorTok atom metas repo =
  ResolvedToolchain
    { rtAtom = atom,
      rtEmergeSpec = emergeSpec repo atom floorTok,
      rtAcceptLine =
        if plainVisible
          then Nothing
          else Just (acceptLine repo atom floorTok arch)
    }
  where
    plainVisible =
      any
        ( \m ->
            keywordsHasBare arch (remKeywords m)
              && pvMeetsFloor floorTok (remPV m)
        )
        metas

emergeSpec :: Text -> Text -> Text -> Text
emergeSpec repo atom floorTok
  | isAnyVersionFloor floorTok = qualifyRepo repo atom
  | otherwise = ">=" <> qualifyRepo repo (atom <> "-" <> floorTok)

acceptLine :: Text -> Text -> Text -> Arch -> Text
acceptLine repo atom floorTok arch
  | isAnyVersionFloor floorTok =
      atom <> "::" <> repo <> " ~" <> arch
  | otherwise =
      ">=" <> atom <> "-" <> floorTok <> "::" <> repo <> " ~" <> arch

-- | Overlay atoms carry @::repo@; gentoo tree atoms do not on the emerge spec.
qualifyRepo :: Text -> Text -> Text
qualifyRepo repo atom
  | repo == gentooRepoName = atom
  | otherwise = atom <> "::" <> repo

isAnyVersionFloor :: Text -> Bool
isAnyVersionFloor t = T.null t || t == "0"

displayFloor :: Text -> Text
displayFloor t
  | T.null t = "0"
  | otherwise = t

pvMeetsFloor :: Text -> EbuildVersion -> Bool
pvMeetsFloor floorTok pv
  | isAnyVersionFloor floorTok = True
  | otherwise =
      case comparePV pv (parseEbuildVersion floorTok) of
        Just LT -> False
        Just _ -> True
        Nothing -> False
