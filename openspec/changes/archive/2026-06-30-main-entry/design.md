## Context

The repository is a fresh Haskell project created with `cabal init`. It currently contains only placeholder modules (`app/Main.hs`, `src/MyLib.hs`) and the generated `.cabal` file. The desired user-facing command is `mndz-overlay-mgr <tool>`. Before any overlay-management tools can be written, the program must reliably obtain a validated path to the user's Gentoo overlay from a TOML configuration file.

Key constraints discovered during exploration:
- Config path must respect `XDG_CONFIG_HOME` with fallback to `~/.config/mndz/overlay-manager.toml`.
- Hard errors (error-level log + exit 1) are required for missing file, missing key, or invalid overlay layout.
- Logging must be fully initialized before any config or CLI work so that early errors use the same facility.
- CLI must support subcommands (future tools) via `optparse-applicative` and must allow `--help` without requiring a valid config.
- A `--config` override flag and log-level control (`-v`, `--log-level`) are desired global options.

## Goals / Non-Goals

**Goals:**
- Provide a working CLI skeleton that parses subcommands and global options.
- Load and validate the TOML config on every non-help invocation.
- Emit precise, actionable error messages via a rich `co-log` logger.
- Validate that the overlay contains the four required Gentoo layout elements and that `repo_name` matches the hardcoded value `"mndz"`.
- Keep the design simple enough that the first real tool can be added later with minimal friction.

**Non-Goals:**
- Implement any actual overlay-management tools (sync, add-ebuild, etc.).
- Provide a machine-readable output mode or JSON export.
- Support per-tool configuration tables in this change (future work).
- Add colored output beyond the logger's default level coloring.

## Decisions

**Decision: Use `toml-parser` (EricMertens) for TOML handling**  
Rationale: It is the actively maintained 2025/2026 library supporting TOML 1.1.0, provides schema-based `FromValue`/`ToValue` with `GenericTomlTable`, and produces source-located error messages. `htoml` is unmaintained since 2016.

**Decision: Use `optparse-applicative` for CLI parsing**  
Rationale: It is the established, clap-like library in the Haskell ecosystem. It supports `hsubparser` + `command` for subcommands, auto-generates rich help, and integrates bash/zsh/fish completion out of the box. No other library matches this feature set as cleanly.

**Decision: Use `co-log` (and `co-log-core`) for logging**  
Rationale: Modern, composable, contravariant/comonadic design. Supports early bootstrap with a minimal `LogAction` to stderr, later enrichment, and level filtering. Works naturally with the `WithLog` constraint.

**Decision: Initialize the rich logger before argument parsing**  
Rationale: Guarantees that “config missing” and other hard errors are emitted through the same logging facility that later tools will use. The cost is negligible; the logger can be reconfigured after a successful config load if needed.

**Decision: Hardcode the expected `repo_name` value (`"mndz`)**  
Rationale: Keeps the initial TOML schema minimal (only `mndz-overlay-path`). Future tools may introduce their own `[tool.<name>]` tables.

**Decision: `--config` must point directly to a file (not a directory)**  
Rationale: Matches the user's explicit clarification and avoids ambiguity.

**Decision: Default log level = `warn`; `-v` repetition raises the level**  
Rationale: Quiet by default; repeated `-v` provides a familiar UX for increasing verbosity without requiring an explicit level string.

## Risks / Trade-offs

- [Early logger initialization before any config] → The first messages will always use the bootstrap format. Mitigation: keep the bootstrap rich but simple; later enrichment is still possible.
- [Overlay validation is filesystem-dependent] → Tests will need fixture directories or a virtual filesystem abstraction. Mitigation: design validation as a pure function taking a `FilePath` so golden-file and property tests are straightforward.
- [No per-tool config tables yet] → Future tools may need to extend the config schema. Mitigation: keep the top-level config record extensible; tool-specific tables can be added as optional fields or separate decoded sections later.

## Migration Plan

Not applicable — this is a new project with no existing users or deployed state.
