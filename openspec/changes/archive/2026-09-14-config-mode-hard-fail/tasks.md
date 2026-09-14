## 1. Config loader hard-fail

- [x] 1.1 Add a `ConfigError` constructor for wrong or unreadable mode; `configErrorMessage` names the path and expected `0600`
- [x] 1.2 In `loadConfig`, inspect mode after the file is located and before `readFile`; `Left` on not-exactly-`0600` and on `stat` failure
- [x] 1.3 Remove `loadConfigWithWarn`, `configPermissionWarning`, and the raw `hPutStrLn` warn path (do not leave unused exports)

## 2. Tests

- [x] 2.1 `setFileMode 0o600` (or equivalent temp file) before every `loadConfig` that expects success or a decode error
- [x] 2.2 Replace warn-and-continue mode tests with `0644` → `Left`, `0600` → `Right`, and unreadable-mode → `Left`

## 3. Docs and quality gate

- [x] 3.1 Update `README.md` configuration text: hard-fail + `chmod 600`, not warn-and-continue
- [x] 3.2 `openspec validate --change config-mode-hard-fail --strict` and `hk check`; fix format/lint/weeder from the hook removal
