## 1. Config and duration

- [x] 1.1 Add `check-cache-ttl` to config types/loader with parse-at-load into `CacheDisabled | CacheTtl NominalDiffTime` (default 5m when omitted; `0`/`0s` → disabled)
- [x] 1.2 Implement pure single-unit duration parser (case-insensitive `s`/`m`/`h`/`d`); reject multi-unit, bare ints, empty, unknown units with config error
- [x] 1.3 Unit tests for duration accept/reject and default/disabled mapping; extend config fixtures (`full-config.toml` optional key)

## 2. Check-cache core

- [x] 2.1 Add `Update.CheckCache` (or equivalent) as `other-modules`: XDG check-cache dir, friendly+hash12 filename, schema version 1 JSON codec for latest and deps (`RuntimeLanePlan`) entries
- [x] 2.2 Implement fingerprint: sorted non-live local PVs, source id from update source, content hash of non-live ebuilds + Manifest
- [x] 2.3 Implement load / exclusive lock / atomic write (tmp + rename); corrupt or unknown version → empty cache + warning, not hard-fail of the command
- [x] 2.4 Validity: TTL age, fingerprint match, respect disabled and refresh-for-read; never encode fetch/plan failures as hits
- [x] 2.5 Unit tests: path naming, round-trip encode/decode, TTL expiry (injectable clock), fingerprint miss, disabled no write, atomic replace

## 3. CLI

- [x] 3.1 Add `--refresh` to `outdated` and `update` parsers; thread flag into command runners
- [x] 3.2 Update outdated/update help and footers (document `--refresh`; remove “no subcommand-local flags” for outdated)

## 4. Wire outdated and update

- [x] 4.1 Load cache once per `outdated`/`update` run (when not disabled); plumb cache handle + refresh into check path
- [x] 4.2 On check hit use cached remote/plan; on miss live work then store eligible entries; always recompute content-fix from disk
- [x] 4.3 Wire apply latest path (`applyGitMv` / fetcher) and deps plan path (`applyDepsAndAssets`) to trust valid cache entries without network
- [x] 4.4 After successful package apply, rewrite that package’s cache entry with post-apply fingerprint and success payload when cache enabled
- [x] 4.5 Emit one info summary (`hit` / `fetch` counts) per outdated/update run that performed check or plan work

## 5. Tests and docs

- [x] 5.1 Integration-style tests: store then hit; apply uses cache without calling fake fetcher/plan; `--refresh` forces live; successful apply rewrites fingerprint; zero TTL never writes
- [x] 5.2 Update `README.md` for `check-cache-ttl`, default 5m, disable via zero, XDG check-cache path pattern, and `--refresh` on both commands
- [x] 5.3 Adjust any tests that assume outdated has zero local flags or always-live network on every apply

## 6. Quality gates

- [x] 6.1 `openspec validate --change check-cache` (strict if project practice requires)
- [x] 6.2 `hk check` green with no weeder/stan regressions from new modules (prefer `other-modules`; no casual `exposed-modules` expansion)
