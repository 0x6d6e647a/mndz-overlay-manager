module Update.Resolve
  ( resolveSource,
    resolveFromText,
  )
where

import Data.Text (Text)
import Data.Text.IO qualified as T
import Update.Hardcoded (lookupHardcoded)
import Update.Infer (PackageContext (..), inferSource)
import Update.Types (PackageKey, UpdateSource)

-- | Resolve update source: hardcoded first, else Level-1 inference from ebuild file.
resolveSource ::
  PackageKey ->
  -- | package name (PN)
  Text ->
  -- | package version (PV)
  Text ->
  -- | ebuild path for inference
  FilePath ->
  IO (Maybe UpdateSource)
resolveSource key pn pv path =
  case lookupHardcoded key of
    Just src -> pure (Just src)
    Nothing -> do
      text <- T.readFile path
      pure (resolveFromText key pn pv text)

-- | Pure resolve given ebuild text (for tests).
resolveFromText ::
  PackageKey ->
  -- | PN
  Text ->
  -- | PV
  Text ->
  -- | ebuild body
  Text ->
  Maybe UpdateSource
resolveFromText key pn pv text =
  case lookupHardcoded key of
    Just src -> Just src
    Nothing ->
      inferSource PackageContext {ctxPN = pn, ctxPV = pv} text
