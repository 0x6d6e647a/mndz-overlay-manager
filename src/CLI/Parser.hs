{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

module CLI.Parser
  ( Options (..),
    Command (..),
    Verbosity (..),
    ColorMode (..),
    parserInfo,
    showTopLevelHelpExit1,
    resolveVerbosity,
    resolveColorMode,
    resolveJobs,
  )
where

import GHC.Conc (getNumProcessors)
import Options.Applicative
import System.Environment (getProgName, lookupEnv)
import System.Exit (ExitCode (..), exitWith)

data Verbosity
  = Error
  | Warn
  | Info
  | Debug
  deriving (Eq, Show, Enum, Bounded)

-- | Whether ANSI color is enabled for logs and activity chrome.
data ColorMode
  = ColorOn
  | ColorOff
  deriving (Eq, Show)

data Command
  = List
  | Outdated
  | Update [String]
  deriving (Eq, Show)

data Options = Options
  { optConfig :: Maybe FilePath,
    optOverlayPath :: Maybe FilePath,
    optVerbosity :: Verbosity,
    optJobs :: Maybe Int,
    optNoProgress :: Bool,
    optNoColor :: Bool,
    -- | 'Nothing' when no subcommand was given (bare / globals-only).
    optCommand :: Maybe Command
  }
  deriving (Eq, Show)

-- | Shared footer for command-scoped help: globals live before the subcommand.
globalsFooter :: String
globalsFooter =
  "Global options (e.g. --config, --overlay-path, --jobs) are accepted before \
  \the subcommand. See mndz-overlay-manager --help for the full list."

-- | Map @-v@ count to verbosity starting from 'Warn'.
-- Each flag steps Warn → Info → Debug (capped).
verbosityFromCount :: Int -> Verbosity
verbosityFromCount n
  | n <= 0 = Warn
  | n == 1 = Info
  | otherwise = Debug

parseLevel :: String -> Either String Verbosity
parseLevel "error" = Right Error
parseLevel "warn" = Right Warn
parseLevel "info" = Right Info
parseLevel "debug" = Right Debug
parseLevel s = Left $ "Unknown log level: " <> s

-- | Resolve verbosity from optional explicit level and @-v@ count.
-- Explicit @--log-level@ wins over @-v@.
resolveVerbosity :: Maybe Verbosity -> Int -> Verbosity
resolveVerbosity (Just level) _ = level
resolveVerbosity Nothing count = verbosityFromCount count

verbosityParser :: Parser Verbosity
verbosityParser = do
  mLevel <-
    optional $
      option
        (eitherReader parseLevel)
        ( long "log-level"
            <> metavar "LEVEL"
            <> help "Set log level (error|warn|info|debug); overrides -v when set"
        )
  vCount <-
    length
      <$> many
        ( flag'
            ()
            ( short 'v'
                <> long "verbose"
                <> help "Increase verbosity from warn (repeatable: -v info, -vv debug)"
            )
        )
  pure (resolveVerbosity mLevel vCount)

jobsParser :: Parser (Maybe Int)
jobsParser =
  optional $
    option
      auto
      ( long "jobs"
          <> metavar "N"
          <> help "Max concurrent package jobs (default: host processor count)"
      )

noProgressParser :: Parser Bool
noProgressParser =
  switch
    ( long "no-progress"
        <> help "Disable interactive activity indicators"
    )

noColorParser :: Parser Bool
noColorParser =
  switch
    ( long "no-color"
        <> help "Disable ANSI colors in logs and indicators"
    )

configParser :: Parser (Maybe FilePath)
configParser =
  optional $
    strOption
      ( long "config"
          <> short 'c'
          <> metavar "FILE.toml"
          <> help "Path to overlay-manager.toml (overrides XDG default)"
      )

overlayPathParser :: Parser (Maybe FilePath)
overlayPathParser =
  optional $
    strOption
      ( long "overlay-path"
          <> metavar "DIR"
          <> help "Override overlay path from config"
      )

updateParser :: Parser Command
updateParser =
  Update
    <$> many
      ( strArgument
          ( metavar "PACKAGE..."
              <> help
                "Package targets as category/package or an unambiguous package \
                \name; omit to update all packages that need work"
          )
      )

listInfo :: ParserInfo Command
listInfo =
  info
    (pure List)
    ( fullDesc
        <> progDesc "List all ebuilds in the overlay"
        <> footer
          ( "Print one package atom per line (category/package-version) for each \
            \discovered ebuild. Empty inventory is an error. No subcommand-local \
            \flags. "
              <> globalsFooter
          )
    )

outdatedInfo :: ParserInfo Command
outdatedInfo =
  info
    (pure Outdated)
    ( fullDesc
        <> progDesc "Report packages with newer upstream versions"
        <> footer
          ( "Check each discovered package against its update source and print \
            \outdated lines to stdout. Empty inventory is an error. No \
            \subcommand-local flags. "
              <> globalsFooter
          )
    )

updateInfo :: ParserInfo Command
updateInfo =
  info
    updateParser
    ( fullDesc
        <> progDesc "Update outdated packages with signed commits"
        <> footer
          ( "Bump ebuilds, regenerate Manifests, and create signed git commits \
            \for packages that need work. PACKAGE may be category/package or an \
            \unambiguous package name. With no PACKAGE arguments, update all \
            \packages that need work (outdated non-Go packages and Go packages \
            \with tree-lane gaps). "
              <> globalsFooter
          )
    )

commandParser :: Parser (Maybe Command)
commandParser =
  optional $
    hsubparser
      ( command "list" listInfo
          <> command "outdated" outdatedInfo
          <> command "update" updateInfo
          <> metavar "COMMAND"
      )

optionsParser :: Parser Options
optionsParser = do
  optConfig <- configParser
  optOverlayPath <- overlayPathParser
  optVerbosity <- verbosityParser
  optJobs <- jobsParser
  optNoProgress <- noProgressParser
  optNoColor <- noColorParser
  optCommand <- commandParser
  pure Options {..}

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc "mndz-overlay-manager - Gentoo overlay management tool"
        <> header "mndz-overlay-manager - manage your mndz Gentoo overlay"
    )

-- | Print full top-level help (same body as @--help@) and exit with status 1.
--
-- Used when no subcommand is given. Explicit @--help@ still exits 0 via the
-- library helper path.
showTopLevelHelpExit1 :: IO a
showTopLevelHelpExit1 = do
  prog <- getProgName
  let failure = parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty
      (msg, _) = renderFailure failure prog
  -- renderFailure omits a trailing newline; --help via handleParseResult adds one.
  putStrLn msg
  exitWith (ExitFailure 1)

-- | Resolve color mode from @--no-color@ and non-empty @NO_COLOR@.
resolveColorMode :: Bool -> IO ColorMode
resolveColorMode noColorFlag
  | noColorFlag = pure ColorOff
  | otherwise = do
      mNoColor <- lookupEnv "NO_COLOR"
      pure $ case mNoColor of
        Just s | not (null s) -> ColorOff
        _ -> ColorOn

-- | Resolve jobs: explicit positive @--jobs N@, else host processor count.
resolveJobs :: Maybe Int -> IO Int
resolveJobs (Just n)
  | n > 0 = pure n
  | otherwise = pure 1
resolveJobs Nothing = getNumProcessors
