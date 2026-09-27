{-# LANGUAGE OverloadedStrings #-}

-- | Gas Town Dolt floor and Beads version-gate parse, and the ebuild rewrite
-- applied before overlay mutation.
module Update.Gastown.Gates
  ( prepareGastownEbuild,
    isGastownKey,
  )
where

import Data.Char (isAlpha, isDigit, isSpace)
import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Overlay.Version (comparePV, parseEbuildVersion)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Update.Types (PackageKey (..))

-- | Last parsed Beads window. @Nothing@ maximum means no maximum.
data BeadsWindow = BeadsWindow
  { bwMin :: Text,
    bwMax :: Maybe Text
  }
  deriving (Eq, Show)

data BeadsShape
  = BeadsFloor Text
  | BeadsCeiling Text
  deriving (Eq, Show)

data ParsedGates = ParsedGates
  { pgDolt :: Text,
    pgShape :: BeadsShape
  }
  deriving (Eq, Show)

-- | @dev-util/gastown@ is the only package whose apply reads these gates.
isGastownKey :: PackageKey -> Bool
isGastownKey (PackageKey "dev-util/gastown") = True
isGastownKey _ = False

operatorPin :: Text
operatorPin = "1.0.4"

-- | Read the tag checkout and rewrite the to-be-written ebuild.
--
-- The second component is a stdout notice when the recorded Beads window
-- changed. 'Nothing' means the windows match and no notice is printed.
prepareGastownEbuild :: FilePath -> Text -> IO (Either Text (Text, Maybe Text))
prepareGastownEbuild root body = do
  parsed <- parseCheckout root
  pure (qualify (parsed >>= rewriteEbuild body))

qualify :: Either Text a -> Either Text a
qualify (Left err)
  | "dev-util/gastown:" `T.isPrefixOf` err = Left err
  | otherwise = Left ("dev-util/gastown: " <> err)
qualify (Right a) = Right a

------------------------------------------------------------------------
-- Checkout parse
------------------------------------------------------------------------

parseCheckout :: FilePath -> IO (Either Text ParsedGates)
parseCheckout root = do
  eDolt <- readSource root "internal/deps/dolt.go"
  eBeads <- readSource root "internal/deps/beads.go"
  eCmd <- readSource root "internal/cmd/beads_version.go"
  eRoot <- readSource root "internal/cmd/root.go"
  pure $ do
    doltBody <- missingFile "internal/deps/dolt.go" eDolt
    dolt <- parseMinDolt doltBody
    beadsBody <- missingGateFile "internal/deps/beads.go" eBeads
    cmdBody <- missingGateFile "internal/cmd/beads_version.go" eCmd
    rootBody <- missingGateFile "internal/cmd/root.go" eRoot
    shape <- parseBeadsShape beadsBody cmdBody rootBody
    pure ParsedGates {pgDolt = dolt, pgShape = shape}

readSource :: FilePath -> FilePath -> IO (Either FilePath Text)
readSource root rel = do
  let path = root </> rel
  exists <- doesFileExist path
  if exists
    then Right <$> TIO.readFile path -- allow-non-ebuild: gastown tag source
    else pure (Left rel)

missingFile :: FilePath -> Either FilePath Text -> Either Text Text
missingFile rel (Left _) =
  Left ("MinDoltVersion is missing in " <> T.pack rel)
missingFile _ (Right body) = Right body

missingGateFile :: FilePath -> Either FilePath Text -> Either Text Text
missingGateFile rel (Left _) =
  Left (unrecognized ("missing " <> T.pack rel))
missingGateFile _ (Right body) = Right body

parseMinDolt :: Text -> Either Text Text
parseMinDolt body =
  case [v | (name, v) <- assignments body, name == "MinDoltVersion"] of
    [v]
      | dotted v -> Right v
      | otherwise ->
          Left "MinDoltVersion is not a dotted numeric version in internal/deps/dolt.go"
    [] -> Left "MinDoltVersion is missing in internal/deps/dolt.go"
    _ -> Left "MinDoltVersion is declared more than once in internal/deps/dolt.go"

parseBeadsShape :: Text -> Text -> Text -> Either Text BeadsShape
parseBeadsShape beads cmd root = do
  statuses <- beadsStatuses beads
  let extra = filter (`notElem` knownStatuses) statuses
  if not (null extra)
    then Left (unrecognized ("new status " <> T.intercalate ", " extra))
    else do
      consts <- beadsVersionConsts beads
      let older = hasOlderMin beads
          newer = hasNewerMax beads
          tooNew = mentionsTooNew beads || mentionsTooNew cmd || mentionsTooNew root
      case consts of
        [("MinBeadsVersion", ver)]
          | not tooNew && older && "BeadsTooOld" `elem` statuses ->
              Right (BeadsFloor ver)
          | otherwise ->
              Left (unrecognized "floor shape is incomplete")
        [("MinBeadsVersion", minV), ("MaxBeadsVersion", maxV)] ->
          ceilingShape minV maxV statuses older newer cmd root
        [("MaxBeadsVersion", _), ("MinBeadsVersion", _)] ->
          Left (unrecognized "Beads version constants are not Min then Max")
        names ->
          Left
            ( unrecognized
                ( "Beads version constants "
                    <> T.intercalate ", " (map fst names)
                )
            )

ceilingShape ::
  Text ->
  Text ->
  [Text] ->
  Bool ->
  Bool ->
  Text ->
  Text ->
  Either Text BeadsShape
ceilingShape minV maxV statuses older newer cmd root = do
  same <- versionsEqual minV maxV
  let hard = commandHardFailsTooNew cmd root
  if same && older && newer && "BeadsTooNew" `elem` statuses && hard
    then Right (BeadsCeiling minV)
    else Left (unrecognized "ceiling shape is incomplete")

commandHardFailsTooNew :: Text -> Text -> Bool
commandHardFailsTooNew cmd root =
  let cmdFlat = flatten cmd
      rootFlat = flatten root
   in T.isInfixOf "casedeps.BeadsTooNew:" cmdFlat
        && T.isInfixOf "returncachedVersionCheckResult" cmdFlat
        && T.isInfixOf "deps.BeadsTooNew" cmdFlat
        && T.isInfixOf
          "ifisUnsupportedNewBeadsVersion(beadsVersionErr){returnbeadsVersionErr}"
          rootFlat

mentionsTooNew :: Text -> Bool
mentionsTooNew = T.isInfixOf "BeadsTooNew"

hasOlderMin :: Text -> Bool
hasOlderMin body =
  T.isInfixOf "CompareVersions(version,MinBeadsVersion)<0" (flatten body)

hasNewerMax :: Text -> Bool
hasNewerMax body =
  T.isInfixOf "CompareVersions(version,MaxBeadsVersion)>0" (flatten body)

knownStatuses :: [Text]
knownStatuses =
  ["BeadsOK", "BeadsNotFound", "BeadsTooOld", "BeadsUnknown", "BeadsTooNew"]

-- | Identifiers in the @BeadsStatus@ const block.
beadsStatuses :: Text -> Either Text [Text]
beadsStatuses body =
  case dropWhile (not . isStatusType) (T.lines body) of
    (_ : rest) ->
      case dropWhile (not . isConstOpen) rest of
        (_ : block) ->
          let (inside, _) = break isConstClose block
              names =
                [ name
                | ln <- inside,
                  Just name <- [statusName ln]
                ]
           in if null names
                then Left (unrecognized "BeadsStatus const block is empty")
                else Right names
        [] -> Left (unrecognized "BeadsStatus const block is missing")
    [] -> Left (unrecognized "BeadsStatus type is missing")
  where
    isStatusType ln = "type BeadsStatus" `T.isInfixOf` ln
    isConstOpen ln = T.strip ln == "const ("
    isConstClose ln = T.strip ln == ")"
    statusName ln =
      case T.words (stripComment ln) of
        (name : _)
          | "Beads" `T.isPrefixOf` name && T.all isIdent name -> Just name
        _ -> Nothing
    isIdent c = isAlpha c || isDigit c || c == '_'

beadsVersionConsts :: Text -> Either Text [(Text, Text)]
beadsVersionConsts body =
  let found =
        [ (name, ver)
        | (name, ver) <- assignments body,
          "BeadsVersion" `T.isSuffixOf` name
        ]
   in case found of
        [] -> Left (unrecognized "MinBeadsVersion is not declared")
        pairs
          | not (all (dotted . snd) pairs) ->
              Left (unrecognized "a Beads version constant is not a dotted numeric string")
          | otherwise -> Right pairs

assignments :: Text -> [(Text, Text)]
assignments body =
  [ (name, ver)
  | ln <- T.lines body,
    Just (name, ver) <- [assignment (stripComment ln)]
  ]

assignment :: Text -> Maybe (Text, Text)
assignment ln =
  case T.breakOn "=" ln of
    (_, "") -> Nothing
    (lhs, rhs0) ->
      let name = T.strip (T.unwords (filter (/= "const") (T.words lhs)))
          rhs = T.strip (T.drop 1 rhs0)
       in case quotedString rhs of
            Just ver
              | not (T.null name) && T.all isIdent name -> Just (name, ver)
            _ -> Nothing
  where
    isIdent c = isAlpha c || isDigit c || c == '_'

quotedString :: Text -> Maybe Text
quotedString t =
  case T.uncons (T.strip t) of
    Just ('"', rest) ->
      let (inside, after) = T.break (== '"') rest
       in case T.uncons after of
            Just ('"', _) -> Just inside
            _ -> Nothing
    _ -> Nothing

stripComment :: Text -> Text
stripComment = T.stripEnd . fst . T.breakOn "//"

dotted :: Text -> Bool
dotted t =
  case T.splitOn "." t of
    parts@(_ : _ : _) -> all (\p -> not (T.null p) && T.all isDigit p) parts
    _ -> False

flatten :: Text -> Text
flatten = T.filter (not . isSpace)

unrecognized :: Text -> Text
unrecognized detail =
  "unrecognized Beads version gate ("
    <> detail
    <> "); a plain update is not sufficient"

------------------------------------------------------------------------
-- Ebuild rewrite
------------------------------------------------------------------------

rewriteEbuild :: Text -> ParsedGates -> Either Text (Text, Maybe Text)
rewriteEbuild body gates = do
  withDolt <- replaceDoltAtom (pgDolt gates) body
  withPin <- applyPin (pgShape gates) withDolt
  syncWindow (windowOf (pgShape gates)) withPin

windowOf :: BeadsShape -> BeadsWindow
windowOf (BeadsFloor ver) = BeadsWindow ver Nothing
windowOf (BeadsCeiling ver) = BeadsWindow ver (Just ver)

applyPin :: BeadsShape -> Text -> Either Text Text
applyPin (BeadsFloor ver) body = do
  newer <- strictlyNewer ver operatorPin
  if newer
    then Left (floorPastPin ver)
    else Right body
applyPin (BeadsCeiling ver) body = do
  same <- versionsEqual ver operatorPin
  if same
    then Right body
    else Left (ceilingNotPin ver)

floorPastPin :: Text -> Text
floorPastPin ver =
  "Beads floor "
    <> ver
    <> " is newer than pin ~dev-util/beads-"
    <> operatorPin
    <> " (window min="
    <> ver
    <> " max=none); a plain update is not sufficient"

ceilingNotPin :: Text -> Text
ceilingNotPin ver =
  "Beads ceiling "
    <> ver
    <> " is not pin ~dev-util/beads-"
    <> operatorPin
    <> " (window min="
    <> ver
    <> " max="
    <> ver
    <> "); a plain update is not sufficient"

replaceDoltAtom :: Text -> Text -> Either Text Text
replaceDoltAtom ver body
  | not (dotted ver) = Left "MinDoltVersion is not a dotted numeric version"
  | not ("dev-db/dolt" `T.isInfixOf` body) =
      Left "ebuild has no dev-db/dolt dependency atom"
  | otherwise =
      let atom = ">=dev-db/dolt-" <> ver
          rewritten = T.unlines (map (rewriteDoltLine atom) (T.lines body))
       in if atom `T.isInfixOf` rewritten
            then Right rewritten
            else Left "could not rewrite the dev-db/dolt dependency atom"

rewriteDoltLine :: Text -> Text -> Text
rewriteDoltLine atom line
  | "dev-db/dolt" `T.isInfixOf` line = go line
  | otherwise = line
  where
    needle = "dev-db/dolt" :: Text
    go t =
      case T.breakOn needle t of
        (_, "") -> t
        (before, rest) ->
          let prefix = T.dropWhileEnd isOp before
              after = dropAtomTail (T.drop (T.length needle) rest)
           in prefix <> atom <> go after
    isOp c = c == '>' || c == '=' || c == '<' || c == '~'
    dropAtomTail t =
      case T.uncons t of
        Just ('-', rs) ->
          let (verTok, rest) = T.span isVer rs
           in if T.null verTok then t else rest
        _ -> t
    isVer c = isDigit c || c == '.' || c == '_' || isAlpha c

syncWindow :: BeadsWindow -> Text -> Either Text (Text, Maybe Text)
syncWindow new body = do
  recorded <- findWindow body
  case recorded of
    Just old
      | old == new -> Right (body, Nothing)
    _ ->
      Right
        ( writeWindow new body,
          Just (windowNotice recorded new)
        )

findWindow :: Text -> Either Text (Maybe BeadsWindow)
findWindow body =
  case filter (T.isInfixOf "gastown-beads-window") (T.lines body) of
    [] -> Right Nothing
    [one] ->
      case parseWindowLine one of
        Just w -> Right (Just w)
        Nothing ->
          Left
            "unrecognized gastown-beads-window record; a plain update is not sufficient"
    _ ->
      Left
        "multiple gastown-beads-window records; a plain update is not sufficient"

parseWindowLine :: Text -> Maybe BeadsWindow
parseWindowLine raw =
  case T.words (T.strip raw) of
    ["#", "gastown-beads-window:", minTok, maxTok] -> do
      mn <- T.stripPrefix "min=" minTok
      mxRaw <- T.stripPrefix "max=" maxTok
      if not (dotted mn)
        then Nothing
        else case mxRaw of
          "none" -> Just (BeadsWindow mn Nothing)
          _
            | dotted mxRaw -> Just (BeadsWindow mn (Just mxRaw))
            | otherwise -> Nothing
    _ -> Nothing

writeWindow :: BeadsWindow -> Text -> Text
writeWindow w body =
  let line = "# gastown-beads-window: " <> renderWindow w
      lns = T.lines body
   in case break (T.isInfixOf "gastown-beads-window") lns of
        (pre, _old : post) ->
          T.unlines (pre <> [line] <> filter (not . T.isInfixOf "gastown-beads-window") post)
        _ ->
          case findIndex (\ln -> "RDEPEND=" `T.isPrefixOf` T.stripStart ln) lns of
            Just idx ->
              let (pre, post) = splitAt idx lns
               in T.unlines (pre <> [line] <> post)
            Nothing -> T.unlines (lns <> [line])

windowNotice :: Maybe BeadsWindow -> BeadsWindow -> Text
windowNotice mOld new =
  "dev-util/gastown: Beads window "
    <> maybe "min=none max=none" renderWindow mOld
    <> " -> "
    <> renderWindow new
    <> "; pin ~dev-util/beads-"
    <> operatorPin
    <> " was kept"

renderWindow :: BeadsWindow -> Text
renderWindow (BeadsWindow mn mmx) =
  "min=" <> mn <> " max=" <> fromMaybe "none" mmx

strictlyNewer :: Text -> Text -> Either Text Bool
strictlyNewer a b =
  case comparePV (parseEbuildVersion a) (parseEbuildVersion b) of
    Just GT -> Right True
    Just _ -> Right False
    Nothing -> Left ("could not compare versions " <> a <> " and " <> b)

versionsEqual :: Text -> Text -> Either Text Bool
versionsEqual a b =
  case comparePV (parseEbuildVersion a) (parseEbuildVersion b) of
    Just EQ -> Right True
    Just _ -> Right False
    Nothing -> Left ("could not compare versions " <> a <> " and " <> b)
