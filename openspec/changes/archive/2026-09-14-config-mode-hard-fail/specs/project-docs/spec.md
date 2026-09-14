## MODIFIED Requirements

### Requirement: README documents Docker full-path materialize and config mode

`README.md` SHALL document at operator depth:

1. That `update` of DepsAndAssets packages that need **full-path** materialize requires `docker` on `PATH` and a product Gentoo materialize image (host CPU architecture), and does not require host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` for that path.
2. That reuse of existing assets releases does not require Docker or those language tools.
3. That GPG-signed commits, SSH `git push`, GitHub token, `ebuild` / `egencache`, and overlay/assets worktrees stay on the host.
4. How to build or obtain the materialize image (in-repo definition).
5. That work commands hard-fail when the overlay-manager TOML is not exactly mode `0600` or its mode cannot be read, without changing token resolution.

#### Scenario: Operator finds Docker in the runtime table

- **WHEN** an operator reads `README.md` runtime requirements after this capability ships
- **THEN** the documentation lists `docker` for full-path `update` of vendor/deps/crates packages and does not claim host `go`/`npm`/`bun` are required for that path

#### Scenario: Operator finds config mode warning

- **WHEN** an operator reads `README.md` configuration documentation
- **THEN** the documentation states that a config file not mode `0600` is a hard failure
