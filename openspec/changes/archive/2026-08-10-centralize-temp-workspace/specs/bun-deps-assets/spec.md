## MODIFIED Requirements

### Requirement: Bun cache tarball from GitHub tag

For `DepsAndAssets Bun` full-path materialization of PV for packages that use **BunCache** packaging (including `dev-util/ralph-tui`), the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) require a `bun.lock` at the repository root and hard-fail if missing; (3) run `bun install --frozen-lockfile --cache-dir <bun-cache-path>` with the cache directory under the unit workspace so the cache can be packaged; (4) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` (or equivalent staged output path for publish) whose top-level entry is `bun-cache/`, using xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9`). The program SHALL implement this in Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle (delete on success or soft-skip; retain on hard-fail with path in the error).

#### Scenario: Tarball layout for ralph-tui

- **WHEN** bun cache construction succeeds for PN `ralph-tui` at PV `0.12.0`
- **THEN** the output file is named `ralph-tui-0.12.0-deps.tar.xz` and unpacking yields a top-level `bun-cache` directory

#### Scenario: Missing lockfile hard-fails

- **WHEN** the checked-out tag has no `bun.lock` at the repository root
- **THEN** materialization hard-fails before assets publish
