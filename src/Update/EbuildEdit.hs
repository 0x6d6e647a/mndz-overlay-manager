{-# LANGUAGE OverloadedStrings #-}

module Update.EbuildEdit
  ( assetsSrcUriParameterized,
    parameterizeAssetsSrcUri,
    nextRevisionVersion,
    writeVersionForPlannedPV,
    ebuildFileNameWithRev,
    parseManifestVendorSHA512,
    manifestHasVendorDist,
    ebuildNeedsContentFix,
    ebuildNeedsContentFixAtom,
    ebuildNeedsCargoContentFix,
    goBdependAtom,
    nodejsBdependAtom,
    bunBdependAtom,
    ebuildHasDevLangGoBdepend,
    ebuildHasNodejsBdepend,
    ebuildHasBunBinBdepend,
    goBdependMatches,
    nodejsBdependMatches,
    bunBdependMatches,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureBunBdepend,
    ensureRustMinVer,
    ensureCargoAssetsSrcUri,
    ensureEmptyCrates,
    cargoCratesSrcUriLine,
    parseKeywordsLine,
    setKeywords,
    keywordsMatch,
  )
where

import Data.Char (isAlpha, isDigit, isHexDigit)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), comparePV, renderPV)
import System.FilePath (takeFileName)
import Update.Cargo.Msrv (normalizeRustVersion, parseRustMinVerFromEbuild)

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
                  ["-vendor", "-deps", "-crates", ".tar"]
           in pkgName <> "-${PV}" <> suffix

    firstSuffix t markers =
      case [s | m <- markers, let (_, s) = T.breakOn m t, not (T.null s)] of
        (s : _) -> s
        [] -> t

nextRevisionVersion :: EbuildVersion -> EbuildVersion
nextRevisionVersion (Numeric comps Nothing) = Numeric comps (Just 1)
nextRevisionVersion (Numeric comps (Just r)) = Numeric comps (Just (r + 1))
nextRevisionVersion (Raw t) = Raw (t <> "-r1")

-- | Filename version for a planned PV given local non-live versions.
--
-- When no local ebuild shares the planned PV (@comparePV@ EQ), return the
-- bare planned PV (new materialization). When one or more locals match,
-- return @nextRevisionVersion@ of the highest local revision (bare \< @-r1@
-- \< @-r2@ \< …). Planned revision, if any, is ignored in favor of local max.
writeVersionForPlannedPV :: EbuildVersion -> [EbuildVersion] -> EbuildVersion
writeVersionForPlannedPV planned localPVs =
  let target = barePV planned
      same = filter (samePV target) localPVs
   in case same of
        [] -> target
        (v : vs) -> nextRevisionVersion (foldl' maxRevision v vs)
  where
    barePV (Numeric comps _) = Numeric comps Nothing
    barePV (Raw t) = Raw t
    samePV a b = case comparePV a b of
      Just EQ -> True
      _ -> False

-- | Higher Gentoo revision wins; bare is lower than any @-rN@.
maxRevision :: EbuildVersion -> EbuildVersion -> EbuildVersion
maxRevision a b =
  case compareRevision a b of
    GT -> a
    LT -> b
    EQ -> a

compareRevision :: EbuildVersion -> EbuildVersion -> Ordering
compareRevision (Numeric _ ra) (Numeric _ rb) = compare (revRank ra) (revRank rb)
compareRevision a b = compare (renderPV a) (renderPV b)

revRank :: Maybe Word -> Word
revRank Nothing = 0
revRank (Just r) = r

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

-- | True when Manifest has a DIST line for the vendor tarball basename.
manifestHasVendorDist :: Text -> FilePath -> Bool
manifestHasVendorDist manifestContent distfile =
  let name = T.pack (takeFileName distfile)
   in any
        ( \ln ->
            "DIST" `T.isPrefixOf` ln && name `T.isInfixOf` ln
        )
        (T.lines manifestContent)

-- | True when ebuild content needs overlay fix (SRC_URI / BDEPEND / KEYWORDS).
--
-- When @mRequiredGo@ is @Just ver@, BDEPEND adequacy requires the exact atom
-- @>=dev-lang\/go-\<ver\>:@= (not mere presence of @dev-lang\/go@). When
-- unknown (@Nothing@), only a missing @dev-lang\/go@ atom counts as needs-work.
ebuildNeedsContentFix :: [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFix keywords content mRequiredGo =
  not (assetsSrcUriParameterized content)
    || not (keywordsMatch keywords content)
    || bdependNeedsFix mRequiredGo content

-- | Content fix when the full required BDEPEND atom string is known.
-- @Nothing@ means no BDEPEND check (KEYWORDS / SRC_URI only).
ebuildNeedsContentFixAtom :: [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFixAtom keywords content mAtom =
  not (assetsSrcUriParameterized content)
    || not (keywordsMatch keywords content)
    || case mAtom of
      Just atom -> not (atom `T.isInfixOf` content)
      Nothing -> False

-- | Cargo content fix: assets crates SRC_URI, KEYWORDS, RUST_MIN_VER, no list-era form.
ebuildNeedsCargoContentFix :: [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsCargoContentFix keywords content mRequiredMsrv =
  not (assetsSrcUriParameterized content)
    || not (keywordsMatch keywords content)
    || not (hasCratesAssetsSrcUri content)
    || hasListEraCargoDeps content
    || cratesFieldNonEmpty content
    || case mRequiredMsrv of
      Just ver ->
        case parseRustMinVerFromEbuild content of
          Just existing ->
            case (normalizeRustVersion existing, normalizeRustVersion ver) of
              (Just a, Just b) -> a /= b
              _ -> True
          Nothing -> True
      Nothing -> False

hasCratesAssetsSrcUri :: Text -> Bool
hasCratesAssetsSrcUri content =
  assetsMarker `T.isInfixOf` content
    && "-crates.tar.xz" `T.isInfixOf` content

-- | List-era crate deps via @CARGO_CRATE_URIS@ or crates.io crate dist URLs.
hasListEraCargoDeps :: Text -> Bool
hasListEraCargoDeps content =
  "CARGO_CRATE_URIS" `T.isInfixOf` content
    || "crates.io/api/v1/crates" `T.isInfixOf` content

-- | True when @CRATES=@ is present and not empty (quoted empty is OK).
cratesFieldNonEmpty :: Text -> Bool
cratesFieldNonEmpty content =
  case mapMaybe lineCrates (T.lines content) of
    (val : _) ->
      let stripped = T.strip val
       in not (T.null stripped) && stripped /= "\"\"" && stripped /= "''"
    [] -> False
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineCrates ln =
      let s = T.stripStart ln
       in if "CRATES=" `T.isPrefixOf` s
            then Just (T.drop (T.length ("CRATES=" :: Text)) s)
            else Nothing

-- | Assets crates SRC_URI line (parameterized).
cargoCratesSrcUriLine :: Text -> Text
cargoCratesSrcUriLine pn =
  "SRC_URI+=\" https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/"
    <> pn
    <> "-${PV}/"
    <> pn
    <> "-${PV}-crates.tar.xz\""

-- | Ensure assets crates SRC_URI form; strip list-era crate URI patterns.
--
-- Rewrites the whole @SRC_URI@ assignment to a clean two-line form:
--
-- @
-- SRC_URI=\"\<github source archive\>\"
-- SRC_URI+=\" https://…\/mndz-overlay-assets\/…\/{pn}-${PV}-crates.tar.xz\"
-- @
--
-- so multi-line donor\/pycargoebuild blocks (with @${CARGO_CRATE_URIS}@) cannot
-- swallow the @SRC_URI+=@ line inside the quoted string.
ensureCargoAssetsSrcUri :: Text -> Text -> Text
ensureCargoAssetsSrcUri pn content
  -- Already in clean single-line source + crates form: only parameterize.
  | hasCratesAssetsSrcUri content
      && hasCleanGithubSourceLine content
      && not (hasListEraCargoDeps content) =
      parameterizeAssetsSrcUri pn content
  | otherwise =
      let (pre, _oldBlock, post) = splitSrcUriAssignment (T.lines content)
          mSource = extractGithubSourceArchiveUri content
          sourceLine = case mSource of
            Just uri -> "SRC_URI=\"" <> uri <> "\""
            Nothing -> "SRC_URI=\"\""
          cratesLine = cargoCratesSrcUriLine pn
          rebuilt = T.unlines (pre <> [sourceLine, cratesLine] <> post)
       in parameterizeAssetsSrcUri pn rebuilt

hasCleanGithubSourceLine :: Text -> Bool
hasCleanGithubSourceLine content =
  any
    ( \ln ->
        let s = T.stripStart ln
         in ( "SRC_URI=\"" `T.isPrefixOf` s
                || (not ("SRC_URI" `T.isPrefixOf` s) && "https://github.com/" `T.isPrefixOf` s)
            )
              && "/archive/" `T.isInfixOf` s
              && not ("SRC_URI=\"SRC_URI=" `T.isInfixOf` s)
    )
    (T.lines content)

-- | Split ebuild lines into (before SRC_URI, SRC_URI lines, after).
-- Handles both single-line and multi-line @SRC_URI=\"…\"@ blocks, and adjacent
-- @SRC_URI+=@ lines.
splitSrcUriAssignment :: [Text] -> ([Text], [Text], [Text])
splitSrcUriAssignment lns =
  let (pre, rest) = break isSrcUriStart lns
   in case rest of
        [] -> (lns, [], [])
        _ ->
          let (block, after) = takeSrcUriBlock rest
           in (pre, block, after)
  where
    isSrcUriStart ln =
      let s = T.stripStart ln
       in "SRC_URI=" `T.isPrefixOf` s || "SRC_URI+=" `T.isPrefixOf` s

    takeSrcUriBlock [] = ([], [])
    takeSrcUriBlock (x : xs)
      | isSrcUriStart x =
          if isCompleteSrcUriLine x
            then
              let (morePlus, rest) = span isSrcUriPlus xs
               in (x : morePlus, rest)
            else
              -- Multi-line SRC_URI=" … " — consume until a line with closing quote.
              let (mid, rest0) = break lineClosesQuote xs
               in case rest0 of
                    (closeLn : rest1) ->
                      let (morePlus, rest2) = span isSrcUriPlus rest1
                       in (x : mid <> [closeLn] <> morePlus, rest2)
                    [] -> (x : mid, [])
      | otherwise = ([], x : xs)

    isSrcUriPlus ln = "SRC_URI+=" `T.isPrefixOf` T.stripStart ln

    -- Single-line assignment: SRC_URI="…" or SRC_URI+="…" with closing " on same line.
    isCompleteSrcUriLine ln =
      let s = T.strip ln
          afterEq = T.drop 1 (T.dropWhile (/= '=') s)
       in T.length afterEq >= 2 && T.head afterEq == '"' && T.count "\"" afterEq >= 2

    lineClosesQuote ln =
      let t = T.stripEnd ln
       in not (T.null t) && T.last t == '"'

-- | Prefer the GitHub source archive URI (including @-> ${P}.tar.gz@ rename) from ebuild text.
extractGithubSourceArchiveUri :: Text -> Maybe Text
extractGithubSourceArchiveUri content =
  case mapMaybe cleanLine (T.lines content) of
    (u : _) -> Just u
    [] -> Nothing
  where
    cleanLine ln
      | "mndz-overlay-assets" `T.isInfixOf` ln = Nothing
      | "crates.io" `T.isInfixOf` ln = Nothing
      | not ("github.com/" `T.isInfixOf` ln) = Nothing
      | not ("/archive/" `T.isInfixOf` ln) = Nothing
      | otherwise =
          let t0 = T.strip ln
              t1
                | "SRC_URI+=" `T.isPrefixOf` t0 =
                    T.drop (T.length ("SRC_URI+=" :: Text)) t0
                | "SRC_URI=" `T.isPrefixOf` t0 =
                    T.drop (T.length ("SRC_URI=" :: Text)) t0
                | otherwise = t0
              t2 = T.strip t1
              t3 =
                if T.length t2 >= 1 && T.head t2 == '"'
                  then T.drop 1 t2
                  else t2
              t4 = T.dropWhileEnd (\c -> c == '"' || c == '\r') (T.strip t3)
           in if T.null t4 then Nothing else Just t4

-- | Force @CRATES=""@ (tarball packaging). Replaces multi-line CRATES blocks.
ensureEmptyCrates :: Text -> Text
ensureEmptyCrates content =
  let lns = T.lines content
      (pre, post) = break isCratesLine lns
      line = "CRATES=\"\""
   in case post of
        [] -> content
        (first : rest0) ->
          let rest =
                if isCompleteCratesLine first
                  then rest0
                  else drop 1 (dropWhile (not . lineClosesQuote) rest0)
           in T.unlines (pre <> [line] <> rest)
  where
    isCratesLine ln = "CRATES=" `T.isPrefixOf` T.stripStart ln
    isCompleteCratesLine ln =
      let s = T.strip ln
          afterEq = T.drop 1 (T.dropWhile (/= '=') s)
       in T.length afterEq >= 2 && T.head afterEq == '"' && T.count "\"" afterEq >= 2
    lineClosesQuote ln =
      let t = T.stripEnd ln
       in not (T.null t) && T.last t == '"'

-- | Ensure @RUST_MIN_VER="…"@ is present and matches @ver@ (normalized).
ensureRustMinVer :: Text -> Text -> Either Text Text
ensureRustMinVer ver content =
  case normalizeRustVersion ver of
    Nothing -> Left ("invalid RUST_MIN_VER: " <> ver)
    Just norm ->
      let line = "RUST_MIN_VER=\"" <> norm <> "\""
          lns = T.lines content
          (pre, post) = break isRustMin lns
       in case post of
            (_old : rest) -> Right (T.unlines (pre <> [line] <> rest))
            [] ->
              case findLastInheritIdx lns of
                Nothing -> Right (T.unlines (lns <> ["", line]))
                Just idx ->
                  let (before, after) = splitAt (idx + 1) lns
                      (blanks, rest) = span T.null after
                   in Right (T.unlines (before <> blanks <> [line] <> rest))
  where
    isRustMin ln = "RUST_MIN_VER=" `T.isPrefixOf` T.stripStart ln

-- | BDEPEND adequacy vs optional known go.mod language version.
bdependNeedsFix :: Maybe Text -> Text -> Bool
bdependNeedsFix (Just ver) content = not (goBdependMatches ver content)
bdependNeedsFix Nothing content = not (ebuildHasDevLangGoBdepend content)

-- | Portage atom for a go.mod language version (e.g. @"1.26.5"@).
goBdependAtom :: Text -> Text
goBdependAtom goVer = ">=dev-lang/go-" <> goVer <> ":="

-- | Portage atom for engines.node minimum with npm USE.
nodejsBdependAtom :: Text -> Text
nodejsBdependAtom ver = ">=net-libs/nodejs-" <> ver <> "[npm]"

-- | Portage atom for engines.bun minimum.
bunBdependAtom :: Text -> Text
bunBdependAtom ver = ">=dev-lang/bun-bin-" <> ver

-- | True when the ebuild text mentions a @dev-lang/go@ dependency atom.
ebuildHasDevLangGoBdepend :: Text -> Bool
ebuildHasDevLangGoBdepend content =
  "dev-lang/go" `T.isInfixOf` content

ebuildHasNodejsBdepend :: Text -> Bool
ebuildHasNodejsBdepend content =
  "net-libs/nodejs" `T.isInfixOf` content

ebuildHasBunBinBdepend :: Text -> Bool
ebuildHasBunBinBdepend content =
  "dev-lang/bun-bin" `T.isInfixOf` content

-- | True when the ebuild already has the exact required go BDEPEND atom.
goBdependMatches :: Text -> Text -> Bool
goBdependMatches goVer content =
  goBdependAtom goVer `T.isInfixOf` content

nodejsBdependMatches :: Text -> Text -> Bool
nodejsBdependMatches ver content =
  nodejsBdependAtom ver `T.isInfixOf` content

bunBdependMatches :: Text -> Text -> Bool
bunBdependMatches ver content =
  bunBdependAtom ver `T.isInfixOf` content

-- | Ensure the ebuild declares @BDEPEND@ with @>=dev-lang/go-<ver>:=@.
ensureGoBdepend :: Text -> Text -> Either Text Text
ensureGoBdepend goVer =
  ensureBdependAtom
    "go"
    "dev-lang/go"
    (goBdependAtom goVer)
    goVer

-- | Ensure @>=net-libs/nodejs-<ver>[npm]@ in BDEPEND.
ensureNodejsBdepend :: Text -> Text -> Either Text Text
ensureNodejsBdepend ver =
  ensureBdependAtom
    "nodejs"
    "net-libs/nodejs"
    (nodejsBdependAtom ver)
    ver

-- | Ensure @>=dev-lang/bun-bin-<ver>@ in BDEPEND.
ensureBunBdepend :: Text -> Text -> Either Text Text
ensureBunBdepend ver =
  ensureBdependAtom
    "bun-bin"
    "dev-lang/bun-bin"
    (bunBdependAtom ver)
    ver

ensureBdependAtom ::
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Either Text Text
ensureBdependAtom label pkgInfix atom ver content
  | T.null (T.strip ver) = Left ("empty " <> label <> " version for BDEPEND")
  | not (validVer ver) =
      Left ("invalid " <> label <> " version for BDEPEND: " <> ver)
  | pkgInfix `T.isInfixOf` content =
      Right (replacePkgAtoms pkgInfix atom content)
  | otherwise =
      case insertAfterInherit atom content of
        Just fixed -> Right fixed
        Nothing ->
          Left "could not insert BDEPEND: no inherit line found in ebuild"
  where
    validVer v =
      let parts = T.splitOn "." v
       in not (null parts)
            && all (\p -> not (T.null p) && T.all isDigit p) parts

-- | Replace each @pkgInfix…@ dependency atom with the required atom.
replacePkgAtoms :: Text -> Text -> Text -> Text
replacePkgAtoms pkgInfix atom content =
  T.unlines (map (replaceInLine atom) (T.lines content))
  where
    replaceInLine a ln
      | pkgInfix `T.isInfixOf` ln = replaceAtomsInText pkgInfix a ln
      | otherwise = ln

-- | Replace @>=pkg-1.x@-style tokens (optional operators, version, slot, USE).
--
-- The old atom tail after @pkgInfix@ is dropped as: optional @-version@,
-- optional slot (@:=@ / @:\<slot\>@ / @:\<slot\>=@), optional USE (@[\…]@).
-- USE flag *names* (letters) must be consumed so rewrites of e.g.
-- @>=net-libs/nodejs-20.19.0[npm]@ do not leave a dangling @npm]@.
replaceAtomsInText :: Text -> Text -> Text -> Text
replaceAtomsInText pkgInfix atom = go
  where
    go t =
      case T.breakOn pkgInfix t of
        (_, rest)
          | T.null rest -> t
        (before, rest) ->
          let prefix = T.dropWhileEnd isAtomOp before
              afterAtom = dropPkgAtom rest
           in prefix <> atom <> go afterAtom

    isAtomOp c = c == '>' || c == '=' || c == '<' || c == '~'

    -- @rest@ starts with @pkgInfix@.
    dropPkgAtom rest =
      dropUse (dropSlot (dropVersion (T.drop (T.length pkgInfix) rest)))

    -- @-20.19.0@, @-1.26.5_p1@, etc.
    dropVersion t =
      case T.uncons t of
        Just ('-', rs) ->
          let (ver, rest) = T.span isVersionChar rs
           in if T.null ver then t else rest
        _ -> t

    isVersionChar c =
      isDigit c || c == '.' || c == '_' || isAlpha c

    -- @:=@, @:0@, @:0/@, @:slot=@ — stop at USE or whitespace/quote.
    dropSlot t =
      case T.uncons t of
        Just (':', rs) ->
          let (_slotBody, rest0) = T.span isSlotChar rs
           in case T.uncons rest0 of
                Just ('=', r) -> r
                _ -> rest0
        _ -> t

    isSlotChar c =
      isDigit c
        || c == '.'
        || c == '+'
        || c == '_'
        || c == '/'
        || isAlpha c

    -- @[npm]@, @[npm(+)]@, multi-flag USE lists.
    dropUse t =
      case T.uncons t of
        Just ('[', rs) ->
          case T.break (== ']') rs of
            (_inside, rest)
              | Just (']', after) <- T.uncons rest -> after
              | otherwise -> t
        _ -> t

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

-- | Parse KEYWORDS tokens from ebuild content (first KEYWORDS= line).
parseKeywordsLine :: Text -> [Text]
parseKeywordsLine content =
  case mapMaybe lineKeywords (T.lines content) of
    (toks : _) -> toks
    [] -> []
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineKeywords ln =
      let stripped = T.stripStart ln
       in if "KEYWORDS=" `T.isPrefixOf` stripped
            then Just (tokenize (T.drop (T.length ("KEYWORDS=" :: Text)) stripped))
            else Nothing
    tokenize raw =
      let unquoted = stripQuotes (T.strip raw)
       in filter (not . T.null) (T.words unquoted)
    stripQuotes t
      | T.length t >= 2,
        T.head t == '"',
        T.last t == '"' =
          T.init (T.tail t)
      | otherwise = t

-- | True when KEYWORDS tokens match exactly (order-insensitive multiset).
keywordsMatch :: [Text] -> Text -> Bool
keywordsMatch expected content =
  let actual = parseKeywordsLine content
   in length expected == length actual
        && all (`elem` actual) expected
        && all (`elem` expected) actual

-- | Set or replace KEYWORDS to the given space-joined tokens (quoted).
-- Replaces a multi-line @KEYWORDS=\"…\"@ block when present.
setKeywords :: [Text] -> Text -> Text
setKeywords toks content =
  let line = "KEYWORDS=\"" <> T.unwords (map stripTok toks) <> "\""
      lns = T.lines content
      (pre, post) = break isKeywordsLine lns
   in case post of
        [] ->
          -- Insert after inherit block when missing.
          case findLastInheritIdx lns of
            Nothing -> T.unlines (lns <> ["", line])
            Just idx ->
              let (before, after) = splitAt (idx + 1) lns
                  (blanks, rest) = span T.null after
               in T.unlines (before <> blanks <> [line] <> rest)
        (first : rest0) ->
          let rest =
                if isCompleteKeywordsLine first
                  then rest0
                  else drop 1 (dropWhile (not . lineClosesQuote) rest0)
           in T.unlines (pre <> [line] <> rest)
  where
    isKeywordsLine ln = "KEYWORDS=" `T.isPrefixOf` T.stripStart ln
    isCompleteKeywordsLine ln =
      let s = T.strip ln
          afterEq = T.drop 1 (T.dropWhile (/= '=') s)
       in T.length afterEq >= 2 && T.head afterEq == '"' && T.count "\"" afterEq >= 2
    lineClosesQuote ln =
      let t = T.stripEnd ln
       in not (T.null t) && T.last t == '"'
    stripTok t =
      let t1 = T.strip t
       in if T.length t1 >= 2 && T.head t1 == '"' && T.last t1 == '"'
            then T.init (T.tail t1)
            else t1
