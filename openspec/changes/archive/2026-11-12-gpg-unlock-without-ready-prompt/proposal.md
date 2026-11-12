# Proposal

## Why

Before a cold GPG unlock, the program stops at "Press Enter when ready to unlock GPG for signed commits…" and only then starts pinentry. The GitHub token and SSH passphrase prompts appear immediately and never time out, so GPG is the odd one out.

The gate exists because of a pinentry timeout: `pinentry-tty` gives up after 60 seconds when the agent sends no timeout (measured, pinentry 1.3.3 and GnuPG 2.5.24), so an operator who has stepped away would hard-fail the run. The Enter wait has no timeout, so the 60 seconds only started once the operator was back. The session agent's `gpg-agent.conf` can raise that limit: `pinentry-timeout` is a plain config line, and with a very large value the gate has nothing left to protect.

## What Changes

- Set `pinentry-timeout 2147483647` in the session agent's `gpg-agent.conf`. That is `INT_MAX` seconds, the largest value `pinentry-tty` can parse safely (it reads the value with `atoi` into an `int`; larger values wrap to a small or zero timeout). A value of `0` does not work, because the agent then sends no timeout and pinentry falls back to 60 seconds.
- Remove the "press Enter" ready-prompt. A cold unlock goes straight to the terminal pinentry, which appears immediately like the GitHub token and SSH passphrase prompts.
- Keep everything else about the cold-unlock path: the controlling-terminal requirement and its hard-fail, the activity panel pause around the unlock, the up-front unlock before concurrent work, the warm check before each signed commit, and the `GPG_TTY` / `DISPLAY` handling.
- Drop the ready-prompt from the injectable agent operations and from the tests that fake it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `gpg-sign-readiness`: the cold-cache requirement stops requiring a ready confirmation before pinentry; the session agent requirement states the long `pinentry-timeout`; wording that names the ready-prompt (Purpose, warm and cold scenarios, no-flag requirement, up-front unlock requirement) is updated.
- `update-apply`: the "Parallel work then serial signed commits" requirement stops naming a ready-prompt in its description of GPG sign readiness.

## Impact

- Code: `src/Update/GpgAgent.hs` (`gpgAgentConfText`, `unlockCold`, `readyPromptOnTty`, the `gaoReadyPrompt` field of `GpgAgentOps` and its production wiring).
- Tests: `test/Test/Gpg.hs`, `test/Test/Waves.hs`, `test/Test/Git.hs` (fakes that set `gaoReadyPrompt`; the "Cold Ready Prompt Fails" case; prompt-count assertions).
- Specs: the two capabilities above. No change to `run-metrics`: the `prompt` span still covers the activity panel pause around the unlock.
- Docs: README, CONTRIBUTING and AGENTS do not mention the ready-prompt, so no edits are expected; confirm during the doc check.
- Operator-visible: the passphrase prompt now appears right after the SSH prompt (and before concurrent package work) with no confirmation step, and it never times out. The operator must be at the terminal at launch, as already needed for the token and SSH prompts.

## Non-goals

- Changing which pinentry is used (`pinentry-tty` stays) or how `GPG_TTY` and `DISPLAY` are set.
- Unattended unlock without a terminal; that stays out of scope and still hard-fails.
- A wrapper script that passes `--timeout 0` to `pinentry-tty`; the config value is enough.
- Changing the desktop agent, its configuration, or cache lifetimes.
- Changing the GitHub token or SSH prompt behavior.
