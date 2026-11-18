# Spec Delta

## ADDED Requirements

### Requirement: README documents gated publishing

`README.md` SHALL document, in its `update` section:

- that each update is smoke-tested before any publish or commit, and that there is no opt-out;
- the per-unit order from build to overlay push;
- that unpublished distfiles are served to the gate by a fetch shim;
- the prerequisites, Docker 28 or newer and the containerd image store, which apply whenever work exists;
- `--no-compile-cache`.

#### Scenario: Operator reads why update takes longer

- **WHEN** an operator reads the `update` section of `README.md`
- **THEN** it explains that each update runs one smoke run per lane ceiling before publishing

### Requirement: README documents overlay push and sync requirements

`README.md` SHALL state that `update` pushes the overlay after each unit's commit. It SHALL state that the overlay and assets branches must have an upstream and be in sync with it before a run that has work, and how to recover when they are not. It SHALL state that an overlay push failure keeps the commit and stops further publishing, and that `ssh-identity` is needed whenever work exists.

#### Scenario: Refused run

- **WHEN** an operator's `update` is refused because the overlay is ahead of its upstream
- **THEN** the README tells them to push or reconcile the branch and run `update` again

### Requirement: README documents held entries

`README.md` SHALL document when a unit is held, the held entry location and contents, how to inspect or re-apply a held patch by hand, and that held entries are never removed by the program or by `eclean`.

#### Scenario: Operator inspects a failed update

- **WHEN** an operator reads the README after a gate failure
- **THEN** it names the `held/` directory and shows how to apply the held patch with `git apply`
