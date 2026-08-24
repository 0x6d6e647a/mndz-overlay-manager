## MODIFIED Requirements

### Requirement: Preflight tools for materialize

When a selected `DepsAndAssets Sbcl` package requires full-path materialize, preflight SHALL require `docker` and a usable materialize image as specified by `hermetic-asset-materialize`. The image SHALL provide the tools needed to produce the deps tarball (including `git`, `sbcl`, cargo for vendoring, and **`qlot` on `PATH`** from overlay `dev-lisp/qlot`, not a Quicklisp tree under `/home/builder/quicklisp` and not the operator `~/quicklisp/setup.lisp`). Reuse-only paths SHALL NOT require `docker` or those materialize-only tools solely because the package is Sbcl. The program SHALL NOT require Quicklisp at the operator home.

#### Scenario: Reuse without cargo

- **WHEN** apply will only reuse an existing deps asset for autolith
- **THEN** preflight does not fail solely due to missing `docker` or host `cargo` for that package

#### Scenario: Full path does not require operator Quicklisp

- **WHEN** full-path Autolith materialize runs and `~/quicklisp/setup.lisp` is absent on the host
- **THEN** preflight does not fail solely for that missing host file
