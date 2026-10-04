#!/usr/bin/env bash
# Запускать НА МАШИНЕ С ИНТЕРНЕТОМ (WSL Ubuntu).
# Нужен установленный docker или podman - только чтобы вытянуть и сохранить образы.
# Результат: podman-offline-bundle.tar.gz -> scp на кластер.
#
#   ./prepare-bundle.sh            полный бандл: рантайм + образы из IMAGES
#   ./prepare-bundle.sh --release  архив для публикации (GitHub Releases):
#                                  только рантайм, БЕЗ образов, + .sha256.
#                                  docker/podman для этого не нужны.
set -euo pipefail

RELEASE=no
case "${1:-}" in
  --release) RELEASE=yes ;;
  "") ;;
  *) echo "Использование: $0 [--release]" >&2; exit 2 ;;
esac

# ---- ЧТО ПОЛОЖИТЬ В БАНДЛ ------------------------------------------------
# Впиши сюда образы, которые понадобятся на кластере. Скачаются заранее.
IMAGES=(
  "docker.io/library/alpine:latest"
  # "docker.io/verilator/verilator:latest"
  # "docker.io/library/ubuntu:22.04"
)
ARCH="amd64"          # для arm64 поменять на arm64

# ВАЖНО: podman 6.x при старте падает с "Cgroups v1 not supported".
# RHEL8 по умолчанию на cgroups v1, переключить может только админ (параметр
# ядра systemd.unified_cgroup_hierarchy=1). Поэтому берём последнюю 5.x.
# Если на твоих нодах cgroups v2 (stat -fc %T /sys/fs/cgroup -> cgroup2fs),
# можно поставить VERSION="latest".
VERSION="v5.6.1"

# Запасной вариант: udocker (режим PRoot). Работает без root и БЕЗ user
# namespaces - установщик ставит его сам, если podman на кластере невозможен.
# Нужен только python3 на кластере. UDOCKER_TOOLS должен совпадать с
# tarball_release внутри этой версии udocker (для 1.3.17 это 1.2.11).
UDOCKER_VERSION="1.3.17"
UDOCKER_TOOLS="1.2.11"

# Портативный python для udocker - на случай, если на кластере нет своего.
# Сборки python-build-standalone: один каталог, без установки, glibc 2.17+
# (RHEL7 и новее). Кладём обе ветки; установщик берёт 3.12, при сбое 3.11.
PYSTANDALONE_TAG="20261003"
PYSTANDALONE_VERSIONS=("3.12.15" "3.11.17")
# --------------------------------------------------------------------------

WORK="$(mktemp -d)"
OUT="$PWD/podman-offline-bundle.tar.gz"
if [ "$RELEASE" = "yes" ]; then
  # образы в публичный архив не кладём: у них свои лицензии и свой размер
  IMAGES=()
  OUT="$PWD/podman-offline-runtime-${VERSION}-${ARCH}.tar.gz"
fi
BUNDLE="$WORK/bundle"
mkdir -p "$BUNDLE/images"

if [ "$VERSION" = "latest" ]; then
  BASE="https://github.com/mgoltzsche/podman-static/releases/latest/download"
else
  BASE="https://github.com/mgoltzsche/podman-static/releases/download/$VERSION"
fi

echo "==> Качаю podman-static $VERSION ($ARCH)"
curl -fL --progress-bar \
  -o "$WORK/podman.tar.gz" \
  "$BASE/podman-linux-${ARCH}.tar.gz"

echo "==> Проверяю подпись (не критично, при ошибке просто продолжим)"
if command -v gpg >/dev/null 2>&1; then
  curl -fsSL -o "$WORK/podman.tar.gz.asc" \
    "$BASE/podman-linux-${ARCH}.tar.gz.asc" || true
  if [ -f "$WORK/podman.tar.gz.asc" ]; then
    gpg --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys 0CCF102C4F95D89E583FF1D4F8B5AF50344BB503 2>/dev/null || true
    gpg --batch --verify "$WORK/podman.tar.gz.asc" "$WORK/podman.tar.gz" 2>/dev/null \
      && echo "    подпись OK" \
      || echo "    ПРЕДУПРЕЖДЕНИЕ: подпись не проверена"
  fi
fi

tar -xzf "$WORK/podman.tar.gz" -C "$BUNDLE"
mv "$BUNDLE/podman-linux-${ARCH}" "$BUNDLE/podman-static"

echo "==> Качаю udocker $UDOCKER_VERSION (запасной вариант без user namespaces)"
mkdir -p "$BUNDLE/udocker"
curl -fL --progress-bar \
  -o "$BUNDLE/udocker/udocker-${UDOCKER_VERSION}.tar.gz" \
  "https://github.com/indigo-dc/udocker/releases/download/${UDOCKER_VERSION}/udocker-${UDOCKER_VERSION}.tar.gz"
# proot/runc/библиотеки: udocker обычно докачивает их сам, на кластере нечем
curl -fL --progress-bar \
  -o "$BUNDLE/udocker/udocker-englib-${UDOCKER_TOOLS}.tar.gz" \
  "https://raw.githubusercontent.com/jorge-lip/udocker-builds/master/tarballs/udocker-englib-${UDOCKER_TOOLS}.tar.gz"

case "$ARCH" in amd64) PYARCH="x86_64" ;; arm64) PYARCH="aarch64" ;; *) PYARCH="$ARCH" ;; esac
PYBASE="https://github.com/astral-sh/python-build-standalone/releases/download/$PYSTANDALONE_TAG"
mkdir -p "$BUNDLE/python"
curl -fsSL -o "$WORK/PYSUMS" "$PYBASE/SHA256SUMS"
for pyv in "${PYSTANDALONE_VERSIONS[@]}"; do
  pyf="cpython-${pyv}+${PYSTANDALONE_TAG}-${PYARCH}-unknown-linux-gnu-install_only_stripped.tar.gz"
  echo "==> Качаю портативный python $pyv"
  # в URL знак + надо кодировать
  curl -fL --progress-bar -o "$BUNDLE/python/$pyf" "$PYBASE/${pyf//+/%2B}"
  (cd "$BUNDLE/python" && grep " $pyf\$" "$WORK/PYSUMS" | sha256sum -c --quiet -) \
    && echo "    sha256 OK" \
    || { echo "ОШИБКА: sha256 не сошлась для $pyf" >&2; exit 1; }
done

# ---- образы ---------------------------------------------------------------
ENGINE=""
command -v podman >/dev/null 2>&1 && ENGINE=podman
[ -z "$ENGINE" ] && command -v docker >/dev/null 2>&1 && ENGINE=docker
if [ -z "$ENGINE" ] && [ ${#IMAGES[@]} -gt 0 ]; then
  echo "ОШИБКА: нет ни docker, ни podman - нечем скачать образы." >&2
  echo "Поставь любой из них, либо очисти список IMAGES." >&2
  exit 1
fi

: > "$BUNDLE/images/manifest.txt"
for img in "${IMAGES[@]}"; do
  echo "==> Тяну $img через $ENGINE"
  "$ENGINE" pull "$img"
  fname="$(echo "$img" | tr '/:' '__').tar"
  echo "    сохраняю -> images/$fname"
  "$ENGINE" save -o "$BUNDLE/images/$fname" "$img"
  echo "$fname|$img" >> "$BUNDLE/images/manifest.txt"
done

# ---- установщик кладём внутрь бандла --------------------------------------
if [ -f "$(dirname "$0")/install-podman.sh" ]; then
  cp "$(dirname "$0")/install-podman.sh" "$BUNDLE/"
else
  echo "ПРЕДУПРЕЖДЕНИЕ: install-podman.sh не найден рядом, положи его в бандл вручную"
fi
chmod +x "$BUNDLE/install-podman.sh" 2>/dev/null || true

# ---- NOTICE: что внутри, под какими лицензиями, где исходники --------------
# Часть компонентов под GPL: при раздаче бинарников нужно указать лицензию и
# где взять исходный код. Бинарники кладутся как есть, без изменений.
echo "==> Генерирую NOTICE.md"
binver() { "$@" 2>/dev/null | head -1 | tr -d '\r' || true; }
PB="$BUNDLE/podman-static/usr/local"
{
  cat <<EOF
# NOTICE - third-party software in this bundle

Built: $(date -u +%Y-%m-%d) by prepare-bundle.sh. All binaries are
redistributed UNMODIFIED, exactly as published by the upstream projects
listed below. Every component is free / open-source software. The source
code for each one is available at the "Source" link, at the version shown.
The install scripts themselves (prepare-bundle.sh, install-podman.sh) are
separate works and are not derived from any of these components.

## 1. podman-static $VERSION ($ARCH)

Downloaded from: $BASE/podman-linux-${ARCH}.tar.gz
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

EOF
  echo '```'
  binver "$PB/bin/podman" --version
  binver "$PB/bin/crun" --version
  binver "$PB/bin/runc" --version
  binver "$PB/lib/podman/conmon" --version
  binver "$PB/bin/fuse-overlayfs" --version
  binver "$PB/lib/podman/netavark" --version
  binver "$PB/lib/podman/aardvark-dns" --version
  echo '```'
  cat <<EOF

## 2. udocker $UDOCKER_VERSION and its tools tarball $UDOCKER_TOOLS

Downloaded from:
- https://github.com/indigo-dc/udocker/releases/download/${UDOCKER_VERSION}/udocker-${UDOCKER_VERSION}.tar.gz
- https://raw.githubusercontent.com/jorge-lip/udocker-builds/master/tarballs/udocker-englib-${UDOCKER_TOOLS}.tar.gz

The license texts are inside the tools tarball under udocker_dir/doc/.

| Component | License | Source |
|---|---|---|
| udocker | Apache-2.0 | https://github.com/indigo-dc/udocker |
| PRoot (udocker fork) | GPL-2.0-or-later | https://github.com/jorge-lip/proot-udocker |
| patchelf (udocker fork) | GPL-3.0-or-later | https://github.com/jorge-lip/patchelf-udocker |
| fakechroot (udocker fork) | LGPL-2.1-or-later | https://github.com/jorge-lip/libfakechroot-glibc-udocker |
| runc | Apache-2.0 | https://github.com/opencontainers/runc |
| crun | GPL-2.0-or-later | https://github.com/containers/crun |

## 3. Portable CPython (python-build-standalone $PYSTANDALONE_TAG)

Downloaded from: $PYBASE/
Versions: ${PYSTANDALONE_VERSIONS[*]} ($PYARCH, install_only_stripped)

| Component | License | Source |
|---|---|---|
| CPython | PSF-2.0 | https://github.com/python/cpython |
| build recipes | MPL-2.0 | https://github.com/astral-sh/python-build-standalone |

CPython's license and the licenses of the libraries built into it (OpenSSL,
SQLite, zlib, bzip2, xz, libffi, ncurses, Tcl/Tk and others) are in
lib/python3.X/LICENSE.txt inside each archive and are documented at
https://gregoryszorc.com/docs/python-build-standalone/main/running.html#licensing
EOF
  if [ ${#IMAGES[@]} -gt 0 ]; then
    cat <<EOF

## 4. Container images

This bundle also contains container images (images/manifest.txt). Each image
carries its own licenses; they are NOT covered by this file:

EOF
    printf -- '- %s\n' "${IMAGES[@]}"
  fi
} > "$BUNDLE/NOTICE.md"

echo "==> Пакую"
tar -czf "$OUT" -C "$WORK" bundle

echo
if [ "$RELEASE" = "yes" ]; then
  (cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
  cp "$BUNDLE/NOTICE.md" "$PWD/NOTICE.md"
fi
rm -rf "$WORK"

echo "Готово: $OUT"
du -h "$OUT"
echo
echo "Дальше:"
echo "  scp $(basename "$OUT") user@cluster:~/"
echo "  ssh user@cluster"
echo "  tar -xzf $(basename "$OUT") && cd bundle && ./install-podman.sh"
