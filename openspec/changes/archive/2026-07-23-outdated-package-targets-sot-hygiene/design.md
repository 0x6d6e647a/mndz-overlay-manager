## Context

`update` and `gencache` resolve CLI package tokens through `Update.Targets.resolveTargets`: empty → all inventory keys; `category/package` → exact key; bare `package` → unique match or `AmbiguousPackage` / `UnknownPackage`. `outdated` is still `Command` constructor `Outdated` with no args and always checks every discovered package. Specs and README document that gap.

Living OpenSpec SoT still carries post-`DepsAndAssets` rename residue (`GoVendorAndAssets` titles and prose, Cargo holes in shared rules, four-lane Go labels vs multi-arch ceilings, “in this change” language, TBD purposes). Code already uses only `DepsAndAssets`. `openspec/config.yaml` is an empty template, so agent conventions are not encoded.

Constraints: quality gates (`hk check`); reuse existing target resolution; no PV CLI args; prefer behavioral specs over library names.

## Goals / Non-Goals

**Goals:**

- Same package-target model on `outdated` as `update`/`gencache`
- Rewrite update PV-selection wording so package targets stay clear and PV is never a CLI argument
- Scrub SoT vocabulary and contradictions called out in the quality audit (critical + important items)
- Encode project OpenSpec conventions in `openspec/config.yaml`
- Update operator help/README for outdated targets

**Non-Goals:**

- CLI version/PV pinning (`update crush 1.2.3`)
- Changing check algorithms, lane planning, or soft/hard exit semantics beyond filtering which packages run
- Reimplementing progress host (only de-specify layoutz/MVar in SoT)
- Full split of `go-tree-lanes` into a tiny Go-only domain (thin wording only; large structural move deferred)
- Rewriting archived changes

## Decisions

### Decision: Reuse `resolveTargets` for outdated

Wire `Outdated [String]` (or equivalent) through the same `resolveTargets entries tokens` path as update/gencache. Empty args → all keys; errors → log and exit 1 before checks (same spine hardness as update for unknown/ambiguous).

**Rationale:** One resolution model; inventory is the universe for “known package.”  
**Alternatives:** Soft-skip unknown outdated targets — rejected (inconsistent with gencache/update hard-fail on bad tokens).

### Decision: Filtered set is the check universe

After resolve, run concurrent checks only for selected package keys (filter inventory or pass keys into check). Multi-progress totals reflect selected packages. Stdout/soft warnings only for selected packages. Unselected packages are silent (not “unconfigured” warnings).

**Rationale:** Operators use targets to focus; noise from the rest of the overlay defeats the feature.  
**Alternatives:** Check all, filter stdout only — rejected (wastes work and still probes unselected remotes).

### Decision: Package target vs PV selection (update wording)

Keep **Update package targets** as the package-selection requirement. Replace **Latest upstream only** with a requirement that:

1. States CLI accepts only package tokens (not version/PV).
2. GitMv (and other non-`DepsAndAssets`) apply PV = latest from configured source.
3. `DepsAndAssets` apply PV set = runtime-lane plan (may be older than upstream tip).

**Rationale:** Matches code and operator mental model; removes false “no user target” and “latest only” framing.  
**Alternatives:** Keep ban sentence only — insufficient; still confuses package targets with PV.

### Decision: Unknown/ambiguous outdated targets hard-fail

Match update: any `TargetError` aborts the command with exit 1 before package checks.

### Decision: SoT hygiene via deltas + living Purpose/config edits

- Requirement behavior/title changes → delta ADDED/MODIFIED/RENAMED/REMOVED.
- Purpose-only and residual prose scrub inside requirements modified for other reasons → full MODIFIED bodies.
- Pure string scrub of `GoVendorAndAssets` inside requirements not otherwise changing → include in those domains’ MODIFIED/RENAMED where practical; remaining prose scrub as explicit apply tasks on living `openspec/specs/**` so archive merges cleanly.
- `openspec/config.yaml` is not a capability delta; update in tasks.

### Decision: Lane labels follow discovered arches

Modify `go-tree-lanes` **Lane labels** to require `(dev-lang/go <tier-arch>)` form for every discovered Go lane arch/tier (same pattern as `runtime-lanes`), not a closed set of four amd64/arm64 labels.

### Decision: cli-activity behavior-only

MODIFIED teardown: exception-safe panel critical sections, cooperative stop, bounded wait, cancel-after-grace, best-effort chrome — without naming MVar. REMOVED or MODIFIED layoutz requirement to “progress presentation on stderr via an in-process multi-line renderer” without pinning `layoutz` (or REMOVED if redundant with other presentation requirements).

**Rationale:** Stack choice belongs in design archives; product requires hang-free, stderr-only indicators.  
**Alternatives:** Keep layoutz normative — rejected (audit finding; freezes dependency in SoT).

### Decision: Cargo completeness in shared apply/update requirements

Explicitly include Cargo alongside Go/Npm/Bun wherever first-class technique or “not unsupported” soft-skip is stated; exact-set prune applies to all `DepsAndAssets`.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Outdated targets change help/README without code → doc drift | Same change: parser + Main + tests + docs |
| Large SoT scrub misses a string | `rg GoVendorAndAssets openspec/specs` gate before done; weeder/stan N/A for markdown |
| Thinning go-tree-lanes too far loses Go probe rules | Only change labels + purpose + residual names; leave early-exit/cache/progress intact |
| Archive merge of many MODIFIED domains is noisy | Keep deltas full-requirement bodies; run validate |

## Migration Plan

1. Land spec deltas and config.yaml with code for outdated targets.  
2. Operators gain `outdated PACKAGE...` immediately; no data migration.  
3. Rollback: revert commit (CLI remains backward compatible for zero-arg outdated).

## Open Questions

_(none blocking — package target model confirmed: `cat/pn` \| `pn` \| empty.)_
