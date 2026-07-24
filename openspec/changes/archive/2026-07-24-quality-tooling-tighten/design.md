## Context

Part 8 of 8 (final). After structural cleanup, re-enable more of Stan and fix small hygiene items. Current `.stan.toml` excludes Style, Warning, Performance, and Infinite categories entirely; only Error-level anti-patterns effectively remain.

## Goals / Non-Goals

**Goals:**

- Incrementally stronger static analysis without drowning in noise.
- Cheap strictness on hot records where safe.
- Total gap-line pool indexing (no `!!`).
- Cabal synopsis/description filled.
- Weeder roots consistent with part 5.
- Document any new contributor expectations in CONTRIBUTING.

**Non-Goals:**

- Zero excludes forever.
- New tools beyond ormolu/hlint/stan/weeder.
- Large performance projects.

## Decisions

### D1: Stan re-enable order

**Choice:** First re-enable **Performance** (or Warning) in a branch-local experiment; fix or exclude per-finding with comments in `.stan.toml`. Do not re-enable all severities at once.

**Rationale:** Controlled noise; Error stays as today.

### D2: StrictData

**Choice:** Enable `StrictData` per-module or on specific modules with hot records (`CLI.Progress` state, `PackageEntry`, plan records) rather than a blanket package default in cabal — unless a package-wide default proves painless.

### D3: Gap lines

**Choice:** In `buildGapLines` (or successor name post-rename), use `NonEmpty` for the from-version pool or pattern-match non-empty lists; never `!!`.

### D4: Cabal metadata

**Choice:** Add one-line synopsis and short description matching README purpose.

### D5: Specs

**Choice:** Modify `git-hooks-quality-gates` / `project-docs` **only if** the documented blocking pipeline or contributor baseline narrative changes (e.g. “Stan Performance is now enforced”). If only exclude list shrinks without policy text change, specs may stay untouched.

## Risks / Trade-offs

- **[Risk] Stan flood of findings** → Mitigation: incremental enable; justified excludes; fix real issues first.
- **[Risk] StrictData changes laziness-sensitive code** → Mitigation: module-scoped; tests catch divergences.
- **[Risk] Fighting mid-flight if applied too early** → Mitigation: part 8 last in the program.

## Migration Plan

1. Gap-line total rewrite + cabal synopsis (easy wins).
2. Strictness on selected modules.
3. Stan config tighten + fix loop until `hk check` green.
4. Docs/spec deltas if policy text changes.
5. Archive — quality program complete.

Rollback: restore `.stan.toml` / strictness commits.

## Open Questions

- Exact Stan observations to enable first — decide at apply by running stan with temporarily widened checks and triaging counts.
