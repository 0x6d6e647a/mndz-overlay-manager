{-# LANGUAGE OverloadedStrings #-}

-- | Operator CPU and I/O scheduling priority: the request read from the
-- command line and config, its resolution against the inherited priority
-- (absolute targets with a floor), and the shell prelude that applies the
-- effective priority to container workload commands.
module Process.Priority
  ( -- * Requests
    IoClass (..),
    IoRequest (..),
    PriorityRequest (..),
    noPriorityRequest,
    SettingSource (..),
    checkNice,
    checkIoLevel,
    parseIoClass,
    priorityRequest,
    mergePriority,

    -- * Resolution
    IoPriority (..),
    InheritedPriority (..),
    EffectivePriority (..),
    Resolved (..),
    defaultEffectivePriority,
    ioRank,
    ioRequestTarget,
    resolvePriority,
    renderIoPriority,
    renderIoRequest,
    floorWarnings,
    priorityEventAttrs,

    -- * Container prelude
    containerNice,
    containerIo,
    priorityToolsNeeded,
    priorityToolCheck,
    priorityPrelude,
    priorityWrap,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson ((.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Data.Text qualified as T

-- | Requestable I/O scheduling classes (no realtime).
data IoClass = ClassIdle | ClassBestEffort
  deriving (Eq, Show)

-- | A requested I/O priority. @'IoBestEffortReq' Nothing@ uses the level the
-- kernel derives from the effective nice value.
data IoRequest = IoIdleReq | IoBestEffortReq (Maybe Int)
  deriving (Eq, Show)

-- | Priority settings from one source. 'Nothing' leaves the inherited value.
data PriorityRequest = PriorityRequest
  { reqNice :: Maybe Int,
    reqIo :: Maybe IoRequest
  }
  deriving (Eq, Show)

noPriorityRequest :: PriorityRequest
noPriorityRequest = PriorityRequest Nothing Nothing

-- | Where a setting came from, for error messages naming the option or key.
data SettingSource = FromCommandLine | FromConfig
  deriving (Eq, Show)

settingName :: SettingSource -> String -> String
settingName FromCommandLine key = "--" <> key
settingName FromConfig key = key

checkRange :: SettingSource -> String -> Integer -> Integer -> Integer -> Either String Int
checkRange src key lo hi n
  | n < lo || n > hi =
      Left (settingName src key <> " must be between " <> show lo <> " and " <> show hi <> " (got " <> show n <> ")")
  | otherwise = Right (fromInteger n)

-- | @nice@: an absolute nice value from 0 to 19. Never clamped.
checkNice :: SettingSource -> Integer -> Either String Int
checkNice src = checkRange src "nice" 0 19

-- | @ionice-level@: a best-effort level from 0 to 7. Never clamped.
checkIoLevel :: SettingSource -> Integer -> Either String Int
checkIoLevel src = checkRange src "ionice-level" 0 7

-- | @ionice-class@: @idle@ or @best-effort@.
parseIoClass :: SettingSource -> String -> Either String IoClass
parseIoClass src = \case
  "idle" -> Right ClassIdle
  "best-effort" -> Right ClassBestEffort
  other -> Left (settingName src "ionice-class" <> " must be idle or best-effort (got " <> show other <> ")")

-- | Combine validated values of one source. A level alone means
-- best-effort; idle takes no level.
priorityRequest :: SettingSource -> Maybe Int -> Maybe IoClass -> Maybe Int -> Either String PriorityRequest
priorityRequest src nice cls level =
  PriorityRequest nice <$> case (cls, level) of
    (Nothing, Nothing) -> Right Nothing
    (Nothing, Just l) -> Right (Just (IoBestEffortReq (Just l)))
    (Just ClassBestEffort, l) -> Right (Just (IoBestEffortReq l))
    (Just ClassIdle, Nothing) -> Right (Just IoIdleReq)
    (Just ClassIdle, Just _) ->
      Left (settingName src "ionice-class" <> " idle takes no " <> settingName src "ionice-level")

-- | @mergePriority cli config@: the command-line nice replaces the config
-- nice, and any command-line I/O setting replaces the config I/O setting.
mergePriority :: PriorityRequest -> PriorityRequest -> PriorityRequest
mergePriority cli config =
  PriorityRequest
    { reqNice = reqNice cli <|> reqNice config,
      reqIo = reqIo cli <|> reqIo config
    }

-- | A thread's I/O priority as the kernel reports it.
data IoPriority
  = -- | No explicit class: best-effort at the level derived from nice.
    IoNone
  | IoRealtime Int
  | IoBestEffort Int
  | IoIdle
  deriving (Eq, Show)

-- | The calling thread's priority before any change.
data InheritedPriority = InheritedPriority
  { ihNice :: Int,
    ihIo :: IoPriority
  }
  deriving (Eq, Show)

-- | The priority the manager runs at and its container workloads follow.
data EffectivePriority = EffectivePriority
  { epNice :: Int,
    epIo :: IoPriority
  }
  deriving (Eq, Show)

-- | Nice 0 with no explicit I/O class: containers need no priority change.
defaultEffectivePriority :: EffectivePriority
defaultEffectivePriority = EffectivePriority 0 IoNone

data Resolved = Resolved
  { rsRequest :: PriorityRequest,
    rsInherited :: InheritedPriority,
    rsEffective :: EffectivePriority,
    -- | The inherited nice was kept instead of a higher-priority target.
    rsNiceFloor :: Bool,
    -- | The inherited I/O priority was kept instead of a higher-priority target.
    rsIoFloor :: Bool,
    -- | I/O priority to set on every thread ('Nothing' leaves it alone).
    rsIoTarget :: Maybe IoPriority
  }
  deriving (Eq, Show)

-- | Rank from highest (0) to lowest priority: realtime 0–7, best-effort 0–7,
-- then idle. 'IoNone' ranks as best-effort at @(nice + 20) / 5@.
ioRank :: Int -> IoPriority -> Int
ioRank nice = \case
  IoRealtime l -> l
  IoBestEffort l -> 8 + l
  IoIdle -> 16
  IoNone -> 8 + derivedLevel nice

derivedLevel :: Int -> Int
derivedLevel nice = (nice + 20) `div` 5

-- | The I/O priority a request targets at the effective nice value.
ioRequestTarget :: Int -> IoRequest -> IoPriority
ioRequestTarget nice = \case
  IoIdleReq -> IoIdle
  IoBestEffortReq (Just l) -> IoBestEffort l
  IoBestEffortReq Nothing -> IoBestEffort (derivedLevel nice)

-- | Absolute targets with a floor: never above the inherited priority. An
-- inherited 'IoNone' ranks by the inherited nice.
resolvePriority :: PriorityRequest -> InheritedPriority -> Resolved
resolvePriority req inh =
  Resolved
    { rsRequest = req,
      rsInherited = inh,
      rsEffective = EffectivePriority effNice effIo,
      rsNiceFloor = maybe False (< ihNice inh) (reqNice req),
      rsIoFloor = ioFloor,
      rsIoTarget = ioTarget
    }
  where
    effNice = maybe (ihNice inh) (max (ihNice inh)) (reqNice req)
    (effIo, ioFloor, ioTarget) = case ioRequestTarget effNice <$> reqIo req of
      Nothing -> (ihIo inh, False, Nothing)
      Just t
        | ioRank effNice t < ioRank (ihNice inh) (ihIo inh) -> (ihIo inh, True, Nothing)
        | otherwise -> (t, False, Just t)

renderIoPriority :: IoPriority -> Text
renderIoPriority = \case
  IoNone -> "none"
  IoRealtime l -> "realtime " <> tshow l
  IoBestEffort l -> "best-effort " <> tshow l
  IoIdle -> "idle"

renderIoRequest :: IoRequest -> Text
renderIoRequest = \case
  IoIdleReq -> "idle"
  IoBestEffortReq Nothing -> "best-effort"
  IoBestEffortReq (Just l) -> "best-effort " <> tshow l

-- | One warning per floor that applied.
floorWarnings :: Resolved -> [Text]
floorWarnings r =
  [ "inherited nice "
      <> tshow (ihNice (rsInherited r))
      <> " is kept instead of the requested "
      <> tshow n
      <> ": the manager never raises its priority"
  | rsNiceFloor r,
    Just n <- [reqNice (rsRequest r)]
  ]
    <> [ "inherited I/O priority "
           <> renderIoPriority (ihIo (rsInherited r))
           <> " is kept instead of the requested "
           <> renderIoRequest io
           <> ": the manager never raises its priority"
       | rsIoFloor r,
         Just io <- [reqIo (rsRequest r)]
       ]

-- | Attributes of the @priority@ run metrics event. Requested values are
-- absent when unset.
priorityEventAttrs :: Resolved -> [Pair]
priorityEventAttrs r =
  ["requested_nice" .= n | Just n <- [reqNice (rsRequest r)]]
    <> ["requested_io" .= renderIoRequest io | Just io <- [reqIo (rsRequest r)]]
    <> [ "effective_nice" .= epNice eff,
         "effective_io" .= renderIoPriority (epIo eff),
         "nice_floor" .= rsNiceFloor r,
         "io_floor" .= rsIoFloor r
       ]
  where
    eff = rsEffective r

------------------------------------------------------------------------
-- Container prelude

-- | Nice target in a container. Containers cannot go below 0.
containerNice :: EffectivePriority -> Int
containerNice = max 0 . epNice

-- | Explicit I/O class a container applies. Realtime cannot be granted to a
-- container, so it is left alone like 'IoNone'.
containerIo :: EffectivePriority -> Maybe IoPriority
containerIo ep = case epIo ep of
  io@(IoBestEffort _) -> Just io
  IoIdle -> Just IoIdle
  IoNone -> Nothing
  IoRealtime _ -> Nothing

-- | Container tools the prelude needs (empty at the default priority).
priorityToolsNeeded :: EffectivePriority -> [Text]
priorityToolsNeeded ep =
  ["nice" | containerNice ep > 0] <> ["ionice" | Just _ <- [containerIo ep]]

-- | Setup command that fails naming the first missing priority tool.
-- 'Nothing' when no tool is needed.
priorityToolCheck :: EffectivePriority -> Maybe Text
priorityToolCheck ep = case priorityToolsNeeded ep of
  [] -> Nothing
  tools ->
    Just . T.intercalate "; " $
      [ "command -v " <> t <> " >/dev/null 2>&1 || { echo '" <> t <> " not found (needed for process priority)' >&2; exit 1; }"
      | t <- tools
      ]

-- | Shell script run as @sh -c script mndz-priority argv...@: set the I/O
-- priority of its own shell, then @exec@ the command under @nice@. Values
-- below the current priority are kept with one line on standard error.
-- 'Nothing' when the effective priority needs no change.
priorityPrelude :: EffectivePriority -> Maybe Text
priorityPrelude ep
  | null (priorityToolsNeeded ep) = Nothing
  | otherwise = Just (T.intercalate "\n" (ioLines <> niceLines))
  where
    target = containerNice ep
    ioLines = case containerIo ep of
      Nothing -> []
      Just io ->
        [ "cur=$(nice 2>/dev/null) || cur=0",
          "io=$(ionice -p $$ 2>/dev/null) || io=",
          "cls=${io%%:*}",
          "lvl=${io##*prio }",
          "case $lvl in ''|*[!0-9]*) lvl= ;; esac",
          "case $cls in",
          "  idle) rank=16 desc=idle ;;",
          "  realtime) if [ -n \"$lvl\" ]; then rank=$lvl desc=\"realtime $lvl\"; else cls=none; fi ;;",
          "  best-effort) if [ -n \"$lvl\" ]; then rank=$((8 + lvl)) desc=\"best-effort $lvl\"; else cls=none; fi ;;",
          "  *) cls=none ;;",
          "esac",
          "if [ \"$cls\" = none ]; then rank=$((8 + (cur + 20) / 5)) desc=none; fi",
          "if [ \"$rank\" -le " <> tshow (ioRank target io) <> " ]; then",
          "  ionice " <> ionArgs io <> " -p $$ || exit 1",
          "else",
          "  echo \"mndz-overlay-manager: keeping I/O priority $desc instead of the requested " <> renderIoPriority io <> "\" >&2",
          "fi"
        ]
    niceLines
      | target > 0 =
          [ "cur=$(nice) || exit 1",
            "if [ \"$cur\" -lt " <> tshow target <> " ]; then exec nice -n $((" <> tshow target <> " - cur)) \"$@\"; fi",
            "if [ \"$cur\" -gt " <> tshow target <> " ]; then echo \"mndz-overlay-manager: keeping nice $cur instead of the requested " <> tshow target <> "\" >&2; fi",
            "exec \"$@\""
          ]
      | otherwise = ["exec \"$@\""]
    ionArgs = \case
      IoIdle -> "-c 3"
      IoBestEffort l -> "-c 2 -n " <> tshow l
      IoRealtime l -> "-c 1 -n " <> tshow l
      IoNone -> "-c 0"

-- | Run @argv@ at the effective priority: unchanged at the default
-- priority, otherwise behind 'priorityPrelude' (which @exec@s it, so no
-- extra process remains).
priorityWrap :: EffectivePriority -> [String] -> [String]
priorityWrap ep argv = case priorityPrelude ep of
  Nothing -> argv
  Just script -> ["sh", "-c", T.unpack script, "mndz-priority"] <> argv

tshow :: (Show a) => a -> Text
tshow = T.pack . show
