## MODIFIED Requirements

### Requirement: Private application layout and wrapper

The package SHALL install Autolith as a private application (not the global `common-lisp-3` library registry as the primary layout) using **two dests**: arch-independent files under `/usr/share/autolith` and architecture-specific files under `/usr/$(get_libdir)/autolith`. Share SHALL contain Autolith Lisp (`src/`, `autolith.asd`, `qlfile`, `qlfile.lock`, `sbcl.version`), the `.qlot/` tree required at runtime (Quicklisp client, dist software, ColorLisp `languages/` queries), fabricated `.git`, launchers the `/usr/bin/autolith` wrapper execs (`bin/autolith`, `bin/autolith-active`, `bin/autolith-runtime`, `bin/autolith-search-worker`), recovery sources and image-builder scripts hashed into cores, `sbcl-source-releases.sha256`, and synthetic `sbcl-source`. Libdir SHALL contain ELF shared objects, `libexec` helper, and recovery/active cores plus manifests. The wrapper SHALL set required environment variables (SBCL, SBCL source root under share, native library paths and core paths under libdir, git `safe.directory` equal to the share tree). Compile SHALL fabricate git provenance in the source tree **after** the installed tracked file set is known, then pack that repo (`git gc --prune=now`, stat-less index via `read-tree HEAD`, no `git init` sample hooks) so `HEAD` matches the installed tree. The package SHALL NOT inherit `common-lisp-3` as the primary layout.

#### Scenario: Wrapper entrypoint

- **WHEN** the package is emerged
- **THEN** `/usr/bin/autolith` exists and runs the packaged Autolith for `autolith --version`

#### Scenario: Two dests after emerge

- **WHEN** the package is emerged
- **THEN** `/usr/share/autolith/bin/autolith` exists
- **AND** `/usr/$(get_libdir)/autolith/lib/libfff_c.so` exists
- **AND** `/usr/share/common-lisp/systems/autolith.asd` is not installed by this package

#### Scenario: Fabricated git matches installed tracked files

- **WHEN** the package is emerged
- **THEN** `/usr/share/autolith/.git` exists
- **AND** `git -C /usr/share/autolith status --porcelain` (with `safe.directory` equal to that tree) is empty of tracked modifications

## ADDED Requirements

### Requirement: Installed share omits packaging and compile-only trees

`src_install` SHALL NOT copy the full `${S}` tree. Share SHALL NOT contain `.github/`, `flake.nix`, `flake.lock`, `nix/`, `server/`, `bin/autolith-release`, `script/install`, `script/bootstrap`, `script/qlot-install.lisp`, `script/build-fff`, `script/build-fff.lisp`, `sbcl-source.sha256`, `native/fff/`, or `tests/`. Share SHALL NOT contain packaged `AGENTS.md` or `AUTOLITH.org` (workspace copies live in the user’s project). Human-only `docs/` files that no Autolith Lisp at that tag loads (release notes, guide, architecture) SHALL NOT be installed; files a later tag loads as prompt templates (`docs/system-prompt.org`, `docs/request-context.org`) SHALL be installed when present. `USE=test` SHALL NOT cause `tests/` to be installed; Portage `src_test` remains an offline load/version check.

#### Scenario: Packaging trees are absent after emerge

- **WHEN** the package is emerged
- **THEN** `/usr/share/autolith/tests` does not exist
- **AND** `/usr/share/autolith/server` does not exist
- **AND** `/usr/share/autolith/flake.nix` does not exist
- **AND** `/usr/share/autolith/.github` does not exist

### Requirement: ColorLisp vendor C is compile-only

`src_compile` SHALL build `libcolorlisp-tree-sitter.so` from the deps tarball ColorLisp vendor C. After that library exists, `src_install` SHALL NOT install ColorLisp `vendor/grammars/`, `vendor/tree-sitter/`, `vendor/common/`, or `native/colorlisp-tree-sitter.c`. Share SHALL keep ColorLisp Lisp sources, `.asd`, and `languages/` query files. The deps tarball SHALL still contain the vendor C for compile. Installed `.qlot` MAY omit tmp leftovers, `cl-exec-sandbox` `build/` helper copies, bordeaux-threads `docs/`, ironclad `testing/`, cffi `doc/`/`tests`/`examples`, and nested `.github/` under dist software. Installed `.qlot` SHALL keep local-time `zoneinfo/` and ironclad `doc/` when that directory is an `ironclad/core` ASDF component.

#### Scenario: Highlight queries remain, parser C does not

- **WHEN** the package is emerged
- **THEN** `/usr/$(get_libdir)/autolith/lib/libcolorlisp-tree-sitter.so` exists
- **AND** ColorLisp `languages/` exists under `/usr/share/autolith/.qlot`
- **AND** ColorLisp `vendor/grammars` does not exist under `/usr/share/autolith/.qlot`
