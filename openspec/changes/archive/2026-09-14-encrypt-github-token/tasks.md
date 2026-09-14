## 1. Envelope, load gate, and origin parse

- [x] 1.1 Add pure `mndz1.` envelope encode/decode (Argon2id + ChaCha20-Poly1305 or XChaCha20-Poly1305 via `crypton`) and verify round-trip plus wrong-password failure tests
- [x] 1.2 Classify on-disk `github-token` (omit / envelope / plaintext) at config load; plaintext hard-fails even when env is set; verify load tests for omit, `mndz1.`, `ghp_`, `github_pat_`, and env-does-not-excuse
- [x] 1.3 Parse `github.com/{owner}/{repo}` from `origin` URL forms (SSH, `ssh://`, HTTPS, optional `.git`) and verify reject tests for missing origin, non-GitHub hosts, and unparsable URLs

## 2. Token resolution and update wiring

- [x] 2.1 Extend token resolution: env still wins with warning (+ extra warning if not `github_pat_`); decrypt envelope only when a config token is required; no TTY → hard-fail; verify pure/warning tests and that `outdated` does not decrypt
- [x] 2.2 When `update` needs assets GitHub, parse `assets-path` `origin` into owner/repo (replace hardcoded `0x6d6e647a` / `mndz-overlay-assets`) and verify a missing/`origin` failure happens before mutate
- [x] 2.3 Pause activity indicators during wrap-password prompt (same hooks as GPG) and verify a fake-prompt unit path does not need a live TTY

## 3. `github-token` command

- [x] 3.1 Add `github-token` / `--force` to `CLI.Parser` and top-level/command help; verify parse tests and `github-token --help` exits 0 without loading config
- [x] 3.2 Implement TTY prompts (token, then probe, then password twice), `github_pat_` prefix gate, and fail-closed HTTP probe (GET repo, `/user/repos` singleton, empty POST `/releases` 422 vs 403) with injectable HTTP; verify fake-HTTP tests for classic PAT, extra repos, 403, and 422 success
- [x] 3.3 Surgical TOML splice of `github-token`, re-decode, atomic write, mode `0600`; skip overlay validation; existing key without `--force` hard-fails; verify splice tests preserve sibling keys/comments and `--force` overwrite

## 4. SRC_URI from origin

- [x] 4.1 Parameterize assets download marker and write templates in `Update.EbuildEdit` from `{owner}/{repo}`; verify Go vendor and Cargo crates URL tests for a non-mndz origin and that jemalloc/non-assets companions stay untouched
- [x] 4.2 Keep package-owned vs pin-keyed (rusty-v8) ownership using the derived `{repo}/releases/download/` marker; verify frozen `{pn}-` still needs work and rusty-v8 tags do not

## 5. Docs and quality gate

- [x] 5.1 Update `README.md`: `github-token` command, `--force` migrate, `mndz1.` envelope, FG PAT (Contents: write, only assets repo), env warnings, origin-derived assets GitHub repo
- [x] 5.2 Expand Unit coverage per `test-coverage` (CLI parse, envelope, origin parse, load gate, probe fakes, env warnings) without live GitHub or interactive TTY
- [x] 5.3 `openspec validate --change encrypt-github-token --strict` and `hk check`; fix format/lint/weeder (no new unused exports, no blanket weeder roots)
