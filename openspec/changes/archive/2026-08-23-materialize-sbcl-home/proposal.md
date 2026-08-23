## Why

Ensure’s generated image emerges Gentoo `dev-lisp/sbcl` successfully, then the next layer runs `sbcl --no-userinit --no-sysinit` to bootstrap Quicklisp and dies with `Can't find sbcl.core`. Docker `RUN` is not a login shell, so `/etc/env.d/50sbcl` (`SBCL_HOME=/usr/$(get_libdir)/sbcl`) is never loaded; the ELF at `/usr/bin/sbcl` looks next to itself. The same miss hits later `docker run` unless the host’s `SBCL_HOME` happens to leak and match. Full-path Autolith (and any prepare that pays for SBCL) cannot ensure the image.

## What Changes

- **Bake `SBCL_HOME` (and `SBCL_SOURCE_ROOT`) into the generated Dockerfile** as `ENV` after the sbcl emerge `RUN` and before the Quicklisp `RUN`, using Gentoo `get_libdir` for the host `RecipeArch` (`lib64` vs `lib`). Image `USE=source` stays off.
- **`docker run` does not pass host `SBCL_HOME` / `SBCL_SOURCE_ROOT`.** Drop them like `PATH`; the image `ENV` wins. Still `--user` host uid/gid and `HOME=/home/builder` (no `USER builder`, no login `SHELL`).
- **Quicklisp installer fetch uses `aria2c`** (`net-misc/aria2` is already in the base layer). Keep emerging `net-misc/wget`. Do not pin or overlay-package Quicklisp/qlot in this change.
- **Generator identity** becomes `mndz-overlay-manager-materialize-4` so existing `:local` sidecars rebuild.

### Non-goals

- `useradd builder`, passwordless sudo, Dockerfile `USER`, login-shell `SHELL` / `ENTRYPOINT`
- `USE=source` on image SBCL (overlay Autolith keeps `:=[source]`)
- Overlay `dev-lisp/qlot` / `dev-lisp/quicklisp` (wiki `quicklisp-ebuild-handoff.md`)
- Pinning `quicklisp.lisp` as a hashed distfile; dropping the Quicklisp bootstrap
- Removing `wget` from the base emerge; host-path materialize; PKGDIR prune

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `ensure-materialize-image`: generated recipe sets `ENV SBCL_HOME` and `ENV SBCL_SOURCE_ROOT` from the host arch’s libdir when it emerges SBCL; Quicklisp bootstrap fetch uses `aria2c`; generator `…-4`
- `hermetic-asset-materialize`: full-path `docker run` does not pass host `SBCL_HOME` or `SBCL_SOURCE_ROOT` into the container

## Impact

- **Code:** `Update.Materialize.Recipe` (libdir on `RecipeArch`, `ENV` between sbcl emerge and Quicklisp, `aria2c` for the installer URL); `Update.Materialize.Sidecar` generator id; `Update.Process.Docker` drop-list for `SBCL_*`
- **Tests:** rendered SBCL recipe contains the `ENV` lines (`/usr/lib64/sbcl` on `x86_64`, `/usr/lib/sbcl` on `i686`/`armv7l`); Quicklisp URL fetched with `aria2c` not `wget`; base layer still emerges wget and aria2; docker-wrap tests do not forward host `SBCL_HOME`
- **Docs:** none unless README currently claims wget for the Quicklisp `RUN` (it should not)
- **Operator:** first full-path `update` after this change rebuilds `:local` (generator mismatch). Ensure should pass the former `sbcl.core` fatal on amd64
