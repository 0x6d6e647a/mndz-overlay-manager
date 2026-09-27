# gastown-dep-gates Specification

## Purpose

On each `dev-util/gastown` apply, rewrite the Dolt floor from that tag and interpret the Beads version gate so an unrecognized gate fails closed, while the operator pin `~dev-util/beads-1.0.4` stays in the ebuild until an operator removes it.

## Requirements

### Requirement: Dolt floor is rewritten from the tag

Before overlay mutation of a `dev-util/gastown` apply, the program SHALL read `MinDoltVersion` from `internal/deps/dolt.go` at the tag being applied and SHALL set the ebuild `RDEPEND` Dolt atom to `>=dev-db/dolt-<that version>`. The program SHALL hard-fail that apply before overlay mutation when the constant is missing or not a dotted numeric version. The rewritten ebuild is the to-be-written ebuild that `overlay-atom-closure` evaluates. When no retained `dev-db/dolt` ebuild satisfies the floor, and a selected Dolt update's planned remaining versions would satisfy it, the program SHALL wait as `overlay-atom-closure` already specifies. Otherwise the program SHALL hard-fail the Gas Town unit without overlay mutation, and the error SHALL name `dev-util/gastown`, `dev-db/dolt`, and the atom.

#### Scenario: 1.1.0 floor stays 1.82.4 until a newer tag

- **WHEN** apply writes Gas Town from tag `v1.1.0`
- **THEN** the ebuild `RDEPEND` contains `>=dev-db/dolt-1.82.4`

#### Scenario: Bump to 1.2.1 raises the floor

- **WHEN** apply updates Gas Town to tag `v1.2.1`
- **THEN** the ebuild `RDEPEND` contains `>=dev-db/dolt-2.0.7`
- **AND** the previous `>=dev-db/dolt-1.82.4` atom is gone

#### Scenario: Floor above every retained Dolt version

- **WHEN** the tag's `MinDoltVersion` is newer than every retained `dev-db/dolt` PV and Dolt is not selected with a planned PV that would satisfy the floor
- **THEN** the Gas Town unit hard-fails without an overlay commit
- **AND** the error names the unsatisfied `>=dev-db/dolt-…` atom

#### Scenario: Unreadable Dolt constant

- **WHEN** `internal/deps/dolt.go` at the tag has no `MinDoltVersion` string constant
- **THEN** the Gas Town unit hard-fails before overlay mutation

### Requirement: Beads gate accepts two shapes

The program SHALL parse the Beads version gate from `internal/deps/beads.go` and the command wrapper that reports it, at the tag being applied. Exactly two shapes are valid:

- **Floor.** The file declares `MinBeadsVersion` as a dotted numeric string, compares an installed version as older than that minimum, and does not declare `MaxBeadsVersion` or a "too new" result.
- **Ceiling.** The file declares both `MinBeadsVersion` and `MaxBeadsVersion` as the same dotted numeric version, compares older-than-min and newer-than-max, and the command path returns the newer-than-max result as a hard command failure.

Any other shape SHALL hard-fail the Gas Town unit before overlay mutation. The error SHALL name the gate as unrecognized and SHALL state that a plain update is not sufficient. Other selected packages SHALL continue.

#### Scenario: Shipped tags are the floor shape

- **WHEN** the tag is `v1.1.0` or `v1.2.1`
- **THEN** the parse result is a floor of `0.57.0` with no maximum
- **AND** the apply is not failed for gate shape

#### Scenario: Equal min and max is the ceiling shape

- **WHEN** a tag declares `MinBeadsVersion` and `MaxBeadsVersion` both equal to `1.0.4` and the command path hard-fails when `bd` is newer
- **THEN** the parse result is a ceiling of `1.0.4`
- **AND** the apply is not failed for gate shape

#### Scenario: Renamed or relocated gate

- **WHEN** the tag no longer contains those constants in that form, or adds another Beads version constant or status
- **THEN** the Gas Town unit hard-fails before overlay mutation
- **AND** no Gas Town success line is written

### Requirement: Operator pin is not loosened

While the Gas Town ebuild `RDEPEND` contains `~dev-util/beads-1.0.4` or `=dev-util/beads-1.0.4`, apply SHALL leave that pin in place. A floor-shaped gate SHALL NOT replace the pin with `>=dev-util/beads-<MinBeadsVersion>`. A ceiling whose version is `1.0.4` SHALL leave the same pin in place. A ceiling whose version is different from `1.0.4`, or a floor whose minimum is strictly newer than `1.0.4`, SHALL hard-fail the unit before overlay mutation. The error SHALL name the pin and the parsed window. The pin atom SHALL remain the overlay-internal atom that `overlay-atom-closure` reverse-dep keep uses to retain a `dev-util/beads` ebuild of PV `1.0.4`.

#### Scenario: 1.2.1 floor does not delete the pin

- **WHEN** apply updates Gas Town from `1.1.0` to `1.2.1` and the parsed gate is a floor of `0.57.0`
- **THEN** the written ebuild still `RDEPEND`s on `~dev-util/beads-1.0.4`
- **AND** it does not `RDEPEND` on `>=dev-util/beads-0.57.0` in place of that pin

#### Scenario: Kept Beads ebuild survives a later Beads tip update

- **WHEN** a later Beads apply's planned tip is newer than `1.0.4` and a retained Gas Town ebuild still contains `~dev-util/beads-1.0.4`
- **THEN** `beads-1.0.4.ebuild` (or its revision of PV `1.0.4`) remains in the overlay
- **AND** the newer Beads tip ebuild remains as well

#### Scenario: Floor rises past the pin

- **WHEN** the parsed floor is strictly newer than `1.0.4` while the ebuild still pins `~dev-util/beads-1.0.4`
- **THEN** the Gas Town unit hard-fails before overlay mutation
- **AND** the pin is still present on the previous ebuild

### Requirement: Beads window notice on change only

The ebuild SHALL record the last parsed Beads window as a minimum and an optional maximum. After a successful Gas Town apply, when the newly parsed window differs from the recorded window, the program SHALL write one stdout line that names `dev-util/gastown`, the previous window, the new window, and that the pin `~dev-util/beads-1.0.4` was kept. The program SHALL update the recorded window to the new value. The line SHALL NOT replace runtime-lane success lines. The program SHALL exit 0 for that unit when the apply otherwise succeeded. When the parsed window equals the recorded window, the program SHALL NOT write that line.

#### Scenario: 1.1.0 to 1.2.1 is silent

- **WHEN** both the recorded window and the `v1.2.1` parse are minimum `0.57.0` and no maximum
- **THEN** stdout does not contain a Beads window notice
- **AND** the recorded window remains minimum `0.57.0` and no maximum

#### Scenario: A later window change is reported once

- **WHEN** a later tag parses to a different window and the apply succeeds under the pin rules
- **THEN** stdout contains one Beads window notice naming the old window, the new window, and the kept pin
- **AND** a second apply of the same tag does not print the notice again
