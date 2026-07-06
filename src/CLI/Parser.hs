{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}
module CLI.Parser
  ( Options(..)
  , Command(..)
  , Verbosity(..)
  , parserInfo
  , showHelp
  ) where

import Options.Applicative

data Verbosity
  = Error
  | Warn
  | Info
  | Debug
  deriving (Eq, Show, Enum, Bounded)

data Command
  = Help
  | Other String
  deriving (Eq, Show)

data Options = Options
  { optConfig    :: Maybe FilePath
  , optVerbosity :: Verbosity
  , optCommand   :: Command
  }
  deriving (Eq, Show)

verbosityFromCount :: Int -> Verbosity
verbosityFromCount n =
  toEnum (min (fromEnum (maxBound :: Verbosity)) n)

parseLevel :: String -> Either String Verbosity
parseLevel "error" = Right Error
parseLevel "warn"  = Right Warn
parseLevel "info"  = Right Info
parseLevel "debug" = Right Debug
parseLevel s       = Left $ "Unknown log level: " <> s

verbosityParser :: Parser Verbosity
verbosityParser =
  option (eitherReader parseLevel)
    ( long "log-level"
   <> metavar "LEVEL"
   <> help "Set log level (error|warn|info|debug)"
   <> value Warn
   <> showDefaultWith (const "warn")
    )
    <|> (verbosityFromCount . length <$> many (flag' () (short 'v' <> long "verbose" <> help "Increase verbosity (repeatable)")))
    <|> pure Warn

configParser :: Parser (Maybe FilePath)
configParser =
  optional $ strOption
    ( long "config"
   <> short 'c'
   <> metavar "FILE.toml"
   <> help "Path to overlay-manager.toml (overrides XDG default)"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "help" (info (pure Help) (progDesc "Show this help message"))
   <> metavar "COMMAND"
    )
  <|> pure (Other "default")

optionsParser :: Parser Options
optionsParser = do
  optConfig    <- configParser
  optVerbosity <- verbosityParser
  optCommand   <- commandParser
  pure Options {..}

parserInfo :: ParserInfo Options
parserInfo =
  info (optionsParser <**> helper)
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
