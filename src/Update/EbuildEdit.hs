{-# LANGUAGE OverloadedStrings #-}

module Update.EbuildEdit
  ( AssetsHost (..),
    defaultAssetsHost,
    assetsDownloadMarker,
    assetsSrcUriParameterized,
    assetsSrcUriParameterizedFor,
    assetsOwnedTagCollision,
    assetsOwnedTagCollisionFor,
    parameterizeAssetsSrcUri,
    parameterizeAssetsSrcUriFor,
    pnCollidesWithPinIdentity,
    rustyV8PinIdentity,
    nextRevisionVersion,
    writeVersionForPlannedPV,
    ebuildFileNameWithRev,
    parseManifestVendorSHA512,
    manifestHasVendorDist,
    ebuildNeedsContentFix,
    ebuildNeedsContentFixFor,
    ebuildNeedsContentFixAtom,
    ebuildNeedsContentFixAtomFor,
    ebuildNeedsCargoContentFix,
    ebuildNeedsCargoBodyFix,
    ebuildNeedsCargoBodyFixFor,
    cargoProvenanceMismatch,
    CargoSourceForm (..),
    goBdependAtom,
    nodejsBdependAtom,
    bunCompilePinBdependAtom,
    bunFloorBdependAtom,
    bunBdependAtomFor,
    bunAtomVersion,
    ebuildHasDevLangGoBdepend,
    goBdependMatches,
    nodejsBdependMatches,
    ensureGoBdepend,
    ensureNodejsBdepend,
    ensureBunBdepend,
    ensureBunBdependFor,
    parseSrcCompileCd,
    rewriteBunExactInvocations,
    parseEbuildSlot,
    setSlotField,
    ensureSbclAtom,
    ensureRustMinVer,
    parseQuotedAssignment,
    ensureQuotedAssignment,
    ensureCodexV8Overlay,
    ensureCodexV8OverlayFor,
    ensureCargoAssetsSrcUri,
    ensureCargoAssetsSrcUriFor,
    ensureCargoAssetsSrcUriForHost,
    stripWindowsOnlyGitCrates,
    hasCleanCratesIoSourceLine,
    cargoCratesIoSrcUriLine,
    ensureEmptyCrates,
    cargoCratesSrcUriLine,
    cargoCratesSrcUriLineFor,
    sbclBdependAtom,
    sbclBdependMatches,
    parseKeywordsLine,
    setKeywords,
    keywordsMatch,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Containers.ListUtils (nubOrd)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), renderPV, samePV)
import Update.Bun.Cache (isBunCompilePinPackage)
import Update.Cargo.Lock (parseGitPackageNames)
import Update.Cargo.Msrv
  ( normalizeRustVersion,
    parseRustMinVerFromEbuild,
    rustMinVerTooLow,
    windowsOnlyDepNames,
  )
import Update.Manifest.Dist (exactDistSHA512, manifestHasExactDist)
import Update.TextUtil (stripSurroundingQuotes)
import Update.Types (CargoSource (..), PackageKey)

-- | GitHub owner/repo for assets-repository SRC_URI (from @assets-path@ origin).
data AssetsHost = AssetsHost
  { ahOwner :: Text,
    ahRepo :: Text
  }
  deriving (Eq, Show)

-- | Historical mndz overlay assets host; tests and wrappers default here.
defaultAssetsHost :: AssetsHost
defaultAssetsHost =
  AssetsHost
    { ahOwner = "0x6d6e647a",
      ahRepo = "mndz-overlay-assets"
    }

-- | @{repo}/releases/download/@ marker that identifies assets-host URLs.
assetsDownloadMarker :: AssetsHost -> Text
assetsDownloadMarker host = ahRepo host <> "/releases/download/"

assetsReleasePrefix :: AssetsHost -> Text
assetsReleasePrefix host =
  "https://github.com/"
    <> ahOwner host
    <> "/"
    <> ahRepo host
    <> "/releases/download/"

-- | Reserved pin-keyed assets identity for the rusty_v8 snapshot.
rustyV8PinIdentity :: Text
rustyV8PinIdentity = "rusty-v8"

-- | True when overlay PN prefix-collides with a reserved pin identity.
--
-- Collision is any of: equal names; @{pn}-@ is a prefix of @{identity}-@;
-- @{identity}-@ is a prefix of @{pn}-@.
pnCollidesWithPinIdentity :: Text -> Text -> Bool
pnCollidesWithPinIdentity pn identity =
  pn == identity
    || (pn <> "-") `T.isPrefixOf` (identity <> "-")
    || (identity <> "-") `T.isPrefixOf` (pn <> "-")

-- | True when this assets-host release tag belongs to the overlay package.
packageAssetsTag :: Text -> Text -> Bool
packageAssetsTag pkgName tag =
  "${PV}" `T.isInfixOf` tag
    || (pkgName <> "-") `T.isPrefixOf` tag

reservedPinIdentityTag :: Text -> Bool
reservedPinIdentityTag tag =
  tag == rustyV8PinIdentity
    || (rustyV8PinIdentity <> "-") `T.isPrefixOf` tag

ownedTagCollides :: Text -> Text -> Bool
ownedTagCollides pkgName tag =
  packageAssetsTag pkgName tag
    && pnCollidesWithPinIdentity pkgName rustyV8PinIdentity
    && reservedPinIdentityTag tag

assetsPathOf :: Text -> Text
assetsPathOf = T.takeWhile (\c -> c /= ' ' && c /= '"' && c /= '\n')

assetsTagOf :: Text -> Text
assetsTagOf seg = fst (T.breakOn "/" (assetsPathOf seg))

-- | Hard-fail reason when a reserved pin-identity tag would be treated as
-- package-owned (for example PN @rusty@ vs tag @rusty-v8-150.4.0@).
assetsOwnedTagCollision :: Text -> Text -> Maybe Text
assetsOwnedTagCollision = assetsOwnedTagCollisionFor defaultAssetsHost

assetsOwnedTagCollisionFor :: AssetsHost -> Text -> Text -> Maybe Text
assetsOwnedTagCollisionFor host pn content =
  case colliding of
    (tag : _) ->
      Just $
        "overlay PN "
          <> pn
          <> " prefix-collides with reserved pin identity "
          <> rustyV8PinIdentity
          <> " (assets tag "
          <> tag
          <> ")"
    [] -> Nothing
  where
    marker = assetsDownloadMarker host
    colliding =
      [ tag
      | tag <- tags,
        ownedTagCollides pn tag
      ]
    tags =
      case T.splitOn marker content of
        [] -> []
        [_] -> []
        _ : segs -> map assetsTagOf segs

-- | True when every *package-owned* assets-repo release download URL
-- already uses @${PV}@. Non-owned tags (a different version axis) are ignored.
assetsSrcUriParameterized :: Text -> Text -> Bool
assetsSrcUriParameterized = assetsSrcUriParameterizedFor defaultAssetsHost

assetsSrcUriParameterizedFor :: AssetsHost -> Text -> Text -> Bool
assetsSrcUriParameterizedFor host pn content =
  case T.splitOn (assetsDownloadMarker host) content of
    [] -> True
    [_] -> True
    _ : segs -> all (segmentParameterized pn) segs
  where
    segmentParameterized pkgName seg =
      let path = assetsPathOf seg
          tag = fst (T.breakOn "/" path)
       in not (packageAssetsTag pkgName tag) || "${PV}" `T.isInfixOf` path

-- | Rewrite frozen version components in assets release URLs to @${PV}@.
--
-- Important: rejoin with 'T.intercalate' on the full parts list (prefix plus
-- rewritten segments). Using @prefix <> intercalate marker segs@ drops the
-- marker when there is only one segment (intercalate on a singleton never
-- inserts the separator), which produced broken URLs like
-- @https:\/\/github.com\/0x6d6e647a\/dolt-${PV}\/…@ instead of
-- @…\/{repo}\/releases\/download\/dolt-${PV}\/…@.
parameterizeAssetsSrcUri :: Text -> Text -> Text
parameterizeAssetsSrcUri = parameterizeAssetsSrcUriFor defaultAssetsHost

parameterizeAssetsSrcUriFor :: AssetsHost -> Text -> Text -> Text
parameterizeAssetsSrcUriFor host pn content =
  case T.splitOn marker content of
    [] -> content
    prefix : rest ->
      T.intercalate marker (prefix : map (fixSeg pn) rest)
  where
    marker = assetsDownloadMarker host
    fixSeg pkgName seg =
      let (tagPart, rest0) = T.breakOn "/" seg
       in case T.uncons rest0 of
            Just ('/', afterSlash) ->
              let (filePart, rest1) =
                    T.break (\c -> c == ' ' || c == '"' || c == '\n') afterSlash
                  -- Only rewrite this package's release tag. rusty_v8 is keyed
                  -- by crate version (rusty-v8-150.4.0), not {pn}-${PV}. A PN
                  -- that would own that tag via prefix collision is left
                  -- unrewritten here; rewrite/adequacy hard-fail separately.
                  colliding = ownedTagCollides pkgName tagPart
                  newTag =
                    if packageAssetsTag pkgName tagPart && not colliding
                      then pkgName <> "-${PV}"
                      else tagPart
                  newFile =
                    if colliding then filePart else rewriteFile pkgName filePart
               in newTag <> "/" <> newFile <> rest1
            _ -> seg

    rewriteFile pkgName filePart
      | not (T.isPrefixOf (pkgName <> "-") filePart) = filePart
      | otherwise =
          let afterPn = T.drop (T.length pkgName + 1) filePart
              suffix =
                firstSuffix
                  afterPn
                  ["-vendor", "-deps", "-crates", "-models", ".tar"]
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
  case exactDistSHA512 manifestContent distfile of
    Right m -> m
    Left _ -> Nothing

-- | True when Manifest has an exact DIST record for the basename.
manifestHasVendorDist :: Text -> FilePath -> Bool
manifestHasVendorDist = manifestHasExactDist

-- | True when ebuild content needs overlay fix (SRC_URI / BDEPEND / KEYWORDS).
--
-- When @mRequiredGo@ is @Just ver@, BDEPEND adequacy requires the exact atom
-- @>=dev-lang\/go-\<ver\>:@= (not mere presence of @dev-lang\/go@). When
-- unknown (@Nothing@), only a missing @dev-lang\/go@ atom counts as needs-work.
ebuildNeedsContentFix :: Text -> [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFix = ebuildNeedsContentFixFor defaultAssetsHost

ebuildNeedsContentFixFor :: AssetsHost -> Text -> [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFixFor host pn keywords content mRequiredGo =
  not (assetsSrcUriParameterizedFor host pn content)
    || not (keywordsMatch keywords content)
    || bdependNeedsFix mRequiredGo content

-- | Content fix when the full required BDEPEND atom string is known.
-- @Nothing@ means no BDEPEND check (KEYWORDS / SRC_URI only).
ebuildNeedsContentFixAtom :: Text -> [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFixAtom = ebuildNeedsContentFixAtomFor defaultAssetsHost

ebuildNeedsContentFixAtomFor ::
  AssetsHost -> Text -> [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsContentFixAtomFor host pn keywords content mAtom =
  not (assetsSrcUriParameterizedFor host pn content)
    || not (keywordsMatch keywords content)
    || case mAtom of
      Just atom -> not (atom `T.isInfixOf` content)
      Nothing -> False

-- | Cargo body fix excluding RUST_MIN_VER (SRC_URI, KEYWORDS, CRATES, list-era).
-- CratesIo provenance additionally requires the canonical crates.io primary
-- source line; GitTag requirements are unchanged.
ebuildNeedsCargoBodyFix :: CargoSource -> Text -> [Text] -> Text -> Bool
ebuildNeedsCargoBodyFix = ebuildNeedsCargoBodyFixFor defaultAssetsHost

ebuildNeedsCargoBodyFixFor ::
  AssetsHost -> CargoSource -> Text -> [Text] -> Text -> Bool
ebuildNeedsCargoBodyFixFor host CargoCratesIo pn keywords content =
  not (assetsSrcUriParameterizedFor host pn content)
    || not (keywordsMatch keywords content)
    || not (hasCratesAssetsSrcUriFor host content)
    || not (hasCleanCratesIoSourceLine content)
    || hasListEraCargoDepsFor CargoCratesIo content
    || cratesFieldNonEmpty content
ebuildNeedsCargoBodyFixFor host CargoGitTag pn keywords content =
  not (assetsSrcUriParameterizedFor host pn content)
    || not (keywordsMatch keywords content)
    || not (hasCratesAssetsSrcUriFor host content)
    || hasListEraCargoDeps content
    || cratesFieldNonEmpty content

-- | Cargo content fix: body plus too-low-only RUST_MIN_VER vs the decision floor.
ebuildNeedsCargoContentFix :: CargoSource -> Text -> [Text] -> Text -> Maybe Text -> Bool
ebuildNeedsCargoContentFix cargoSrc pn keywords content mRequiredMsrv =
  ebuildNeedsCargoBodyFix cargoSrc pn keywords content
    || case mRequiredMsrv of
      Just ver ->
        case parseRustMinVerFromEbuild content of
          Just existing -> rustMinVerTooLow existing ver
          Nothing -> True
      Nothing -> False

hasCratesAssetsSrcUriFor :: AssetsHost -> Text -> Bool
hasCratesAssetsSrcUriFor host content =
  assetsDownloadMarker host `T.isInfixOf` content
    && "-crates.tar.xz" `T.isInfixOf` content

-- | List-era crate deps via @CARGO_CRATE_URIS@ or crates.io crate dist URLs.
-- @${CARGO_CRATE_URIS}@ is list-era registry URIs only when @CRATES@ is
-- non-empty. Empty @CRATES@ plus @CARGO_CRATE_URIS@ is the git-crates form.
-- For CratesIo provenance the canonical crates.io download line is manager-owned,
-- so only @CARGO_CRATE_URIS@ is list-era (still gated on non-empty @CRATES@).
hasListEraCargoDeps :: Text -> Bool
hasListEraCargoDeps content =
  (cratesFieldNonEmpty content && "CARGO_CRATE_URIS" `T.isInfixOf` content)
    || "crates.io/api/v1/crates" `T.isInfixOf` content

hasListEraCargoDepsFor :: CargoSource -> Text -> Bool
hasListEraCargoDepsFor CargoGitTag = hasListEraCargoDeps
hasListEraCargoDepsFor CargoCratesIo = \content ->
  cratesFieldNonEmpty content && "CARGO_CRATE_URIS" `T.isInfixOf` content

-- | True when @CRATES=@ is present and not empty (quoted empty is OK).
-- Multiline @CRATES="\\n"@ (pycargoebuild empty list) is empty, not list-era.
cratesFieldNonEmpty :: Text -> Bool
cratesFieldNonEmpty = not . T.null . T.strip . cratesAssignmentInner

-- | Inner text of the first @CRATES=@ assignment, surrounding quotes stripped.
cratesAssignmentInner :: Text -> Text
cratesAssignmentInner content =
  case break isCratesLine (T.lines content) of
    (_, []) -> ""
    (_, first : rest0) ->
      if isCompleteCratesLine first
        then stripSurroundingQuotes (T.strip (cratesRhs first))
        else
          let (mid, rest1) = break lineClosesQuote rest0
              closeLn = case rest1 of
                (c : _) -> c
                [] -> ""
              firstRest = dropOpeningQuote (cratesRhs first)
              closeBody = T.dropWhileEnd (== '"') (T.stripEnd closeLn)
           in T.strip (T.unlines (firstRest : mid) <> closeBody)
  where
    isCratesLine ln = "CRATES=" `T.isPrefixOf` T.stripStart ln
    cratesRhs ln = T.drop (T.length ("CRATES=" :: Text)) (T.stripStart ln)
    isCompleteCratesLine ln =
      let s = T.strip ln
          afterEq = T.drop 1 (T.dropWhile (/= '=') s)
       in T.length afterEq >= 2 && T.head afterEq == '"' && T.count "\"" afterEq >= 2
    lineClosesQuote ln =
      let t = T.stripEnd ln
       in not (T.null t) && T.last t == '"'
    dropOpeningQuote rhs =
      let t = T.stripStart rhs
       in if not (T.null t) && T.head t == '"' then T.drop 1 t else t

-- | Assets crates SRC_URI line (parameterized).
cargoCratesSrcUriLine :: Text -> Text
cargoCratesSrcUriLine = cargoCratesSrcUriLineFor defaultAssetsHost

cargoCratesSrcUriLineFor :: AssetsHost -> Text -> Text
cargoCratesSrcUriLineFor host pn =
  "SRC_URI+=\" "
    <> assetsReleasePrefix host
    <> pn
    <> "-${PV}/"
    <> pn
    <> "-${PV}-crates.tar.xz\""

-- | Canonical crates.io primary source distfile line (CratesIo provenance).
cargoCratesIoSrcUriLine :: Text -> Text
cargoCratesIoSrcUriLine pn =
  "SRC_URI=\"https://crates.io/api/v1/crates/"
    <> pn
    <> "/${PV}/download -> "
    <> pn
    <> "-${PV}.crate\""

-- | True when some @SRC_URI=@ line is the clean crates.io download form.
hasCleanCratesIoSourceLine :: Text -> Bool
hasCleanCratesIoSourceLine content =
  any
    ( \ln ->
        let s = T.stripStart ln
         in "SRC_URI=\"" `T.isPrefixOf` s
              && "crates.io/api/v1/crates/" `T.isInfixOf` s
              && "/download" `T.isInfixOf` s
    )
    (T.lines content)

-- | Ensure the provenance-appropriate SRC_URI form (GitTag: github archive;
-- CratesIo: canonical crates.io download distfile) plus the assets crates line.
ensureCargoAssetsSrcUriFor :: CargoSource -> Text -> Text -> Text
ensureCargoAssetsSrcUriFor =
  ensureCargoAssetsSrcUriForHost defaultAssetsHost

ensureCargoAssetsSrcUriForHost ::
  AssetsHost -> CargoSource -> Text -> Text -> Text
ensureCargoAssetsSrcUriForHost host cargoSrc pn content = case cargoSrc of
  CargoGitTag -> ensureCargoAssetsSrcUriHost host pn content
  CargoCratesIo ->
    -- Already in clean single-line crates.io + crates form: only parameterize.
    if hasCratesAssetsSrcUriFor host content
      && hasCleanCratesIoSourceLine content
      && not (hasListEraCargoDepsFor CargoCratesIo content)
      then parameterizeAssetsSrcUriFor host pn content
      else
        let (pre, _oldBlock, post) = splitSrcUriAssignment (T.lines content)
            sourceLine = cargoCratesIoSrcUriLine pn
            cratesLine = cargoCratesSrcUriLineFor host pn
            rebuilt = T.unlines (pre <> [sourceLine, cratesLine] <> post)
         in parameterizeAssetsSrcUriFor host pn rebuilt

------------------------------------------------------------------------
-- Provenance coherence (policy provenance <-> ebuild source-line form)
------------------------------------------------------------------------

-- | Observed primary source-line form of an ebuild.
data CargoSourceForm
  = -- | @github.com/…/archive/@ primary source line.
    SourceFormGithubArchive
  | -- | canonical @crates.io/api/v1/crates/…/download@ primary source line.
    SourceFormCratesIo
  | -- | Neither manager-written form (left alone to avoid false positives).
    SourceFormOther
  deriving (Eq, Show)

-- | Primary source-line form of an ebuild body: crates.io download beats
-- github archive when both appear; assets release URLs are never primary.
ebuildCargoSourceForm :: Text -> CargoSourceForm
ebuildCargoSourceForm content
  | hasCleanCratesIoSourceLine content = SourceFormCratesIo
  | hasCleanGithubSourceLine content = SourceFormGithubArchive
  | otherwise = SourceFormOther

-- | Provenance coherence error for one ebuild body: 'Nothing' when the
-- observed primary source form agrees with the policy provenance (or is
-- unrecognizable); @Just@ names the expected and observed forms otherwise.
cargoProvenanceMismatch :: CargoSource -> Text -> Text -> Maybe Text
cargoProvenanceMismatch cargoSrc name content =
  let observed = ebuildCargoSourceForm content
      expected = case cargoSrc of
        CargoGitTag -> SourceFormGithubArchive
        CargoCratesIo -> SourceFormCratesIo
   in if observed == expected || observed == SourceFormOther
        then Nothing
        else
          Just $
            "cargo provenance mismatch for "
              <> name
              <> ": policy provenance "
              <> cargoSourceName cargoSrc
              <> " requires primary source line "
              <> expectedForm
              <> " but observed "
              <> observedForm
  where
    expectedForm = case cargoSrc of
      CargoGitTag ->
        "the upstream GitHub source archive (github.com/.../archive/)"
      CargoCratesIo ->
        "the canonical crates.io download distfile \
        \(crates.io/api/v1/crates/<crate>/<pv>/download)"
    observedForm = case ebuildCargoSourceForm content of
      SourceFormGithubArchive -> "a GitHub archive source line"
      SourceFormCratesIo -> "a crates.io download source line"
      SourceFormOther -> "an unrecognized primary source line"

cargoSourceName :: CargoSource -> Text
cargoSourceName CargoGitTag = "CargoGitTag"
cargoSourceName CargoCratesIo = "CargoCratesIo"

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
ensureCargoAssetsSrcUri = ensureCargoAssetsSrcUriHost defaultAssetsHost

ensureCargoAssetsSrcUriHost :: AssetsHost -> Text -> Text -> Text
ensureCargoAssetsSrcUriHost host pn content
  -- Already in clean single-line source + crates form: only parameterize.
  -- Extra companion SRC_URI+= lines (V8 snapshot, GCS clang, git-crate URIs)
  -- are part of the assignment block; skip rewrite when the primary+crates
  -- pair is already present and this is not list-era.
  | hasCratesAssetsSrcUriFor host content
      && hasCleanGithubSourceLineFor host content
      && not (hasListEraCargoDeps content) =
      parameterizeAssetsSrcUriFor host pn content
  | otherwise =
      let (pre, oldBlock, post) = splitSrcUriAssignment (T.lines content)
          mSource = extractGithubSourceArchiveUriFor host content
          sourceLine = case mSource of
            Just uri -> "SRC_URI=\"" <> uri <> "\""
            Nothing -> "SRC_URI=\"\""
          cratesLine = cargoCratesSrcUriLineFor host pn
          extras = extraCargoSrcUriLines host pn (hasListEraCargoDeps content) oldBlock
          rebuilt = T.unlines (pre <> [sourceLine, cratesLine] <> extras <> post)
       in parameterizeAssetsSrcUriFor host pn rebuilt

-- | Companion @SRC_URI+=@ lines that are neither the GitHub/crates.io primary
-- source nor the assets crates tarball. List-era drops @CARGO_CRATE_URIS@;
-- empty-@CRATES@ git-crate form keeps it.
extraCargoSrcUriLines :: AssetsHost -> Text -> Bool -> [Text] -> [Text]
extraCargoSrcUriLines host pn dropCrateUris block =
  [ "SRC_URI+=\" " <> T.strip body <> "\""
  | ln <- block,
    Just body <- [srcUriLineBody ln],
    not (T.null (T.strip body)),
    keepCompanion host pn dropCrateUris (T.strip body)
  ]

srcUriLineBody :: Text -> Maybe Text
srcUriLineBody ln =
  let s = T.strip ln
      stripped
        | "SRC_URI+=\"" `T.isPrefixOf` s =
            T.drop (T.length ("SRC_URI+=\"" :: Text)) s
        | "SRC_URI=\"" `T.isPrefixOf` s =
            T.drop (T.length ("SRC_URI=\"" :: Text)) s
        | otherwise = s
      unquoted = T.dropWhileEnd (== '"') (T.strip stripped)
   in if T.null unquoted then Nothing else Just unquoted

keepCompanion :: AssetsHost -> Text -> Bool -> Text -> Bool
keepCompanion host pn dropCrateUris body
  | "->" `T.isPrefixOf` T.strip body = False
  | "/archive/" `T.isInfixOf` body && "github.com/" `T.isInfixOf` body = False
  | ahRepo host `T.isInfixOf` body
      && (pn <> "-${PV}-crates.tar.xz") `T.isInfixOf` body =
      False
  | ahRepo host `T.isInfixOf` body
      && "-crates.tar.xz" `T.isInfixOf` body =
      False
  | dropCrateUris && "CARGO_CRATE_URIS" `T.isInfixOf` body = False
  | "crates.io/api/v1/crates" `T.isInfixOf` body = False
  | otherwise = True

hasCleanGithubSourceLine :: Text -> Bool
hasCleanGithubSourceLine = hasCleanGithubSourceLineFor defaultAssetsHost

hasCleanGithubSourceLineFor :: AssetsHost -> Text -> Bool
hasCleanGithubSourceLineFor host content =
  any
    ( \ln ->
        let s = T.stripStart ln
         in ( "SRC_URI=\"" `T.isPrefixOf` s
                || (not ("SRC_URI" `T.isPrefixOf` s) && "https://github.com/" `T.isPrefixOf` s)
            )
              && "/archive/" `T.isInfixOf` s
              && not (ahRepo host `T.isInfixOf` s)
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
extractGithubSourceArchiveUriFor :: AssetsHost -> Text -> Maybe Text
extractGithubSourceArchiveUriFor host content =
  go (T.lines content)
  where
    go [] = Nothing
    go (ln : rest) =
      case cleanLine ln of
        Nothing -> go rest
        Just u ->
          Just $
            if "->" `T.isInfixOf` u
              then u
              else case rest of
                (n : _)
                  | "->" `T.isPrefixOf` T.strip n ->
                      T.strip (u <> " " <> T.strip n)
                _ -> u
    cleanLine ln
      | ahRepo host `T.isInfixOf` ln = Nothing
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

-- | Drop @GIT_CRATES@ entries whose crate is a git remote reached only through
-- windows-only (or wasm-only) target tables of the supplied Cargo.toml bodies.
stripWindowsOnlyGitCrates :: Text -> [Text] -> Text -> Text
stripWindowsOnlyGitCrates lockBody tomlBodies ebuild =
  let winNames =
        nubOrd $
          concat
            [ names
            | body <- tomlBodies,
              Right names <- [windowsOnlyDepNames body]
            ]
      gitNames = parseGitPackageNames lockBody
      dropNames = [n | n <- gitNames, n `elem` winNames]
   in if null dropNames
        then ebuild
        else filterGitCratesNames dropNames ebuild

filterGitCratesNames :: [Text] -> Text -> Text
filterGitCratesNames dropNames content =
  let lns = T.lines content
      (pre, post) = break isGitCratesStart lns
   in case post of
        [] -> content
        (first : rest0)
          | isAssocArrayStart first ->
              let (mid, rest1) = break isAssocArrayEnd rest0
               in case rest1 of
                    (closeLn : rest2) ->
                      let kept = filterGitCratesBlock dropNames (first : mid <> [closeLn])
                       in T.unlines (pre <> kept <> rest2)
                    [] -> content
          | isCompleteAssignment first ->
              T.unlines (pre <> [rewriteGitCratesLine dropNames first] <> rest0)
          | otherwise ->
              let (mid, rest1) = break lineClosesQuote rest0
               in case rest1 of
                    (closeLn : rest2) ->
                      let kept = filterGitCratesBlock dropNames (first : mid <> [closeLn])
                       in T.unlines (pre <> kept <> rest2)
                    [] -> content
  where
    isGitCratesStart ln =
      let s = T.stripStart ln
       in "GIT_CRATES=" `T.isPrefixOf` s
            || "declare -A GIT_CRATES=" `T.isPrefixOf` s
    isAssocArrayStart ln =
      "declare -A GIT_CRATES=" `T.isPrefixOf` T.stripStart ln
        || "GIT_CRATES=(" `T.isPrefixOf` T.stripStart ln
    isAssocArrayEnd ln = T.strip ln == ")"
    isCompleteAssignment ln =
      let s = T.strip ln
          afterEq = T.drop 1 (T.dropWhile (/= '=') s)
       in T.length afterEq >= 2 && T.head afterEq == '"' && T.count "\"" afterEq >= 2
    lineClosesQuote ln =
      let t = T.stripEnd ln
       in not (T.null t) && T.last t == '"'

rewriteGitCratesLine :: [Text] -> Text -> Text
rewriteGitCratesLine dropNames ln =
  T.unlines (filterGitCratesBlock dropNames [ln])

filterGitCratesBlock :: [Text] -> [Text] -> [Text]
filterGitCratesBlock dropNames block =
  [ ln
  | ln <- block,
    let stripped = T.strip ln
     in not (any (`gitCratesEntryName` stripped) dropNames)
  ]

gitCratesEntryName :: Text -> Text -> Bool
gitCratesEntryName name ln =
  let t = T.dropWhile (\c -> c == '\t' || c == ' ') ln
   in (name <> ";") `T.isPrefixOf` t
        || ("[" <> name <> "]=") `T.isPrefixOf` t
        || ("[" <> name <> "] =") `T.isPrefixOf` t

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
-- Removes every duplicate direct assignment so the body has exactly one.
ensureRustMinVer :: Text -> Text -> Either Text Text
ensureRustMinVer ver content =
  case normalizeRustVersion ver of
    Nothing -> Left ("invalid RUST_MIN_VER: " <> ver)
    Just norm ->
      let line = "RUST_MIN_VER=\"" <> norm <> "\""
          lns = T.lines content
          (pre, post) = break isRustMin lns
          restWithout = filter (not . isRustMin) (drop 1 post)
       in case post of
            (_old : _) -> Right (T.unlines (pre <> [line] <> restWithout))
            [] ->
              case findLastInheritIdx lns of
                Nothing -> Right (T.unlines (lns <> ["", line]))
                Just idx ->
                  let (before, after) = splitAt (idx + 1) lns
                      (blanks, rest) = span T.null after
                   in Right (T.unlines (before <> blanks <> [line] <> rest))
  where
    isRustMin ln = "RUST_MIN_VER=" `T.isPrefixOf` T.stripStart ln

-- | Value of the first @KEY=\"...\"@ assignment, if present.
parseQuotedAssignment :: Text -> Text -> Maybe Text
parseQuotedAssignment key content =
  case [ln | ln <- T.lines content, prefix `T.isPrefixOf` T.stripStart ln] of
    (ln : _) ->
      let rhs = T.drop (T.length prefix) (T.stripStart ln)
       in Just (stripSurroundingQuotes (T.strip rhs))
    [] -> Nothing
  where
    prefix = key <> "="

-- | Replace or insert @KEY=\"value\"@. Inserts after an existing @RUSTY_V8_VER@,
-- else @RUST_MIN_VER@, else last @inherit@, else at the end.
ensureQuotedAssignment :: Text -> Text -> Text -> Text
ensureQuotedAssignment key value content =
  let line = key <> "=\"" <> value <> "\""
      lns = T.lines content
      isKey ln = (key <> "=") `T.isPrefixOf` T.stripStart ln
      (pre, post) = break isKey lns
      restWithout = filter (not . isKey) (drop 1 post)
   in case post of
        (_old : _) -> T.unlines (pre <> [line] <> restWithout)
        [] ->
          let insertAfter p =
                case findLastPrefixIdx p lns of
                  Nothing -> Nothing
                  Just idx ->
                    let (before, after) = splitAt (idx + 1) lns
                        (blanks, rest) = span T.null after
                     in Just (T.unlines (before <> blanks <> [line] <> rest))
           in case insertAfter "RUSTY_V8_VER="
                <|> insertAfter "RUST_MIN_VER=" of
                Just t -> t
                Nothing ->
                  case findLastInheritIdx lns of
                    Nothing -> T.unlines (lns <> ["", line])
                    Just idx ->
                      let (before, after) = splitAt (idx + 1) lns
                          (blanks, rest) = span T.null after
                       in T.unlines (before <> blanks <> [line] <> rest)

findLastPrefixIdx :: Text -> [Text] -> Maybe Int
findLastPrefixIdx p lns =
  case [i | (i, ln) <- zip [0 ..] lns, p `T.isPrefixOf` T.stripStart ln] of
    [] -> Nothing
    xs -> Just (last xs)

-- | Write @RUSTY_V8_VER@ and rusty-v8 SRC_URI tag from the lock pin.
-- When clang/rust-toolchain names are @Just@, rewrite those assignments too.
ensureCodexV8Overlay :: Text -> Maybe Text -> Maybe Text -> Text -> Text
ensureCodexV8Overlay = ensureCodexV8OverlayFor defaultAssetsHost

ensureCodexV8OverlayFor ::
  AssetsHost -> Text -> Maybe Text -> Maybe Text -> Text -> Text
ensureCodexV8OverlayFor host ver mClang mRust content =
  let withVer = ensureQuotedAssignment "RUSTY_V8_VER" ver content
      withUri = rewriteRustyV8AssetsTagFor host withVer
      withClang = maybe withUri (\c -> ensureQuotedAssignment "CLANG_DIST" c withUri) mClang
   in maybe withClang (\r -> ensureQuotedAssignment "RUST_TC_DIST" r withClang) mRust

-- | Keep rusty-v8 download tags on @${RUSTY_V8_VER}@ (never @{pn}-${PV}@).
rewriteRustyV8AssetsTagFor :: AssetsHost -> Text -> Text
rewriteRustyV8AssetsTagFor host content =
  case T.splitOn rustyMarker content of
    [] -> content
    prefix : rest -> T.intercalate rustyMarker (prefix : map fixSeg rest)
  where
    rustyMarker = assetsDownloadMarker host <> "rusty-v8-"
    fixSeg seg =
      let newTag = "${RUSTY_V8_VER}"
       in case T.uncons (snd (T.breakOn "/" seg)) of
            Just ('/', afterSlash) ->
              let (filePart, rest1) =
                    T.break (\c -> c == ' ' || c == '"' || c == '\n') afterSlash
                  newFile =
                    if "rusty-v8-" `T.isPrefixOf` filePart
                      then "rusty-v8-${RUSTY_V8_VER}-with-submodules.tar.xz"
                      else filePart
               in newTag <> "/" <> newFile <> rest1
            _ -> newTag <> snd (T.breakOn "/" seg)

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

-- | Floor consumer atom: @>=dev-lang/bun-bin-\<min\>:0@.
bunFloorBdependAtom :: Text -> Text
bunFloorBdependAtom ver = ">=dev-lang/bun-bin-" <> ver <> ":0"

-- | Compile-pin atom: @~dev-lang/bun-bin-\<exact\>@ (this PV, any revision).
bunCompilePinBdependAtom :: Text -> Text
bunCompilePinBdependAtom ver = "~dev-lang/bun-bin-" <> ver

-- | BDEPEND atom for a Bun package key at the given version (min or exact).
bunBdependAtomFor :: PackageKey -> Text -> Text
bunBdependAtomFor key ver
  | isBunCompilePinPackage key = bunCompilePinBdependAtom ver
  | otherwise = bunFloorBdependAtom ver

-- | Version token from a bun-bin BDEPEND atom (@>=…:0@, @=…@, or @~…@).
bunAtomVersion :: Text -> Maybe Text
bunAtomVersion raw =
  let t0 = T.dropWhile (\c -> c == '>' || c == '=' || c == '<' || c == '~') (T.strip raw)
      rest = T.drop (T.length ("dev-lang/bun-bin-" :: Text)) t0
      ver = T.takeWhile (\c -> isDigit c || c == '.') rest
   in if T.null ver then Nothing else Just ver

-- | Portage atom for SBCL floor with subslot and source USE (seed template form).
sbclBdependAtom :: Text -> Text
sbclBdependAtom ver = ">=dev-lisp/sbcl-" <> ver <> ":=[source]"

-- | True when the ebuild text mentions a @dev-lang/go@ dependency atom.
ebuildHasDevLangGoBdepend :: Text -> Bool
ebuildHasDevLangGoBdepend content =
  "dev-lang/go" `T.isInfixOf` content

-- | True when the ebuild already has the exact required go BDEPEND atom.
goBdependMatches :: Text -> Text -> Bool
goBdependMatches goVer content =
  goBdependAtom goVer `T.isInfixOf` content

nodejsBdependMatches :: Text -> Text -> Bool
nodejsBdependMatches ver content =
  nodejsBdependAtom ver `T.isInfixOf` content

sbclBdependMatches :: Text -> Text -> Bool
sbclBdependMatches ver content =
  sbclBdependAtom ver `T.isInfixOf` content

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

-- | Ensure floor @>=dev-lang/bun-bin-\<ver\>:0@ in BDEPEND (and any existing atoms).
ensureBunBdepend :: Text -> Text -> Either Text Text
ensureBunBdepend = ensureBunBdependForFloor

ensureBunBdependForFloor :: Text -> Text -> Either Text Text
ensureBunBdependForFloor ver =
  ensureBdependAtom
    "bun-bin"
    "dev-lang/bun-bin"
    (bunFloorBdependAtom ver)
    ver

-- | Ensure the packaging-mode bun-bin atom for @key@.
ensureBunBdependFor :: PackageKey -> Text -> Text -> Either Text Text
ensureBunBdependFor key ver =
  ensureBdependAtom
    "bun-bin"
    "dev-lang/bun-bin"
    (bunBdependAtomFor key ver)
    ver

-- | First @cd@ target in @src_compile@, with @${S}/@ stripped.
-- Comment lines are ignored. Does not rewrite the ebuild.
parseSrcCompileCd :: Text -> Maybe Text
parseSrcCompileCd content = do
  body <- ebuildFunctionBody "src_compile" content
  cdLine <-
    firstJust
      [ T.strip code
      | ln <- T.lines body,
        let stripped = T.strip ln,
        not (T.null stripped),
        not ("#" `T.isPrefixOf` stripped),
        let code = T.takeWhile (/= '#') stripped,
        "cd " `T.isPrefixOf` T.strip code || T.strip code == "cd"
      ]
  let afterCd = T.strip (T.drop 2 (T.strip cdLine))
      token = T.takeWhile (\c -> c /= ' ' && c /= ';' && c /= '&' && c /= '|') afterCd
      unquoted = T.dropAround (\c -> c == '"' || c == '\'') token
      strippedS = fromMaybe unquoted (T.stripPrefix "${S}/" unquoted <|> T.stripPrefix "$S/" unquoted)
  if T.null strippedS then Nothing else Just strippedS
  where
    firstJust [] = Nothing
    firstJust (x : xs)
      | T.null x = firstJust xs
      | otherwise = Just x

-- | Rewrite versioned @bun-\<X.Y.Z\>@ and unversioned command @bun@ in
-- @src_compile@ / @src_test@ to @bun-\<exact\>. Comment text is left unchanged.
rewriteBunExactInvocations :: Text -> Text -> Text
rewriteBunExactInvocations exact content
  | T.null (T.strip exact) = content
  | otherwise =
      mapEbuildFunctionBody "src_compile" rewritePhase $
        mapEbuildFunctionBody "src_test" rewritePhase content
  where
    rewritePhase =
      T.intercalate "\n" . map (rewritePhaseLine exact) . T.splitOn "\n"

rewritePhaseLine :: Text -> Text -> Text
rewritePhaseLine exact ln =
  let stripped = T.dropWhile (\c -> c == ' ' || c == '\t') ln
   in if "#" `T.isPrefixOf` stripped
        then ln
        else
          let (code, hashAndComment) = T.break (== '#') ln
           in rewriteBunCommandTokens exact code <> hashAndComment

rewriteBunCommandTokens :: Text -> Text -> Text
rewriteBunCommandTokens exact = go
  where
    needle = "bun" :: Text
    go t =
      case T.breakOn needle t of
        (before, rest)
          | T.null rest -> t
          | otherwise ->
              let after = T.drop (T.length needle) rest
                  leftOk =
                    T.null before
                      || not (isIdentChar (T.last before))
               in if not leftOk
                    then before <> needle <> go after
                    else case parseAfterBun after of
                      (Versioned leftover) ->
                        before <> "bun-" <> exact <> go leftover
                      Bare leftover ->
                        before <> "bun-" <> exact <> go leftover
                      Skip ->
                        before <> needle <> go after

data AfterBun
  = Versioned Text
  | Bare Text
  | Skip

parseAfterBun :: Text -> AfterBun
parseAfterBun rest =
  case T.uncons rest of
    Just ('-', more) ->
      case T.uncons more of
        Just (c, _)
          | isDigit c ->
              let (ver, leftover) = T.span (\x -> isDigit x || x == '.') more
               in if T.null ver then Skip else Versioned leftover
        _ -> Skip
    Just (c, _)
      | isIdentChar c || c == '.' -> Skip
    _ -> Bare rest

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

ebuildFunctionBody :: Text -> Text -> Maybe Text
ebuildFunctionBody name content =
  case T.breakOn (name <> "()") content of
    (_, rest)
      | T.null rest -> Nothing
      | otherwise ->
          let afterSig = T.drop (T.length name + 2) rest
              afterWs = T.dropWhile (`elem` [' ', '\t', '\n', '\r']) afterSig
           in case T.uncons afterWs of
                Just ('{', bodyAndRest) -> fst <$> splitMatchingBrace bodyAndRest
                _ -> Nothing

mapEbuildFunctionBody :: Text -> (Text -> Text) -> Text -> Text
mapEbuildFunctionBody name f content =
  case T.breakOn (name <> "()") content of
    (before, rest)
      | T.null rest -> content
      | otherwise ->
          let sig = name <> "()"
              afterSig = T.drop (T.length sig) rest
              (ws, afterWs) =
                T.span (`elem` [' ', '\t', '\n', '\r']) afterSig
           in case T.uncons afterWs of
                Just ('{', bodyAndRest) ->
                  case splitMatchingBrace bodyAndRest of
                    Just (body, after) ->
                      before <> sig <> ws <> "{" <> f body <> "}" <> after
                    Nothing -> content
                _ -> content

splitMatchingBrace :: Text -> Maybe (Text, Text)
splitMatchingBrace = go (1 :: Int) []
  where
    go n acc rest
      | n == 0 = Just (T.concat (reverse acc), rest)
      | T.null rest = Nothing
      | otherwise =
          case T.uncons rest of
            Nothing -> Nothing
            Just ('{', xs) -> go (n + 1) (T.singleton '{' : acc) xs
            Just ('}', xs)
              | n == 1 -> Just (T.concat (reverse acc), xs)
              | otherwise -> go (n - 1) (T.singleton '}' : acc) xs
            Just (c, xs) ->
              let (chunk, more) = T.break (\x -> x == '{' || x == '}') xs
               in go n (T.cons c chunk : acc) more

-- | Ensure @>=dev-lisp/sbcl-<floor>:=[source]@ (RDEPEND/BDEPEND body).
-- Replaces every @dev-lisp/sbcl@ atom when present; otherwise inserts BDEPEND.
ensureSbclAtom :: Text -> Text -> Either Text Text
ensureSbclAtom ver =
  ensureBdependAtom
    "sbcl"
    "dev-lisp/sbcl"
    (sbclBdependAtom ver)
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
      let unquoted = stripSurroundingQuotes (T.strip raw)
       in filter (not . T.null) (T.words unquoted)

-- | True when KEYWORDS tokens match exactly (order-insensitive multiset).
keywordsMatch :: [Text] -> Text -> Bool
keywordsMatch expected content =
  let actual = parseKeywordsLine content
   in length expected == length actual
        && all (`elem` actual) expected
        && all (`elem` expected) actual

-- | SLOT assignment value; omitted SLOT is treated as @0@.
parseEbuildSlot :: Text -> Text
parseEbuildSlot content =
  case mapMaybe lineSlot (T.lines content) of
    (s : _) -> s
    [] -> "0"
  where
    mapMaybe f = foldr (\x acc -> case f x of Just y -> y : acc; Nothing -> acc) []
    lineSlot ln =
      let stripped = T.stripStart ln
       in if "SLOT=" `T.isPrefixOf` stripped
            then
              Just
                ( stripSurroundingQuotes
                    (T.strip (T.takeWhile (/= '#') (T.drop (T.length ("SLOT=" :: Text)) stripped)))
                )
            else Nothing

-- | Set or replace a one-line @SLOT=\"…\"@ assignment.
setSlotField :: Text -> Text -> Text
setSlotField slot content =
  let line = "SLOT=\"" <> slot <> "\""
      lns = T.lines content
      (pre, post) = break isSlotLine lns
   in case post of
        [] ->
          case findLastInheritIdx lns of
            Nothing -> T.unlines (lns <> ["", line])
            Just idx ->
              let (before, after) = splitAt (idx + 1) lns
                  (blanks, rest) = span T.null after
               in T.unlines (before <> blanks <> [line] <> rest)
        (_old : rest) -> T.unlines (pre <> [line] <> rest)
  where
    isSlotLine ln = "SLOT=" `T.isPrefixOf` T.stripStart ln

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
