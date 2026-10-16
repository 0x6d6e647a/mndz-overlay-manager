# Design

## Context

See proposal.md for why `designcraft-0.8.0` dies in `src_compile`. `cargo.eclass` writes `[patch]` into `CARGO_HOME/config.toml`. On Cargo 1.97 that table does not satisfy a git dependency the workspace manifest lists under `[patch.*]`. It does satisfy direct git dependencies such as `craft-print` and `craft-ui`.

The unpacked work directory for the failed emerge is still present. An offline `cargo metadata` against it reproduced the `hayro` checkout error, then the `winit` checkout error after only the hayro lines were path-patched, and resolved 568 packages after every `[patch.crates-io]` git pin pointed at its unpacked tree. The work-tree `Cargo.toml` and `Cargo.lock` were restored after that probe.

Codex already solves the same Cargo 1.97 hole in ebuild `src_prepare` (`dev-util-codex-seed`, "Patch-table commits follow GIT_CRATES"). That rewrite is a fixed name list. This change uses the same phase and the same `GIT_CRATES` lookup, and selects lines from the manifest instead of a name list.

## Goals / Non-Goals

**Goals:**

- `src_prepare` reads commit and directory from each `GIT_CRATES` value (`uri;commit;crate_dir`, `%commit%` replaced), as `cargo.eclass` documents.
- Every one-line `[patch.*]` git pin whose name and `rev` match an entry becomes `path = "${WORKDIR}/<directory>"`.
- A `[patch.*]` git pin that does not match, and a match whose unpacked `Cargo.toml` is absent, die before `src_compile`.
- `craft-print` and `craft-ui` stay git lines.

**Non-Goals:**

- See proposal.md. In particular, do not change the manager, do not hardcode the five crate names or either commit, and do not revision-bump.

## Decisions

### Select pins from the patch tables, not from a name list

Bash passes every `GIT_CRATES` triple into a short Python rewrite of `${S}/Cargo.toml`. Python treats a table as a patch table when its header starts with `[patch.`. Inside that table, a one-line assignment that contains `git` and `rev` is a pin. A pin whose name and rev equal a triple is rewritten. The same name at the same rev on more than one line is rewritten each time. Assignments outside patch tables are left alone, so `craft-print` and `craft-ui` stay on the eclass patch.

Match the crate name and the rev. Ignore the git URL, so `winit`'s `.git` suffix still matches the `GIT_CRATES` URI that has no `.git`.

The rewritten assignment is `name = { path = "<absolute workdir path>" }`. DesignCraft 0.8.0's five pins have no other keys. A pin that also carries `features`, `default-features`, or `version` keeps those keys and only replaces the git source.

Alternative considered: hardcode `hayro`, `hayro-interpret`, `hayro-syntax`, `hayro-jbig2`, and `winit`, as Codex hardcodes three names. The next pdfcraft vendor pin (`lopdf`, `egui-wgpu`) would then miss the rewrite and fail the same way. Rejected.

Alternative considered: rewrite every `GIT_CRATES` git line in the manifest, including `craft-print` and `craft-ui`. The eclass patch already resolves those, and rewriting them is what the Codex design rejected. Rejected.

### Fail closed on a pin the rewrite cannot place

Die when a one-line `[patch.*]` git pin's name and rev are not in `GIT_CRATES`, when the line is a git pin the matcher cannot parse, or when the destination `Cargo.toml` is missing. Call `default` first, then die with a message that names the crate. Do not continue into `src_compile`.

A `GIT_CRATES` key with no patch-table line is not an error. `craft-print` and `craft-ui` are that case.

Alternative considered: skip an unmatched patch pin and let Cargo fetch it. That is the failure this change exists to stop. Rejected.

### Edit `designcraft-0.8.0.ebuild` in place

Installed DesignCraft is 0.6.0. The 0.8.0 overlay commit is not on `origin/master`. Replace the ebuild body. Do not add `-r1`.

`cargo build` does not pass `--locked`. After the rewrite, Cargo refreshes `Cargo.lock` inside `WORKDIR` (`Locking 7 packages` in the probe). That lockfile is not installed.

## Risks / Trade-offs

- [A later DesignCraft tag uses a multiline `[patch.*]` table or `branch` instead of `rev`] → the matcher dies instead of skipping. That is the signal to update it.
- [A later bump's donor is an ebuild that lost `src_prepare`] → the offline clone failure returns. `pycargoebuild` keeps phase functions when this ebuild is the donor, which is the normal update path.
- [Metadata resolve succeeded and the compile has not been run] → the operator's emerge of `=app-office/designcraft-0.8.0` is the compile check. The agent does not run sudo.
- [The workdir lockfile records path sources after prepare] → acceptable. The installed package does not ship `Cargo.lock`.

## Migration Plan

1. Add `src_prepare` to the overlay ebuild.
2. Replay the rewrite against the preserved failed work tree and run `cargo metadata --offline`. Restore that tree's `Cargo.toml` and `Cargo.lock` afterward.
3. The operator re-emerges `=app-office/designcraft-0.8.0`. Rollback is deleting `src_prepare`. No installed 0.8.0 exists to roll back.
