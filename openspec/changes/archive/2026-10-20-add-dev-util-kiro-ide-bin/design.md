# Design

## Context

See `proposal.md` for why this package is added. `GitMvAndManifest` already renames the newest ebuild to the remote PV, runs `ebuild manifest` and package `egencache`, and signs one overlay commit. The only body rewrite on that path is `dev-util/grok-bot-bin`'s commit pin. `policy` records an empty arch allowlist, so `KEYWORDS` live in the ebuild and survive the rename. `ebuild manifest` digests every conditional `SRC_URI`, including the archive the host profile does not emerge.

The stable metadata documents are `https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json` and `https://prod.download.desktop.kiro.dev/stable/metadata-linux-arm64-stable.json`. Each is a JSON object whose top-level `currentRelease` was `1.4.10` on 2026-10-20. Multi-URL HttpJson already fails the package when those values differ. `dev-util/kiro-cli-bin` stays a separate HttpJson entry on `desktop-release.q.us-east-1.amazonaws.com`, field `version`.

## Goals / Non-Goals

**Goals:**

- One policy entry, one policy test, and one apply test. No new fetch code.
- An ebuild body that a rename can carry from `1.4.5` to the feed's `currentRelease`.
- Two USE flags whose dependencies are visible to Portage, and a `chrome-sandbox` that stays mode `0755`.

**Non-Goals:**

- A new HttpJson fetcher, an assets release, or a `DepsAndAssets` lane.
- Teaching `GitMv` to edit `IUSE`, `RDEPEND`, or `product.json`. The ebuild body is the pin.
- Changing `project-docs`. The operator CLI is unchanged.
- Packaging Kiro Crew, tracking the insider channel, or editing `dev-util/kiro-cli-bin`.

## Decisions

- **HttpJson, two URLs, field `currentRelease`, technique `GitMvAndManifest`, empty allowlist.** Add a `policy` entry beside `dev-util/kiro-cli-bin` using the same `HttpJson` record as `dev-util/grok-bot-bin`, with `httpJsonField` `currentRelease`. Alternative: one metadata URL — the arm64 feed can move alone, and the grok-bot pair already rejects that. Alternative: GitHub tags — `kirodotdev/Kiro` is the issue tracker. Alternative: the insider metadata document — that channel is a different train.

- **Seed `1.4.5`, not `1.4.9`.** On 2026-10-20 the stable tarballs for `1.4.6` through `1.4.9` answered 403. `1.4.5` answered 200 on both arches (x64 277459584 bytes, sha256 `0f594cbd9e043e5f1a3087dfbef22763d4f5804fbc00582c3b770b97f157aa4f`). `1.4.5` sorts before `1.4.10` under numeric ebuild ordering. The bump target is whatever `currentRelease` says when `update` runs. Alternative: seed the live feed — then the first `outdated` has nothing to prove.

- **Signed stable `tar.gz` on `prod.download.desktop.kiro.dev`.** amd64 selects `linux-x64/signed/${PV}/tar/kiro-ide-${PV}-stable-linux-x64.tar.gz`. arm64 selects the `linux-arm64` twin. There is no musl archive, so there is no `elibc_musl` conditional and no musl USE flag. `KEYWORDS` are `-* ~amd64 ~arm64`. Alternative: the `.deb` — other trees wrap it with `--no-sandbox` or language packs. The tar is the layout this overlay installs. Upstream signature files are not fetched. The Manifest hashes are the integrity check, as for the other bin packages.

- **Install `Kiro/` at `/usr/share/kiro` and symlink `/usr/bin/kiro`.** `S="${WORKDIR}/Kiro"`. The upstream `bin/kiro` wrapper resolves a symlink through `readlink -f`, so the command can live on `/usr/bin` while the ELF stays at `/usr/share/kiro/kiro`. Do not install under `/opt`. Do not run an upstream installer. Do not provide `kiro-cli`. The x64 `1.4.5` and `1.4.10` trees match on that wrapper, the main ELF `DT_NEEDED`, `LICENSE.txt`, and the top-level names, so the body can stay stable across the bump. The arm64 tarball was not unpacked. The same `S` is the assumption, and a different layout fails emerge.

- **`IUSE="+command-sandbox microsoft-auth"`.** `command-sandbox` adds `sys-apps/bubblewrap` and `net-misc/socat`. The IDE command sandbox stays off until the user sets `enabled` in their own `sandbox.json`. The flag only puts `bwrap` and `socat` on the system so that choice can become Active. Missing `bwrap` makes an enabled sandbox Unavailable. Both atoms sit on one flag because the documented network mode that needs `socat` is the same feature. Alternative: a flag named `sandbox` — that name collides with the Electron renderer helper. Alternative: default off — an operator who enables the feature in the IDE then gets no OS isolation and no package warning. Alternative: split `socat` onto a second flag — the docs treat it as part of this sandbox.

- **`microsoft-auth` defaults off and deletes `resources/app/extensions/microsoft-authentication` before install.** On, the directory stays and `RDEPEND` adds `net-libs/webkit-gtk:4.1`, `net-libs/libsoup:3`, `net-misc/curl`, `dev-libs/openssl`, and `sys-apps/util-linux`. Those sonames belong to `libmsalruntime.so`, not the main ELF. `product.json` does not list the extension in `alwaysEnabledExtensions`. Alternative: default on — it would pull WebKit into every IDE install for a sign-in extension the product does not force on.

- **`chrome-sandbox` is mode `0755`.** Force that mode at install so a setuid bit in the tarball does not survive. Do not pass `--no-sandbox`. The desktop entry may pass `--ozone-platform-hint=auto`. Do not set `StartupWMClass`; it was not observed from a window. `pkg_postinst` elogs that a host without user namespaces needs a root-owned mode `4755` helper, and that the operator does that by hand. Alternative: `fperms 4755` — rejected. User namespaces are the normal desktop path, and a setuid helper is a separate privilege.

- **Unconditional libraries are the main ELF plus the always-installed addons.** `RDEPEND` includes `>=sys-libs/glibc-2.34` with no USE guard. The highest observed symbol in the unpacked x64 tree is `GLIBC_2.34`, inside `libmsalruntime.so`. The floor stays even when that extension is removed, matching `dev-util/kiro-cli-bin`. Do not `RDEPEND` on gcc. The main ELF `DT_NEEDED` set, `keymapping.node`'s `libxkbfile`, and dlopen names in the main ELF (`libEGL.so.1`, `libGL.so.1`, `libnotify.so.4`, `libpulse.so.0`, `libsecret-1.so.0`) map to: `x11-libs/gtk+:3`, `dev-libs/glib:2`, `x11-libs/cairo`, `x11-libs/pango`, `app-accessibility/at-spi2-core`, `x11-libs/libX11`, `x11-libs/libXcomposite`, `x11-libs/libXdamage`, `x11-libs/libXext`, `x11-libs/libXfixes`, `x11-libs/libXrandr`, `x11-libs/libxcb`, `x11-libs/libxkbcommon`, `x11-libs/libxkbfile`, `media-libs/alsa-lib`, `dev-libs/nspr`, `dev-libs/nss`, `dev-libs/expat`, `media-libs/mesa`, `net-print/cups`, `sys-apps/dbus`, `virtual/libudev`, `app-crypt/libsecret`, `x11-libs/libnotify`, `media-libs/libpulse`, `media-libs/libglvnd`, and `app-shells/bash-completion`. `libwayland-client.so.0` is absent, so there is no Wayland atom. `kerberos.node` links only libc, so there is no `mit-krb5`. Cups and alsa are `DT_NEEDED` by `kiro`, so they are not optional. Bundled `libffmpeg.so`, `libvulkan.so.1`, `libvk_swiftshader.so`, and the static-pie `rg` copies stay in the tree. Do not add `system-rg`, `L10N`, or a language-pack strip. Ship all bundled locales.

- **`/etc/kiro/policy.json` is `{"UpdateMode":"none"}`.** `main.js` reads that path. `UpdateMode` `none` wins over an update URL. The Linux updater would open an archive in the browser. It does not replace `/usr`. Portage already protects `/etc`. Do not write `~/.kiro`, `sandbox.json`, or `/etc/kiro/managed-settings.json`. Do not edit `product.json`. `pkg_postinst` elogs `UpdateMode` `none`, the command-sandbox enablement note, and the `0755` chrome-sandbox note.

- **`src_prepare` drops Windows PE addons and, when `microsoft-auth` is off, the authentication extension.** The x64 `1.4.5` inventory was 25 ELF64-amd64, 6 PE, and 0 foreign ELF. Identified PE members are both `windows-foreground-love` `foreground_love.node` files, `@vscode/deviceid` `windows.node`, and both `ms-vscode.js-debug` `win32-app-container-tokens` nodes. Re-scan with `file` at seed time and remove every PE file. Do not guess a missing sixth name from memory if the scan lists it. The static `apply-seccomp` helper under `@vscode/sandbox-runtime` is vendor data inside the tree. It is not the bubblewrap backend and it stays.

- **Prebuilt, no `IUSE=test`.** `RESTRICT="bindist mirror strip"`. `QA_PREBUILT` covers `usr/share/kiro`. No `src_test`. The exemption is the existing overlay-test-use list plus `dev-util/kiro-ide-bin`. `FEATURES=test` still runs an empty test phase. Do not pass `USE=test`.

- **Metadata matches the CLI tracker and the IDE site.** `bugs-to` is `https://github.com/kirodotdev/Kiro/issues`. The website remote id is `https://kiro.dev/`. There is no GitHub remote id. `DESCRIPTION` is written for this overlay. `LICENSE.txt` and the upstream license page are all-rights-reserved under the AWS customer and IP terms. `product.json` `licenseName` `MIT` is leftover editor metadata and is not the package license. Chromium notices ship inside the tree and are not copied into the overlay `licenses/` directory.

- **Tests name the IDE so coverage selection does not rely on the CLI names.** Policy test pattern `Hardcoded Kiro IDE`, modeled on `testHardcodedKiro` with the two-URL assertion from `testHardcodedGrokBot`: `lookupPolicy` returns the two URLs, field `currentRelease`, `GitMvAndManifest`, and `[]`, and a version token is not a package target. Apply test pattern `Kiro IDE GitMv`, modeled on `runKiroGitMv`: a fixture `kiro-ide-bin-1.4.5.ebuild` renames to `kiro-ide-bin-1.4.10.ebuild`, the body is unchanged, and the grok-bot commit-feed hook does not run. Disagreeing `currentRelease` values stay on the existing HttpJson path that reports `HttpJson: feed versions disagree`.

## Risks / Trade-offs

- [Risk] `ebuild manifest` fetches both arch tarballs. At `1.4.5` that is about 277MB plus 274MB. → Accepted. An emerge on one profile fetches one archive. There is no second USE flag that would shrink the manifest fetch.
- [Risk] The arm64 archive was not unpacked. → `S="${WORKDIR}/Kiro"` matches the amd64 tree. A different arm64 layout fails that emerge. This host can smoke amd64 only.
- [Risk] The feed moves past `1.4.10` before `update` runs. → The bump target is `currentRelease`, not a hardcoded `1.4.10`. The apply fixture still uses `1.4.10`.
- [Risk] A later PV adds a `DT_NEEDED` library. `GitMv` will not rewrite the body, so the post-bump emerge is the proof. → A body fix after that PV is merged is a `-rN` on the new PV.
- [Risk] User namespaces are disabled on some hosts. The window then needs a root-owned mode `4755` `chrome-sandbox`, and `bwrap` needs its own setuid helper, which this `RDEPEND` does not provide. → The elog states the `0755` fallback. The package does not chmod either helper to setuid.
- [Risk] `libsecret` is a dlopen name in the main ELF, not a `DT_NEEDED` entry, so Portage QA will not demand it. → Keep `app-crypt/libsecret` unconditional because the binary names it.
- [Risk] `StartupWMClass` is wrong if it is guessed. → Omit it. A desktop-file fix after a real window is a content revision.
- [Risk] Upstream drops `1.4.5` before the seed manifest. → Seed while both arch URLs answer 200. A missing archive fails `ebuild manifest`.
- [Risk] Installing `bubblewrap` for the IDE also puts `bwrap` on `PATH` for `dev-util/kiro-cli-bin`. → Accepted. Do not edit the CLI ebuild. The IDE flag does not write the CLI settings file.

## Migration Plan

Add the overlay package and the policy entry. The seed commit includes the ebuild, `metadata.xml`, Manifest, and md5-cache, and stays local. Subject is `dev-util/kiro-ide-bin: 1.4.5` with an empty body. The operator emerges `=dev-util/kiro-ide-bin-1.4.5` and smokes `kiro --version`. `outdated` then `update` on a TTY. Apply renames `kiro-ide-bin-1.4.5.ebuild` away. The operator emerges the bumped ebuild, smokes again, then emerges with `FEATURES=test` and smokes again. Rollback is dropping the local overlay commits and unmerging the package. Do not push.

After archive, the modified overlay-test-use requirement text grows past 500 characters because `dev-util/kiro-ide-bin` is added to a paragraph that is already near the limit. Leave that paragraph whole. The change validator does not length-check `MODIFIED` text.
