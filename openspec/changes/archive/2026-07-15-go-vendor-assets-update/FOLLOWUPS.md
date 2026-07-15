# Follow-ups for a later OpenSpec session

Out of scope for completing `go-vendor-assets-update`. Capture here so the next propose/apply cycle can turn these into a change.

## F1 — Half-apply / orphan-assets resume

**Problem:** After assets publish succeeds but overlay `ebuild manifest` (or SRC_URI rewrite) fails, re-running `update` can soft-skip (“already at latest”) or re-attempt release create (tag exists), without finishing Manifest.

**Desired behavior:**

- If GitHub already has release tag `{pn}-{pv}` with the expected vendor asset, skip vendor rebuild + assets commit/push/release (optionally verify remote asset hash).
- Still ensure ebuild `SRC_URI` is the full parameterized assets URL and run `ebuild … manifest` + overlay commit when needed.
- Treat broken/missing `mndz-overlay-assets/releases/download/` path as “needs fix” even when `${PV}` is already present and local PV equals remote.

**Suggested change name:** `update-assets-resume` (or part of a combined change).

## F2 — Crush / host Go toolchain

**Problem:** `go mod download` can fail when the package’s `go.mod` requires a newer Go than the host (e.g. requires 1.26.5 while host has 1.26.4 and `GOTOOLCHAIN=local`).

**Desired behavior (TBD in propose):**

- Clearer error / preflight messaging, and/or
- Document minimum Go, and/or
- Allow `GOTOOLCHAIN=auto` for vendor construction only.

**Suggested change name:** `go-vendor-toolchain` (or fold into a Go polish change).

## F3 — `update --force` for dirty package paths

**Problem:** Half-applied or operator dirt on ebuild/Manifest causes hard-fail (“involved paths are dirty”), blocking otherwise valid updates (observed with `opencode-bin` during a multi-package run).

**Desired behavior:**

- CLI flag such as `--force` (or `--force-dirty`) that allows apply when involved paths are dirty, with clear warnings.
- Spec which dirt is forceable vs still fatal (e.g. still refuse non-git overlay).

**Suggested change name:** `update-force-dirty` (or part of a combined change).

---

When starting the next session, run `/openspec-propose` (or explore) with the chosen subset of F1–F3.
