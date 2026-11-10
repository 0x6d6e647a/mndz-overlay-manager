# Tasks

## 1. Selection

- [x] 1.1 Add selection and message functions beside `resolveTargets` in `src/Update/Targets.hs`, and cover them with an `ExcludeSelection` test in `test/Test/Targets.hs`. The test must show untargeted subtraction in inventory order, a positional list with one key removed and the remaining explicit order kept, duplicate tokens collapsing, unknown and ambiguous tokens reported together with bad positionals, a PV token rejected, a resolved exclude outside the base omitted from the removed list, and the one-key warning, multi-key warning, and empty-selection error texts. Verify with `just test ExcludeSelection`.

## 2. Parser and help

- [x] 2.1 Add `excludeTokens` and the long-only `--exclude PACKAGE,...` reader to `outdated`, `update`, and `gencache` in `src/CLI/Parser.hs`. Update the existing record assertions in `test/Test/CLI.hs`, and add an `ExcludeParser` test for comma splitting, trimmed spaces, repeated flags, an empty segment, a whitespace-only value, rejection on `list`, `eclean`, `github-token`, and a leading global `--exclude`, a positional word that contains a comma, and `--exclude` followed by a separate positional. Verify with `just test Parser`.

- [x] 2.2 Document `--exclude` in the `outdated`, `update`, and `gencache` help text: comma-separated, repeatable, removed from the positional selection or from the whole inventory, and an empty selection is an error. Add an `ExcludeHelp` test that those three helps say so and exit without config, that top-level help does not document `--exclude` as a global, and that `list --help` does not document it as a `list` option. Verify with `just test ExcludeHelp`.

## 3. Command wiring

- [x] 3.1 Call the selection function from `runOutdated`, `runUpdate`, and `runGencache` at their current resolve sites. On target errors, log them and exit `1` before the warning. On an empty selection, log only the empty-selection error and exit `1`. Otherwise log the warning when at least one package was removed, and pass only the remaining packages into check, plan, or cache generation. Leave overlay wait-edge, atom-closure, and dirty-preflight modules unchanged, and leave `gencache` resolution after its git, tool, and layout preflight. Verify with `just build`.

## 4. README

- [x] 4.1 Document `--exclude` in the README `outdated`, `update`, and `gencache` sections. Each section needs an example. The `update` section must state that a non-empty removal logs one warning, that an empty selection is an error, that `--exclude dev-lang/bun-bin` does not add bun-bin back, and that a dirty ensure-emerge atom is still checked when the materialize recipe will emerge it. Verify by reading those sections against `openspec/changes/package-exclude-flag/specs/project-docs/spec.md`.

## 5. Gate

- [x] 5.1 Run `openspec validate package-exclude-flag --type change --strict` and `just check`. Both exit 0. Mark earlier tasks complete only when the check they name is green.

## Workflow follow-up

- Archive is what syncs these deltas into `openspec/specs/`. Leave the living specs unchanged until then, and do not put delta wording into a Purpose line.
