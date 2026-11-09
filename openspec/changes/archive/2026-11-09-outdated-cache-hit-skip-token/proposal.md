# Proposal

## Why

`outdated` asks for the `github-token` wrap password when a cached runtime-lane plan still needs work, even though that command will not call `api.github.com`. The check-cache entry is valid, `--refresh` was not passed, and the plan is served from cache. The prompt exists because the live-GitHub decision treats "needs work" as "will fetch."

## What Changes

- `outdated` skips the wrap-password prompt, the GitHub health preflight, and the unauthenticated-quota warning when every GitHub read that this run would make is already a valid check-cache hit and `--refresh` was not passed.
- A valid deps-plan hit whose plan still needs work (missing planned PV, extra local PV, or content fix) is still a hit. It does not by itself make `outdated` call `api.github.com` or prompt.
- `outdated` still prompts once, before health and package checks, when any selected package will actually call `api.github.com`. That includes a cache miss, an unusable Cargo plan snapshot, a fingerprint or overlay-provider fingerprint mismatch, `--refresh`, a cold overlay-provider latest entry, and a ceiling change that is about to run the uncached hypothetical consumer plan.
- One such package in the selection prompts for the whole command. `GITHUB_TOKEN` or `GH_TOKEN` still wins and skips the prompt. With no token configured, a live call still fetches unauthenticated and logs the existing 60-per-hour warning.
- `update` keeps its current rule: prompt when that run will call `api.github.com`, including an assets release lookup for a package whose lane plan is already cached and still needs work. A GitMv-only `update` whose latest entries all hit, with no assets GitHub access, still does not prompt.
- README states this `outdated` / `update` split.

## Non-goals

- Changing `update`'s prompt rule. In particular, do not fix the existing `update` case that live-plans a satisfied Bun consumer under new ceilings while both the consumer plan and the provider latest entry are valid hits. That plan-phase read can run before the assets unlock.
- Caching hypothetical Bun plans.
- Changing check-cache TTL, fingerprint inputs, or Cargo snapshot usability.
- New CLI flags, or prompt behavior for `list`, `gencache`, `eclean`, and `github-token`.
- Requiring a GitHub token when none is configured.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `outdated-command`: Skip decrypt and health when no live `api.github.com` read remains. A needs-work cached plan is still a hit. A provider latest miss or a ceiling-changed hypothetical plan still decrypts.
- `github-auth`: The outdated skip-decrypt scenario follows the same "this run will call `api.github.com`" rule, including those extra Bun reads, and does not treat a needs-work plan hit as a live fetch.
- `github-api-resilience`: Health preflight and the unauthenticated warning use that same outdated decision.
- `project-docs`: README states that a fresh `outdated` hit does not prompt, and that `update` still prompts for assets GitHub work.

## Impact

- `outdated` live-GitHub decision in `src/Update/Check.hs` and the `outdated` path in `app/Main.hs`. `update` continues to use the existing decision.
- Tests that today only cover a GitMv cache hit skipping decrypt. Add the needs-work deps hit and the Bun extra-read cases. No live GitHub and no TTY in the gate.
- `README.md` token / `outdated` / `update` paragraphs.
- No config schema, cache document, or CLI flag change.
