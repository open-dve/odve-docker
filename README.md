# odve-docker

Run Docker/OCI images on a Linux machine where you have **no root, no sudo and
no internet** - for example an HPC cluster login or compute node.

Everything is prepared on a machine with internet access, copied over as one
archive, and installed into `~/.local`. No package manager is used.

The installer picks the runtime by itself:

| Situation on the target machine | What gets installed |
|---|---|
| unprivileged user namespaces work | rootless **podman** (static build) |
| user namespaces are disabled or blocked | **udocker** in PRoot mode (needs no user namespaces) |

udocker needs Python 3.6+. A system `python3.12` / `python3.11` / `python3` /
`platform-python` is used when present; otherwise a portable CPython (3.12,
falling back to 3.11) from the bundle is unpacked.

## Quick start

Runtime only (no images) - take the archive from the
[Releases](https://github.com/open-dve/odve-docker/releases) page:

```bash
scp podman-offline-runtime-v5.6.1-amd64.tar.gz user@cluster:~/
ssh user@cluster
tar -xzf podman-offline-runtime-v5.6.1-amd64.tar.gz && cd bundle && ./install-podman.sh
```

Runtime **plus your images** - build your own bundle on a machine with
internet and docker or podman:

```bash
vim prepare-bundle.sh        # list your images in IMAGES
./prepare-bundle.sh          # -> podman-offline-bundle.tar.gz
scp podman-offline-bundle.tar.gz user@cluster:~/
# on the cluster:
tar -xzf podman-offline-bundle.tar.gz && cd bundle && ./install-podman.sh
```

Then, depending on what the installer chose:

```bash
source ~/.local/podman.env  && podman run --rm alpine echo ok
source ~/.local/udocker.env && udocker run alpine echo ok
```

Add the `source` line to `~/.bashrc` and to your Slurm job scripts.

## Options

| | |
|---|---|
| `./prepare-bundle.sh --release` | build the runtime-only archive, its `.sha256` and `NOTICE.md` |
| `UDOCKER_PYTHON=portable3.11 ./install-podman.sh` | force a Python for udocker: `portable`, `portable3.12`, `portable3.11` or a path |

## Notes and limits

- podman is pinned to **5.6.1**: podman 6 refuses to start on cgroups v1,
  which is the default on RHEL 8.
- Storage defaults to `$HOME` (assumed to be NFS); the podman runroot is
  always on local `/tmp`.
- Several jobs must not share one podman graphroot at the same time; give
  each job its own: `podman --root /tmp/podman-$SLURM_JOB_ID/storage ...`.
- udocker: changes inside a container persist between runs, heavy I/O is
  slower, images that need real root (systemd, mounts) will not work.
- x86_64 by default; set `ARCH="arm64"` in `prepare-bundle.sh` for arm64
  (not tested).

## Test status

Tested on Ubuntu 24.04 (kernel 6.8), where user namespaces are blocked: the
udocker path works end to end, fully offline, with every Python variant.
**Not yet tested:** a real RHEL 8 machine, and the podman path up to
`podman run`.

## Licenses

The scripts in this repository are under the MIT license (see `LICENSE`).
The release archive redistributes unmodified third-party binaries under
their own open-source licenses (Apache-2.0, GPL, LGPL, PSF and others) -
see [`NOTICE.md`](NOTICE.md) for the list and the links to their sources.
