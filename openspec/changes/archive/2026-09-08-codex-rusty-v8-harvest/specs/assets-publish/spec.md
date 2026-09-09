## ADDED Requirements

### Requirement: Pin-keyed rusty-v8 publish identity

When publishing a rusty_v8+submodules snapshot, the program SHALL use a pin-keyed identity that is not an overlay `{category}/{package}`:

- checksum sidecars under `{assets-root}/rusty-v8/{distfile}.{sha256,sha512,b3}`
- signed assets commit message `rusty-v8: ${ver}` (crate version, no leading `v`)
- GitHub `tag_name` = `rusty-v8-${ver}`
- GitHub release `name` = `rusty-v8-${ver}`
- GitHub release `body` = `rusty-v8: ${ver}`
- uploaded asset basename `rusty-v8-${ver}-with-submodules.tar.xz`
- `target_commitish` = the git commit that added those sidecars (not a later `main` HEAD)

Overlay DepsAndAssets packages SHALL keep `{category}/{package}` layout, `category/package: version` commits, and `{category}/{pn}-{pv}` release names. The program SHALL NOT create overlay category `dev-util` (or any other category) for rusty-v8. The program SHALL NOT attach the snapshot to a `codex-${PV}` release.

When crates publish and rusty-v8 harvest both run for one Codex unit, they SHALL be two complete commit-push-release cycles (crates, then rusty-v8) so each tag points at the commit that added its sidecars.

#### Scenario: rusty-v8 release metadata

- **WHEN** publishing snapshot version `150.5.0`
- **THEN** the GitHub release tag and name are both `rusty-v8-150.5.0`
- **AND** sidecars are written under `rusty-v8/` in the assets worktree
- **AND** the assets commit message is `rusty-v8: 150.5.0`

#### Scenario: Not a Codex release asset

- **WHEN** Codex full-path publishes crates for PV `0.153.4` and reuses rusty_v8 `150.4.0`
- **THEN** GitHub release `codex-0.153.4` does not gain a rusty-v8 tarball asset

#### Scenario: Tag points at the sidecar commit

- **WHEN** rusty-v8 sidecars are committed and then a later assets commit lands on `main` before the GitHub release is created
- **THEN** tag `rusty-v8-${ver}` still names the commit that added the rusty-v8 sidecars
