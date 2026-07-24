## Why

The library stanza exposes every module, and weeder `root-modules` lists nearly the entire package. Test-only Apply entry points sit on the public surface. Dead-code and accidental-API enforcement cannot work; the package reads like a published library while it is an application support library.

## What Changes

- Shrink the intentional public module surface: prefer `other-modules` for internals, keeping `exposed-modules` to what the executable (and any deliberate public API) need.
- Because tests currently import many internals, choose a practical encapsulation strategy (see design): single-library export lists aligned to Main + test needs, or a clearer internal-vs-app split that still builds `cabal test`.
- Tighten weeder roots: stop blanket-rooting every module; root executable/test `Main.main` and only justified public roots.
- Relocate or clearly mark test-only Apply hooks so they are not product API.
- Update AGENTS/CONTRIBUTING only if agent/contributor weeder or module policy text must change (`project-docs` triggers).

## Program context

- **Part 5 of 8** of the post-audit quality program.
- **Apply order:** after `split-apply-module`; may parallel `structured-domain-errors`.
- **Depends on:** `split-apply-module` (module map stable).

## Non-goals

- Publishing to Hackage or inventing a stable external API versioning story.
- Rewriting tests to only go through CLI process integration.
- Changing product commands or operator docs beyond quality/agent process notes if required.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `git-hooks-quality-gates`: Weeder roots must be entrypoint-oriented, not a blanket list of every library module.
- `project-docs`: AGENTS guidance against reintroducing blanket weeder roots / unjustified exposed-modules expansion.

## Impact

- **Code:** `mndz-overlay-manager.cabal`, `weeder.toml`, Apply test hooks, possibly test imports.
- **Docs:** CONTRIBUTING/AGENTS when policy text changes.
- **Risk:** over-hiding modules breaks tests — design must keep test build green.
