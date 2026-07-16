{-# LANGUAGE OverloadedStrings #-}

module Update.EbuildEdit
  ( assetsSrcUriParameterized,
    parameterizeAssetsSrcUri,
    nextRevisionVersion,
    ebuildFileNameWithRev,
    parseManifestVendorSHA512,
    goBdependAtom,
    ebuildHasDevLangGoBdepend,
    goBdependMatches,
    ensureGoBdepend,
  )
where

import Data.Char (isDigit, isHexDigit)
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

-- | Portage atom for a go.mod language version (e.g. @"1.26.5"@).
goBdependAtom :: Text -> Text
goBdependAtom goVer = ">=dev-lang/go-" <> goVer <> ":="

-- | True when the ebuild text mentions a @dev-lang/go@ dependency atom.
ebuildHasDevLangGoBdepend :: Text -> Bool
ebuildHasDevLangGoBdepend content =
  "dev-lang/go" `T.isInfixOf` content

-- | True when the ebuild already has the exact required go BDEPEND atom.
goBdependMatches :: Text -> Text -> Bool
goBdependMatches goVer content =
  goBdependAtom goVer `T.isInfixOf` content

-- | Ensure the ebuild declares @BDEPEND@ with @>=dev-lang/go-<ver>:=@.
-- Replaces existing @dev-lang/go@ atoms inside @BDEPEND@ / @BDEPEND+@ lines;
-- inserts a new @BDEPEND@ line after @inherit@ when none is present.
ensureGoBdepend :: Text -> Text -> Either Text Text
ensureGoBdepend goVer content
  | T.null (T.strip goVer) = Left "empty go version for BDEPEND"
  | not (validGoVer goVer) =
      Left ("invalid go version for BDEPEND: " <> goVer)
  | ebuildHasDevLangGoBdepend content =
      Right (replaceGoAtoms (goBdependAtom goVer) content)
  | otherwise =
      case insertAfterInherit (goBdependAtom goVer) content of
        Just fixed -> Right fixed
        Nothing ->
          Left "could not insert BDEPEND: no inherit line found in ebuild"
  where
    validGoVer v =
      let parts = T.splitOn "." v
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts

-- | Replace each @dev-lang/go…@ dependency atom with the required atom.
replaceGoAtoms :: Text -> Text -> Text
replaceGoAtoms atom content =
  T.unlines (map (replaceInLine atom) (T.lines content))
  where
    replaceInLine a ln
      | "dev-lang/go" `T.isInfixOf` ln = replaceAtomsInText a ln
      | otherwise = ln

-- | Replace @>=dev-lang/go-1.x@-style tokens (optional operators, version, @:=@).
replaceAtomsInText :: Text -> Text -> Text
replaceAtomsInText atom = go
  where
    go t =
      case T.breakOn "dev-lang/go" t of
        (_, rest)
          | T.null rest -> t
        (before, rest) ->
          let prefix = T.dropWhileEnd isAtomOp before
              afterAtom = dropGoAtom rest
           in prefix <> atom <> go afterAtom

    isAtomOp c = c == '>' || c == '=' || c == '<' || c == '~'

    -- @rest@ starts with @dev-lang/go@.
    dropGoAtom rest =
      let afterPkg = T.drop (T.length ("dev-lang/go" :: Text)) rest
          -- optional -version and := / :slot
          verPart =
            T.takeWhile
              (\c -> isDigit c || c == '.' || c == '-' || c == ':' || c == '=')
              afterPkg
       in T.drop (T.length verPart) afterPkg

insertAfterInherit :: Text -> Text -> Maybe Text
insertAfterInherit atom content =
  let lns = T.lines content
      bdependLine = "BDEPEND=\"" <> atom <> "\""
   in case findLastInheritIdx lns of
        Nothing -> Nothing
        Just idx ->
          let (pre, post) = splitAt (idx + 1) lns
              -- Skip a blank line after inherit if present, insert after that blank.
              (blanks, rest) = span T.null post
              insertion =
                case blanks of
                  [] -> [""] <> [bdependLine] <> [""]
                  (_ : _) -> blanks <> [bdependLine] <> [""]
           in Just (T.unlines (pre <> insertion <> rest))

findLastInheritIdx :: [Text] -> Maybe Int
findLastInheritIdx lns =
  case [i | (i, ln) <- zip [0 ..] lns, "inherit" `T.isPrefixOf` T.stripStart ln] of
    [] -> Nothing
    xs -> Just (last xs)
