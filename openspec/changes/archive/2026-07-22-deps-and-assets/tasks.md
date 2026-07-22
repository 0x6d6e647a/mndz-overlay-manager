## 1. Types and naming

- [x] 1.1 Replace `GoVendorAndAssets` with `DepsAndAssets EcosystemSpec` (`Go` | `Npm` | `Bun`) in `Update.Types`; update `techniqueNeedsAssets`
- [x] 1.2 Generalize distfile naming helpers (`-vendor` / `-deps` by ecosystem; always PN) in `Update.Assets.Layout` and call sites
- [x] 1.3 Update `Update.Hardcoded` policy: Go packages → `DepsAndAssets Go`; openspec → `Npm`; ralph-tui → `Bun`
- [x] 1.4 Mechanical renames in Apply/Check/tests for the old technique constructor

## 2. Runtime lanes

- [x] 2.1 Generalize ceiling discovery: arch set from runtime KEYWORDS (all arches); plain/tilde per arch; ignore `-*` and live ebuilds
- [x] 2.2 Wire ceiling sources: gentoo `dev-lang/go`, gentoo `net-libs/nodejs`, overlay `dev-lang/bun-bin`
- [x] 2.3 Implement candidate set = non-live local PVs ∪ upstream > max(local); hard-fail if no non-live local
- [x] 2.4 Lane select / collapse / KEYWORDS / labels / exact-set prune shared across ecosystems
- [x] 2.5 Zero planned PVs → hard-fail; empty individual lanes allowed
- [x] 2.6 Unit tests for multi-arch ceilings, tilde-only bun-bin, candidate filtering

## 3. Go under DepsAndAssets

- [x] 3.1 Route Go apply through `DepsAndAssets Go` + runtime lanes (preserve vendor materialize, BDEPEND `go:=`, reuse, Manifest verify)
- [x] 3.2 Apply candidate-set rule to Go tag probing (overlay ∪ newer)
- [x] 3.3 Ensure KEYWORDS assembly uses all go arches, not hard-coded amd64/arm64 only
- [x] 3.4 Update Go-related tests for new type names and multi-arch behavior

## 4. Npm materializer and apply

- [x] 4.1 Implement registry-only npm pack + `npm-cache/` tarball builder (Haskell; injectable process ops)
- [x] 4.2 Parse `engines.node` minimum forms; hard-fail plan on missing/unparseable
- [x] 4.3 BDEPEND rewrite `>=net-libs/nodejs-<v>[npm]`
- [x] 4.4 Host Node version gate on full path only
- [x] 4.5 Wire npm into shared spine (reuse deps asset, SRC_URI, Manifest SHA512, commit-on-unit)
- [x] 4.6 Require `UpdateSource.Npm` for `DepsAndAssets Npm`
- [x] 4.7 Unit tests with fake npm/registry responses

## 5. Bun materializer and apply

- [x] 5.1 Implement GitHub clone + `bun install --frozen-lockfile --cache-dir` + `bun-cache/` tarball builder
- [x] 5.2 Require root `bun.lock`; hard-fail if missing
- [x] 5.3 Parse `engines.bun` minimum forms; hard-fail plan on missing/unparseable
- [x] 5.4 BDEPEND rewrite `>=dev-lang/bun-bin-<v>`
- [x] 5.5 Host Bun version gate on full path only
- [x] 5.6 Wire bun into shared spine; require `UpdateSource.GitHub`
- [x] 5.7 Unit tests with injectable bun/git ops

## 6. CLI: outdated, update, preflight

- [x] 6.1 Outdated: lane-labeled multi-line for all `DepsAndAssets` (Go/npm/bun labels)
- [x] 6.2 Update selection and stdout for npm/bun lanes; reuse token on success lines
- [x] 6.3 Preflight: `npm`/`bun`/`go` when full-path work in scope; `xz` + assets + token for any deps assets work
- [x] 6.4 Soft-skip reasons no longer treat openspec/ralph as unsupported deps

## 7. Ebuild edit and content-fix

- [x] 7.1 Parameterize `-deps` SRC_URI (confirm existing helper covers both suffixes)
- [x] 7.2 Content-fix / needs-work for deps Manifest DIST names and BDEPEND adequacy
- [x] 7.3 KEYWORDS set from plan for npm/bun packages

## 8. Docs and quality gate

- [x] 8.1 Update README operator tool list for conditional `npm`/`bun` (and go) on deps/vendor packages
- [x] 8.2 Touch CONTRIBUTING/AGENTS only if process surfaces change (per project-docs)
- [x] 8.3 Run full `hk check` and fix issues until green

## 9. Validation notes

- [x] 9.1 Confirm no references to `GoVendorAndAssets` remain in src/test (except historical comments if any)
- [x] 9.2 Confirm manager never shells out to overlay `*-make-*-tarball.py` scripts

## 10. Post-apply fix: nodejs USE atom rewrite

- [x] 10.1 Fix `replaceAtomsInText` / atom-tail drop to consume full USE brackets (no `[npm]npm]`)
- [x] 10.2 Spec + unit tests for openspec-style RDEPEND/`[npm]` rewrite
