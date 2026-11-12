# Tasks

## 1. Long pinentry timeout in the session agent

- [x] 1.1 In `src/Update/GpgAgent.hs`, add `pinentry-timeout 2147483647` to `gpgAgentConfText`, with a comment that it is `INT_MAX` because pinentry parses it with `atoi` and `0` falls back to the 60 second default. Verify with the session-home test in `test/Test/Gpg.hs` (the case that reads `gpg-agent.conf`): add an assertion that the file contains `pinentry-timeout 2147483647`, then run `just coverage <pattern>` for that case and see it pass.
- [x] 1.2 Manual live probe (not part of the gate): with a throwaway `GNUPGHOME` using the generated conf and a passphrase-protected key, run `gpg --clearsign` on a pty with `GPG_TTY` set, leave the prompt open for over 60 seconds, and confirm no `Timeout` error. Note the result in the PR or commit message.

## 2. Remove the ready-prompt

- [x] 2.1 In `src/Update/GpgAgent.hs`, remove `readyPromptOnTty`, the `gaoReadyPrompt` field of `GpgAgentOps`, and its wiring in `mkGpgAgentOps`; change `unlockCold` to call `gaoWarmKey` directly inside the existing `bracket_ gaoPauseUi gaoResumeUi`, keeping the no-controlling-TTY hard-fail before the pause. Update the comments that mention the ready-prompt (the field doc, `mkGpgAgentOps`, and the cold/warm comment above `ensureGpgReady`). Verify with `just build-release` and no leftover references: `grep -rn "gaoReadyPrompt\|readyPromptOnTty" src test` finds nothing.
- [x] 2.2 Update the tests that fake the ready-prompt: drop the `gaoReadyPrompt` field from the fakes in `test/Test/Gpg.hs`, `test/Test/Waves.hs`, and `test/Test/Git.hs`; remove "Cold Ready Prompt Fails" (`testColdReadyPromptFails`) and rename "Cold Cache Ready Then Warm" (`testColdCacheReadyThenWarm`) to describe a cold cache unlocking once; replace the "no ready prompt when warm" prompt-count assertions with assertions on warm-key calls; in `test/Test/Waves.hs` drop the `"prompt"` event from the expected event order. Verify with `just coverage` passing for the Gpg, Waves, and Git groups.

## 3. Specs and docs

- [x] 3.1 Sync the delta specs into `openspec/specs/` (`openspec-sync-specs`, or on archive). Then scrub residue directly in the main `gpg-sign-readiness` spec: update the Purpose line (it still says "ready-prompt and TTY pinentry"), and rename the three scenarios the delta had to keep under their old names ("Warm cache skips ready prompt", "Cold cache requires readiness", "Ready then unlock on TTY") to match their new meaning. Verify with `grep -rniE "ready.?prompt|press enter" openspec/specs` returning nothing and `openspec validate --specs` passing.
- [x] 3.2 Confirm README.md, CONTRIBUTING.md and AGENTS.md do not describe the Enter-to-continue step or a GPG prompt timeout (`grep -niE "press enter|pinentry|gpg" README.md CONTRIBUTING.md AGENTS.md`); update the matching file in this change if any does, per `project-docs`. If README documents the operator prompts, add one line that the GPG passphrase prompt appears immediately and does not time out.

## 4. Gate

- [x] 4.1 Run `openspec validate gpg-unlock-without-ready-prompt --strict`, then `just check` (runs `hk check`, including format, hlint, release build, stan, weeder, and coverage tests) and verify it is green. Mark tasks complete only after this passes.

## Workflow follow-up

- Archive the change after review.
- Verify the archived result by re-running `openspec validate --specs --strict`.
