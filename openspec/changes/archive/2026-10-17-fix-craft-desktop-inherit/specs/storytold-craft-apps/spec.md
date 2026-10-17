# Spec Delta

## MODIFIED Requirements

### Requirement: GUI runtime dependencies

With `gui` enabled, each craft app SHALL RDEPEND on `sys-apps/dbus`, `x11-misc/xdg-utils`, `media-libs/libglvnd`, `media-libs/vulkan-loader`, and `x11-libs/libxkbcommon`. `portal` SHALL add `sys-apps/xdg-desktop-portal`. Without `portal`, `gui` SHALL RDEPEND on `gnome-extra/zenity`. The ebuild SHALL NOT RDEPEND on a Vulkan driver package or a portal backend.

#### Scenario: Portal selects the dialog provider

- **WHEN** a craft app ebuild is inspected with `portal` enabled
- **THEN** `RDEPEND` includes `sys-apps/xdg-desktop-portal`
- **AND** `RDEPEND` does not include `gnome-extra/zenity` solely because `portal` is on

#### Scenario: Disabled portal selects zenity

- **WHEN** a craft app ebuild is inspected with `USE=-portal` and `gui` enabled
- **THEN** `RDEPEND` includes `gnome-extra/zenity`
- **AND** `RDEPEND` does not include `sys-apps/xdg-desktop-portal`

## ADDED Requirements

### Requirement: Desktop install helpers

Each craft app ebuild SHALL inherit `desktop` together with `cargo` and `xdg`. When `gui` is enabled, `src_install` SHALL install the desktop entry with `domenu` and the hicolor icons with `doicon`.

#### Scenario: Inherit provides the desktop helpers

- **WHEN** a craft app ebuild is inspected
- **THEN** its inherit line includes `cargo`, `desktop`, and `xdg`
- **AND** the `gui` install path calls `domenu` and `doicon`
