# Design

## Context

`outdated`, `update`, and `gencache` already share `Update.Targets.resolveTargets`. An empty positional list returns every discovered key in entry order. A non-empty list resolves each token and returns `nubOrd` keys. Unknown and ambiguous tokens are collected and logged together, then the command exits `1`.

`app/Main.hs` applies that result differently per command. `outdated` and `update` keep the entry list and filter by membership, so work stays in discovery order. `update` does this before spine-tool preflight. `gencache` passes the key list itself, and it resolves only after the git, tool, and layout preflight. `outdated` help currently says the command accepts no subcommand-local flag besides `--refresh`.

See proposal.md for why the flag exists. The delta specs define the operator-visible contract.

## Goals / Non-Goals

**Goals:**

- One selection function used by all three commands, built on `resolveTargets` and `resolveTargetToken`.
- Syntax failures (empty comma segments) happen in the option parser, before configuration load.
- Package resolution failures stay on the existing target-error path.
- Explicit positional order stays whatever `resolveTargets` returns today. Exclusion only deletes keys from that list.
- `gencache` still resolves after its current preflight.

**Non-Goals:**

- A second package-name matcher, a glob matcher, or a category matcher.
- Changing overlay wait-edge admission, atom closure, or the ensure-emerge dirty check. Those already follow the selected set, and the dirty check already includes an ensure-emerge atom that is not selected.
- Moving `gencache` resolution earlier so a bad exclude fails before `egencache` or `gpg` is probed.
- Prefixing target errors with `exclude:`. The existing message already includes the token.

## Decisions

### Parse the comma list in the option reader

Add `excludeTokens :: [String]` to `Outdated`, `Update`, and `Gencache` in `src/CLI/Parser.hs`. The option is `many` of a long-only `--exclude` with metavar `PACKAGE,...`. Each value is split on `,`, ASCII whitespace is trimmed, and an empty piece fails the reader. The command stores the flattened token list. Repeating the flag concatenates those lists. An absent flag stores `[]`.

The reader cannot resolve names: discovery has not run. Resolving inside the reader would load the overlay during `--help`, which help is required to skip.

Alternative: store the raw argument strings and split after config load. An empty segment would then load configuration first, which the spec forbids.

`--exclude foo bar` still means "exclude `foo`" and positional target `bar`, because the option takes one argument. The help text has to say the list is comma-separated.

### Resolve both sides, then subtract

Add a selection result next to `resolveTargets`:

- Resolve positional tokens and exclude tokens with the existing token rules. If either side has errors, return every error and do not subtract.
- The base is the key list `resolveTargets` would return for the positionals alone.
- Selected keys are that list with exclude keys removed, so explicit-target order does not change.
- Removed keys are the base keys that were excluded, walked in discovered-entry order. That order is only for the warning and the empty-selection error.

An exclude key that resolved and is not in the base does not appear in the removed list. Duplicate tokens collapse because both sides already collapse to keys.

Pure message functions live beside that result:

- one removed key: `excluding <category/package>`
- several: `excluding <N> packages: <key>, <key>`
- empty selection: `exclusions removed every selected package: <key>, <key>`

`logWarning` is the warning. The default level is warn, so the line is visible without `-v`. The empty case uses the existing error exit and does not also log the warning.

Alternative: warn with the raw tokens the user typed. That would print a bare name and a qualified name as two entries for one package, and it would name keys that were not in the base.

### Apply it at the three existing resolve sites

`runOutdated` and `runUpdate` call the new function where they call `resolveTargets` today, before cache, GitHub, and (for `update`) spine tools. They then keep the entry-membership filter, using the selected keys. `runGencache` calls it at its current post-preflight site and passes the selected key list through.

No wave, atom-closure, or dirty-preflight module changes. A smaller selected set is the input those paths already understand. In particular, `update --exclude dev-lang/bun-bin` leaves bun-bin unselected, so plan-delta refuse and the ensure-emerge dirty check stay on their current requirements. `needsLiveGitHubApi` keeps receiving the post-exclusion entries. A selected Bun consumer can still make the run live because its own check reads the unselected provider latest.

`--refresh` and `gencache --force` are unchanged flags. They apply to whatever selection remains.

### Help text stays on the command parsers

Document `--exclude` in the option help and the footers for `outdated`, `update`, and `gencache`. Leave the `list`, `eclean`, and `github-token` parsers alone, and do not add the option to the top-level parser. Top-level help then omits it because it only renders global options.

## Risks / Trade-offs

- [Excluding `dev-lang/bun-bin` on a bulk `update` hard-fails Bun consumers whose plan would change, and the command can still exit `1`] → The warning names bun-bin before that work. README states that the provider is not pulled back. Do not soft-skip those consumers.
- [A selected consumer can still fetch the excluded provider's latest and can still prompt for the wrap password] → That is the existing unselected-provider check. Do not suppress it.
- [Excluding `dev-lang/bun-bin`, `dev-lisp/qlot`, or `dev-build/node-gyp` does not skip the dirty check when this run's materialize recipe will emerge that atom] → README says so. The dirty-preflight requirement already says "even if that package is not in the selection."
- [`gencache` reports a bad exclude only after tool preflight] → Same point as a bad positional target. Keep one resolve site.
- [Adding a record field breaks the `CLI.Outdated`, `CLI.Update`, and `CLI.Gencache` assertions in `test/Test/CLI.hs`, and the positional matches in `app/Main.hs`] → Update those sites in the same change. No other module constructs those records.
- [`--exclude foo bar` silently treats `bar` as a positional target] → Help and README show a comma. The parser cannot accept spaces inside one option value without taking the following argument.

## Migration Plan

No configuration or cache migration. Invocations that do not pass `--exclude` keep today's selection. Rollback is reverting the change. Operators who already pass `--exclude` would then get an unknown-option error.
