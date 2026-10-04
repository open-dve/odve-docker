#!/usr/bin/env bash
# Запускать НА КЛАСТЕРЕ, из распакованного каталога bundle/. Без sudo.
# Ставит rootless podman в ~/.local, генерирует конфиги, загружает образы.
# Если podman здесь невозможен (нет user namespaces) - ставит udocker (PRoot).
set -euo pipefail

PREFIX="$HOME/.local"
CONF="$HOME/.config/containers"
SRC="$(cd "$(dirname "$0")" && pwd)"
ME="$(id -un)"

# runroot ОБЯЗАТЕЛЬНО локальный: там unix-сокеты и локи, на NFS не работает.
RUNROOT="/tmp/podman-$ME/run"
# graphroot по умолчанию на NFS (в $HOME), ниже может быть переопределён.
GRAPHROOT="$HOME/.podman/storage"

# docker-archive -> OCI-архив, который udocker точно прочитает.
# Сам 'udocker load' понимает только старый формат docker save (каталог на
# слой); архивы от podman save и других инструментов он не грузит. Поэтому
# перекладываем по manifest.json - он есть в любом docker-archive.
# Аргументы: python, входной tar, выходной tar, имя образа для udocker.
docker2oci() {
  "$1" - "$2" "$3" "$4" <<'PYEOF'
import hashlib, json, os, shutil, sys, tarfile, tempfile

src, dst, ref = sys.argv[1:4]
work = tempfile.mkdtemp(prefix="d2o-", dir=os.environ.get("TMPDIR"))
try:
    raw, oci = os.path.join(work, "raw"), os.path.join(work, "oci")
    blobs = os.path.join(oci, "blobs", "sha256")
    os.makedirs(blobs)
    with tarfile.open(src) as t:
        t.extractall(raw)
    with open(os.path.join(raw, "manifest.json")) as f:
        entry = json.load(f)[0]

    def add_file(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            gz = f.read(2) == b"\x1f\x8b"
            f.seek(0)
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        size = os.path.getsize(path)
        target = os.path.join(blobs, h.hexdigest())
        if not os.path.exists(target):
            shutil.move(os.path.realpath(path), target)
        return "sha256:" + h.hexdigest(), size, gz

    def add_bytes(data):
        d = hashlib.sha256(data).hexdigest()
        with open(os.path.join(blobs, d), "wb") as f:
            f.write(data)
        return "sha256:" + d, len(data)

    with open(os.path.join(raw, entry["Config"]), "rb") as f:
        cfg_digest, cfg_size = add_bytes(f.read())
    layers = []
    for layer in entry["Layers"]:
        digest, size, gz = add_file(os.path.join(raw, layer))
        layers.append({
            "mediaType": "application/vnd.oci.image.layer.v1.tar"
                         + ("+gzip" if gz else ""),
            "digest": digest, "size": size})
    manifest = json.dumps({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                   "digest": cfg_digest, "size": cfg_size},
        "layers": layers}).encode()
    m_digest, m_size = add_bytes(manifest)
    with open(os.path.join(oci, "index.json"), "w") as f:
        json.dump({"schemaVersion": 2, "manifests": [{
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": m_digest, "size": m_size,
            "annotations": {"org.opencontainers.image.ref.name": ref}}]}, f)
    with open(os.path.join(oci, "oci-layout"), "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)
    with tarfile.open(dst, "w") as t:
        for name in sorted(os.listdir(oci)):
            t.add(os.path.join(oci, name), arcname=name)
finally:
    shutil.rmtree(work, ignore_errors=True)
PYEOF
}

# ---- запасной вариант: udocker ---------------------------------------------
# Вызывается, когда rootless podman невозможен. udocker в режиме PRoot (P1)
# перехватывает системные вызовы через ptrace: не нужны ни root, ни user
# namespaces, ни fuse. Цена - медленнее на интенсивном вводе-выводе.
fallback_udocker() {
  echo
  echo "=== Запасной вариант: ставлю udocker вместо podman ==="
  local tgz tools py="" c udir="$HOME/.udocker"
  tgz="$(ls "$SRC"/udocker/udocker-[0-9]*.tar.gz 2>/dev/null | head -1)"
  tools="$(ls "$SRC"/udocker/udocker-englib-*.tar.gz 2>/dev/null | head -1)"
  if [ -z "$tgz" ] || [ -z "$tools" ]; then
    echo "  СТОП: в бандле нет каталога udocker/. Пересобери бандл свежим"
    echo "  prepare-bundle.sh."
    exit 1
  fi

  # --- выбор python: три ветки ----------------------------------------------
  # udocker написан на python (годится 3.6+). Порядок:
  #   1) системный python3.12 / python3.11, если есть под этим именем;
  #   2) любой другой системный 3.6+ (python3, python, platform-python -
  #      последний на RHEL8 есть, даже когда python3 не установлен);
  #   3) портативный из бандла: сначала 3.12, не запустился - 3.11.
  # Принудительно: UDOCKER_PYTHON=portable | portable3.12 | portable3.11
  #                или UDOCKER_PYTHON=/путь/к/python
  local want="${UDOCKER_PYTHON:-auto}" v pydir pytgz
  py_ok() {  # запускается, 3.6+, есть модули, нужные udocker и конвертеру
    "$1" -c 'import sys, json, tarfile, hashlib, ssl
sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1
  }
  py_ver() { "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'; }

  echo "  ищу python для udocker (нужен 3.6+), режим: $want"
  case "$want" in
    auto)
      for c in python3.12 python3.11 python3 python /usr/libexec/platform-python; do
        if command -v "$c" >/dev/null 2>&1; then
          if py_ok "$c"; then
            py="$(command -v "$c")"
            echo "    системный $c ...... $(py_ver "$c") - беру его"
            break
          fi
          echo "    системный $c ...... не подходит (старый или битый)"
        fi
      done
      [ -z "$py" ] && echo "    системного подходящего нет -> портативный из бандла"
      ;;
    portable*) ;;
    *)
      if py_ok "$want"; then
        py="$(command -v "$want")"
        echo "    заданный $want ...... $(py_ver "$want")"
      else
        echo "  СТОП: UDOCKER_PYTHON=$want не запускается или старше 3.6."
        exit 1
      fi
      ;;
  esac

  if [ -z "$py" ]; then
    case "$want" in
      portable3.11) set -- 3.11 ;;
      portable3.12) set -- 3.12 ;;
      *)            set -- 3.12 3.11 ;;
    esac
    for v in "$@"; do
      pytgz="$(ls "$SRC"/python/cpython-"$v".*.tar.gz 2>/dev/null | head -1)"
      if [ -z "$pytgz" ]; then
        echo "    портативный $v ..... нет в бандле"; continue
      fi
      pydir="$PREFIX/python-$v"
      mkdir -p "$pydir"
      tar -xzf "$pytgz" -C "$pydir" --strip-components=1
      if py_ok "$pydir/bin/python3"; then
        py="$pydir/bin/python3"
        echo "    портативный $v ..... $(py_ver "$py") -> $pydir"
        break
      fi
      echo "    портативный $v ..... распакован, но не запускается, пробую следующий"
      rm -rf "${pydir:?}"
    done
  fi
  if [ -z "$py" ]; then
    echo "  СТОП: ни системный, ни портативный python не заработал."
    echo "  Проверь 'module avail python' и запусти с UDOCKER_PYTHON=/путь/к/python."
    exit 1
  fi

  echo "  распаковываю udocker в $PREFIX/udocker"
  mkdir -p "$PREFIX/bin" "$PREFIX/udocker" "$HOME/tmp"
  tar -xzf "$tgz" -C "$PREFIX/udocker" --strip-components=1
  # обёртка: в самом udocker шебанг "env python", которого на RHEL8 нет
  cat > "$PREFIX/bin/udocker" <<EOF
#!/bin/sh
exec "$py" "$PREFIX/udocker/udocker/udocker" "\$@"
EOF
  chmod +x "$PREFIX/bin/udocker"

  cat > "$PREFIX/udocker.env" <<EOF
export PATH="$PREFIX/bin:\$PATH"
export UDOCKER_DIR="$udir"
export TMPDIR="$HOME/tmp"
EOF
  # shellcheck disable=SC1090
  source "$PREFIX/udocker.env"

  echo "  ставлю proot и библиотеки из бандла (без сети)"
  UDOCKER_TARBALL="$tools" udocker install >/dev/null
  udocker version | grep -iE 'version|tarball' || true

  echo "  загружаю образы и создаю из них контейнеры"
  local fname img short tag uimg oci first=""
  if [ -f "$SRC/images/manifest.txt" ]; then
    while IFS='|' read -r fname img; do
      [ -z "${fname:-}" ] && continue
      short="${img##*/}"; short="${short%%:*}"
      echo "  -> $img"
      tag="${img##*:}"; [ "$tag" = "$img" ] && tag="latest"
      uimg="bundle/$short:$tag"
      oci="$HOME/tmp/udocker-load-$$.tar"
      if ! docker2oci "$py" "$SRC/images/$fname" "$oci" "$uimg" \
         || ! udocker load -i "$oci" </dev/null >/dev/null; then
        rm -f "$oci"
        echo "     ОШИБКА: образ не загрузился"; continue
      fi
      rm -f "$oci"
      if udocker inspect -p "$short" >/dev/null 2>&1; then
        echo "     контейнер '$short' уже есть, не трогаю"
      else
        udocker create --name="$short" "$uimg" </dev/null >/dev/null
        echo "     образ $uimg, контейнер '$short' создан"
      fi
      [ -z "$first" ] && first="$short"
    done < "$SRC/images/manifest.txt"
  else
    echo "  образов в бандле нет"
  fi

  if [ -n "$first" ]; then
    echo "  пробный запуск: udocker run $first /bin/true"
    if udocker --quiet run "$first" /bin/true </dev/null; then
      echo "    запуск ............. OK"
    else
      echo "    запуск ............. ОШИБКА. Попробуй другой режим:"
      echo "      udocker setup --execmode=P2 $first"
    fi
  fi

  cat <<EOF

================================================================
Готово: установлен udocker (podman здесь невозможен).

Добавь в ~/.bashrc и в Slurm-скрипты:
    source $PREFIX/udocker.env

Запуск (контейнер = распакованный образ, имя = короткое имя образа):
    udocker run ${first:-<имя>} echo ok
    udocker run -v /path/on/nfs:/data ${first:-<имя>} команда
    udocker ps                # список контейнеров

Отличия от podman:
  - изменения внутри контейнера СОХРАНЯЮТСЯ между запусками (нет --rm);
    чистая копия: udocker create --name=новое <образ из 'udocker images'>
  - контейнеры лежат в $udir - это много мелких файлов,
    следи за квотой NFS
  - интенсивный ввод-вывод медленнее (PRoot перехватывает syscalls)
  - сборки образов (build) нет, только запуск
================================================================
EOF
  exit 0
}

echo "=== 1. Раскладываю бинарники ==="
mkdir -p "$PREFIX" "$CONF" "$HOME/.podman" "$RUNROOT" "$HOME/tmp"
chmod 700 "$RUNROOT"
cp -r "$SRC/podman-static/usr/local/." "$PREFIX/"
chmod +x "$PREFIX/bin/"* 2>/dev/null || true
# базовые конфиги из архива (в т.ч. policy.json - без него podman не запустится)
cp -rn "$SRC/podman-static/etc/containers/." "$CONF/" 2>/dev/null || true
# Drop-in из архива жёстко прописывает /usr/local/bin/fuse-overlayfs, которого
# на кластере нет. Убираем, свои настройки пишем ниже.
rm -rf "${CONF:?}/storage.conf.d"

echo "=== 2. Проверяю окружение ==="
HAVE_FUSE=no
if [ -c /dev/fuse ] && [ -r /dev/fuse ]; then HAVE_FUSE=yes; fi
echo "  /dev/fuse ............ $HAVE_FUSE"

CGV="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
if [ "$CGV" = "cgroup2fs" ]; then CGROUPS_MODE="enabled"; else CGROUPS_MODE="disabled"; fi
echo "  cgroups .............. $CGV -> $CGROUPS_MODE"

PODVER="$("$SRC/podman-static/usr/local/bin/podman" --version 2>/dev/null | awk '{print $3}')"
echo "  версия podman ........ ${PODVER:-?}"
case "${PODVER%%.*}" in
  6|7|8|9)
    if [ "$CGV" != "cgroup2fs" ]; then
      echo
      echo "  СТОП: podman $PODVER не поддерживает cgroups v1, а здесь $CGV."
      echo "  Пересобери бандл с VERSION=\"v5.6.1\" в prepare-bundle.sh."
      exit 1
    fi
    ;;
esac

# --- user namespaces: две проверки подряд -----------------------------------
# Rootless podman целиком держится на user namespaces: в них твой UID
# отображается в root контейнера. Без них не запустится ничего.
#
# Проверка 1: лимит ядра. 0 = админ выключил userns полностью.
echo "  user namespaces, проверка 1/2: лимит ядра user.max_user_namespaces"
MAXNS="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
echo "    значение ........... $MAXNS (нужно > 0)"
if [ "$MAXNS" -lt 1 ]; then
  echo
  echo "  PODMAN НЕВОЗМОЖЕН: user namespaces отключены ядром (лимит 0). Rootless podman не заработает."
  echo "  Это лечится только админом: sysctl user.max_user_namespaces=15000."
  echo "  Ставлю udocker в режиме PRoot: ему userns не нужны."
  fallback_udocker
fi

# Проверка 2: реально создаём namespace. Лимит > 0 ещё ничего не гарантирует:
# создание может запрещать AppArmor (Ubuntu 24.04+), SELinux или seccomp.
echo "  user namespaces, проверка 2/2: пробное создание (unshare -Ur true)"
if ! command -v unshare >/dev/null 2>&1; then
  echo "    пропущена: нет утилиты unshare. Узнаем на шаге 6."
elif unshare -Ur true 2>/dev/null; then
  echo "    создание ........... OK"
else
  echo "    создание ........... ОТКАЗ"
  echo
  echo "  PODMAN НЕВОЗМОЖЕН: лимит ядра ненулевой, но создать user namespace не дали."
  echo "  Запрещает политика безопасности (AppArmor/SELinux/seccomp)."
  echo "  Rootless podman не заработает, лечится только админом."
  echo "  Ставлю udocker в режиме PRoot: ему userns не нужны."
  fallback_udocker
fi

# --- subuid: полный маппинг или single-UID ----------------------------------
echo "  subuid: есть ли у $ME диапазон дополнительных UID в /etc/subuid"
if grep -q "^$ME:" /etc/subuid 2>/dev/null; then
  if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
    echo
    echo "  PODMAN НЕВОЗМОЖЕН: в /etc/subuid для $ME есть диапазон, но нет newuidmap/newgidmap."
    echo "  В таком состоянии podman не стартует вообще (чинит только админ:"
    echo "  пакет shadow-utils либо убрать запись из /etc/subuid)."
    fallback_udocker
  fi
  echo "  subuid ............... есть (полный маппинг доступен)"
  IGNORE_CHOWN="false"
else
  echo "  subuid ............... нет -> single-UID режим"
  IGNORE_CHOWN="true"
fi

echo "  проверяю flock на NFS..."
if flock -w 5 "$HOME/.podman/.locktest" -c true 2>/dev/null; then
  echo "    flock OK"
else
  echo "    ПРЕДУПРЕЖДЕНИЕ: flock на \$HOME не работает - podman будет виснуть."
  echo "    Перенеси graphroot на локальный диск (переменная GRAPHROOT в скрипте)."
fi
rm -f "$HOME/.podman/.locktest"

echo "=== 3. Генерирую storage.conf ==="
if [ "$HAVE_FUSE" = "yes" ]; then
  cat > "$CONF/storage.conf" <<EOF
[storage]
driver = "overlay"
graphroot = "$GRAPHROOT"
runroot = "$RUNROOT"

[storage.options.overlay]
mount_program = "$PREFIX/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"
ignore_chown_errors = "$IGNORE_CHOWN"
EOF
  echo "  драйвер overlay + fuse-overlayfs (тонкие слои, экономит место)"
else
  cat > "$CONF/storage.conf" <<EOF
[storage]
driver = "vfs"
graphroot = "$GRAPHROOT"
runroot = "$RUNROOT"

[storage.options.vfs]
ignore_chown_errors = "$IGNORE_CHOWN"
EOF
  echo "  драйвер vfs (fuse недоступен). Внимание: каждый слой копируется целиком,"
  echo "  по NFS это медленно и жрёт квоту."
fi

echo "=== 4. Генерирую containers.conf ==="
cat > "$CONF/containers.conf" <<EOF
[containers]
netns = "host"
cgroups = "$CGROUPS_MODE"
log_driver = "k8s-file"

[engine]
runtime = "crun"
runtime_supports_json = ["crun"]
helper_binaries_dir = ["$PREFIX/lib/podman"]
# conmon ищется ОТДЕЛЬНЫМ ключом, helper_binaries_dir на него не влияет
conmon_path = ["$PREFIX/lib/podman/conmon"]
static_dir = "$GRAPHROOT/libpod"
volume_path = "$GRAPHROOT/volumes"
# podman-static собран БЕЗ systemd: journald-логгер и systemd cgroup-менеджер
# недоступны. Без этих двух строк контейнер не стартует.
events_logger = "file"
cgroup_manager = "cgroupfs"

[engine.runtimes]
crun = ["$PREFIX/bin/crun"]
runc = ["$PREFIX/bin/runc"]
EOF

# offline: незачем ходить в реестры
cat > "$CONF/registries.conf" <<'EOF'
unqualified-search-registries = []
EOF

if [ ! -f "$CONF/policy.json" ]; then
  cat > "$CONF/policy.json" <<'EOF'
{"default":[{"type":"insecureAcceptAnything"}]}
EOF
fi

echo "=== 5. Пишу ~/.local/podman.env ==="
cat > "$PREFIX/podman.env" <<EOF
export PATH="$PREFIX/bin:\$PATH"
export XDG_RUNTIME_DIR="$RUNROOT"
export TMPDIR="$HOME/tmp"
export CONTAINERS_CONF="$CONF/containers.conf"
export CONTAINERS_STORAGE_CONF="$CONF/storage.conf"
export PODMAN_IGNORE_CGROUPSV1_WARNING=1
mkdir -p "$RUNROOT" 2>/dev/null; chmod 700 "$RUNROOT" 2>/dev/null
EOF

# shellcheck disable=SC1090
source "$PREFIX/podman.env"

echo "=== 6. Проверяю запуск ==="
podman version | head -3

echo "=== 7. Загружаю образы ==="
FIRST_IMG=""
if [ -f "$SRC/images/manifest.txt" ]; then
  ALIASES=""
  while IFS='|' read -r fname img; do
    [ -z "${fname:-}" ] && continue
    echo "  -> $img"
    # </dev/null обязательно: podman иначе съедает stdin цикла
    podman load -i "$SRC/images/$fname" </dev/null
    [ -z "$FIRST_IMG" ] && FIRST_IMG="$img"
    short="${img##*/}"; short="${short%%:*}"
    repo="${img%%:*}"
    ALIASES="$ALIASES\"$short\" = \"$repo\"
"
  done < "$SRC/images/manifest.txt"

  # Реестров нет, поэтому короткие имена ("alpine") сами не разрешатся.
  # Прописываем алиасы на загруженные образы.
  if [ -n "$ALIASES" ]; then
    {
      echo 'unqualified-search-registries = []'
      echo ''
      echo '[aliases]'
      printf '%b' "$ALIASES"
    } > "$CONF/registries.conf"
  fi
  podman images
else
  echo "  образов в бандле нет"
fi

cat <<EOF

================================================================
Готово.

Добавь в ~/.bashrc:
    source $PREFIX/podman.env

В Slurm-джобе обязательно то же самое - XDG_RUNTIME_DIR на compute-ноде
свой, иначе podman не найдёт runroot.

ВАЖНО про параллельные джобы: один graphroot из нескольких задач
одновременно портит хранилище. Для параллельного запуска давай каждому
джобу свой:  podman --root /tmp/podman-\$SLURM_JOB_ID/storage ...

Проверка:
    podman run --rm ${FIRST_IMG:-<образ>} echo ok

Реестров нет, поэтому образы запускай полным именем (или короткими
алиасами, которые скрипт прописал в registries.conf).
================================================================
EOF
