## Context

The project is a Haskell Gentoo overlay manager (`mndz-overlay-manager`) with CLI skeleton, logging bootstrap, partial config loading, and overlay layout validation. Only `help` is implemented; `Main.hs` still has a TODO for config loading and command dispatch.

This change introduces the first real tool (`list`) and the reusable ebuild inventory layer that future tools will share. Exploration established: config always loads for non-help; `--overlay-path` is a top-level override after config load; discovery lives in the library; categories are detected by structure (not a deny-list); empty inventory and bad ebuild names fail the run.

## Goals / Non-Goals

**Goals:**
- Complete TOML config loading for `mndz-overlay-path`.
- Resolve overlay path: config first, then CLI `--overlay-path` override.
- Validate overlay via existing `validateOverlay` before any non-help work.
- Provide library types and discovery (`Ebuild`, `ebuildAtom`, `collectEbuilds`).
- Implement `list` as a thin consumer that prints atoms to stdout.
- Fail fast on config, validation, parse, and empty-inventory errors.

**Non-Goals:**
- Filtering, format flags, or JSON output for `list`.
- Hardcoded category allow/deny lists.
- Additional management tools beyond `list`.
- Changing `help` behavior (still skips config/validation).
- Supporting non-`mndz` repo names.

## Decisions

**Decision: Library-first discovery, CLI-thin `list`**  
`Overlay.Types` and `Overlay.Discovery` own the inventory. `list` only formats and prints.  
Alternatives considered: putting walk logic in `Main` or a `CLI.List` module — rejected because future commands need the same `[Ebuild]` collection.

**Decision: Always load config, then apply CLI overrides**  
Even when `--overlay-path` is set, config loads first; the flag overrides only the path field.  
Rationale: keeps one consistent program lifecycle; path override is incidental for `list` but will matter when config gains more settings.  
Alternatives considered: skip config when `--overlay-path` present — rejected as a special case that will bitrot.

**Decision: Structural category heuristic**  
A top-level directory is a category iff it has at least one immediate child directory containing one or more `*.ebuild` files. Non-category dirs (`profiles`, `metadata`, `eclass`, `licenses`, etc.) are skipped automatically.  
Alternatives considered: deny-list of known non-categories; allow-list of Gentoo category prefixes — both more brittle for a personal overlay.

**Decision: Fail the whole run on bad ebuild filenames**  
Any `*.ebuild` that does not parse as `package-version.ebuild` (version extractable per Gentoo naming) aborts with a precise error. Non-`.ebuild` files in package dirs are ignored for inventory (only ebuilds are listed).  
Alternatives considered: skip bad names with a warning — rejected; user prefers fail-fast.

**Decision: Empty inventory is an error**  
Valid overlay structure with zero ebuilds → error-level log + exit 1.  
Rationale: `list` is not useful on an empty tree; surfaces misconfiguration early.

**Decision: Atom format is `category/package-version`**  
`ebuildAtom` produces that string (no path, no extra fields). Version includes revision suffix when present (e.g. `9.4.5-r1`).  
Rationale: matches Gentoo atom style for simple `| grep` pipelines.

**Decision: Module layout**  
- `Overlay.Types` — `Ebuild` + `ebuildAtom`  
- `Overlay.Discovery` — `collectEbuilds` + discovery errors  
- Existing `Overlay.Validation` unchanged in API; called from Main for non-help  
- `CLI.Parser` gains `List` and `--overlay-path`  
- `Config.Loader` completes TOML decode (already depends on `toml-parser`)

**Decision: Filename version parse**  
Split ebuild basename (strip `.ebuild`) into package name and version using Gentoo rules: version starts at the last `-` that begins a version component (digit). Package name must match the parent package directory name.  
If parent dir name does not match the package portion of the filename, fail the run.

## Risks / Trade-offs

- [Heuristic misclassifies odd trees] → Mitigation: only treat as category when child dirs actually contain `*.ebuild`; fail-fast on malformed package files.
- [Version parse edge cases (live 9999, complex suffixes)] → Mitigation: start with standard Portage-style `name-version` split; document that unparseable names error.
- [Config decode incomplete today] → Mitigation: this change finishes decode; keep schema minimal (`mndz-overlay-path` only).
- [Discovery IO-heavy] → Acceptable for personal overlays; no caching in this change.

## Migration Plan

Not applicable for end users (pre-release tool). Developers: rebuild with cabal; extend fixtures under `test/fixtures/` for discovery cases.

## Open Questions

None — decisions locked during exploration.
