# Proposal

## Why

Untargeted `outdated`, `update`, and `gencache` always take the whole inventory. Naming every package except one is impractical, so an operator cannot skip a dirty, expensive, or unwanted package without listing the rest by hand.

## What Changes

- `outdated`, `update`, and `gencache` gain a subcommand-local `--exclude PACKAGE,...` flag. The value is a comma-separated list of the same package tokens as positional `PACKAGE` (`category/package` or an unambiguous bare name). Repeating the flag unions the lists into one set.
- The selection is the existing base with those packages removed. An empty positional list still means the whole inventory. A non-empty positional list is that set, then the exclusions.
- Unknown and ambiguous exclude tokens hard-fail before package work, with the same errors as bad positional targets. A resolved exclude that is not in the base is ignored. An empty selection hard-fails before network, plan, or mutate. A non-empty removal logs one warning naming the canonical keys that were removed.
- `--refresh` and `gencache --force` apply only to the remaining selection. An excluded package is not checked, planned, mutated, or passed to `egencache`, and it is not pulled back in because a selected consumer names it.
- Leaving a provider out by exclusion keeps today's unselected-provider behavior: Bun plan-delta refuse, atom-closure refuse, and dirty checks for overlay atoms the materialize recipe will emerge.
- Command help and `README.md` document the flag.

## Non-goals

- `--exclude` on `list`, `eclean`, or `github-token`.
- A short option, a config-file exclude list, category matches, or globs.
- Comma-separated positional `PACKAGE` arguments, or accepting a PV as a token.
- Pulling an excluded provider back into the selection, soft-skipping consumers that would refuse, or aborting unrelated packages because one consumer refuses.
- Changing overlay wait-edge, atom-closure, or materialize dirty-preflight rules beyond applying them to the selection this flag produces.
- Reordering an explicit positional target list. Exclusions delete keys from that list and leave the remaining order as it is.

## Capabilities

### New Capabilities

- `package-exclude`: Shared `--exclude` grammar, token resolution, base-minus-exclude selection, the removal warning, and the empty-selection error for `outdated`, `update`, and `gencache`.

### Modified Capabilities

- `outdated-command`: Drop the ban on subcommand-local flags other than `--refresh`. The check set is the selection after `--exclude`.
- `update-command`: Plan and mutate that same selection. Zero positionals still mean every discovered package, then exclusion, then the existing needs-work rules on what remains.
- `md5-cache`: `gencache` accepts `--exclude` and generates cache only for the remaining selection. `--force` still regenerates every package that remains.
- `cli-help`: `outdated --help`, `update --help`, and `gencache --help` document `--exclude`. Top-level help does not treat it as a global option.
- `project-docs`: `README.md` documents the flag, including that an excluded provider stays unselected.

## Impact

- `src/CLI/Parser.hs` command records and help text. `app/Main.hs` selection for `runOutdated`, `runUpdate`, and `runGencache`. Shared resolution next to `Update.Targets.resolveTargets`.
- Parser tests in `test/Test/CLI.hs` and resolution tests in `test/Test/Targets.hs`.
- `README.md` sections for `outdated`, `update`, and `gencache`.
- No config schema change. No new dependency.
