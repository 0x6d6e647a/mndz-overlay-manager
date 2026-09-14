## Context

See proposal.md for motivation. Today `github-token` is an optional plaintext TOML string (`Config.Types` / `toml-parser` decode). `Update.Auth.resolveGitHubToken` prefers `GITHUB_TOKEN` then `GH_TOKEN` then that string. Releases API owner/repo are hardcoded in `app/Main.hs` as `0x6d6e647a` / `mndz-overlay-assets`. Ebuild assets URLs and the `mndz-overlay-assets/releases/download/` marker live in `Update.EbuildEdit`. Config is read-only (`Config.Loader`); `eclean` loads config without overlay validation. SSH/GPG already prompt on a controlling TTY and pause activity indicators.

`toml-parser` encode/pretty-print drops comments and sorts keys. `crypton` is already a library dependency (hashing).

## Goals / Non-Goals

**Goals:**

- Classify on-disk `github-token` at load: omit, `mndz1.` envelope, or plaintext hard-fail.
- One interactive setter; surgical TOML splice; mode `0600`.
- Decrypt only when a config token is required; env still wins with warnings.
- One `{owner}/{repo}` parsed from `assets-path` `origin` for probe, Releases API, and SRC_URI.
- Tests use injectable HTTP and do not need a live TTY or live GitHub.

**Non-Goals:**

- Comment-preserving full-document TOML encode.
- New crypto packages unless `crypton` cannot provide Argon2id + a one-shot AEAD.
- Un-hardcoding overlay `repo_name == mndz` or package policies.
- GitHub Enterprise.

## Decisions

**1. Envelope `mndz1.` as the same TOML key**

Keep `github-token` as `Maybe Text`. A present value must start with `mndz1.` or config load fails. Version byte in the prefix allows `mndz2.` later. Payload after the prefix: base64 (or unpadded base64url) of salt, nonce, ciphertext+tag, and KDF parameters so decrypt does not need extra config keys.

- *Alternative — `github-token-enc` key:* Rejected in explore; one key, detect by prefix.
- *Alternative — sidecar file:* Rejected; extra path and mode to keep in sync.

**2. Argon2id then ChaCha20-Poly1305 (XChaCha if `crypton` exports it)**

Derive a 256-bit key with Argon2id (id variant, parameters stored in the envelope; pick moderate interactive defaults, e.g. 64 MiB memory). Encrypt with XChaCha20-Poly1305 when available; otherwise IETF ChaCha20-Poly1305 with a fresh 12-byte random nonce (each envelope has unique salt+nonce, one message). Use `crypton` only. Confirm wrap password twice on set.

- *Alternative — AES-GCM:* Rejected; nonce misuse is easier and we already have ChaCha in the hashing-era `crypton` tree.
- *Alternative — GPG-wrap:* Rejected; operator chose a dedicated wrap password.

**3. Surgical splice + decode-before/decode-after**

Do not `Toml.encode` the whole `OverlayConfig`. After a successful decode of the current file:

- If a top-level `github-token = "…"` (or `'…'`) line exists, replace the quoted value.
- Else append `github-token = "mndz1.…"` as a new line.
- Decode the result as `OverlayConfig` again; abort if that fails.
- Atomic replace (`rename` over the original) and `chmod 0600`.

- *Alternative — full prettyToml rewrite:* Rejected; comments and key order die.
- *Alternative — regex-only without re-decode:* Rejected; fail-closed on a bad splice.

**4. Prompt order: token → probe → passwords → write**

Refuse non-`github_pat_` immediately. Probe with injectable HTTP (same `HttpLbs` style as `Update.Assets.Release`). Empty `POST /releases` → 422 means Contents: write without creating a release. `/user/repos?affiliation=owner` must be exactly the origin repo (pagination). Fail closed. Then wrap-password twice.

- *Alternative — skip write probe:* Rejected; operator asked to probe.
- *Alternative — create+delete a draft:* Rejected; leftover tags if delete fails.

**5. `origin` parse is the assets identity**

Parse `git remote get-url origin` (production via `CommandRunner`). Accept:

- `git@github.com:owner/repo.git`
- `ssh://git@github.com/owner/repo.git`
- `https://github.com/owner/repo[.git]`

Use that pair in `usdAssetsOwner` / `usdAssetsRepo` / `aeAssetsOwner` / `aeAssetsRepo` and in EbuildEdit marker/templates (`{repo}/releases/download/`). `github-token` requires this parse; `update` requires it when assets GitHub is required. Remote name `origin` is the only remaining name hardcode.

- *Alternative — keep hardcoded `0x6d6e647a/mndz-overlay-assets` for publish:* Rejected; probe and publish would diverge, and adopters would still write the wrong SRC_URI.

**6. CLI: `github-token` like `eclean`**

New `Command` constructor. `--force` is command-local (same flag name as `gencache`; different meaning — document in command help). Load config via `loadConfigOrDie`; skip `loadValidatedEbuilds`. No overlay validation.

**7. Decrypt site and env warnings**

Extend `resolveGitHubToken` (or a wrapper used by `outdated` / `update`) to:

1. After config load has already rejected plaintext.
2. If env wins: warning (+ extra warning if not `github_pat_`); return env; no decrypt.
3. If envelope present and caller says token is required: TTY prompt, decrypt, cache for the process.
4. If envelope present and token is not required: return `Nothing` (do not decrypt).

`outdated` does not require a config token. `update` requires one only on the existing assets/token preflight. Pause/resume activity indicators around the prompt (same hooks as GPG).

**8. Tests without a live TTY**

Pure: prefix classify, origin parse, envelope round-trip with a supplied password, splice on fixture strings, resolution/warning helpers.

HTTP: fake `HttpLbs` for GET repo, GET `/user/repos`, POST releases.

Do not drive real `/dev/tty` in the coverage gate; inject prompt functions.

## Risks / Trade-offs

- **[Existing plaintext configs hard-fail until `github-token --force`]** → Documented **BREAKING**; README migrate path.
- **[Empty POST /releases 422 vs 403 is a GitHub convention, not a documented dry-run]** → If GitHub changes that, setter fails closed; `update` still fails a read-only token. Tests pin the 422/403 split.
- **[`/user/repos` singleton cannot distinguish “only select” from “all repos” when the user owns one repo]** → Accepted; document “Only select repositories.”
- **[Wrap password forgotten]** → Re-run `github-token --force` with a live PAT; no recovery of the old envelope.
- **[Surgical splice misses exotic TOML (multiline, dotted tables)]** → Re-decode fails closed; operator-facing files are a flat table of strings.
- **[SRC_URI marker follows origin `{repo}` only]** → Foreign-host leftover URLs are not rewritten; mndz origin keeps today’s marker.

## Migration Plan

Operators:

1. Create a fine-grained PAT for the assets repo (Contents: write).
2. `chmod 600` remains required.
3. `mndz-overlay-manager github-token --force` (TTY).
4. Subsequent `update` that publishes assets prompts for the wrap password unless `GITHUB_TOKEN`/`GH_TOKEN` is set.

Rollback: revert the change; plaintext `github-token` works again. Encrypted values would then fail as unknown tokens until replaced with a live PAT.

## Open Questions

None that change specs or the task breakdown. Argon2id time/memory constants can be tuned in implementation as long as they are stored in the envelope.
