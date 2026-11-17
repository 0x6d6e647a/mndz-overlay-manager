{-# LANGUAGE OverloadedStrings #-}

-- | Host-arch runtime ceilings for smoke planning, read from local trees only
-- (the managed Gentoo tree, and the overlay for Bun). Nothing here takes an
-- HTTP manager or reads the check cache.
module Smoke.Ceilings
  ( loadHostCeilings,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Smoke.Plan (HostCeilings (..), LaneRuntime (..), runtimeLabelAtom)
import Update.OverlayTree (withNewTreeLock)
import Update.Runtime.Ceilings
  ( ArchCeilings (..),
    RuntimeCeilings (..),
    discoverBunBinCeilings,
    discoverGoCeilingsWith,
    discoverNodejsCeilingsWith,
    discoverRustUnionCeilingsWith,
    discoverSbclCeilingsWith,
  )

-- | Ceilings of @runtimes@ on host arch @arch@. A runtime whose package
-- directory is missing has no ceiling; any other read failure is an error.
loadHostCeilings ::
  -- | Host @KEYWORDS@ token.
  Text ->
  -- | Managed Gentoo tree root.
  FilePath ->
  -- | Overlay root.
  FilePath ->
  [LaneRuntime] ->
  IO (Either Text (Map LaneRuntime HostCeilings))
loadHostCeilings arch gentoo overlay runtimes = do
  results <- traverse one runtimes
  pure (Map.fromList <$> sequence results)
  where
    one rt = do
      res <- discover rt
      pure $ case res of
        Right c -> Right (rt, forHost c)
        Left err
          | missingDir err -> Right (rt, HostCeilings Nothing Nothing)
          | otherwise -> Left ("could not read " <> runtimeLabelAtom rt <> " ceilings: " <> err)
    discover = \case
      RuntimeGo -> discoverGoCeilingsWith gentoo
      RuntimeNodejs -> discoverNodejsCeilingsWith gentoo
      RuntimeBun -> withNewTreeLock (`discoverBunBinCeilings` overlay)
      RuntimeRust -> discoverRustUnionCeilingsWith gentoo
      RuntimeSbcl -> discoverSbclCeilingsWith gentoo
    forHost c = case Map.lookup arch (rcByArch c) of
      Nothing -> HostCeilings Nothing Nothing
      Just ac -> HostCeilings (acPlain ac) (acTilde ac)
    missingDir err =
      "directory not found:" `T.isInfixOf` err || "neither dev-lang/rust nor" `T.isPrefixOf` err
