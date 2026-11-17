{-# LANGUAGE OverloadedStrings #-}

-- | The smoke compile cache: one Docker volume holding a directory per
-- @category/package@, mounted into that package's run containers through a
-- volume subpath. This module renders the Portage and ccache files that
-- point builds at it, the Go trim suppression check, the helper scripts
-- that inspect, clean, and reset the volume, and the per-run report. Every
-- decision (what to remove, the budget) is made by the pure 'planCleanup'.
module Smoke.CompileCache
  ( -- * Layout
    compileCacheVolume,
    compileCacheDir,
    compileCacheLockPath,
    compileCacheMount,
    CacheUse (..),

    -- * Run configuration
    ccacheConfPath,
    ccacheConf,
    cacheMakeConfLines,
    portageBashrc,
    cacheSetupLines,

    -- * Go trim check
    TrimCheck (..),
    goTrimCheckScript,
    parseTrimCheck,
    renderTrimCheck,
    goVersionScript,
    GoChecks,
    newGoChecks,
    claimGoCheck,

    -- * Configure failures
    configureCacheNote,
    confcacheMarkerScript,

    -- * Per-run report
    CacheReport (..),
    reportScript,
    parseReport,
    reportLine,
    reportWarning,
    recordCacheReport,

    -- * Inspection
    CacheEntry (..),
    Inspection (..),
    inspectScript,
    parseInspection,

    -- * Cleanup planning
    RemovalReason (..),
    CleanupInput (..),
    Apply (..),
    CleanupPlan (..),
    planCleanup,
    effectiveBudget,
    packageCcacheSize,

    -- * Helper container
    HelperCfg (..),
    helperArgs,
    applyScript,
    PrepareCfg (..),
    PrepareResult (..),
    prepareCompileCache,
    recordCleanup,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson ((.=))
import Data.Either (lefts, rights)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Metrics.Core (Metrics (..), SpanId (..))
import Smoke.Tree (shellQuote)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Update.FileLock (LockMode (..), withFileLock)
import Update.Process
  ( CommandRunner,
    Measure (..),
    ProcessMode (..),
    ProcessRequest (..),
    ProcessResult (..),
  )
import Update.Process.Docker
  ( materializePidLabelKey,
    materializeProductLabel,
    materializeRunLabelKey,
  )
import Update.Runtime.Ceilings (KeywordTier (..))
import Update.Types (PackageKey, packageKeyText)

------------------------------------------------------------------------
-- Layout

compileCacheVolume :: String
compileCacheVolume = "mndz-smoke-compile-cache"

-- | Where a run container sees its package's cache.
compileCacheDir :: Text
compileCacheDir = "/var/cache/mndz-compile"

-- | Host lock serializing cleanups: @\<smoke cache\>/compile-cache.lock@.
compileCacheLockPath :: FilePath -> FilePath
compileCacheLockPath smokeCacheDir = smokeCacheDir </> "compile-cache.lock"

-- | @--mount@ value for a run of @key@: only that package's subdirectory.
compileCacheMount :: PackageKey -> String
compileCacheMount key =
  "type=volume,src="
    <> compileCacheVolume
    <> ",dst="
    <> T.unpack compileCacheDir
    <> ",volume-subpath="
    <> T.unpack (packageKeyText key)

-- | Whether a command's runs use the cache, and ccache's size limit (bytes)
-- for each package when they do.
data CacheUse
  = CacheOff
  | CacheOn Integer
  deriving (Eq, Show)

gib :: Integer
gib = 1024 * 1024 * 1024

day :: Integer
day = 24 * 60 * 60

------------------------------------------------------------------------
-- Run configuration

ccacheConfPath :: Text
ccacheConfPath = "/etc/mndz-ccache.conf"

ccacheStatsLog :: Text
ccacheStatsLog = "/var/tmp/mndz-ccache-stats.log"

confcacheMarkerDir :: Text
confcacheMarkerDir = "/var/tmp/mndz-confcache-used"

goEntriesBeforeFile :: Text
goEntriesBeforeFile = "/var/tmp/mndz-go-entries-before"

-- | ccache's size syntax: KiB with a suffix (a bare number means GiB, and
-- 0 means unlimited, so the value is at least @1Ki@).
ccacheSize :: Integer -> Text
ccacheSize bytes = tshow (max 1 (bytes `div` 1024)) <> "Ki"

-- | @/etc/mndz-ccache.conf@: the only file ccache reads, outside the cache.
ccacheConf :: Integer -> Text
ccacheConf size =
  T.unlines
    [ "cache_dir = " <> compileCacheDir <> "/ccache",
      "compiler_check = %compiler% -v",
      "hash_dir = false",
      "base_dir = /var/tmp/portage",
      "umask = 002",
      "max_size = " <> ccacheSize size
    ]

-- | @make.conf@ lines besides @FEATURES@: the ccache settings again as
-- environment (which outranks any configuration file), the stats log, and
-- the run's lane for the configure cache.
cacheMakeConfLines :: Integer -> Maybe KeywordTier -> [Text]
cacheMakeConfLines size tier =
  [ k <> "=\"" <> v <> "\""
  | (k, v) <-
      [ ("CCACHE_DIR", compileCacheDir <> "/ccache"),
        ("CCACHE_CONFIGPATH", ccacheConfPath),
        ("CCACHE_COMPILERCHECK", "%compiler% -v"),
        ("CCACHE_NOHASHDIR", "1"),
        ("CCACHE_BASEDIR", "/var/tmp/portage"),
        ("CCACHE_UMASK", "002"),
        ("CCACHE_MAXSIZE", ccacheSize size),
        ("CCACHE_STATSLOG", ccacheStatsLog),
        ("MNDZ_SMOKE_LANE", laneName tier)
      ]
  ]

laneName :: Maybe KeywordTier -> Text
laneName = \case
  Just Plain -> "plain"
  Just Tilde -> "tilde"
  Nothing -> "none"

-- | @/etc/portage/bashrc@: user phase hooks that run after the eclasses'
-- exports, immediately before each phase function.
--
-- * Go (when an eclass set @GOCACHE@): the package's Go cache, @-trimpath@,
--   and a fresh @trim.txt@ so Go's own trimming skips the cache.
-- * Zig (when @ZIG_GLOBAL_CACHE_DIR@ is set): the package's Zig cache.
-- * @econf@: @--cache-file@ per ABI (the escaped @${ABI}@ expands when
--   @econf@ evaluates @EXTRA_ECONF@), loaded from and saved to the
--   package's per-lane directory, without environment, library, or install
--   program results.
portageBashrc :: Text
portageBashrc =
  T.unlines
    [ "# Generated by mndz-overlay-manager smoke: compile cache hooks.",
      "mndz_cache_hook() {",
      "\tlocal root=" <> compileCacheDir,
      "\taddwrite " <> ccacheStatsLog,
      "\tif [[ -n ${GOCACHE} ]]; then",
      "\t\texport GOCACHE=${root}/go",
      "\t\taddwrite \"${GOCACHE}\"",
      "\t\t[[ \" ${GOFLAGS} \" == *\" -trimpath \"* ]] || export GOFLAGS=\"${GOFLAGS} -trimpath\"",
      "\t\tdate +%s > \"${GOCACHE}/trim.txt.$$\" && mv -f \"${GOCACHE}/trim.txt.$$\" \"${GOCACHE}/trim.txt\"",
      "\tfi",
      "\tif [[ -n ${ZIG_GLOBAL_CACHE_DIR} ]]; then",
      "\t\texport ZIG_GLOBAL_CACHE_DIR=${root}/zig",
      "\t\taddwrite \"${ZIG_GLOBAL_CACHE_DIR}\"",
      "\tfi",
      "}",
      "mndz_confcache_dir() {",
      "\techo \"" <> compileCacheDir <> "/autoconf/${CATEGORY}/${PN}/${MNDZ_SMOKE_LANE:-none}\"",
      "}",
      "pre_src_unpack() { mndz_cache_hook; }",
      "pre_src_prepare() { mndz_cache_hook; }",
      "pre_src_configure() {",
      "\tmndz_cache_hook",
      "\tlocal saved",
      "\tsaved=$(mndz_confcache_dir)",
      "\taddwrite " <> compileCacheDir <> "/autoconf",
      "\taddwrite " <> confcacheMarkerDir,
      "\tmkdir -p \"${T}/mndz-confcache\"",
      "\tif [[ -d ${saved} ]]; then",
      "\t\tcp -f \"${saved}\"/* \"${T}/mndz-confcache/\" 2>/dev/null",
      "\tfi",
      "\t[[ ${EXTRA_ECONF} == *mndz-confcache* ]] || export EXTRA_ECONF=\"${EXTRA_ECONF} --cache-file=${T}/mndz-confcache/\\${ABI:-default}\"",
      "\t: > \"" <> confcacheMarkerDir <> "/${CATEGORY}_${PN}\"",
      "}",
      "post_src_configure() {",
      "\tlocal saved f",
      "\tsaved=$(mndz_confcache_dir)",
      "\tmkdir -p \"${saved}\" || return 0",
      "\tfor f in \"${T}\"/mndz-confcache/*; do",
      "\t\t[[ -f ${f} ]] || continue",
      "\t\tgrep -v -E '^(ac_cv_env_|ac_cv_lib_|ac_cv_path_install[=_])' \"${f}\" > \"${saved}/.${f##*/}.$$\" &&",
      "\t\t\tmv -f \"${saved}/.${f##*/}.$$\" \"${saved}/${f##*/}\"",
      "\tdone",
      "}",
      "pre_src_compile() { mndz_cache_hook; }",
      "pre_src_test() { mndz_cache_hook; }",
      "pre_src_install() { mndz_cache_hook; }"
    ]

-- | Root setup commands: the configure marker directory and the empty stats
-- log (both writable by Portage's build user), the cache's last-used time,
-- and the Go entry count before the run.
cacheSetupLines :: [Text]
cacheSetupLines =
  [ "install -d -m 2775 -o root -g portage " <> confcacheMarkerDir,
    "install -m 0664 -o root -g portage /dev/null " <> ccacheStatsLog,
    "date +%s > " <> compileCacheDir <> "/.last-used",
    goEntryCount <> " > " <> goEntriesBeforeFile
  ]

goEntryCount :: Text
goEntryCount =
  "find " <> compileCacheDir <> "/go -path '" <> compileCacheDir <> "/go/??/*' -name '*-a' 2>/dev/null | wc -l"

------------------------------------------------------------------------
-- Go trim check

data TrimCheck
  = -- | Go kept entries older than its trim limit.
    TrimOk
  | -- | Go trimmed despite a fresh @trim.txt@.
    TrimFail
  | -- | The check could not tell (the control kept entries, or a build failed).
    TrimInconclusive
  deriving (Eq, Show)

-- | Last line of the script's output; anything else is inconclusive.
parseTrimCheck :: Text -> TrimCheck
parseTrimCheck out = case reverse (filter (not . T.null) (map T.strip (T.lines out))) of
  "ok" : _ -> TrimOk
  "fail" : _ -> TrimFail
  _ -> TrimInconclusive

renderTrimCheck :: TrimCheck -> Text
renderTrimCheck = \case
  TrimOk -> "ok"
  TrimFail -> "fail"
  TrimInconclusive -> "inconclusive"

-- | Checks that Go still skips trimming a build cache whose @trim.txt@ is
-- fresh. POSIX sh plus @touch -d \@epoch@; prints @ok@, @fail@, or
-- @inconclusive@ and details on stderr.
--
-- __This tests a fragile mechanism on purpose.__ @trim.txt@ is an
-- undocumented internal of the @go@ command, not a supported interface. Go
-- maintainers call it an internal implementation detail and declined to
-- support this use (golang/go#69565); a configurable trim limit was
-- declined (golang/go#69879); and work aimed at Go 1.28 makes automatic
-- trimming more aggressive (golang/go#81830). If this check starts failing,
-- the fallback is our own standard-library-only @GOCACHEPROG@, not a
-- third-party one.
--
-- Steps: build module A (imports @encoding/json@) into a fresh cache,
-- backdate every entry by 10 days, and copy the cache. Treatment: a fresh
-- @trim.txt@, build an empty module B, and count entries still backdated
-- (must be > 0). Control, on the copy: @trim.txt@ two days old, build B,
-- and count again (must be 0, proving Go would otherwise trim).
goTrimCheckScript :: Text
goTrimCheckScript =
  T.unlines
    [ "set -u",
      "work=$(mktemp -d \"${TMPDIR:-/tmp}/mndz-go-trim.XXXXXX\") || { echo inconclusive; exit 0; }",
      "trap 'chmod -R u+w \"$work\" 2>/dev/null; rm -rf \"$work\"' EXIT",
      "export GOENV=off GOTOOLCHAIN=local GOPROXY=off GOFLAGS= GOWORK=off GO111MODULE=on GOTELEMETRY=off",
      "export GOPATH=\"$work/gopath\" GOMODCACHE=\"$work/gopath/pkg/mod\"",
      "mkmod() {",
      "\tmkdir -p \"$work/$1\" &&",
      "\t\tprintf 'module example.com/%s\\n' \"$1\" > \"$work/$1/go.mod\" &&",
      "\t\tprintf '%s\\n' \"$2\" > \"$work/$1/main.go\"",
      "}",
      "build() { (cd \"$work/$1\" && GOCACHE=\"$2\" go build -o /dev/null .) >&2; }",
      "backdated() { find \"$1\" -path \"$1/??/*\" -name '*-[ad]' ! -newer \"$work/ref\" | wc -l; }",
      "now=$(date +%s)",
      "mkmod a 'package main",
      "",
      "import (",
      "\t\"encoding/json\"",
      "\t\"os\"",
      ")",
      "",
      "func main() { _ = json.NewEncoder(os.Stdout).Encode(1) }' &&",
      "\tmkmod b 'package main",
      "",
      "func main() {}' &&",
      "\tbuild a \"$work/treat\" || { echo inconclusive; exit 0; }",
      "find \"$work/treat\" -path \"$work/treat/??/*\" -name '*-[ad]' -exec touch -d \"@$((now - 10 * 86400))\" {} + &&",
      "\ttouch -d \"@$((now - 5 * 86400))\" \"$work/ref\" &&",
      "\tcp -Rp \"$work/treat\" \"$work/control\" || { echo inconclusive; exit 0; }",
      "echo \"$now\" > \"$work/treat/trim.txt\"",
      "echo \"$((now - 2 * 86400))\" > \"$work/control/trim.txt\"",
      "build b \"$work/treat\" && build b \"$work/control\" || { echo inconclusive; exit 0; }",
      "kept=$(backdated \"$work/treat\")",
      "control=$(backdated \"$work/control\")",
      "echo \"go trim check: $(go env GOVERSION): treatment kept $kept, control kept $control\" >&2",
      "if [ \"$control\" -gt 0 ]; then echo inconclusive",
      "elif [ \"$kept\" -gt 0 ]; then echo ok",
      "else echo fail",
      "fi"
    ]

-- | Prints the installed Go version, or nothing when @go@ is not on @PATH@.
goVersionScript :: String
goVersionScript = "command -v go >/dev/null 2>&1 && GOTOOLCHAIN=local go env GOVERSION || true"

-- | Go versions already checked in this command.
newtype GoChecks = GoChecks (IORef (Set Text))

newGoChecks :: IO GoChecks
newGoChecks = GoChecks <$> newIORef Set.empty

-- | 'True' the first time a version is claimed in this command.
claimGoCheck :: GoChecks -> Text -> IO Bool
claimGoCheck (GoChecks ref) v =
  atomicModifyIORef' ref (\s -> (Set.insert v s, not (Set.member v s)))

------------------------------------------------------------------------
-- Configure failures

-- | Prints the configure cache markers left by the bashrc hook.
confcacheMarkerScript :: String
confcacheMarkerScript = "ls -A " <> T.unpack confcacheMarkerDir <> " 2>/dev/null || true"

-- | Sentence added to a failure in a configure phase that used the cache.
configureCacheNote :: Text
configureCacheNote =
  "a configure cache was in use; rerun with --no-compile-cache to build without the compile cache"

------------------------------------------------------------------------
-- Per-run report

data CacheReport = CacheReport
  { crCcacheHits :: Int,
    crCcacheMisses :: Int,
    -- | Go cache entries added by the run.
    crGoAdded :: Int,
    -- | Go version and result, when this run checked trimming.
    crTrimCheck :: Maybe (Text, TrimCheck)
  }
  deriving (Eq, Show)

-- | Prints ccache's per-run counters (from the stats log) and the Go entry
-- counts before and after the run.
reportScript :: Text
reportScript =
  T.unlines
    [ "CCACHE_CONFIGPATH=" <> ccacheConfPath <> " CCACHE_STATSLOG=" <> ccacheStatsLog <> " ccache --print-log-stats 2>/dev/null | sed 's/^/ccache /'",
      "printf 'go-before %s\\n' \"$(cat " <> goEntriesBeforeFile <> " 2>/dev/null || echo 0)\"",
      "printf 'go-after %s\\n' \"$(" <> goEntryCount <> ")\""
    ]

-- | Lenient: missing counters are 0.
parseReport :: Text -> Maybe (Text, TrimCheck) -> CacheReport
parseReport out trim =
  CacheReport
    { crCcacheHits = ccache "direct_cache_hit" + ccache "preprocessed_cache_hit",
      crCcacheMisses = ccache "cache_miss",
      crGoAdded = max 0 (field ["go-after"] - field ["go-before"]),
      crTrimCheck = trim
    }
  where
    rows = map T.words (T.lines out)
    field key = fromMaybe 0 (lookup key [(init ws, n) | ws@(_ : _ : _) <- rows, Right (n, "") <- [TR.decimal (last ws)]])
    ccache name = field ["ccache", name]

-- | @compile cache: ccache H hits, M misses; go cache +N entries[; go trim
-- check R (V)]@.
reportLine :: CacheReport -> Text
reportLine r =
  "compile cache: ccache "
    <> tshow (crCcacheHits r)
    <> " hits, "
    <> tshow (crCcacheMisses r)
    <> " misses; go cache +"
    <> tshow (crGoAdded r)
    <> " entries"
    <> maybe "" (\(v, c) -> "; go trim check " <> renderTrimCheck c <> " (" <> v <> ")") (crTrimCheck r)

-- | Warning for a failed trim check.
reportWarning :: CacheReport -> Maybe Text
reportWarning r = case crTrimCheck r of
  Just (v, TrimFail) ->
    Just
      ( "Go cache trimming is not suppressed for "
          <> v
          <> ": Go may delete compile cache entries unused for 5 days; builds still succeed but reuse less (see README, smoke compile cache)"
      )
  _ -> Nothing

-- | @compile-cache@ event naming the run's span (the caller's current span)
-- and atom.
recordCacheReport :: Metrics -> Text -> CacheReport -> IO ()
recordCacheReport m atom r = do
  sid <- mCurrentSpan m
  mEvent m "compile-cache" $
    [ "span" .= fmap (\(SpanId i) -> i) sid,
      "atom" .= atom,
      "ccache_hits" .= crCcacheHits r,
      "ccache_misses" .= crCcacheMisses r,
      "go_entries_added" .= crGoAdded r
    ]
      <> concat
        [ ["go_trim_check" .= renderTrimCheck c, "go_version" .= v]
        | Just (v, c) <- [crTrimCheck r]
        ]

------------------------------------------------------------------------
-- Inspection

data CacheEntry = CacheEntry
  { -- | @category/package@.
    ceKey :: Text,
    ceSize :: Integer,
    -- | Epoch seconds from @.last-used@; 'Nothing' counts as never used.
    ceLastUsed :: Maybe Integer
  }
  deriving (Eq, Show)

data Inspection = Inspection
  { inEntries :: [CacheEntry],
    -- | Available and total bytes of the filesystem holding the volume.
    inAvailable :: Integer,
    inTotal :: Integer
  }
  deriving (Eq, Show)

-- | Prints @pkg \<bytes\> \<last-used|-\> \<category/package\>@ per package
-- and one @fs \<available\> \<total\>@ line, for the volume at @/cache@.
inspectScript :: Text
inspectScript =
  T.unlines
    [ "set -eu",
      "cd /cache",
      "for d in */*/; do",
      "\t[ -d \"$d\" ] || continue",
      "\td=${d%/}",
      "\tsize=$(du -sb -- \"$d\" | cut -f1)",
      "\tused=$(cat -- \"$d/.last-used\" 2>/dev/null | tr -cd 0-9)",
      "\tprintf 'pkg %s %s %s\\n' \"$size\" \"${used:--}\" \"$d\"",
      "done",
      "df -B1 --output=avail,size /cache | tail -n 1 | { read -r avail total; printf 'fs %s %s\\n' \"$avail\" \"$total\"; }"
    ]

parseInspection :: Text -> Either Text Inspection
parseInspection out = do
  parsed <- traverse parseLine (filter (not . T.null . T.strip) (T.lines out))
  case rights parsed of
    [(avail, total)] -> Right (Inspection (lefts parsed) avail total)
    _ -> Left "compile cache inspection printed no single filesystem line"
  where
    parseLine l = case T.words l of
      ["pkg", size, used, key]
        | Just s <- nat size,
          Just u <- if used == "-" then Just Nothing else Just <$> nat used,
          [_, _] <- T.splitOn "/" key ->
            Right (Left (CacheEntry key s u))
      ["fs", avail, total]
        | Just a <- nat avail, Just t <- nat total -> Right (Right (a, t))
      _ -> Left ("unexpected compile cache inspection line: " <> l)
    nat t = case TR.decimal t of
      Right (n, "") -> Just n
      _ -> Nothing

------------------------------------------------------------------------
-- Cleanup planning

data RemovalReason
  = RemovedReset
  | RemovedNotInInventory
  | RemovedIdle
  | RemovedOverBudget
  deriving (Eq, Show)

data CleanupInput = CleanupInput
  { -- | Every overlay @category/package@.
    ciInventory :: [Text],
    -- | Packages this command will run.
    ciSelected :: [Text],
    -- | Packages whose caches @--reset-compile-cache@ deletes.
    ciReset :: [Text],
    -- | Epoch seconds.
    ciNow :: Integer,
    -- | @smoke-compile-cache-max-size@.
    ciMaxSize :: Integer,
    ciInspection :: Inspection
  }
  deriving (Eq, Show)

-- | What the apply helper does, in order: remove package directories,
-- create missing ones, write @.last-used@ (so a concurrent cleanup keeps
-- them until the runs start), and prune old Go and Zig entries.
data Apply = Apply
  { apRemove :: [Text],
    apCreate :: [Text],
    apStamp :: [Text],
    apPrune :: Bool
  }
  deriving (Eq, Show)

data CleanupPlan = CleanupPlan
  { cpRemoved :: [(Text, RemovalReason)],
    cpApply :: Apply,
    cpBudget :: Integer,
    cpSizeBefore :: Integer,
    cpSizeAfter :: Integer,
    -- | Set when only caches used within 24 hours keep the total over budget.
    cpWarning :: Maybe Text
  }
  deriving (Eq, Show)

-- | Bytes always left free on the volume's filesystem.
freeReserve :: Integer
freeReserve = 2 * gib

-- | @min(max-size, total + available − 2 GiB)@, floored at 0.
effectiveBudget :: Integer -> Integer -> Integer -> Integer
effectiveBudget maxSize total available = max 0 (min maxSize (total + available - freeReserve))

-- | ccache limit per package: @min(1 GiB, budget)@.
packageCcacheSize :: Integer -> Integer
packageCcacheSize = min gib

-- | Remove, in order: reset packages; packages not in the inventory;
-- caches unused for 30 days; then least recently used caches until the
-- total fits the effective budget, never one used within 24 hours.
planCleanup :: CleanupInput -> CleanupPlan
planCleanup ci =
  CleanupPlan
    { cpRemoved = removed,
      cpApply =
        Apply
          { apRemove = map fst removed,
            apCreate = [k | k <- ciSelected ci, k `notElem` map ceKey kept],
            apStamp = ciSelected ci,
            apPrune = True
          },
      cpBudget = budget,
      cpSizeBefore = before,
      cpSizeAfter = after,
      cpWarning =
        if after > budget
          then
            Just
              ( "compile cache uses "
                  <> tshow after
                  <> " bytes, over its budget of "
                  <> tshow budget
                  <> ", but every remaining cache was used within the last 24 hours"
              )
          else Nothing
    }
  where
    insp = ciInspection ci
    entries = inEntries insp
    before = sum (map ceSize entries)
    budget = effectiveBudget (ciMaxSize ci) before (inAvailable insp)
    recent e = maybe False (\t -> ciNow ci - t < day) (ceLastUsed e)
    idle e = maybe True (\t -> ciNow ci - t > 30 * day) (ceLastUsed e)
    (resetE, rest1) = partitionOn ((`elem` ciReset ci) . ceKey) entries
    (goneE, rest2) = partitionOn ((`notElem` ciInventory ci) . ceKey) rest1
    (idleE, rest3) = partitionOn idle rest2
    lru = sortOn (\e -> (ceLastUsed e, ceKey e)) (filter (not . recent) rest3)
    overE = evict (sum (map ceSize rest3)) lru
    evict _ [] = []
    evict total (e : es)
      | total <= budget = []
      | otherwise = e : evict (total - ceSize e) es
    removedE =
      [(e, RemovedReset) | e <- resetE]
        <> [(e, RemovedNotInInventory) | e <- goneE]
        <> [(e, RemovedIdle) | e <- idleE]
        <> [(e, RemovedOverBudget) | e <- overE]
    removed = [(ceKey e, why) | (e, why) <- removedE]
    kept = [e | e <- rest3, ceKey e `notElem` map ceKey overE]
    after = sum (map ceSize kept)
    partitionOn p xs = (filter p xs, filter (not . p) xs)

------------------------------------------------------------------------
-- Helper container

data HelperCfg = HelperCfg
  { -- | Smoke image tag.
    hcImage :: String,
    hcRunId :: String,
    hcCliPid :: String
  }
  deriving (Eq, Show)

-- | @docker run@ argv (no @docker@ binary): root, no network, the whole
-- volume at @/cache@, the smoke container labels, and only @script@.
helperArgs :: HelperCfg -> Text -> [String]
helperArgs cfg script =
  [ "run",
    "--rm",
    "--network",
    "none",
    "--label",
    materializeProductLabel,
    "--label",
    materializeRunLabelKey <> "=" <> hcRunId cfg,
    "--label",
    materializePidLabelKey <> "=" <> hcCliPid cfg,
    "--mount",
    "type=volume,src=" <> compileCacheVolume <> ",dst=/cache",
    hcImage cfg,
    "sh",
    "-c",
    T.unpack script
  ]

-- | The apply helper's script. Package directories are root:root 0755 and
-- their cache subdirectories root:portage 2775, so a build writes only its
-- caches and never @.last-used@.
applyScript :: Apply -> Text
applyScript ap =
  T.unlines $
    ["set -eu", "cd /cache"]
      <> concat
        [ ["rm -rf -- " <> q k, "rmdir -- " <> q (category k) <> " 2>/dev/null || true"]
        | k <- apRemove ap
        ]
      <> concat
        [ [ "install -d -o root -g root -m 0755 -- " <> q (category k) <> " " <> q k,
            "for s in ccache go autoconf zig; do install -d -o root -g portage -m 2775 -- " <> q k <> "/$s; done"
          ]
        | k <- apCreate ap
        ]
      <> ["date +%s > " <> q (k <> "/.last-used") | k <- apStamp ap]
      <> ( if apPrune ap
             then
               [ "find /cache -path '/cache/*/*/go/??/*' -type f -name '*-[ad]' -mmin +43200 -delete",
                 "find /cache -path '/cache/*/*/zig/*' -type f -mmin +43200 -delete"
               ]
             else []
         )
  where
    q = T.pack . shellQuote . T.unpack
    category = T.takeWhile (/= '/')

data PrepareCfg = PrepareCfg
  { pcRun :: CommandRunner,
    pcHelper :: HelperCfg,
    pcLockPath :: FilePath,
    -- | Epoch seconds.
    pcNow :: IO Integer,
    pcMaxSize :: Integer,
    pcInventory :: [Text],
    -- | Packages with runs in this command.
    pcSelected :: [Text],
    -- | Packages whose caches @--reset-compile-cache@ deletes (the selected
    -- packages, or none).
    pcReset :: [Text],
    -- | Not @--no-compile-cache@.
    pcEnabled :: Bool
  }

data PrepareResult = PrepareResult
  { prUse :: CacheUse,
    -- | The cleanup applied, when the cache is on.
    prPlan :: Maybe CleanupPlan,
    prWarnings :: [Text]
  }
  deriving (Eq, Show)

-- | Before the first run, under the host lock: inspect, plan, and apply
-- (cache on), or only delete the selected caches (@--reset-compile-cache@
-- with the cache off). Any failure is a warning and turns the cache off.
prepareCompileCache :: PrepareCfg -> IO PrepareResult
prepareCompileCache cfg
  | pcEnabled cfg = locked $ do
      inspected <- helper inspectScript
      case inspected >>= parseInspection of
        Left err -> pure (off ("could not inspect the compile cache: " <> err))
        Right insp -> do
          now <- pcNow cfg
          let plan =
                planCleanup
                  CleanupInput
                    { ciInventory = pcInventory cfg,
                      ciSelected = pcSelected cfg,
                      ciReset = pcReset cfg,
                      ciNow = now,
                      ciMaxSize = pcMaxSize cfg,
                      ciInspection = insp
                    }
          applied <- helper (applyScript (cpApply plan))
          pure $ case applied of
            Left err -> off ("could not clean the compile cache: " <> err)
            Right _ ->
              PrepareResult
                { prUse = CacheOn (packageCcacheSize (cpBudget plan)),
                  prPlan = Just plan,
                  prWarnings = maybeToList (cpWarning plan)
                }
  | not (null (pcReset cfg)) = locked $ do
      applied <- helper (applyScript (Apply (pcReset cfg) [] [] False))
      pure $ case applied of
        Left err -> PrepareResult CacheOff Nothing ["could not reset the compile cache: " <> err]
        Right _ -> PrepareResult CacheOff Nothing []
  | otherwise = pure (PrepareResult CacheOff Nothing [])
  where
    off why = PrepareResult CacheOff Nothing ["running without the compile cache: " <> why]
    locked act = do
      r <- try @SomeException (withFileLock ExclusiveLock (pcLockPath cfg) act)
      pure $ case r of
        Right res -> res
        Left e
          | pcEnabled cfg -> off (T.pack (displayException e))
          | otherwise -> PrepareResult CacheOff Nothing ["could not reset the compile cache: " <> T.pack (displayException e)]
    helper script = do
      res <-
        pcRun
          cfg
          ProcessRequest
            { prMode = ExecCmd "docker" (helperArgs (pcHelper cfg) script),
              prCwd = Nothing,
              prEnv = Nothing,
              prStdin = "",
              prMeasure = Timed
            }
      pure $
        if prExitCode res == ExitSuccess
          then Right (T.pack (prStdout res))
          else Left (exitDetail res)
    exitDetail res =
      let detail = T.strip (T.pack (prStderr res))
       in case prExitCode res of
            ExitFailure n -> "helper container exited " <> tshow n <> (if T.null detail then "" else ": " <> lastLine detail)
            ExitSuccess -> detail
    lastLine = fromMaybe "" . lastMay . T.lines
    lastMay xs = if null xs then Nothing else Just (last xs)

-- | @compile-cache.cleanup@ event: sizes before and after, the budget, and
-- the removed packages.
recordCleanup :: Metrics -> CleanupPlan -> IO ()
recordCleanup m plan =
  mEvent
    m
    "compile-cache.cleanup"
    [ "size_before" .= cpSizeBefore plan,
      "size_after" .= cpSizeAfter plan,
      "budget" .= cpBudget plan,
      "packages_removed" .= length (cpRemoved plan),
      "removed" .= map fst (cpRemoved plan)
    ]

------------------------------------------------------------------------

tshow :: (Show a) => a -> Text
tshow = T.pack . show
