{-# LANGUAGE OverloadedStrings #-}

-- | Per-package smoke checks: types, combinators, and the interpreter.
--
-- A check is named, runs one or more commands in order, and stops at the
-- first command whose expectation fails. Expectations are host functions over
-- the captured outcome. The interpreter takes the exec and network functions
-- as arguments, so it runs against fakes in tests.
module Smoke.Check
  ( -- * Types
    Command (..),
    Outcome (..),
    CheckCtx (..),
    Expect,
    Step (..),
    Check (..),
    SmokeDef (..),
    defaultCheckTimeout,

    -- * Commands
    argv,
    shell,

    -- * Expectations
    exitsWith,
    outputContains,
    outputContainsPv,
    outputLacks,
    firstLineIs,
    allOf,

    -- * Checks
    check,
    step,
    versionCheck,
    helpCheck,
    filesExist,
    networked,
    timeoutAfter,
    smokeDef,

    -- * Interpreter
    CheckIO (..),
    CheckResult (..),
    runChecks,
    failedCheckNames,
    renderCommand,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (EbuildVersion)
import Update.Types (PackageKey)

-- | One command run as the check user. @cmdArgv@ is passed to @timeout@ as
-- is; 'shell' wraps a script in @sh -c@.
data Command = Command
  { cmdArgv :: [Text],
    cmdStdin :: Text,
    cmdEnv :: [(Text, Text)]
  }
  deriving (Eq, Show)

-- | Captured result of one command.
data Outcome = Outcome
  { oExit :: Int,
    oStdout :: Text,
    oStderr :: Text
  }
  deriving (Eq, Show)

-- | The ebuild under test. @ccPv@ is its PV without revision.
data CheckCtx = CheckCtx
  { ccKey :: PackageKey,
    ccVersion :: EbuildVersion,
    ccPv :: Text
  }
  deriving (Eq, Show)

type Expect = CheckCtx -> Outcome -> Either Text ()

data Step = Step
  { stCommand :: CheckCtx -> Command,
    stExpect :: Expect
  }

data Check = Check
  { ckName :: Text,
    ckNetwork :: Bool,
    -- | Limit per command, in seconds.
    ckTimeout :: Int,
    ckSteps :: NonEmpty Step
  }

data SmokeDef = SmokeDef
  { sdChecks :: NonEmpty Check,
    -- | Gentoo atoms installed after the package for use by checks.
    sdExtraAtoms :: [Text],
    -- | Gentoo atoms whose testing keywords are accepted for these runs.
    sdAcceptKeywords :: [Text],
    -- | @package.use@ lines (atom and flags) for these runs.
    sdPackageUse :: [Text],
    -- | Groups the check user joins after the installs, for this
    -- package's runs only.
    sdCheckGroups :: [Text]
  }

defaultCheckTimeout :: Int
defaultCheckTimeout = 60

argv :: [Text] -> Command
argv as = Command {cmdArgv = as, cmdStdin = "", cmdEnv = []}

shell :: Text -> Command
shell script = argv ["sh", "-c", script]

output :: Outcome -> Text
output o = oStdout o <> oStderr o

exitsWith :: Int -> Expect
exitsWith code _ o
  | oExit o == code = Right ()
  | otherwise =
      Left ("exited " <> tshow (oExit o) <> ", expected " <> tshow code <> lastLine o)

outputContains :: Text -> Expect
outputContains needle _ o
  | needle `T.isInfixOf` output o = Right ()
  | otherwise = Left ("output does not contain " <> quote needle <> lastLine o)

-- | Output contains the PV of the ebuild under test.
outputContainsPv :: Expect
outputContainsPv ctx = outputContains (ccPv ctx) ctx

outputLacks :: Text -> Expect
outputLacks needle _ o
  | needle `T.isInfixOf` output o = Left ("output contains " <> quote needle)
  | otherwise = Right ()

-- | First line of standard output, stripped, equals @expected@ with @{PV}@
-- replaced by the PV under test.
firstLineIs :: Text -> Expect
firstLineIs expected ctx o =
  let want = T.replace "{PV}" (ccPv ctx) expected
      got = case T.lines (oStdout o) of
        l : _ -> T.strip l
        [] -> ""
   in if got == want
        then Right ()
        else Left ("first line is " <> quote got <> ", expected " <> quote want)

-- | Every expectation, reporting the first that fails.
allOf :: [Expect] -> Expect
allOf es ctx o = mapM_ (\e -> e ctx o) es

step :: (CheckCtx -> Command) -> Expect -> Step
step = Step

check :: Text -> Step -> [Step] -> Check
check name s ss =
  Check {ckName = name, ckNetwork = False, ckTimeout = defaultCheckTimeout, ckSteps = s :| ss}

-- | @version@: @prog args@ exits 0 and its output contains the PV.
versionCheck :: Text -> [Text] -> Check
versionCheck prog args =
  check "version" (step (const (argv (prog : args))) (allOf [exitsWith 0, outputContainsPv])) []

-- | @help@: @prog --help@ exits 0.
helpCheck :: Text -> Check
helpCheck prog = check "help" (step (const (argv [prog, "--help"])) (exitsWith 0)) []

-- | @files@: every path exists (floor for packages that install no program).
filesExist :: [Text] -> Check
filesExist paths =
  check
    "files"
    ( step
        ( const
            ( argv
                ( [ "sh",
                    "-c",
                    "for f; do test -e \"$f\" || { echo \"missing $f\"; exit 1; }; done",
                    "sh"
                  ]
                    <> paths
                )
            )
        )
        (exitsWith 0)
    )
    []

networked :: Check -> Check
networked c = c {ckNetwork = True}

timeoutAfter :: Int -> Check -> Check
timeoutAfter secs c = c {ckTimeout = secs}

smokeDef :: Check -> [Check] -> SmokeDef
smokeDef c cs =
  SmokeDef
    { sdChecks = c :| cs,
      sdExtraAtoms = [],
      sdAcceptKeywords = [],
      sdPackageUse = [],
      sdCheckGroups = []
    }

------------------------------------------------------------------------
-- Interpreter

-- | Container effects the interpreter needs.
data CheckIO = CheckIO
  { -- | Run a command as the check user, stopped after the limit (seconds).
    cioExec :: Int -> Command -> IO Outcome,
    -- | Attach ('True') or detach the container's network.
    cioNetwork :: Bool -> IO (Either Text ())
  }

data CheckResult = CheckResult
  { crName :: Text,
    -- | 'Nothing' when the check passed.
    crFailure :: Maybe Text,
    -- | Every command run and its output.
    crLog :: Text
  }
  deriving (Eq, Show)

-- | Run every check in order. A failing command stops its check; later
-- checks still run. A network check is attached for its duration only.
runChecks :: CheckIO -> CheckCtx -> NonEmpty Check -> IO [CheckResult]
runChecks cio ctx = traverse one . NE.toList
  where
    one c
      | ckNetwork c = do
          up <- cioNetwork cio True
          case up of
            Left err -> pure (CheckResult (ckName c) (Just ("could not attach the network: " <> err)) "")
            Right () -> do
              r <- steps c
              down <- cioNetwork cio False
              pure $ case down of
                Left err | Nothing <- crFailure r -> r {crFailure = Just ("could not detach the network: " <> err)}
                _ -> r
      | otherwise = steps c
    steps c = go (NE.toList (ckSteps c)) []
      where
        go [] logs = pure (CheckResult (ckName c) Nothing (T.concat (reverse logs)))
        go (s : rest) logs = do
          let cmd = stCommand s ctx
          o <- cioExec cio (ckTimeout c) cmd
          let entry = logEntry cmd o
              verdict
                | oExit o `elem` [124, 137] =
                    Left ("stopped after " <> tshow (ckTimeout c) <> " seconds")
                | otherwise = stExpect s ctx o
          case verdict of
            Right () -> go rest (entry : logs)
            Left why ->
              pure
                CheckResult
                  { crName = ckName c,
                    crFailure = Just (renderCommand cmd <> ": " <> why),
                    crLog = T.concat (reverse (entry : logs))
                  }

failedCheckNames :: [CheckResult] -> [Text]
failedCheckNames rs = [crName r | r <- rs, Just _ <- [crFailure r]]

renderCommand :: Command -> Text
renderCommand = T.unwords . cmdArgv

logEntry :: Command -> Outcome -> Text
logEntry cmd o =
  T.unlines
    [ "$ " <> renderCommand cmd,
      "[exit " <> tshow (oExit o) <> "]",
      "--- stdout",
      oStdout o,
      "--- stderr",
      oStderr o
    ]

lastLine :: Outcome -> Text
lastLine o = case reverse (filter (not . T.null . T.strip) (T.lines (output o))) of
  l : _ -> " (" <> T.strip l <> ")"
  [] -> ""

quote :: Text -> Text
quote t = "\"" <> t <> "\""

tshow :: (Show a) => a -> Text
tshow = T.pack . show
