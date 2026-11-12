# Design

## Context

See proposal.md for motivation. Current state, read from `src/Update/GpgAgent.hs`:

- `gpgAgentConfText` writes the session `gpg-agent.conf` (`default-cache-ttl 28800`, `max-cache-ttl 28800`, `pinentry-program /usr/bin/pinentry-tty`). `writeGpgSessionSkeleton` writes it into the process-owned session home, from `prepareSigningSession` and again from `buildGpgSessionHomeWith`. Every GPG child gets that home through `GNUPGHOME` (`pinentryChildEnv`) or `--homedir`. The desktop agent and its config are never used for signing.
- `unlockCold` runs, for a cold keygrip with a controlling terminal: `bracket_ gaoPauseUi gaoResumeUi (gaoReadyPrompt >>= gaoWarmKey)`. `readyPromptOnTty` writes "Press Enter when ready…" to the terminal device node and blocks on a line. `warmKeyDummy` then runs `gpg --clearsign` with `GPG_TTY` set and `DISPLAY` cleared, which starts `pinentry-tty` through the session agent.

Facts measured with the installed stack (pinentry 1.3.3, GnuPG 2.5.24), and confirmed in their source:

- gpg-agent sends `SETTIMEOUT n` to pinentry only when `pinentry-timeout` is nonzero (`agent/call-pinentry.c`). The option is parsed as an unsigned long.
- pinentry stores the value with `atoi` into an `int` (`cmd_settimeout`), and `pinentry-tty` arms `alarm(timeout)`. With no `SETTIMEOUT`, pinentry's default is 60 seconds.
- Through the real agent: no setting timed out at 60s; `pinentry-timeout 0` timed out at 60s; `86400` and `2147483647` stayed open past 60s (75s and 12s probes).
- `atoi` of a value above `INT_MAX` wraps (`2147483648` → negative, `4294967296` → `0`, `4294967297` → `1`), so the configured value must not exceed `2147483647`.

## Goals / Non-Goals

**Goals:**

- The GPG passphrase prompt appears as soon as unlock is needed, like the GitHub token and SSH passphrase prompts, and does not expire while the operator is away.
- Remove the ready-prompt code, its injectable seam, and the tests that only exist for it.

**Non-Goals:**

- A pinentry wrapper script. `pinentry-program` takes a filename only, so passing `--timeout 0` would need a generated executable; the config value makes that unnecessary.
- Any change to when unlock happens (still before concurrent work, and again only if the session cache is cold before a signed commit).
- Supporting a pinentry other than `pinentry-tty`; the session config already pins it.

## Decisions

**1. `pinentry-timeout 2147483647` in the session `gpg-agent.conf`.**
`INT_MAX` is the largest value that survives `atoi`, and `alarm` takes an `unsigned int`, so it is also safe on the pinentry side. Alternatives: `86400` (a day; not unlimited but longer than the 8h cache, and the same one-line change), rejected because the true maximum costs nothing; `0` (does not work, the agent sends nothing and pinentry uses 60s); a wrapper script with `--timeout 0` (truly no timeout, but an extra generated executable whose failure mode is `No pinentry`). Put a short comment beside the value saying why it is `INT_MAX`, so it is not "rounded up" later.

**2. Remove the ready-prompt rather than keeping it for mid-run unlocks.**
The only job of the gate was to start pinentry's 60-second clock when the operator was present. With no practical timeout there is nothing left for it to protect, and a cold mid-run unlock waits exactly as long either way. One code path is simpler than two. Cost: an unexpected passphrase prompt in a mid-run unlock appears without a warning line; pinentry's own description (key user id and id) says what it is asking for.

**3. Delete `gaoReadyPrompt` and `readyPromptOnTty` outright.**
`unlockCold` becomes `bracket_ gaoPauseUi gaoResumeUi (gaoWarmKey ops mHome mTty key)`. The remaining "no controlling TTY" check in `unlockCold` stays (it already returns the "run from a terminal" error before the pause), so `readyPromptOnTty`'s own no-TTY error is dead. `warmKeyDummy`'s "Unlocking GPG signing key (TTY pinentry)…" status line stays, as the one line the operator sees before pinentry's own text.

**4. Spec housekeeping.**
`gpg-sign-readiness` renames "Ready prompt and unlock when cache is cold" to "Unlock when cache is cold" and gains one requirement stating the non-expiring prompt. The delta validator refuses to drop a scenario from a MODIFIED block, so three scenario names that still say "ready" ("Warm cache skips ready prompt", "Cold cache requires readiness", "Ready then unlock on TTY") are kept in the delta with updated bodies; the SoT scrub task renames them in the main spec after sync. `update-apply` only needs one parenthetical edited, but a MODIFIED requirement must carry its whole block, so the delta copies it.

## Risks / Trade-offs

- [Operator is away at launch and the prompt waits forever] → Same as the GitHub token and SSH prompts; the run does no package work before the unlock completes, so nothing is half-applied. Ctrl-C ends it.
- [Prompt appears with no confirmation, so keys typed beforehand can land in it] → Minor and shared with the SSH prompt. The unlock happens right after the SSH prompt and before concurrent work, so there is no output churn to type through.
- [A future GnuPG/pinentry changes how the timeout is read] → The value is a documented option and `INT_MAX` is accepted by both `atoi` and `alarm`; a unit test pins the generated config text so a change is visible. The 75s live probe is manual, not part of the gate (the gate must not need a live pinentry).
- [Mid-run cold unlock loses the warning line] → Accepted under decision 2; it only happens if the 8h cache expires during a run.

## Open Questions

None blocking. Whether to also add an automated, opt-in smoke test that runs the live agent through a pty is deferred; the coverage gate must stay free of live pinentry.
