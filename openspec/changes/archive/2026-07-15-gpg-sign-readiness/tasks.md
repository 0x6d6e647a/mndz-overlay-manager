## 1. Spike and module skeleton

- [x] 1.1 Spike on this host: cold keygrip + `GPG_TTY` + child `DISPLAY` cleared → terminal pinentry (not gnome); document approach A vs B choice in a short note if B is required
- [x] 1.2 Spike dummy warm (clearsign/`gpg --sign` with `user.signingkey`) vs first `commit -S` as unlock; prefer dummy if reliable
- [x] 1.3 Add `Update.GpgAgent` module skeleton: types for keygrip, per-worktree state (`weWarmed`), injectable `GpgAgentOps`, production ops stubs
- [x] 1.4 Export module from library (`mndz-overlay-manager.cabal` / package modules list as required)

## 2. Key resolution and agent ops

- [x] 2.1 Implement `resolveSigningKeygrip` via `git -C <repo> config --get user.signingkey` + gpg colon/keygrip listing; hard-fail if unset or non-sign-capable (no gpg default fallback)
- [x] 2.2 Implement KEYINFO poll: cached `1` vs `-` for a keygrip
- [x] 2.3 Implement ready-prompt on controlling `/dev/tty` (message + wait for Enter); hard-fail if no TTY when unlock required
- [x] 2.4 Implement unlock/warm under TTY pinentry env (`GPG_TTY` set, `DISPLAY` cleared for child); mark `weWarmed` for that keygrip
- [x] 2.5 Implement `CLEAR_PASSPHRASE` (or equivalent) for warmed keygrips only; dedupe by keygrip; teardown entrypoint for Main

## 3. Wire into signed commits and Main

- [x] 3.1 Thread GPG readiness state/handle through apply / `GitOps` so every `git commit -S` (overlay phase-2 and assets publish) calls ensure-ready for that worktree first
- [x] 3.2 Ensure signed-commit child processes use the TTY pinentry environment (`GPG_TTY`, no `DISPLAY` in child)
- [x] 3.3 Bracket GPG teardown in `app/Main.hs` for `update` (clear warmed keygrips on success or failure), analogous to SSH session teardown
- [x] 3.4 Surface readiness/signingkey/TTY failures as hard package or spine errors with clear messages (no unsigned fallback)

## 4. Tests and quality gates

- [x] 4.1 Unit tests with fake ops: missing `user.signingkey` fails; warm cache skips prompt; cold cache requires ready then warm; no TTY fails; clear only if warmed; per-repo keygrips
- [x] 4.2 Keep default `cabal test` free of live pinentry / interactive gpg
- [x] 4.3 Format and pass `hk check` (ormolu, build, test, hlint, stan, weeder); update `weeder.toml` only if new intentional roots are required

## 5. Manual smoke (maintainer)

- [x] 5.1 Manual smoke: cold agent, run `update` for a signing package → ready prompt + TTY pinentry + successful signed commit + KEYINFO cold after exit
- [x] 5.2 Manual smoke: already-warm agent → no ready prompt; exit does not clear (we did not warm)
- [x] 5.3 Manual smoke: assets path (if available) uses assets worktree `user.signingkey` / same global key without GUI pinentry
