## ADDED Requirements

### Requirement: Suite exercises residual agent, Git, and Release HTTP surfaces

The test suite SHALL include Unit and/or Integration tests that execute residual product surfaces for SSH agent session handling, GPG readiness edges not already covered, Git operations edges via injectable git ops, and Assets.Release HTTP-oriented paths (download/create/delete as product exposes them) using fakes rather than live agents or live GitHub API access in the coverage gate.

#### Scenario: SSH and GPG residual paths run with fakes

- **WHEN** agent-oriented tests run under the coverage entrypoint
- **THEN** product SSH session and/or GPG readiness code paths beyond the pre-wave baseline are executed with injectable ops or controlled environment fakes

#### Scenario: Git and Release residual paths run with fakes

- **WHEN** Git- and Release-oriented residual tests run under the coverage entrypoint
- **THEN** product Git ops edge paths and Assets.Release HTTP-oriented paths are executed without requiring interactive pinentry or live GitHub network access

#### Scenario: Http and Npm fetch residual when still thin

- **WHEN** after prior waves Http or Npm fetch product modules remain largely unexercised
- **THEN** the suite includes Unit and/or Integration tests that execute those fetch paths via fakes or injectable managers

### Requirement: Maximization program leaves floors unenforced

After residual coverage tests land, the coverage entrypoint SHALL still succeed based on tests and report production only. Numeric floors and ratchet baselines SHALL remain out of scope for this residual wave (a separate change may introduce them later).

#### Scenario: No floor enforcement after residual wave

- **WHEN** Wave-5 residual tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor or differs from a baseline file
