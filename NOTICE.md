# NOTICE - third-party software in this bundle

Built: 2026-10-04 by prepare-bundle.sh. All binaries are
redistributed UNMODIFIED, exactly as published by the upstream projects
listed below. Every component is free / open-source software. The source
code for each one is available at the "Source" link, at the version shown.
The install scripts themselves (prepare-bundle.sh, install-podman.sh) are
separate works and are not derived from any of these components.

## 1. podman-static v5.6.1 (amd64)

Downloaded from: https://github.com/mgoltzsche/podman-static/releases/download/v5.6.1/podman-linux-amd64.tar.gz
Build recipe (exact versions and sources of every component):
https://github.com/mgoltzsche/podman-static (Apache-2.0)

| Component | License | Source |
|---|---|---|
| podman, rootlessport, quadlet | Apache-2.0 | https://github.com/containers/podman |
| conmon | Apache-2.0 | https://github.com/containers/conmon |
| runc | Apache-2.0 | https://github.com/opencontainers/runc |
| crun | GPL-2.0-or-later (libcrun: LGPL-2.1-or-later) | https://github.com/containers/crun |
| netavark | Apache-2.0 | https://github.com/containers/netavark |
| aardvark-dns | Apache-2.0 | https://github.com/containers/aardvark-dns |
| fuse-overlayfs | GPL-2.0-or-later | https://github.com/containers/fuse-overlayfs |
| fusermount3 (libfuse) | GPL-2.0 (library: LGPL-2.1) | https://github.com/libfuse/libfuse |
| pasta (passt) | GPL-2.0-or-later AND BSD-3-Clause | https://passt.top/passt |
| catatonit | GPL-2.0-or-later | https://github.com/openSUSE/catatonit |

These are static builds; they also contain statically linked libraries,
among them musl libc (MIT), libseccomp (LGPL-2.1), glib (LGPL-2.1-or-later).
See the build recipe above for the complete list.

Versions as reported by the binaries:

```
podman version 5.6.1
crun version 1.23.1
runc version 1.3.1
conmon version 2.1.13
fuse-overlayfs: version 1.15
netavark 1.16.1
aardvark-dns 1.16.0
```

## 2. udocker 1.3.17 and its tools tarball 1.2.11

Downloaded from:
- https://github.com/indigo-dc/udocker/releases/download/1.3.17/udocker-1.3.17.tar.gz
- https://raw.githubusercontent.com/jorge-lip/udocker-builds/master/tarballs/udocker-englib-1.2.11.tar.gz

The license texts are inside the tools tarball under udocker_dir/doc/.

| Component | License | Source |
|---|---|---|
| udocker | Apache-2.0 | https://github.com/indigo-dc/udocker |
| PRoot (udocker fork) | GPL-2.0-or-later | https://github.com/jorge-lip/proot-udocker |
| patchelf (udocker fork) | GPL-3.0-or-later | https://github.com/jorge-lip/patchelf-udocker |
| fakechroot (udocker fork) | LGPL-2.1-or-later | https://github.com/jorge-lip/libfakechroot-glibc-udocker |
| runc | Apache-2.0 | https://github.com/opencontainers/runc |
| crun | GPL-2.0-or-later | https://github.com/containers/crun |

## 3. Portable CPython (python-build-standalone 20261003)

Downloaded from: https://github.com/astral-sh/python-build-standalone/releases/download/20261003/
Versions: 3.12.15 3.11.17 (x86_64, install_only_stripped)

| Component | License | Source |
|---|---|---|
| CPython | PSF-2.0 | https://github.com/python/cpython |
| build recipes | MPL-2.0 | https://github.com/astral-sh/python-build-standalone |

CPython's license and the licenses of the libraries built into it (OpenSSL,
SQLite, zlib, bzip2, xz, libffi, ncurses, Tcl/Tk and others) are in
lib/python3.X/LICENSE.txt inside each archive and are documented at
https://gregoryszorc.com/docs/python-build-standalone/main/running.html#licensing
