## 1. Remove help subcommand

- [x] 1.1 Remove `Help` from `Command`, the `command "help"` entry, and any `Help` references in `CLI.Parser`
- [x] 1.2 Remove `showHelp` export/implementation from `CLI.Parser`
- [x] 1.3 Remove `Cmd.Help` dispatch and `showHelp` import from `app/Main.hs`

## 2. Top-level help and bare invocation

- [x] 2.1 Rename help `header` / `progDesc` strings from `mndz-overlay-mgr` to `mndz-overlay-manager`
- [x] 2.2 Ensure top-level `--help` / `-h` still document globals (`--jobs`, `--no-progress`, `--no-color`, etc.) and list only `list`, `outdated`, `update`
- [x] 2.3 Implement bare invocation: print full top-level help text (same substance as `--help`) and exit with status `1` (not `0`)

## 3. Per-command detailed help

- [x] 3.1 Attach command-scoped helper and enrich `list` help (behaviour blurb + globals-before-command footer)
- [x] 3.2 Enrich `outdated` help (behaviour blurb + globals footer)
- [x] 3.3 Enrich `update` help: `PACKAGE...` forms, omit-all-needing-work, brief apply/signed-commit behaviour, globals footer
- [x] 3.4 Confirm `list|outdated|update --help` / `-h` exit `0` without loading config

## 4. Docs and quality gate

- [x] 4.1 Update `MNDZ.md` (mark help backlog item done) and any README/docs that still mention the `help` subcommand
- [x] 4.2 Manually verify: bare (exit 1 + full help), `--help`/`-h` (exit 0), each command `--help` (detail + footer), `help` no longer a command
- [x] 4.3 Run `hk check` and fix any format/lint/weeder issues from the removal
