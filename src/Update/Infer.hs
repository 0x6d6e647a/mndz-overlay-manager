{-# LANGUAGE OverloadedStrings #-}
module Update.Infer
  ( PackageContext (..)
  , expandEbuild
  , inferSource
  ) where

import Data.Char (isAlphaNum)
import Data.List (find, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Update.Types (UpdateSource (..))

-- | Package context for Level-1 expansion.
data PackageContext = PackageContext
  { ctxPN :: Text  -- ^ package name
  , ctxPV :: Text  -- ^ package version (PV)
  }
  deriving (Eq, Show)

-- | Expand simple assignments and known/variable references in ebuild text.
-- Returns fully expanded text (useful for matching).
expandEbuild :: PackageContext -> Text -> Text
expandEbuild ctx original =
  let assignments = parseAssignments (T.unpack original)
      env0 = builtinEnv ctx
      env = resolveAssignments env0 assignments
  in T.pack (expandString env (T.unpack original))

-- | Infer an update source from ebuild text. Returns Nothing if no match.
inferSource :: PackageContext -> Text -> Maybe UpdateSource
inferSource ctx original =
  let expanded = expandEbuild ctx original
      text = T.unpack expanded
  in case findNpm text of
       Just npm -> Just npm
       Nothing  -> findGitHub (T.unpack (ctxPV ctx)) text

------------------------------------------------------------------------
-- Assignments and expansion
------------------------------------------------------------------------

type Env = Map String String

builtinEnv :: PackageContext -> Env
builtinEnv ctx =
  let pn = T.unpack (ctxPN ctx)
      pv = T.unpack (ctxPV ctx)
      p  = pn <> "-" <> pv
  in Map.fromList
       [ ("PN", pn)
       , ("PV", pv)
       , ("P", p)
       ]

-- | Parse simple @VAR="..."@ or @VAR='...'@ assignments (one per line-ish).
parseAssignments :: String -> [(String, String)]
parseAssignments src =
  mapMaybe parseLine (lines src)
  where
    parseLine line =
      let trimmed = dropWhile (== ' ') line
      in case break (== '=') trimmed of
           (name, '=' : rest)
             | isIdent name
             , Just val <- parseQuoted rest ->
                 Just (name, val)
           _ -> Nothing

    isIdent s =
      not (null s)
        && all (\c -> isAlphaNum c || c == '_') s

    parseQuoted :: String -> Maybe String
    parseQuoted s =
      case dropWhile (== ' ') s of
        '"' : rest -> Just (takeWhile (/= '"') rest)
        '\'' : rest -> Just (takeWhile (/= '\'') rest)
        _ -> Nothing

-- | Resolve assignment values against builtins and previously defined vars.
resolveAssignments :: Env -> [(String, String)] -> Env
resolveAssignments = foldl step
  where
    step env (name, rawVal) =
      let expanded = expandString env rawVal
      in Map.insert name expanded env

-- | Expand @${PN}@, @${PV}@, @${P}@, @${PN//-bin/}@, @${VAR}@ in a string.
expandString :: Env -> String -> String
expandString env = go
  where
    go [] = []
    go ('$' : '{' : rest) =
      case parseRef rest of
        Just (expanded, after) -> expanded ++ go after
        Nothing -> '$' : '{' : go rest
    go (c : cs) = c : go cs

    parseRef :: String -> Maybe (String, String)
    parseRef s =
      case break (== '}') s of
        (inner, '}' : after) ->
          Just (expandRef env inner, after)
        _ -> Nothing

expandRef :: Env -> String -> String
expandRef env ref =
  case break (== '/') ref of
    -- ${PN//-bin/}  pattern: VAR//search/replace
    (var, '/' : '/' : rest) ->
      case break (== '/') rest of
        (search, '/' : replace) ->
          let base = Map.findWithDefault "" var env
          in replaceAll search replace base
        _ -> Map.findWithDefault ("${" <> ref <> "}") ref env
    _ ->
      Map.findWithDefault ("${" <> ref <> "}") ref env

replaceAll :: String -> String -> String -> String
replaceAll search replace = go
  where
    go [] = []
    go str@(c : cs)
      | search `isPrefixOf` str =
          replace ++ go (drop (length search) str)
      | otherwise =
          c : go cs

------------------------------------------------------------------------
-- Matchers
------------------------------------------------------------------------

assetsRepo :: String
assetsRepo = "github.com/0x6d6e647a/mndz-overlay-assets"

findNpm :: String -> Maybe UpdateSource
findNpm text =
  listToMaybe $ mapMaybe matchNpmUrl (extractUrls text)
  where
    matchNpmUrl url
      | "registry.npmjs.org/" `isInfixOf` url =
          let after = dropPrefix "registry.npmjs.org/" url
              -- path is like @scope/pkg/-/pkg-ver.tgz or @scope/pkg
              path = takeWhile (/= ' ') after
              pkg = npmPackageFromPath path
          in if null pkg then Nothing else Just (Npm (T.pack pkg))
      | otherwise = Nothing

    dropPrefix pfx s =
      case findInfix pfx s of
        Just i -> drop (i + length pfx) s
        Nothing -> s

npmPackageFromPath :: String -> String
npmPackageFromPath path =
  -- @scope/name/-/... or name/-/... or @scope/name or name
  case path of
    '@' : rest ->
      let (scope, more) = break (== '/') rest
      in case more of
           '/' : nameRest ->
             let name = takeWhile (\c -> c /= '/' && c /= ' ') nameRest
             in if null name then "" else "@" <> scope <> "/" <> name
           _ -> ""
    _ ->
      takeWhile (\c -> c /= '/' && c /= ' ') path

findGitHub :: String -> String -> Maybe UpdateSource
findGitHub pv text =
  listToMaybe $ mapMaybe (matchGitHubUrl pv) (extractUrls text)
  where
    matchGitHubUrl ver url
      | assetsRepo `isInfixOf` url = Nothing
      | otherwise =
          case parseGitHubReleaseOrTag url of
            Just (owner, repo, tagSeg) ->
              let prefix = stripVersionSuffix ver tagSeg
              in Just GitHub
                   { ghOwner = T.pack owner
                   , ghRepo = T.pack repo
                   , ghTagPrefix = T.pack prefix
                   }
            Nothing -> Nothing

-- | Parse owner/repo and tag path segment from archive or release URLs.
parseGitHubReleaseOrTag :: String -> Maybe (String, String, String)
parseGitHubReleaseOrTag url = do
  after <- stripTo "github.com/" url
  let (owner, rest1) = break (== '/') after
  rest1' <- stripSlash rest1
  let (repo, rest2) = break (== '/') rest1'
  rest2' <- stripSlash rest2
  tagSeg0 <- case rest2' of
    -- archive/refs/tags/TAG...
    'a' : 'r' : 'c' : 'h' : 'i' : 'v' : 'e' : '/' : rest ->
      case stripTo "tags/" rest of
        Just tagPath -> Just (takeWhile notFileSep tagPath)
        Nothing -> Nothing
    -- releases/download/TAG/...
    'r' : 'e' : 'l' : 'e' : 'a' : 's' : 'e' : 's' : '/' : 'd' : 'o' : 'w' : 'n' : 'l' : 'o' : 'a' : 'd' : '/' : rest ->
      Just (takeWhile (/= '/') rest)
    _ -> Nothing
  let tagSeg = stripArchiveSuffix tagSeg0
  if null owner || null repo || null tagSeg
    then Nothing
    else Just (owner, repo, tagSeg)
  where
    notFileSep c = c /= '/' && c /= '?'

-- | GitHub archive URLs append @.tar.gz@ etc. to the tag name.
stripArchiveSuffix :: String -> String
stripArchiveSuffix s =
  foldr stripOne s
    [ ".tar.gz"
    , ".tar.xz"
    , ".tar.bz2"
    , ".tgz"
    , ".zip"
    ]
  where
    stripOne sfx str
      | sfx `isSuffixOf` str = take (length str - length sfx) str
      | otherwise = str

stripSlash :: String -> Maybe String
stripSlash ('/' : xs) = Just xs
stripSlash _ = Nothing

stripTo :: String -> String -> Maybe String
stripTo pfx s =
  case findInfix pfx s of
    Just i -> Just (drop (i + length pfx) s)
    Nothing -> Nothing

findInfix :: String -> String -> Maybe Int
findInfix needle hay =
  find (\i -> needle `isPrefixOf` drop i hay) [0 .. max 0 (length hay - length needle)]

-- | If tag segment ends with the version, the prefix is everything before it.
stripVersionSuffix :: String -> String -> String
stripVersionSuffix ver tag
  | ver `isSuffixOf'` tag = take (length tag - length ver) tag
  | otherwise = tag
  where
    isSuffixOf' sfx str =
      let n = length sfx
          m = length str
      in n <= m && drop (m - n) str == sfx

-- | Rough URL extraction: sequences starting with http(s)://
extractUrls :: String -> [String]
extractUrls = go
  where
    go [] = []
    go s
      | "https://" `isPrefixOf` s =
          let (url, rest) = span isUrlChar s
          in url : go rest
      | "http://" `isPrefixOf` s =
          let (url, rest) = span isUrlChar s
          in url : go rest
      | otherwise = go (drop 1 s)

    isUrlChar c =
      isAlphaNum c
        || c `elem` (":/._~-?&=%+@" :: String)
