## Why

Ensure generates `FROM gentoo/stage3:` plus the Portage KEYWORDS token (`amd64`, `arm64`, …). Those Hub tags are fossils (`amd64` last pushed 2021-08-20). Full-path `update` then webrsyncs a current Portage tree onto a masked 2021 toolchain and dies in `emerge --oneshot sys-apps/portage`. The recipe must use a currently maintained official OpenRC stage3 flavor, and must not invent a `FROM` for arches that have no such image.

## What Changes

- **Split Hub tag from KEYWORDS.** Host `uname -m` maps to (1) a Gentoo KEYWORDS token for `package.accept_keywords` and (2) an official `gentoo/stage3:<flavor>-openrc` tag for `FROM`. Do not concatenate the keywords token onto `gentoo/stage3:`.
- **OpenRC glibc defaults only** (`amd64-openrc`, `arm64-openrc`, `ppc64le-openrc`, `rv64_lp64d-openrc`, `s390x-openrc`, `i686-openrc`, `armv7a_hardfp-openrc`, `armv6j_hardfp-openrc`). Not `latest` (its s390x slice has been stale), not systemd/musl/llvm/hardened/desktop, not fossil `amd64`/`arm64`.
- **Unmapped `uname -m` hard-fails before `docker build`**, naming the machine arch. No `FROM gentoo/stage3:$uname`. No host `go`/`npm`/`bun`/`sbcl`/`pycargoebuild` fallback in this change.
- **`MNDZ_MATERIALIZE_IMAGE` unchanged:** inspect-only. On an unmapped arch a usable override still skips generate/build.
- **Generator identity** becomes `mndz-overlay-manager-materialize-2`. A sidecar whose generator does not match is a miss (rebuild), even if floors would otherwise satisfy.
- README states official OpenRC stage3 for the host arch and the unsupported-arch hard-fail.

### Non-goals

- Host-path full-path materialize (unmapped arches or `update --host-materialize`). Follow-up: wiki `host-materialize-handoff.md`, change name `host-materialize-fallback`
- QEMU / foreign-arch materialize
- systemd, musl, llvm, hardened, or desktop stage3 flavors
- Pinning dated Hub tags (`amd64-openrc-20260817`)
- Changing overlay KEYWORDS, BDEPEND, runtime-lane planning, bun-bin bind-mount, `-bin`/binpkg/compile order, or override inspect-only rules
- Publishing a registry image

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `ensure-materialize-image`: Generated `FROM` uses a mapped official OpenRC stage3 flavor; KEYWORDS token is separate; unmapped host arch hard-fails before `docker build`; generator mismatch is a miss; override tag still inspect-only
- `project-docs`: README documents official OpenRC stage3 for the host CPU architecture and that unsupported host arches hard-fail ensure (no host language fallback)

## Impact

- **Code:** `Update.Materialize.Recipe` (`FROM` line); `hostRecipeArch` / a mapping type in Ensure or Recipe (uname → keywords + Hub tag); `materializeGeneratorId`; ensure miss when generator differs; hard-fail message before `docker build`
- **Tests:** Recipe `FROM` is `gentoo/stage3:amd64-openrc` not `:amd64`; mapping table cases; unmapped uname does not emit a fossil `FROM` and ensure fails without `docker build`; generator mismatch rebuilds; override on unmapped arch does not generate
- **Docs:** `README.md` materialize section
- **Operator:** First full-path `update` after this change rebuilds the image from a current stage3. Machines with no official stage3 (sparc, loong, …) get a clear ensure hard-fail until `host-materialize-fallback`
