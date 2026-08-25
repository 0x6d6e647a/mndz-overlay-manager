## MODIFIED Requirements

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short summary synthesizing upstream README and GitHub (live self-modifying Common Lisp AI agent), `HOMEPAGE` to `https://github.com/luciusmagn/autolith`, and a `LICENSE` field that lists Gentoo `licenses/` tokens covering Autolith itself (ISC) **and** every installed `.qlot` software project, colorlisp vendor trees shipped with those sources, fff itself (MIT), and unique SPDX tokens from crates linked into `libfff_c.so`. The field SHALL NOT be solely `ISC`. Token names SHALL match files under Gentoo `licenses/` or overlay `licenses/`. When a shipped project uses COLL-Attribution, the overlay SHALL provide `licenses/COLL-Attribution` and the ebuild SHALL include that token. An ebuild comment SHALL name each inventoried `.qlot` project (and Autolith / fff) mapped to its token; fff-c crate licenses MAY be summarized as unique SPDX tokens rather than one line per crate.

#### Scenario: License and homepage

- **WHEN** the ebuild is inspected
- **THEN** the homepage is `https://github.com/luciusmagn/autolith`
- **AND** `LICENSE` includes `ISC`
- **AND** `LICENSE` includes at least one additional Gentoo or overlay license token required by an installed `.qlot` project or fff-c crate that is not ISC

#### Scenario: COLL-Attribution overlay token

- **WHEN** the ebuild `LICENSE` includes `COLL-Attribution`
- **THEN** overlay `licenses/COLL-Attribution` exists

#### Scenario: fff-c crate tokens are present

- **WHEN** the ebuild `LICENSE` is inspected after the inventory
- **THEN** it includes `Apache-2.0` and `MPL-2.0` in addition to `ISC` and `MIT`

### Requirement: Private application layout and wrapper

The package SHALL install Autolith as a private application (not the global `common-lisp-3` library registry as the primary layout) using **two dests**: arch-independent files under `/usr/share/autolith` (Lisp sources, `.qlot/`, fabricated `.git`, scripts, `bin/autolith` launcher, synthetic `sbcl-source`) and architecture-specific files under `/usr/$(get_libdir)/autolith` (ELF shared objects, `libexec` helper, recovery and active cores plus manifests). It SHALL install a `/usr/bin/autolith` wrapper that sets required environment variables (SBCL, SBCL source root under share, native library paths and core paths under libdir, git `safe.directory` equal to the share tree). Compile SHALL be able to fabricate git provenance in the source tree when recovery/active image builders require it. The package SHALL NOT inherit `common-lisp-3` as the primary layout.

#### Scenario: Wrapper entrypoint

- **WHEN** the package is emerged
- **THEN** `/usr/bin/autolith` exists and runs the packaged Autolith for `autolith --version`

#### Scenario: Two dests after emerge

- **WHEN** the package is emerged
- **THEN** `/usr/share/autolith/bin/autolith` exists
- **AND** `/usr/$(get_libdir)/autolith/lib/libfff_c.so` exists
- **AND** `/usr/share/common-lisp/systems/autolith.asd` is not installed by this package
