## Purpose

Define the shared on-disk cache of successful outdated-check and runtime-lane plan results used by `outdated` and `update`, including location, schema, TTL, fingerprint validity, disable and refresh semantics, concurrency, and summary logging.

## Requirements

### Requirement: Check cache directory under XDG cache

When the check cache is enabled, the program SHALL store overlay check-cache files under `${XDG_CACHE_HOME}/mndz/overlay-manager/check-cache` when `XDG_CACHE_HOME` is set and non-empty, and under `${HOME}/.cache/mndz/overlay-manager/check-cache` when `XDG_CACHE_HOME` is unset or empty.

#### Scenario: XDG_CACHE_HOME set

- **WHEN** `XDG_CACHE_HOME` is `/tmp/cache` and the check cache is enabled
- **THEN** check-cache files for overlays are stored under `/tmp/cache/mndz/overlay-manager/check-cache`

#### Scenario: XDG_CACHE_HOME unset

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and the check cache is enabled
- **THEN** check-cache files are stored under `/home/op/.cache/mndz/overlay-manager/check-cache`

### Requirement: Per-overlay cache file name is friendly prefix plus path hash

For a resolved absolute overlay path, the program SHALL use a single JSON cache file named `<friendly>-<hash12>.json` in the check-cache directory, where `<friendly>` is a sanitized basename of the absolute overlay path (characters outside `[A-Za-z0-9._-]` replaced, empty result becomes `overlay`) and `<hash12>` is the first twelve hexadecimal characters of a SHA-256 digest of that absolute overlay path. Distinct absolute overlay paths SHALL map to distinct file names.

#### Scenario: Basename and hash disambiguate

- **WHEN** the absolute overlay path is `/home/op/overlays/mndz`
- **THEN** the cache file name starts with a friendly form of `mndz` and ends with a twelve-hex-character hash segment before `.json`

#### Scenario: Same basename different paths

- **WHEN** two overlays have the same directory basename but different absolute paths
- **THEN** they use different check-cache file names because the hash segments differ

### Requirement: Cache schema version one stores latest or plan payloads

A check-cache file SHALL include a schema version field equal to `1` and a map of package keys to entries. Each successful entry SHALL record a checked-at timestamp, a fingerprint, and either a latest-remote payload (remote PV for non-`DepsAndAssets` techniques) or a deps payload (full runtime-lane plan sufficient for apply without re-listing or re-probing upstream). The program SHALL NOT require a separate config key for the cache file path.

#### Scenario: GitMv-style entry has remote PV

- **WHEN** a successful latest-only check for a package is stored
- **THEN** the entry includes a remote PV suitable for comparison and apply without another upstream latest fetch

#### Scenario: Deps entry has runtime-lane plan

- **WHEN** a successful `DepsAndAssets` plan for a package is stored
- **THEN** the entry includes a runtime-lane plan usable by apply without repeating upstream version listing and per-PV probes

### Requirement: Configurable TTL with default five minutes

The program SHALL read optional config key `check-cache-ttl` as a human duration string. When the key is omitted, the effective TTL SHALL be five minutes. A valid duration SHALL be a single non-negative integer coefficient and one unit suffix among seconds, minutes, hours, or days (`s`, `m`, `h`, `d`), case-insensitive (for example `30s`, `5m`, `1h`, `2d`). Invalid duration strings SHALL cause configuration load to fail. A duration of zero (`0` or `0s`) SHALL disable the check cache: the program SHALL NOT read or write check-cache files for that run.

#### Scenario: Default TTL when key omitted

- **WHEN** config omits `check-cache-ttl` and the cache is otherwise usable
- **THEN** entries younger than five minutes may be treated as fresh for TTL purposes

#### Scenario: Custom TTL

- **WHEN** config sets `check-cache-ttl = "1h"`
- **THEN** entries may remain valid for TTL purposes up to one hour of age

#### Scenario: Zero disables cache

- **WHEN** config sets `check-cache-ttl = "0s"`
- **THEN** the program neither reads nor writes check-cache files during that run

#### Scenario: Invalid duration fails config load

- **WHEN** config sets `check-cache-ttl` to a value that is not a single-unit duration (for example `1h30m` or `abc`)
- **THEN** configuration loading fails with an error

### Requirement: Strong fingerprint invalidates stale local state

A cache entry SHALL be used only when its age is within the effective TTL (when the cache is enabled), the operator did not request refresh for the run, and its fingerprint matches the package’s current state: the set of non-live local PVs, a stable identifier of the configured update source, and a content hash of the package’s non-live ebuild file contents and Manifest content when present. When any fingerprint component differs, the program SHALL treat the entry as a miss and perform live check or plan work for that package.

#### Scenario: Local PV change is a miss

- **WHEN** a cache entry exists within TTL but the package’s non-live local PVs differ from the entry fingerprint
- **THEN** the program does not use that entry for remote or plan data

#### Scenario: Ebuild content change is a miss

- **WHEN** a cache entry exists within TTL but the content hash of package ebuilds or Manifest differs
- **THEN** the program does not use that entry for remote or plan data

### Requirement: Never cache fetch or plan failures

The program SHALL NOT write check-cache entries for packages whose check or plan ends in fetch failure or plan failure. Successful outcomes including up-to-date (Ok), ahead-of-upstream, and outdated SHALL be eligible to store when the cache is enabled.

#### Scenario: Fetch error not stored

- **WHEN** upstream fetch fails for a package during `outdated` or `update`
- **THEN** no successful cache entry for that failure outcome is written for reuse as a hit

#### Scenario: Ok packages stored

- **WHEN** a configured package is successfully determined to be up to date and the cache is enabled
- **THEN** an entry for that package may be stored so a later run can skip network for it within TTL

### Requirement: Trust valid cache without re-fetch

When a package has a valid cache entry, `outdated` and `update` SHALL use the cached remote PV or runtime-lane plan for that package’s check or apply planning path and SHALL NOT perform the corresponding upstream latest fetch or upstream list/probe plan network work for that package. Content-fix and Manifest adequacy determinations SHALL still be computed from the current overlay files on disk.

#### Scenario: Valid latest entry skips HTTP latest

- **WHEN** `update` applies a non-deps package with a valid latest cache entry
- **THEN** apply uses the cached remote PV without issuing a new latest-version network fetch for that package

#### Scenario: Valid deps entry skips plan network

- **WHEN** `update` applies a `DepsAndAssets` package with a valid deps plan cache entry
- **THEN** apply uses the cached plan without re-listing upstream versions or re-probing per-PV upstream metadata for planning

### Requirement: Rewrite entry after successful apply

After a package is successfully updated (committed apply success for that package’s work in the run), the program SHALL update that package’s check-cache entry to reflect the post-apply local fingerprint and a non-stale success payload when the cache is enabled, so a subsequent run within TTL need not repeat network discovery solely because the entry still described the pre-apply tree.

#### Scenario: Successful GitMv updates cache

- **WHEN** `update` successfully bumps a latest-only package and the cache is enabled
- **THEN** that package’s cache entry is rewritten with a fingerprint matching the post-apply tree

### Requirement: Atomic write and exclusive lock

When writing a check-cache file, the program SHALL use an exclusive lock for the read-modify-write sequence and SHALL publish the new file contents via an atomic replace (write temporary file then rename) so concurrent manager processes do not leave a truncated JSON file as the only durable content.

#### Scenario: Concurrent writers do not leave truncated JSON as sole content

- **WHEN** two manager processes update the same overlay check-cache file
- **THEN** each durable replace is atomic with respect to readers and locking serializes writers

### Requirement: One info summary of hits and fetches

At the end of an `outdated` or `update` run that performs package check or plan work with the cache enabled or refresh forced, the program SHALL log exactly one informational summary that reports how many packages used a valid cache hit and how many performed live fetch or plan network work (for example hit and fetch counts). The program SHALL NOT be required to log per-package hit or miss at info level.

#### Scenario: Summary after mixed run

- **WHEN** a run uses valid cache entries for some packages and live network for others
- **THEN** one info log line (or equivalent single info message) reports both hit and fetch counts
