# Gentoo materialize image for full-path DepsAndAssets work.
# Host-arch only. Operators build this; the CLI does not docker-build on update.
#
#   docker build -t mndz-overlay-manager/materialize:local -f docker/materialize/Dockerfile .
#
# Override the tag the CLI uses with MNDZ_MATERIALIZE_IMAGE.
#
# Provides: git, tar, xz, go, node/npm, bun, sbcl, image-local Quicklisp/qlot,
# cargo, pycargoebuild + Portage Python, aria2c, wget.
# /home/builder is world-writable so docker run --user host-uid:host-gid works.

FROM gentoo/stage3:amd64

ENV FEATURES="-news -ipc-sandbox -network-sandbox -pid-sandbox"
ENV EMERGE_DEFAULT_OPTS="--quiet-build=y --with-bdeps=n"

RUN emerge-webrsync \
 && emerge --oneshot sys-apps/portage \
 && emerge -n \
      app-arch/tar \
      app-arch/xz-utils \
      app-misc/ca-certificates \
      app-portage/pycargoebuild \
      dev-lang/go \
      dev-lang/rust-bin \
      dev-lisp/sbcl \
      dev-vcs/git \
      net-libs/nodejs \
      net-misc/aria2 \
      net-misc/wget \
 && rm -rf /var/cache/distfiles/*

# Official bun binary (not always present in ::gentoo).
ARG BUN_VERSION=1.2.21
RUN wget -O /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
 && (command -v unzip >/dev/null || emerge -n app-arch/unzip) \
 && unzip -o /tmp/bun.zip -d /tmp/bun \
 && install -m 0755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun \
 && rm -rf /tmp/bun /tmp/bun.zip

# Generic home visible to docker run --user <host-uid> (not the operator $HOME).
RUN mkdir -p /home/builder/.config /tmp/builder-cache \
 && chmod 0777 /home/builder /home/builder/.config /tmp/builder-cache

# Image-local Quicklisp + qlot (not ~/quicklisp on the operator host).
RUN wget -O /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && sbcl --non-interactive --no-userinit --no-sysinit \
      --load /tmp/quicklisp.lisp \
      --eval '(quicklisp-quickstart:install :path "/home/builder/quicklisp/")' \
      --eval '(ql:quickload :qlot :silent t)' \
      --quit \
 && rm -f /tmp/quicklisp.lisp \
 && chmod -R a+rX /home/builder/quicklisp \
 && chmod 0777 /home/builder /home/builder/quicklisp

ENV HOME=/home/builder
WORKDIR /home/builder
