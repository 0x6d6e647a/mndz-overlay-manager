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
    commandTreeSync,
    parseOptionsPure,
    parseOptions,
  )
where

import GHC.Conc (getNumProcessors)
import Options.Applicative
import Process.Priority
  ( IoClass,
    PriorityRequest,
    SettingSource (..),
    checkIoLevel,
    checkNice,
    parseIoClass,
    priorityRequest,
  )
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import Text.Read (readMaybe)

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
      { outdatedRefresh :: Bool,
        outdatedTargets :: [String],
        outdatedExcludeTokens :: [String]
      }
  | Update
      { updateRefresh :: Bool,
        updateTargets :: [String],
        updateExcludeTokens :: [String],
        -- | @--no-compile-cache@ for the gate's smoke runs.
        updateNoCompileCache :: Bool
      }
  | Gencache
      { gencacheTargets :: [String],
        gencacheForce :: Bool,
        gencacheExcludeTokens :: [String]
      }
  | Smoke
      { smokeTargets :: [String],
        smokeExcludeTokens :: [String],
        -- | @--no-compile-cache@.
        smokeNoCompileCache :: Bool,
        -- | @--reset-compile-cache@.
        smokeResetCompileCache :: Bool
      }
  | Eclean
  | GitHubToken
      { githubTokenForce :: Bool
      }
  deriving (Eq, Show)

data Options = Options
  { optConfig :: Maybe FilePath,
    optOverlayPath :: Maybe FilePath,
    optDistfilesPath :: Maybe FilePath,
    optVerbosity :: Verbosity,
    optJobs :: Maybe Int,
    optNoProgress :: Bool,
    optNoColor :: Bool,
    -- | Turn off run metrics recording for this invocation.
    optNoMetrics :: Bool,
    -- | @--nice@ (validated range; combination checked by 'parseOptionsPure').
    optNice :: Maybe Int,
    -- | @--ionice-class@.
    optIoniceClass :: Maybe IoClass,
    -- | @--ionice-level@.
    optIoniceLevel :: Maybe Int,
    -- | 'Nothing' when no subcommand was given (bare / globals-only).
    optCommand :: Maybe Command
  }
  deriving (Eq, Show)

-- | Shared footer for command-scoped help: globals live before the subcommand.
globalsFooter :: String
globalsFooter =
  "Global options (e.g. --config, --overlay-path, --distfiles-path, --jobs) are \
  \accepted before the subcommand. See mndz-overlay-manager --help for the full list."

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

noMetricsParser :: Parser Bool
noMetricsParser =
  switch
    ( long "no-metrics"
        <> help
          "Turn off run metrics recording for this invocation (outdated, \
          \update, gencache, and eclean otherwise record a run and require \
          \GNU /usr/bin/time)"
    )

-- | Integer option reader validated by a shared priority checker.
priorityIntReader :: (Integer -> Either String Int) -> ReadM Int
priorityIntReader check = eitherReader $ \raw -> case readMaybe raw of
  Nothing -> Left ("not an integer: " <> show raw)
  Just n -> check n

niceParser :: Parser (Maybe Int)
niceParser =
  optional $
    option
      (priorityIntReader (checkNice FromCommandLine))
      ( long "nice"
          <> metavar "N"
          <> help
            "Run at absolute nice value N (0-19) instead of the inherited one; \
            \never raises an inherited lower priority (config: nice)"
      )

ioniceClassParser :: Parser (Maybe IoClass)
ioniceClassParser =
  optional $
    option
      (eitherReader (parseIoClass FromCommandLine))
      ( long "ionice-class"
          <> metavar "CLASS"
          <> help
            "Run in I/O scheduling class CLASS (idle|best-effort); best-effort \
            \without --ionice-level takes its level from the nice value \
            \(config: ionice-class)"
      )

ioniceLevelParser :: Parser (Maybe Int)
ioniceLevelParser =
  optional $
    option
      (priorityIntReader (checkIoLevel FromCommandLine))
      ( long "ionice-level"
          <> metavar "N"
          <> help
            "Run at best-effort I/O level N (0-7, 7 lowest); implies \
            \--ionice-class best-effort (config: ionice-level)"
      )

-- | Top-level help note on the priority options.
priorityFooter :: String
priorityFooter =
  "Priority: --nice, --ionice-class and --ionice-level are absolute targets, \
  \not increments, and replace the config keys nice, ionice-class and \
  \ionice-level (any I/O option replaces the whole config I/O setting). The \
  \manager never raises the priority it inherited: a lower inherited priority \
  \is kept with a warning, so --nice 0 leaves an inherited nice value alone. \
  \Container workloads (smoke, materialize, Portage tools) run at the \
  \manager's effective priority, including one inherited from nice or \
  \ionice. I/O priority depends on the disk's I/O scheduler: bfq honours it, \
  \while the none and kyber schedulers (common NVMe defaults) ignore it."

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

distfilesPathParser :: Parser (Maybe FilePath)
distfilesPathParser =
  optional $
    strOption
      ( long "distfiles-path"
          <> metavar "DIR"
          <> help
            "Override manager distfiles cache (default: XDG cache \
            \mndz/overlay-manager/distfiles)"
      )

-- | Whether a command reads the managed Gentoo tree and, if so, whether it
-- forces a sync (@--refresh@). 'Nothing' never resolves or syncs the tree.
commandTreeSync :: Command -> Maybe Bool
commandTreeSync = \case
  Outdated {outdatedRefresh} -> Just outdatedRefresh
  Update {updateRefresh} -> Just updateRefresh
  Gencache {} -> Just False
  Smoke {} -> Just False
  List -> Nothing
  Eclean -> Nothing
  GitHubToken {} -> Nothing

refreshParser :: Parser Bool
refreshParser =
  switch
    ( long "refresh"
        <> help
          "Ignore check-cache entries and perform live upstream check/plan \
          \(writes fresh cache entries when caching is enabled), and sync the \
          \managed Gentoo tree regardless of its age"
    )

excludeTokens :: Parser [String]
excludeTokens =
  concat
    <$> many
      ( option
          (eitherReader readExcludeList)
          ( long "exclude"
              <> metavar "PACKAGES"
              <> help "Exclude package tokens (same form as PACKAGE, repeatable)"
          )
      )

readExcludeList :: String -> Either String [String]
readExcludeList raw =
  case words raw of
    [] -> Left "empty --exclude package list"
    tokens -> Right tokens

excludeFooter :: String
excludeFooter =
  "Quote a whitespace-separated list, e.g. --exclude 'a b', or repeat \
  \the option, e.g. --exclude a --exclude b. Replace comma-separated lists with either form. \
  \These packages are removed from the \
  \positional selection, or from the whole inventory when no PACKAGE \
  \arguments are given. An empty selection is an error. "

updateParser :: Parser Command
updateParser =
  Update
    <$> refreshParser
    <*> many
      ( strArgument
          ( metavar "PACKAGE..."
              <> help
                "Package targets as category/package or an unambiguous package \
                \name; omit to update all packages that need work"
          )
      )
    <*> excludeTokens
    <*> switch
      ( long "no-compile-cache"
          <> help
            "Run the smoke gate's runs without the per-package compile cache \
            \(as smoke --no-compile-cache does)"
      )

gencacheParser :: Parser Command
gencacheParser =
  Gencache
    <$> many
      ( strArgument
          ( metavar "PACKAGE..."
              <> help
                "Package targets as category/package or an unambiguous package \
                \name; omit to regenerate cache for all packages"
          )
      )
    <*> switch
      ( long "force"
          <> help
            "Regenerate md5-cache for every selected package even when \
            \_md5_ already matches (required to overwrite mismatches)"
      )
    <*> excludeTokens

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

outdatedParser :: Parser Command
outdatedParser =
  Outdated
    <$> refreshParser
    <*> many
      ( strArgument
          ( metavar "PACKAGE..."
              <> help
                "Package targets as category/package or an unambiguous package \
                \name; omit to check all discovered packages"
          )
      )
    <*> excludeTokens

outdatedInfo :: ParserInfo Command
outdatedInfo =
  info
    outdatedParser
    ( fullDesc
        <> progDesc "Report packages with newer upstream versions"
        <> footer
          ( "Check discovered packages against their update sources and print \
            \outdated lines to stdout. PACKAGE may be category/package or an \
            \unambiguous package name. With no PACKAGE arguments, check all \
            \discovered packages. Empty inventory is an error. Successful checks \
            \are cached briefly (see check-cache-ttl); use --refresh to force \
            \live network checks and a Gentoo tree sync. "
              <> excludeFooter
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
            \with tree-lane gaps). Uses the shared check cache when valid; \
            \--refresh forces live fetch/plan and a Gentoo tree sync. \
            \Every update is smoke-tested in a clean container (one run per \
            \lane ceiling, the checks of smoke) before anything about it is \
            \published or committed; a unit that fails is held under the cache \
            \and rolled back. Each successful update is committed and the \
            \overlay is pushed to its upstream; the overlay and assets branches \
            \must be in sync with their upstreams first. --no-compile-cache runs \
            \the gate's smoke runs without the per-package compile cache. \
            \Needs Docker Engine 28.0 or newer with the containerd image store \
            \when any package needs work. "
              <> excludeFooter
              <> globalsFooter
          )
    )

gencacheInfo :: ParserInfo Command
gencacheInfo =
  info
    gencacheParser
    ( fullDesc
        <> progDesc "Generate or repair Portage md5-cache for the overlay"
        <> footer
          ( "Regenerate metadata/md5-cache (md5-dict) via Portage egencache and \
            \create one GPG-signed overlay commit when cache paths change. \
            \PACKAGE may be category/package or an unambiguous package name. \
            \With no PACKAGE arguments, regenerate cache for all packages that \
            \have ebuilds. Without --force, matching packages are skipped and \
            \_md5_ mismatches hard-fail (use --force to overwrite). "
              <> excludeFooter
              <> globalsFooter
          )
    )

smokeParser :: Parser Command
smokeParser =
  Smoke
    <$> many
      ( strArgument
          ( metavar "PACKAGE..."
              <> help
                "Package targets as category/package or an unambiguous package \
                \name; omit to test all discovered packages"
          )
      )
    <*> excludeTokens
    <*> switch
      ( long "no-compile-cache"
          <> help
            "Run without the per-package compile cache: no cache volume is \
            \mounted, ccache is off, and the Go, configure, and Zig caches \
            \stay at Portage's per-build defaults"
      )
    <*> switch
      ( long "reset-compile-cache"
          <> help
            "Delete the selected packages' compile caches before their runs \
            \(other packages' caches are kept)"
      )

smokeInfo :: ParserInfo Command
smokeInfo =
  info
    smokeParser
    ( fullDesc
        <> progDesc "Install and check overlay packages in a clean container"
        <> footer
          ( "Install every on-disk version of each selected package in a fresh \
            \Docker container with Portage's sandboxes on, then run the \
            \package's checks. Runs happen one at a time; --jobs sets the build \
            \parallelism inside the container (MAKEOPTS), not the number of \
            \runs. PACKAGE may be category/package or an unambiguous package \
            \name. With no PACKAGE arguments, test all discovered packages. \
            \Prints one result line per run and exits 1 when any run fails. \
            \Builds reuse the package's compile cache (ccache, Go, configure, \
            \and Zig results) in the Docker volume mndz-smoke-compile-cache; \
            \--no-compile-cache runs without it and --reset-compile-cache \
            \empties it for the selected packages first. \
            \Needs Docker Engine 28.0 or newer with the containerd image store. "
              <> excludeFooter
              <> globalsFooter
          )
    )

ecleanInfo :: ParserInfo Command
ecleanInfo =
  info
    (pure Eclean)
    ( fullDesc
        <> progDesc "Clean the manager private distfiles cache"
        <> footer
          ( "Delete the manager private Portage distfiles cache used by update \
            \(default under XDG cache mndz/overlay-manager/distfiles). Does not \
            \clean system Portage distfiles (/var/cache/distfiles); refuse if \
            \the effective path is the system DISTDIR. Override with global \
            \--distfiles-path before the subcommand. No subcommand-local flags. "
              <> globalsFooter
          )
    )

githubTokenParser :: Parser Command
githubTokenParser =
  GitHubToken
    <$> switch
      ( long "force"
          <> help
            "Replace an existing github-token key after a successful probe \
            \(migrate plaintext or rotate the wrapped PAT)"
      )

githubTokenInfo :: ParserInfo Command
githubTokenInfo =
  info
    githubTokenParser
    ( fullDesc
        <> progDesc "Store an encrypted GitHub token in the overlay-manager configuration"
        <> footer
          ( "Prompt on a controlling TTY (no echo) for a fine-grained GitHub PAT \
            \(github_pat_ only) scoped to the assets repository with Contents: write, \
            \probe GitHub, then prompt twice for a wrapping password. Writes a mndz1. \
            \ciphertext envelope into github-token (mode 0600) without putting secrets \
            \on the command line. Requires assets-path whose origin is github.com \
            \owner/repo. Refuses an existing github-token key unless --force is given. \
            \Does not validate the overlay. "
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
          <> command "gencache" gencacheInfo
          <> command "smoke" smokeInfo
          <> command "eclean" ecleanInfo
          <> command "github-token" githubTokenInfo
          <> metavar "COMMAND"
      )

optionsParser :: Parser Options
optionsParser = do
  optConfig <- configParser
  optOverlayPath <- overlayPathParser
  optDistfilesPath <- distfilesPathParser
  optVerbosity <- verbosityParser
  optJobs <- jobsParser
  optNoProgress <- noProgressParser
  optNoColor <- noColorParser
  optNoMetrics <- noMetricsParser
  optNice <- niceParser
  optIoniceClass <- ioniceClassParser
  optIoniceLevel <- ioniceLevelParser
  optCommand <- commandParser
  pure Options {..}

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc "mndz-overlay-manager - Gentoo overlay management tool"
        <> header "mndz-overlay-manager - manage your mndz Gentoo overlay"
        <> footer priorityFooter
    )

-- | Parse @args@ and the command-line priority request. Invalid option
-- combinations (idle with a level) are usage errors.
parseOptionsPure :: [String] -> ParserResult (Options, PriorityRequest)
parseOptionsPure args =
  execParserPure defaultPrefs parserInfo args >>= \opts ->
    case priorityRequest FromCommandLine (optNice opts) (optIoniceClass opts) (optIoniceLevel opts) of
      Right request -> pure (opts, request)
      Left err -> Failure (parserFailure defaultPrefs parserInfo (ErrorMsg err) mempty)

-- | 'parseOptionsPure' on the process arguments; usage errors exit non-zero.
parseOptions :: IO (Options, PriorityRequest)
parseOptions = getArgs >>= handleParseResult . parseOptionsPure

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
