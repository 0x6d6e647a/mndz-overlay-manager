{-# LANGUAGE OverloadedStrings #-}

-- | Runtime floors read back from ebuild text, for smoke run planning.
--
-- Each reader is the inverse of the atom the manager writes for that
-- ecosystem. All readers are pure; an ebuild that states no floor yields
-- 'Nothing'.
module Smoke.Floors
  ( goFloor,
    nodejsFloor,
    sbclFloor,
    bunFloor,
    cargoFloor,
    pythonSlot,
    ecosystemFloor,
  )
where

import Data.Char (isDigit, isSpace)
import Data.List (sortBy)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion (..), comparePV, parseEbuildVersion)
import Update.Cargo.Msrv (parseRustMinVerFromEbuild)
import Update.EbuildEdit (bunAtomVersion)
import Update.Types (EcosystemSpec (..))

-- | Highest @>=dev-lang/go-\<v\>@ floor (inverse of @goBdependAtom@).
goFloor :: Text -> Maybe EbuildVersion
goFloor = atomFloor "dev-lang/go"

-- | Highest @>=net-libs/nodejs-\<v\>@ floor. A bare major (@22@) compares as
-- @22@.
nodejsFloor :: Text -> Maybe EbuildVersion
nodejsFloor = atomFloor "net-libs/nodejs"

-- | Highest @>=dev-lisp/sbcl-\<v\>@ floor (inverse of @sbclBdependAtom@).
sbclFloor :: Text -> Maybe EbuildVersion
sbclFloor = atomFloor "dev-lisp/sbcl"

-- | @dev-lang/bun-bin@ floor. A compile pin (@~dev-lang/bun-bin-\<v\>@) is its
-- exact version.
bunFloor :: Text -> Maybe EbuildVersion
bunFloor content =
  highest
    [ v
    | (before, after) <- atomOccurrences "dev-lang/bun-bin" content,
      lowerBoundOperator before,
      Just raw <- [bunAtomVersion ("dev-lang/bun-bin-" <> after)],
      Just v <- [numeric raw]
    ]

-- | @RUST_MIN_VER@.
cargoFloor :: Text -> Maybe EbuildVersion
cargoFloor content = parseRustMinVerFromEbuild content >>= numeric

-- | Python slot named by a single-implementation @PYTHON_COMPAT=( python3_NN )@
-- (inverse of @pythonCompatToken@): @python3_13@ is @3.13@.
pythonSlot :: Text -> Maybe Text
pythonSlot content =
  listToMaybe
    [ slot
    | ln <- codeLines content,
      Just rest <- [T.stripPrefix "PYTHON_COMPAT=" (T.stripStart ln)],
      tok <- T.words (T.filter (`notElem` ("()" :: String)) rest),
      Just slot <- [compatSlot tok]
    ]
  where
    compatSlot tok = case T.stripPrefix "python" tok of
      Just digits
        | [maj, mn] <- T.splitOn "_" digits,
          not (T.null maj),
          not (T.null mn),
          T.all isDigit maj,
          T.all isDigit mn ->
            Just (maj <> "." <> mn)
      _ -> Nothing

-- | Floor reader for a lane-gated DepsAndAssets ecosystem. Uv and Pdm name a
-- Python slot instead of a floor and have none here.
ecosystemFloor :: EcosystemSpec -> Text -> Maybe EbuildVersion
ecosystemFloor = \case
  Go _ -> goFloor
  NpmEco -> nodejsFloor
  Bun -> bunFloor
  Cargo {} -> cargoFloor
  Sbcl -> sbclFloor
  Uv _ -> const Nothing
  Pdm _ -> const Nothing

-- | Highest version among @>=\<atom\>-\<v\>@ (or @~@ / @=@) occurrences in
-- non-comment lines. Upper bounds (@<@, @<=@) are not floors.
atomFloor :: Text -> Text -> Maybe EbuildVersion
atomFloor atom content =
  highest
    [ v
    | (before, after) <- atomOccurrences atom content,
      lowerBoundOperator before,
      Just v <- [numeric (versionPrefix after)]
    ]

-- | For each occurrence of @\<atom\>-\<digit\>@: the text before the atom on
-- its line and the text after @\<atom\>-@.
atomOccurrences :: Text -> Text -> [(Text, Text)]
atomOccurrences atom content =
  [ (before, after)
  | ln <- codeLines content,
    (before, match) <- T.breakOnAll needle ln,
    let after = T.drop (T.length needle) match,
    Just (c, _) <- [T.uncons after],
    isDigit c
  ]
  where
    needle = atom <> "-"

lowerBoundOperator :: Text -> Bool
lowerBoundOperator before
  | ">=" `T.isSuffixOf` before = True
  | "<=" `T.isSuffixOf` before = False
  | otherwise = any (`T.isSuffixOf` before) ["~", "="]

versionPrefix :: Text -> Text
versionPrefix = T.dropWhileEnd (== '.') . T.takeWhile (\c -> isDigit c || c == '.')

numeric :: Text -> Maybe EbuildVersion
numeric raw = case parseEbuildVersion raw of
  v@(Numeric (_ : _) _) -> Just v
  _ -> Nothing

highest :: [EbuildVersion] -> Maybe EbuildVersion
highest = listToMaybe . sortBy (flip versionOrder)
  where
    versionOrder a b = fromMaybe EQ (comparePV a b)

codeLines :: Text -> [Text]
codeLines = mapMaybe code . T.lines
  where
    code ln = case T.uncons (T.dropWhile isSpace ln) of
      Just ('#', _) -> Nothing
      _ -> Just ln
