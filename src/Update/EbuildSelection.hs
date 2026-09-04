{-# LANGUAGE OverloadedStrings #-}

-- | Canonical non-live ebuild inventory selection (highest PV, then highest
-- numeric Gentoo revision). Fails closed when relevant candidates cannot be
-- ordered.
module Update.EbuildSelection
  ( InventoryFile (..),
    inventoryFromEbuild,
    selectCanonicalSamePV,
    selectHighestNonLive,
    compareInventory,
  )
where

import Control.Monad (foldM)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Types (Ebuild (..))
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    renderPV,
    samePV,
  )

-- | One on-disk ebuild considered for inventory selection.
data InventoryFile = InventoryFile
  { invVersion :: EbuildVersion,
    invPath :: FilePath
  }
  deriving (Eq, Show)

inventoryFromEbuild :: Ebuild -> InventoryFile
inventoryFromEbuild e =
  InventoryFile
    { invVersion = parseEbuildVersion (ebuildVersion e),
      invPath = ebuildPath e
    }

-- | Live ebuilds (9999) never participate as donors or templates.
isLiveInventory :: EbuildVersion -> Bool
isLiveInventory (Numeric [9999] _) = True
isLiveInventory (Raw t) = T.strip t == "9999"
isLiveInventory _ = False

-- | Highest numeric Gentoo revision among non-live same-PV files.
-- Bare PV is revision zero. Unrelated PVs are ignored. Incomparable
-- same-PV candidates fail closed.
selectCanonicalSamePV ::
  EbuildVersion ->
  [InventoryFile] ->
  Either Text (Maybe InventoryFile)
selectCanonicalSamePV target files =
  selectBest
    [ f
    | f <- files,
      not (isLiveInventory (invVersion f)),
      samePV (invVersion f) target
    ]

-- | Highest non-live local ebuild (PV then revision). Used as the cross-PV
-- template fallback from the plan's initial inventory.
selectHighestNonLive :: [InventoryFile] -> Either Text (Maybe InventoryFile)
selectHighestNonLive files =
  selectBest [f | f <- files, not (isLiveInventory (invVersion f))]

selectBest :: [InventoryFile] -> Either Text (Maybe InventoryFile)
selectBest [] = Right Nothing
selectBest (x : xs) = Just <$> foldM step x xs
  where
    step acc y =
      case compareInventory (invVersion acc) (invVersion y) of
        Just LT -> Right y
        Just _ -> Right acc
        Nothing ->
          Left
            ( "incomparable ebuild versions in package inventory: "
                <> renderPV (invVersion acc)
                <> " vs "
                <> renderPV (invVersion y)
            )

-- | Compare inventory versions: numeric PV first, then Gentoo revision
-- (bare = 0). 'Nothing' when incomparable.
compareInventory :: EbuildVersion -> EbuildVersion -> Maybe Ordering
compareInventory a b =
  case comparePV a b of
    Just EQ -> Just (compareRevision a b)
    Just o -> Just o
    Nothing -> Nothing

compareRevision :: EbuildVersion -> EbuildVersion -> Ordering
compareRevision (Numeric _ ra) (Numeric _ rb) = compare (revRank ra) (revRank rb)
compareRevision a b = compare (renderPV a) (renderPV b)

revRank :: Maybe Word -> Word
revRank Nothing = 0
revRank (Just r) = r
