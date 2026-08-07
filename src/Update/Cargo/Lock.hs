{-# LANGUAGE OverloadedStrings #-}

-- | Focused Cargo.lock reader for registry package name/version/checksum
-- used when packing crates tarballs. Not a full TOML implementation.
module Update.Cargo.Lock
  ( RegistryPackage (..),
    parseRegistryPackages,
    crateFilename,
    crateDirName,
  )
where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Update.TextUtil (stripSurroundingQuotes)

-- | A crates.io (registry) package entry with a package checksum.
data RegistryPackage = RegistryPackage
  { rpName :: Text,
    rpVersion :: Text,
    rpChecksum :: Text
  }
  deriving (Eq, Show)

-- | @{name}-{version}.crate@ basename under the cargo distdir.
crateFilename :: RegistryPackage -> FilePath
crateFilename p = T.unpack (rpName p <> "-" <> rpVersion p <> ".crate")

-- | Top-level directory name inside a .crate and under cargo_home/gentoo/.
crateDirName :: RegistryPackage -> FilePath
crateDirName p = T.unpack (rpName p <> "-" <> rpVersion p)

-- | Parse registry packages that declare a checksum from a Cargo.lock body.
-- Path, git, and workspace-only entries (no registry checksum) are ignored.
parseRegistryPackages :: Text -> Either Text [RegistryPackage]
parseRegistryPackages body =
  Right $ mapMaybe packageFromBlock (packageBlocks body)

-- | Split on @[[package]]@ table headers (Cargo.lock package sections).
packageBlocks :: Text -> [Text]
packageBlocks body =
  case T.splitOn "[[package]]" body of
    [] -> []
    (_pre : rest) -> rest

packageFromBlock :: Text -> Maybe RegistryPackage
packageFromBlock block =
  let fields = parseSimpleFields block
      mName = lookupField "name" fields
      mVersion = lookupField "version" fields
      mChecksum = lookupField "checksum" fields
      mSource = lookupField "source" fields
   in case (mName, mVersion, mChecksum, mSource) of
        (Just name, Just ver, Just sum_, Just src)
          | isRegistrySource src,
            not (T.null name),
            not (T.null ver),
            not (T.null sum_) ->
              Just
                RegistryPackage
                  { rpName = name,
                    rpVersion = ver,
                    rpChecksum = sum_
                  }
        _ -> Nothing

-- | Accept crates.io registry sources (with or without the registry+ prefix form).
isRegistrySource :: Text -> Bool
isRegistrySource src =
  "registry+" `T.isPrefixOf` src
    || src == "registry+https://github.com/rust-lang/crates.io-index"

-- | Collect top-level @key = value@ pairs until a nested table or array-of-tables.
-- Nested multi-line arrays (dependencies = [ ... ]) are skipped as a unit.
parseSimpleFields :: Text -> [(Text, Text)]
parseSimpleFields block = go (T.lines block) []
  where
    go [] acc = reverse acc
    go (ln0 : rest) acc =
      let ln = T.strip ln0
       in if T.null ln || "#" `T.isPrefixOf` ln
            then go rest acc
            else
              if "[" `T.isPrefixOf` ln
                then reverse acc -- nested table / end of package fields
                else case T.breakOn "=" ln of
                  (key0, restEq)
                    | Just ('=', val0) <- T.uncons restEq ->
                        let key = T.strip key0
                            valRaw = T.strip val0
                         in if "[" `T.isPrefixOf` valRaw
                              then go (dropArray rest) acc
                              else
                                let val = stripSurroundingQuotes valRaw
                                 in go rest ((key, val) : acc)
                  _ -> go rest acc

    dropArray = dropWhile (not . arrayEnded)
    arrayEnded ln =
      let s = T.strip ln
       in "]" `T.isSuffixOf` s || s == "]"

lookupField :: Text -> [(Text, Text)] -> Maybe Text
lookupField = lookup
