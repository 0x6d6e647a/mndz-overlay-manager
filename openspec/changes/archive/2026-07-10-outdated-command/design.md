## Context

The tool already loads config, resolves overlay path, validates layout, and discovers ebuilds (`list`). Version is a bare `Text` on `Ebuild`. The mndz overlay has nine packages whose upstreams are mostly GitHub Releases, one npm package (openspec), and one custom HTTP version file (grok-build). Exploration locked CLI name `outdated`, check-only scope, Level-1 ebuild inference, and stream/exit policies.

## Goals / Non-Goals

**Goals:**
- Structured `EbuildVersion` with PV comparison suitable for update detection
- `UpdateSource` ADT (GitHub, Npm, Http) with resolve = hardcoded ∨ infer
- Level-1 ebuild text inference (simple assignments, `${PN//-bin/}`, SRC_URI patterns)
- Production fetchers for GitHub releases/latest (tag list fallback), npm `/latest`, HTTP body
- CLI `outdated` matching list spine; stdout outdated-only; soft warns; exit 0 on successful check
- Testable pure core and injected HTTP (no live network in default tests)
- Port of grok-build version URL logic as Http source (hardcoded package)

**Non-Goals:**
- Writing/renaming ebuilds or regenerating Manifest/digests/vendor tarballs
- Config-file source maps (TOML update tables)
- Full Portage/PMS version grammar (`_alpha`, `_rc`, slots)
- Inferring sources from HOMEPAGE alone
- tasty/hspec migration
- Exit code 2 for outdated packages

## Decisions

**Decision: Dedicated version type, parse at check time**  
`EbuildVersion` = numeric component list + optional revision, or `Raw Text`. Discovery may keep `ebuildVersion :: Text`; check parses when grouping/comparing.  
Alternatives: upgrade discovery field now — deferred to avoid churn in `list`/fixtures; pure parse is shared either way.

**Decision: PV comparison ignores revision**  
Local `1.2.3-r2` vs remote `1.2.3` is up-to-date. Revision is ebuild metadata, not upstream.  
Statuses: Outdated (local PV < remote), Ok (equal), Ahead (local > remote), plus Unconfigured / Error.

**Decision: UpdateSource ADT, not typeclass**  
Closed set of three sources; config/hardcode/infer all produce the same sum type; one dispatch for fetch.  
Alternatives: typeclass + existentials — more ceremony without extension needs.

**Decision: Resolve = hardcoded map first, else Level-1 infer**  
Hardcode at least `dev-util/grok-build-bin` → Http (`https://x.ai/cli/stable` + GCS fallback). Infer GitHub/npm from ebuild text for the rest.  
Alternatives: TOML map — rejected for v1; pure hardcode of all nine — rejected in favor of inference.

**Decision: Level-1 expander is narrow**  
Support simple `VAR="..."` assignments and `${PN}`, `${PV}`, `${P}`, `${PN//-bin/}`, and `${VAR}` expansion in URL-like strings. Ignore `$(...)` and USE-conditionals. Goal is owner/repo/prefix or npm id, not full artifact SRC_URI.  
Alternatives: full bash — out of scope; Level 0 only — forces hardcoding bun/deno.

**Decision: Inference priority and noise filter**  
Ignore URLs under `github.com/0x6d6e647a/mndz-overlay-assets`. Prefer npm registry matches over GitHub. Prefer SRC_URI-derived GitHub (tags/releases with PV) over HOMEPAGE.  
Openspec has GitHub HOMEPAGE but npm is the version channel.

**Decision: GitHub fetch uses releases/latest first**  
All current overlay GitHub packages publish releases. Tags API is not version-ordered (e.g. dolt). On 404, fall back to tags and pick max by `EbuildVersion` order after prefix strip. Optional `GITHUB_TOKEN` for rate limits.  
Strip configured/inferred prefix from `tag_name` before parse.

**Decision: Per-package newest PV**  
Group ebuilds by `category/package`; take maximum version by PV (revision may break ties for “which file,” but compare to upstream ignores rev). Slots are YAGNI. Infer source from the ebuild file of that newest entry.

**Decision: Stream and exit policy (D-ish hybrid)**  
- stdout: only Outdated lines: `category/package vLOCAL -> vREMOTE` (leading `v` is display sugar)  
- stderr via co-log: warn each Unconfigured, fetch/parse Error, Ahead  
- Ok: silent  
- exit 0 if config/validate/discover/check loop completed; exit 1 only for hard spine errors (same class as `list`)  
- empty inventory: error exit 1 (same as `list`)

**Decision: Inject Fetcher for tests**  
`checkOverlay` takes a fetch function or client record so unit tests supply canned versions. Production wires real HTTP. Hand-rolled tests only (no new test framework).

**Decision: Module layout**  
- `Overlay.Version` — type, parse, render, comparePV  
- `Update.Types` — UpdateSource, PackageKey, UpdateReport, Status  
- `Update.Infer` — Level-1 expand + matchers  
- `Update.Hardcoded` — Map PackageKey UpdateSource  
- `Update.Resolve` — hardcoded ∨ infer  
- `Update.GitHub` / `Update.Npm` / `Update.Http`  
- `Update.Check` — group, resolve, fetch, compare, reports  
- CLI/Main — `outdated` command

**Decision: Dependencies**  
Add HTTP + JSON libraries compatible with the stack (prefer small surface: e.g. `req` or `http-client` + `aeson`). Sequential fetches in v1.

## Risks / Trade-offs

- [Inference misses clever ebuilds] → Hardcode override; warn unconfigured; expand Level-1 only as needed  
- [GitHub rate limits] → Optional token; sequential requests; soft error per package  
- [Remote version unparsable] → Soft warn; do not fail whole run  
- [Numeric vs string sort] → Component-wise Word compare (avoid `1.10` < `1.9` string bug)  
- [Partial ebuild “parser”] → Document supported assignment forms; tests on real overlay snippets  
- [Http client choice / TLS] → Use maintained library; timeouts on all fetches  

## Migration Plan

Not user-facing (pre-release tool). Developers: add deps to cabal, rebuild, run hand-rolled tests. No overlay format change.

## Open Questions

None — decisions locked in exploration (print policy, Level-1, hand-rolled tests, exit 0 on outdated, silent ok).
