## MODIFIED Requirements

### Requirement: Suite exercises required product surfaces

The test suite SHALL exercise product code (not local reimplementations) under Unit and/or Integration isolation as defined by this capability, using fakes or injectable runners so the coverage gate does not require live network, interactive pinentry, or host package-manager binaries for success. Coverage SHALL include at least:

1. **Pure and CLI** — option resolution, work-command parse edges (including `github-token` and `--force`), preflight pure helpers, version-tag and SSH-identity pure helpers, config load error messaging and path selection, overlay validation failures, GitHub token resolution edges (envelope vs plaintext vs env, env warnings, skip-decrypt when a token is not required), `github.com` origin owner/repo parse, `mndz1.` envelope detect/round-trip with a test wrapping password, and technique/ecosystem/package-key pure helpers; logging bootstrap construction for controlled verbosity and color.
2. **Ecosystem builders** — pure helpers and builder entry points for npm, bun, and cargo (and Go vendor as product exposes them) with at least one successful fake-ops path and one controlled failure path per ecosystem; equal treatment across npm/bun/cargo.
3. **Check and plan** — product Check and Deps.Plan pipelines for DepsAndAssets ecosystems Go, Npm, Bun, and Cargo with injectable fetchers/plan ops; at least one multi-package or multi-phase workflow under Integration.
4. **Materialize and apply** — materialize/deps-and-assets apply paths for npm, bun, and cargo (and Go where residual gaps exist), including a reuse path when the product defines one; multi-package apply orchestration under Integration with jobs=1 and jobs greater than 1; content-fix check paths for Go, Npm, Bun, and Cargo on controlled temporary trees.
5. **Process adapters and HTTP** — production process adapters for ecosystem builders and for ebuild/egencache/portageq runners via injectable command fakes; GitHub, npm registry, and go.mod-at-tag HTTP client paths with fake HTTP responses, including `github-token` setter probe paths (assets repo GET, empty origin `POST /releases` 422 vs 403, extra owned-repo names that MUST NOT fail the probe) without live GitHub.
6. **Agent edges** — SSH agent session lifecycle and GPG readiness process edges via injectable fakes without requiring an interactive TTY or pinentry UI for the coverage gate.

Raising or reorganizing these tests SHALL NOT introduce numeric coverage floors or gate failure solely due to coverage percentages (see “Success without numeric floors”).

#### Scenario: Coverage entrypoint runs required surface categories

- **WHEN** the coverage entrypoint completes successfully
- **THEN** Unit and Integration suites have executed product paths spanning pure/CLI, ecosystem builders, check/plan, materialize/apply, process/HTTP adapters, and agent edges as listed above

#### Scenario: No live network for the coverage gate

- **WHEN** coverage-oriented suite tests for builders, plan/check, materialize, HTTP clients, token probe, and agents run in the quality gate
- **THEN** they complete without calling public registries, live GitHub APIs, or interactive pinentry for success

#### Scenario: Floors remain unenforced after suite expansion

- **WHEN** tests pass and reports are written after suite expansion for the surfaces above
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor or differs from a baseline file
