## ADDED Requirements

### Requirement: Full-path Sbcl materialize uses image qlot CLI

When full-path materialize for `DepsAndAssets Sbcl` runs qlot inside the materialize container, it SHALL invoke `qlot` from the image `PATH` (`qlot install` in the cloned project) with `HOME` the generic builder home. It SHALL NOT load `/home/builder/quicklisp/setup.lisp`, SHALL NOT load Autolith `script/qlot-install.lisp` as the primary path, and SHALL NOT bind-mount the operator `~/quicklisp`. Packed `.qlot` configs SHALL still be rewritten so they contain no operator-home pathnames as already specified by `sbcl-deps-assets`.

#### Scenario: Container qlot install does not use Quicklisp setup.lisp

- **WHEN** full-path Autolith materialize runs qlot in the container
- **THEN** the language command is `qlot` (install) on the image `PATH`
- **AND** the invocation does not `--load` `/home/builder/quicklisp/setup.lisp`
