## Why

Work commands that find the overlay-manager TOML with a mode other than `0600` print a bare line and continue with exit `0`. That is not a logger event, so it has no `[Error]` / `[Warning]` tag, and it is not a hard failure — a file that may hold `github-token` stays usable while world-readable. The check should be a real config-load error.

## What Changes

- **BREAKING** for operators: a work command that locates the overlay-manager TOML SHALL hard-fail when the file mode is not exactly `0600`, or when the mode cannot be read (`stat` fail-closed). The program SHALL log an error naming the path and expected mode `0600`, and SHALL exit with status `1` without using that file.
- Route the failure through the existing config-load error path (`logError` + exit `1`), not a raw stdout/stderr print and not a warning that continues.
- `0600` remains silent. Help-only paths still do not load the file and do not emit this error.
- Token resolution order and acceptance of a `github-token` key stay unchanged.
- README (and the `project-docs` requirement that describes this) switch from “warn and continue” to hard-fail + `chmod 600`.

### Non-goals

- Auto-`chmod` or rewriting the config file
- Accepting any mode other than exact `0600` (including owner-read-only `0400`)
- Changing GitHub token resolution or forbidding `github-token` in the TOML
- Loading config on help-only paths
- New CLI flags or verbosity special-cases for this check

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `config-file-permissions`: Replace warn-and-continue with error-level log + exit `1` when the located file is not exactly mode `0600` or its mode cannot be read; `0600` stays silent; help-only paths still skip the check; token policy unchanged
- `overlay-path-resolution`: Config-load hard-fail list includes a located file whose mode is not exactly `0600` or whose mode cannot be read
- `project-docs`: README documents the `0600` hard-fail (not a warning)

## Impact

- **Code**: `Config.Loader` returns a `ConfigError` instead of calling a warn callback; drop `loadConfigWithWarn` / raw `hPutStrLn`; `loadConfigOrDie` already logs and exits on `Left`
- **Tests**: `0644` and unreadable-mode cases become `Left`; `0600` still loads
- **Docs**: `README.md` configuration paragraph per `project-docs`
- **Operator**: Existing non-`0600` configs fail until `chmod 600` the TOML
