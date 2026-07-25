-- | Thin process/command seam for production adapters.
--
-- Domain @*Ops@ records stay the orchestration inject point; this module
-- supplies a uniform request/result runner so production process bodies can be
-- Unit-heated with scripted fakes (no live PATH tools).
module Update.Process
  ( ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
    CommandRunner,
    productionCommandRunner,
  )
where

import System.Exit (ExitCode)
import System.Process
  ( CreateProcess (..),
    proc,
    readCreateProcessWithExitCode,
    shell,
  )

-- | How to invoke the process: argv exec or shell string.
data ProcessMode
  = -- | @proc cmd args@
    ExecCmd
      { pmCmd :: FilePath,
        pmArgs :: [String]
      }
  | -- | @shell cmd@ (ebuild-style)
    ShellCmd
      { pmShell :: String
      }
  deriving (Eq, Show)

-- | Process invocation request.
data ProcessRequest = ProcessRequest
  { prMode :: ProcessMode,
    prCwd :: Maybe FilePath,
    prEnv :: Maybe [(String, String)],
    prStdin :: String
  }
  deriving (Eq, Show)

-- | Captured process result.
data ProcessResult = ProcessResult
  { prExitCode :: ExitCode,
    prStdout :: String,
    prStderr :: String
  }
  deriving (Eq, Show)

-- | Injectable process runner.
type CommandRunner = ProcessRequest -> IO ProcessResult

-- | Production runner mapping to @readCreateProcessWithExitCode@.
productionCommandRunner :: CommandRunner
productionCommandRunner req = do
  let base = case prMode req of
        ExecCmd cmd args -> proc cmd args
        ShellCmd cmd -> shell cmd
      cp =
        base
          { cwd = prCwd req,
            env = prEnv req
          }
  (code, out, err) <- readCreateProcessWithExitCode cp (prStdin req)
  pure
    ProcessResult
      { prExitCode = code,
        prStdout = out,
        prStderr = err
      }
