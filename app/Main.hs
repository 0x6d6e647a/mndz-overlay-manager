module Main (main) where

import CLI.Parser (Command (..), Options (..), parserInfo, showHelp)
import Logging.Bootstrap (bootstrapLogger, runWithLogger)
import Options.Applicative (execParser)

main :: IO ()
main = runWithLogger bootstrapLogger $ do
  opts <- execParser parserInfo
  case optCommand opts of
    Help -> showHelp
    _    -> pure ()
  -- TODO: config loading + dispatch for other commands
  pure ()
