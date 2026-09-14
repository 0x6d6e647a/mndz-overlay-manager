## Why

The overlay-manager TOML may hold a GitHub API token as a plaintext `github-token` string. That secret is typically a classic PAT (`ghp_`) with coarse scopes, while the program only needs write on the assets GitHub repository (plus public read). File mode `0600` does not encrypt the value, and there is no command to store a wrapped token without putting it on the shell history.

## What Changes

- **BREAKING:** Any command that loads the overlay-manager TOML SHALL hard-fail (error-level log, exit `1`) when `github-token` is present and is not a `mndz1.` ciphertext envelope — including a live `github_pat_` / `ghp_` / other plaintext secret, even if `GITHUB_TOKEN` or `GH_TOKEN` would have won resolution. Help-only paths still skip config load. Omitted `github-token` remains valid.
- Add work command `github-token`: controlling TTY only; prompt for a fine-grained PAT then a wrapping password (confirmed); probe GitHub; encrypt (Argon2id + XChaCha20-Poly1305); surgically write the envelope into the existing `github-token` key; keep mode `0600`. Refuse an existing key unless `--force`.
- Setter SHALL accept only `github_pat_…`. Probe `GET` the assets repo from `assets-path` `origin`, require `GET /user/repos` (owner affiliation) to be exactly that one repository, and `POST /repos/…/releases` with `{}` expecting HTTP 422 (Contents: write, nothing created). Probe failure is fail-closed (do not write).
- Decrypt the config token only when a **config** token is actually required (assets publish / reuse). Env `GITHUB_TOKEN` then `GH_TOKEN` still win; when env is used, log a warning, plus an extra warning if the env value is not `github_pat_`. Do not probe env. Unattended `update` uses env (no TTY decrypt).
- Derive GitHub `owner/repo` from `assets-path`’s `origin` (`github.com` only, SSH or HTTPS). Use that pair for token probe, Releases API, and assets `SRC_URI` write/detect. Stop hardcoding `0x6d6e647a/mndz-overlay-assets` in those paths.
- README and `github-token --help` document creating a fine-grained PAT (only the assets repo, Contents: write) and the encrypt/migrate flow (`github-token --force` to replace plaintext).

### Non-goals

- Minting a PAT via GitHub REST or `gh` (no public user mint API; `gh auth token` is overly broad)
- Proving least privilege beyond the probe (extra checkboxes on that one repo are not introspectable)
- OS keyring, GPG-wrapping the token, or a token agent daemon
- GitHub Enterprise / non-`github.com` hosts
- Changing overlay `profiles/repo_name` must equal `mndz`, or un-hardcoding package policies
- `--token` / password CLI flags (secrets must not enter argv or shell history)
- Auto-opening a browser; probing env tokens; rewriting comments via full TOML `encode`

## Capabilities

### New Capabilities

- `github-token-command`: Interactive `github-token` work command (TTY prompts, `--force`, probe, encrypt, config splice); command-scoped help; loads config like `eclean` (no overlay validation)

### Modified Capabilities

- `github-auth`: Encrypted `github-token` envelope; plaintext-on-disk hard-fail; resolution order with decrypt-when-needed; env warnings; never log secrets
- `cli-help`: Catalog `github-token`; per-command help and `--force`; include it in the work-command list
- `overlay-path-resolution`: Config load classifies `github-token` (omit vs envelope vs plaintext); `github-token` command loads config without overlay validation
- `assets-publish`: GitHub Releases owner/repo from `assets-path` `origin` (`github.com`)
- `deps-assets`: Assets `SRC_URI` marker is `{owner}/{repo}/releases/download/` from that origin, not a hardcoded repo name
- `go-vendor-assets`: Written/detected vendor assets URLs use the derived host/repo
- `cargo-crates-assets`: Written crates assets URLs use the derived host/repo
- `update-command`: When assets work needs a config token, decrypt on a controlling TTY; when assets work needs GitHub, parse `origin` or hard-fail
- `project-docs`: README documents the command, encryption, FG PAT, migrate/`--force`, derived assets repo
- `test-coverage`: Cover envelope detect, splice, origin parse, setter probe fakes, env warnings, CLI parse of `github-token`

## Impact

- **Code:** `CLI.Parser` / `Main`; `Config.Loader` / `Types`; `Update.Auth`; new encrypt/splice helpers; `Update.Assets.Release` owner/repo wiring; `Update.EbuildEdit` SRC_URI templates/markers; spine preflight decrypt + origin parse
- **Deps:** `crypton` already present for hashing; use it for Argon2id + XChaCha20-Poly1305 (no new crypto package unless `crypton` cannot express that construction)
- **Tests:** Unit fakes for HTTP probe and crypto; no live GitHub or interactive TTY in the coverage gate
- **Docs:** `README.md` per `project-docs`; in-binary help per `cli-help`
- **Operator:** Existing plaintext `github-token` configs fail until `github-token --force`; wrap password required on `update` when the config token is used
