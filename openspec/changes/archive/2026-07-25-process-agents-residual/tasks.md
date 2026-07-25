## 1. Prerequisites

- [x] 1.1 Confirm `process-command-runner` Process/CommandRunner seam is available (or land minimal shared seam if this change is applied out of order—prefer sequential apply)

## 2. SSH captured production

- [x] 2.1 Route captured-I/O production SSH helpers through CommandRunner / mk production Ops
- [x] 2.2 Unit: scripted success path for ensure/reuse/teardown edges that enter production helpers
- [x] 2.3 Unit: scripted failure paths (run agent fail, list fail, kill edge) as product exposes them
- [x] 2.4 Do not require TTY/askpass interactive matrix for done criteria

## 3. GPG process residual

- [x] 3.1 Identify yellow production GPG process helpers via HPC markup
- [x] 3.2 Route residual through Ops/CommandRunner; Unit success + failure edges

## 4. Quality gate

- [x] 4.1 `./scripts/coverage` green (floor-free)
- [x] 4.2 `hk check` green
- [x] 4.3 Note remaining interactive SSH residual as known non-goal if still yellow

### Known residual (non-goal of this change)

Interactive SSH add paths remain intentionally unheated under Unit:

- `runSshAddInteractive` / `discoverIdentityFiles` (host FS + key discovery)
- `sshAddWithDevTty` / `sshAddWithAskPass` / `findAskPass` / `runSshAddProcess`
- GPG TTY ready-prompt and controlling-tty open (`readyPromptOnTty`, `controllingTtyPath`) stay host-local; cold unlock still requires TTY in production, but Unit heats process bodies via fakes without pinentry

These are deferred per design D1/D3 (captured I/O first; full interactive matrix optional follow-up).
