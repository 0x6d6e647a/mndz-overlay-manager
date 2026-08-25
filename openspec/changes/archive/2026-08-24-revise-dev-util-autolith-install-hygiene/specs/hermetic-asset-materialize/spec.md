## MODIFIED Requirements

### Requirement: Qlot trees have no operator home paths

When packing an Sbcl/Autolith `.qlot/` tree, the packed `.qlot/qlot.conf` and `.qlot/source-registry.conf` SHALL NOT contain any `/home/` pathname (operator home, generic builder home, or otherwise). Quicklisp/qlot SHALL run with `HOME` set to the container generic home or the unit work directory, not the operator home. After `qlot install`, the program SHALL drop `:qlot-source-directory`, `:setup-file`, and a source-registry `:directory` entry that names a builder qlot checkout, keeping `:also-exclude` entries. The program SHALL NOT rewrite those keys to `/home/builder` or another home. If a packed conf still contains `/home/` after that step, pack SHALL hard-fail that unit.

#### Scenario: qlot.conf has no operator home

- **WHEN** full-path Autolith materialize packs `{pn}-{pv}-deps.tar.xz`
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain `/home/`

### Requirement: Full-path Sbcl materialize uses image qlot CLI

When full-path materialize for `DepsAndAssets Sbcl` runs qlot inside the materialize container, it SHALL invoke `qlot` from the image `PATH` (`qlot install` in the cloned project) with `HOME` the generic builder home. It SHALL NOT load `/home/builder/quicklisp/setup.lisp`, SHALL NOT load Autolith `script/qlot-install.lisp` as the primary path, and SHALL NOT bind-mount the operator `~/quicklisp`. Packed `.qlot` configs SHALL still be rewritten so they contain no `/home/` pathnames as already specified by `sbcl-deps-assets`.

#### Scenario: Container qlot install does not use Quicklisp setup.lisp

- **WHEN** full-path Autolith materialize runs qlot in the container
- **THEN** the language command is `qlot` (install) on the image `PATH`
- **AND** the invocation does not `--load` `/home/builder/quicklisp/setup.lisp`
