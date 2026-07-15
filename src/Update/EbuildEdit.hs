{-# LANGUAGE OverloadedStrings #-}

module Update.EbuildEdit
  ( assetsSrcUriParameterized,
    parameterizeAssetsSrcUri,
    nextRevisionVersion,
    ebuildFileNameWithRev,
    parseManifestVendorSHA512,
  )
where

import Data.Char (isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), renderPV)
import System.FilePath (takeFileName)

assetsMarker :: Text
assetsMarker = "mndz-overlay-assets/releases/download/"

-- | True when every mndz-overlay-assets release download URL already uses @${PV}@.
assetsSrcUriParameterized :: Text -> Bool
assetsSrcUriParameterized content =
  case T.splitOn assetsMarker content of
    [] -> True
    [_] -> True
    _ : segs -> all segmentParameterized segs
  where
    segmentParameterized seg =
      let path = T.takeWhile (\c -> c /= ' ' && c /= '"' && c /= '\n') seg
       in "${PV}" `T.isInfixOf` path

-- | Rewrite frozen version components in assets release URLs to @${PV}@.
--
-- Important: rejoin with 'T.intercalate' on the full parts list (prefix plus
-- rewritten segments). Using @prefix <> intercalate marker segs@ drops the
-- marker when there is only one segment (intercalate on a singleton never
-- inserts the separator), which produced broken URLs like
-- @https:\/\/github.com\/0x6d6e647a\/dolt-${PV}\/…@ instead of
-- @…\/mndz-overlay-assets\/releases\/download\/dolt-${PV}\/…@.
parameterizeAssetsSrcUri :: Text -> Text -> Text
parameterizeAssetsSrcUri pn content =
  case T.splitOn assetsMarker content of
    [] -> content
    prefix : rest ->
      T.intercalate assetsMarker (prefix : map (fixSeg pn) rest)
  where
    fixSeg pkgName seg =
      let (_tagPart, rest0) = T.breakOn "/" seg
       in case T.uncons rest0 of
            Just ('/', afterSlash) ->
              let (filePart, rest1) =
                    T.break (\c -> c == ' ' || c == '"' || c == '\n') afterSlash
                  newTag = pkgName <> "-${PV}"
                  newFile = rewriteFile pkgName filePart
               in newTag <> "/" <> newFile <> rest1
            _ -> seg

    rewriteFile pkgName filePart
      | not (T.isPrefixOf (pkgName <> "-") filePart) = filePart
      | otherwise =
          let afterPn = T.drop (T.length pkgName + 1) filePart
              suffix =
                firstSuffix
                  afterPn
                  ["-vendor", "-deps", ".tar"]
           in pkgName <> "-${PV}" <> suffix

    firstSuffix t markers =
      case [s | m <- markers, let (_, s) = T.breakOn m t, not (T.null s)] of
        (s : _) -> s
        [] -> t

nextRevisionVersion :: EbuildVersion -> EbuildVersion
nextRevisionVersion (Numeric comps Nothing) = Numeric comps (Just 1)
nextRevisionVersion (Numeric comps (Just r)) = Numeric comps (Just (r + 1))
nextRevisionVersion (Raw t) = Raw (t <> "-r1")

ebuildFileNameWithRev :: Text -> EbuildVersion -> FilePath
ebuildFileNameWithRev pn ver =
  T.unpack pn <> "-" <> T.unpack (renderPV ver) <> ".ebuild"

parseManifestVendorSHA512 :: Text -> FilePath -> Maybe Text
parseManifestVendorSHA512 manifestContent distfile =
  let name = T.pack (takeFileName distfile)
      matching =
        [ ln
        | ln <- T.lines manifestContent,
          "DIST" `T.isPrefixOf` ln,
          name `T.isInfixOf` ln
        ]
   in case matching of
        (ln : _) -> extractSha512 ln
        [] -> Nothing
  where
    extractSha512 ln =
      let go [] = Nothing
          go ("SHA512" : hex : _)
            | T.all isHexDigit hex = Just (T.toLower hex)
            | otherwise = Nothing
          go (_ : xs) = go xs
       in go (T.words ln)
