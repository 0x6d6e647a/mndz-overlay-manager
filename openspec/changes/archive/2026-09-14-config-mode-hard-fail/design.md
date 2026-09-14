## Context

See proposal.md for motivation. `Config.Loader.loadConfig` already inspects mode after `doesFileExist`, but emits via `loadConfigWithWarn (T.hPutStrLn stderr)` and then reads the file. `loadConfigOrDie` in `app/Main.hs` already turns any `Left ConfigError` into `logError` + `exit 1`. Git-tracked `test/fixtures/*.toml` are mode `0644`; git does not persist `0600`.

## Goals / Non-Goals

**Goals:**

- Wrong or unreadable mode is a `ConfigError`, inspected before the file contents are read.
- Production failure uses the existing `loadConfigOrDie` logger path (no raw print, no warn-and-continue).
- Exact `0600` only; `stat` fail-closed.
- Tests cover `0644`, `0600`, and unreadable-mode without leaving unused warn-hook exports for weeder.

**Non-Goals:**

- Auto-`chmod` or rewriting operator files.
- A second failure path in `Main` besides `dieError`.
- Broadening `exposed-modules` or adding weeder roots.
- Changing token resolution.

## Decisions

**1. Check in `loadConfig`, return `Left`, drop the warn hook.**

Add a `ConfigError` constructor for the permission failure (path plus enough context to name expected `0600`; include the observed mode when `stat` succeeded). `configErrorMessage` formats the operator string. Delete `loadConfigWithWarn` and `configPermissionWarning` (or keep the check private and unexported).

`loadConfigOrDie` stays unchanged: `Left` already logs at Error and exits `1`.

- *Alternative — warn via `logWarning` and continue:* Rejected in explore; operator wants a hard fail.
- *Alternative — check only in `Main` and leave `loadConfig` permissive:* Rejected; every work command goes through `loadConfig`, and tests would not exercise the gate on the real loader.
- *Alternative — keep `loadConfigWithWarn` with an error callback:* Rejected; the callback exists to print a warning. `Either` is the error channel.

**2. Mode before read; exact `0600`; `stat` fail-closed.**

Order after the file is located:

1. `getFileStatus` fails → `Left` (do not `readFile`)
2. `fileMode .&. 0o777 /= 0o600` → `Left` (do not `readFile`)
3. else decode as today

`0400` fails. Cannot prove the mode → same class of error as a bad mode (message still names the path and expected `0600`).

- *Alternative — “no group/other bits” (`mode .&. 0o077 == 0`):* Rejected; product choice is exact `0600`.
- *Alternative — fail-open on `stat` error:* Rejected; inconsistent with a gate.

**3. Fixture / test strategy.**

`loadConfig` on an in-tree `0644` fixture would now fail before decode. Git will not keep `0600` on those files.

- Success and decode-error cases that call `loadConfig` on a real file SHALL `setFileMode 0o600` first (in-place on fixtures is fine: git does not record that bit; prefer temp files where the test already creates one).
- Mode tests stay on temp files: `0644` → `Left`; `0600` → `Right`; inject a `stat` failure (or an unreadable path) → `Left`.
- Rewrite `testConfigModeWarns` / `testConfigModeSilent` to assert `ConfigError` vs success. Drop callback/`IORef` assertions.

**4. Docs in the same change.**

README configuration paragraph: hard-fail + `chmod 600`, not warn-and-continue. Matches `project-docs`. Living `config-file-permissions` Purpose already states the hard-fail (delta cannot change Purpose).

## Risks / Trade-offs

- **[Existing operator configs at `0644` start failing]** → Documented **BREAKING**; README says `chmod 600`. No auto-fix.
- **[Fixture tests flip from decode errors to permission errors if mode is not set first]** → Decision 3; chmod before `loadConfig` on existing files.
- **[Unused warn-hook exports trip weeder]** → Delete them rather than adding roots.
- **[`--log-level error` still shows the message]** → Desired: this is Error, not Warning.

## Migration Plan

Operators: `chmod 600` the overlay-manager TOML (XDG default or `--config` path) before the next work command. Rollback is revert this change; old warn-and-continue behavior returns.
