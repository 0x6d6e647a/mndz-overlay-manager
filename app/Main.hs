module Main (main) where

import CLI.Parser (Command (..), Options (..), parserInfo)
import Logging.Bootstrap (bootstrapLogger, runWithLogger)
import Options.Applicative (execParser)
import System.Exit (exitSuccess)

main :: IO ()
main = runWithLogger bootstrapLogger $ do
  opts <- execParser parserInfo
  case optCommand opts of
    Help -> exitSuccess
    _    -> pure ()
  -- TODO: config loading + dispatch for other commands
  pure ()
