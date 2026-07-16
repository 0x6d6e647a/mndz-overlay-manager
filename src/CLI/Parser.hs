{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

module CLI.Parser
  ( Options (..),
    Command (..),
    Verbosity (..),
    ColorMode (..),
    parserInfo,
    showHelp,
    resolveVerbosity,
    resolveColorMode,
    resolveJobs,
  )
where

import GHC.Conc (getNumProcessors)
import Options.Applicative
import System.Environment (lookupEnv)

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
  = Help
  | List
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
    optCommand :: Command
  }
  deriving (Eq, Show)

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
              <> help "Package targets (category/package or unambiguous package name); omit to update all outdated"
          )
      )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "help" (info (pure Help) (progDesc "Show this help message"))
        <> command "list" (info (pure List) (progDesc "List all ebuilds in the overlay"))
        <> command "outdated" (info (pure Outdated) (progDesc "Report packages with newer upstream versions"))
        <> command
          "update"
          ( info
              updateParser
              (progDesc "Update outdated packages (GitMvAndManifest) with signed commits")
          )
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
        <> progDesc "mndz-overlay-mgr - Gentoo overlay management tool"
        <> header "mndz-overlay-mgr - manage your mndz Gentoo overlay"
    )

-- | Render the top-level help text, identical to the @--help@ flag.
--
-- Reuses the same failure/render path that @helper@ triggers, so output,
-- stdout routing, and exit code match @--help@ exactly. Never returns.
showHelp :: IO a
showHelp =
  handleParseResult . Failure $
    parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty

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
