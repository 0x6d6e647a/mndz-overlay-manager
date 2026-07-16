## Context

`update` creates GPG-signed commits via `git commit -S` in two places: mid-phase-1 assets publishes (`GoVendorAndAssets`) and the phase-2 overlay commit storm. Design option B already forbids reading the passphrase in-process and relies on gpg-agent + pinentry. There is no ready-gate, no per-worktree key resolution for readiness, and no clear of agent cache after this process unlocks keys. Operators launch long updates, walk away, and miss a timed GUI pinentry (e.g. pinentry-gnome3).

SSH already has an early-readiness + teardown pattern in `Update.SshAgent`. GPG needs an analogous, but **per-sign-gate** model (G3): check immediately before each signed commit, not only at process start—because agent TTL can expire during long phase-1 work.

## Goals / Non-Goals

**Goals:**

- Before every signed commit, if the signing key’s agent cache is cold, prompt on a controlling TTY then unlock via **terminal** pinentry so the operator is present.
- Resolve signing identity only from that worktree’s `git config user.signingkey`; map to a sign-capable keygrip for KEYINFO / clear.
- Track warm state **per worktree** (overlay vs assets); clear on exit only keygrips **this process** warmed.
- Set `GPG_TTY` and avoid GUI pinentry for warm/sign children (prefer approach A: child env with `GPG_TTY` set and `DISPLAY` cleared).
- Fail early when unlock is needed but no TTY, missing `user.signingkey`, or TTY pinentry cannot be arranged.
- Keep option B: never store the passphrase; never fall back to unsigned commits.

**Non-Goals:**

- Extending gpg-agent cache TTL for the session.
- Infinite pinentry timeout configuration.
- Fully automated / headless signing (no TTY).
- CLI flags to enable/disable readiness.
- Loopback pinentry or reading the passphrase into Haskell.
- Changing commit message format, ordering, or parallel/serial apply architecture beyond inserting readiness before sign.

## Decisions

**Decision: G3 — ensure readiness before every `git commit -S`**  
Single code path covers assets and overlay commits. Poll agent warmth each time; ready-prompt only when cold (including mid-run TTL expiry).  
Alternatives: start-only warm (rejected: TTL can expire during long phase-1); phase-2-only gate (rejected: assets sign mid-phase-1).

**Decision: Warm detection via `gpg-connect-agent KEYINFO`**  
Use keygrip status line field `cached`: `1` = warm, `-` = cold. Read-only; no unlock.  
Alternatives: attempt sign and catch failure (rejected: messier errors); ignore cache and always ready-prompt (rejected: noisy when already warm).

**Decision: Signing key from git config only**  
For the worktree about to sign: `git -C <repo> config --get user.signingkey`. If unset, hard-fail with a clear message. Map id → secret key → **sign-capable** keygrip (`gpg --list-secret-keys --with-colons --with-keygrip`). Do **not** fall back to gpg’s default secret key.  
Alternatives: gpg default key (rejected: wrong identity risk); global-only config without `-C` (rejected: per-repo override).

**Decision: Per-repo state, dedupe clear by keygrip**  
Maintain readiness state per worktree root (keygrip resolved for that repo, `weWarmed` flag). Teardown clears each distinct keygrip that was warmed at least once. Same grip on overlay and assets → one clear.

**Decision: Ready-prompt on `/dev/tty` then unlock**  
When cold: write a short “Press Enter when ready to unlock GPG for signed commits…” message and wait for Enter on the controlling terminal (same spirit as SSH passphrase path). Then unlock. If no controlling TTY when unlock is required, hard-fail (automation out of scope).

**Decision: Prefer dummy GPG warm after ready (implementation default)**  
After Enter, perform a disposable sign/clearsign with the resolved key under the TTY pinentry env so pinentry is isolated from `git commit`. Mark `weWarmed` only if this process caused unlock. If spike finds dummy unreliable, first `commit -S` as unlock is acceptable fallback (document in tasks).  
Alternatives: first commit is unlock only (simpler; worse error attribution).

**Decision: TTY pinentry via child environment (approach A first)**  
For warm and `git commit -S` children: set `GPG_TTY` to the controlling tty path; unset/clear `DISPLAY` in that child only so pinentry prefers curses/tty over gnome/qt. Parent process keeps its `DISPLAY`. If A fails on the maintainer stack, spike session-scoped `pinentry-program` → `pinentry-curses` with restore on teardown (approach B)—product requirements unchanged.  
Do not silently fall back to GUI pinentry for this path when a TTY is available.

**Decision: Clear only if we warmed**  
On exit (success or failure bracket, parallel to SSH teardown): `CLEAR_PASSPHRASE` for keygrips we marked warmed. Prefer surgical clear over `RELOADAGENT` (avoids flushing unrelated agent state when possible). If the agent was already warm from another tool and we never unlocked, do not clear.

**Decision: Module `Update.GpgAgent` + inject into signed commit path**  
Injectable ops (config lookup, KEYINFO, warm, clear, tty prompt) for unit tests without live pinentry. Wire from `gitAddAndSignedCommit` / `GitOps` or a thin wrapper used by apply; Main owns process-lifetime handle and teardown.

**Decision: No CLI flag**  
Always-on when a signed commit is attempted.

## Risks / Trade-offs

- [Approach A does not force curses on some pinentry builds] → Spike on real stack; fall back to session pinentry-program (B); fail early rather than GUI if TTY path cannot be arranged  
- [Dummy warm uses a different gpg invocation than git] → Pass explicit key id matching `user.signingkey`; verify KEYINFO warm before commit  
- [Clearing a grip the user wanted left open] → Only clear if we warmed; document behavior  
- [Concurrent `update` and other GPG clients] → KEYINFO/clear are best-effort shared agent; accept same class of races as normal gpg-agent use  
- [Ready-prompt races with multi-progress UI on stdout] → Use `/dev/tty` exclusively for ready I/O  
- [`ignore-cache-for-signing` in agent config] → Every sign pinentries; ready-prompt still helps presence; optional warn out of scope for v1  
- [Half-applied packages if sign fails after phase-1] → Unchanged hard-fail policy; readiness reduces timeout-induced sign failures  

## Migration Plan

1. Implement module + wire commit path + Main teardown.  
2. Operators must have `user.signingkey` set for overlay and assets worktrees that sign (global git config usually suffices).  
3. Prefer `pinentry-curses` available on PATH as fallback for agent; document TTY/`GPG_TTY` expectation for remote SSH.  
4. No data migration; no config file format change. Rollback = revert the change (prior lazy pinentry behavior).

## Open Questions

- Dummy warm vs first-commit unlock: prefer dummy; confirm in implementation spike.  
- Exact child env for approach A reliability on Gentoo + pinentry-gnome3: confirm in spike; B if needed.  
- Whether `gpg-connect-agent` / `gpg` must be on PATH beyond existing `gpg` preflight: treat agent tools as required for readiness when signing (fail with clear error if KEYINFO unavailable).
