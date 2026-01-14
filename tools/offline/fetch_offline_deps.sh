#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/assets/offline/manifest.json"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need_cmd python3
need_cmd curl
need_cmd tar

read_json() {
  python3 - "$@" <<PY
import json,sys
with open("$MANIFEST","r",encoding="utf-8") as f:
  data=json.load(f)
cur=data
for k in sys.argv[1:]:
  cur=cur[k]
print(cur)
PY
}

PY_VER="$(read_json python version)"
PY_TAG="$(read_json python providerTag)"
ANSIBLE_VER="$(read_json ansible version)"
SSH_PASS_VER="$(read_json ubuntuTools sshpassVersion)"
UNZIP_VER="$(read_json ubuntuTools unzipVersion)"

ANSIBLE_EXTRA_JSON="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(json.dumps(m.get("ansible", {}).get("extraPip", [])))
PY
)"

PIP_PYTHON="python3"
PIP_TMP=""

ensure_pip_python() {
  if python3 -m pip --version >/dev/null 2>&1; then
    PIP_PYTHON="python3"
    return 0
  fi

  local host_arch bundle path
  host_arch="$(uname -m | tr -d '\n')"
  case "$host_arch" in
    x86_64|amd64) bundle="linux-x86_64" ;;
    aarch64|arm64) bundle="linux-aarch64" ;;
    *) echo "Host arch not supported for wheelhouse build: $host_arch" >&2; exit 2 ;;
  esac

  path="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["pythonArchive"])
PY
)"

  if [[ ! -f "$ROOT/$path" ]]; then
    echo "Host python archive not found for wheelhouse build: $path" >&2
    echo "Run this script once to download python archives first." >&2
    exit 2
  fi

  PIP_TMP="$(mktemp -d)"
  trap '[[ -n "${PIP_TMP:-}" ]] && rm -rf "$PIP_TMP"' EXIT
  tar -xzf "$ROOT/$path" -C "$PIP_TMP"
  PIP_PYTHON="$PIP_TMP/python/bin/python3.12"
  if [[ ! -x "$PIP_PYTHON" ]]; then
    echo "Failed to prepare pip python from archive: $path" >&2
    exit 2
  fi
}

download_python() {
  local bundle="$1"
  local path key url
  key="pythonArchive"
  path="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["$key"])
PY
)"
  mkdir -p "$(dirname "$ROOT/$path")"
  if [[ -f "$ROOT/$path" ]]; then
    echo "[skip] $path exists"
    return 0
  fi
  local part="$ROOT/$path.part"
  local fname
  fname="$(basename "$path")"
  url="https://github.com/indygreg/python-build-standalone/releases/download/${PY_TAG}/${fname}"
  echo "[download] $url"
  curl -L --fail -C - -o "$part" "$url"
  mv -f "$part" "$ROOT/$path"
}

build_wheelhouse() {
  local bundle="$1"
  local out_archive
  local -a platform_args=()
  out_archive="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["ansibleWheelhouseArchive"])
PY
)"

  mkdir -p "$(dirname "$ROOT/$out_archive")"
  if [[ -f "$ROOT/$out_archive" ]]; then
    echo "[skip] $out_archive exists"
    return 0
  fi

  case "$bundle" in
    linux-x86_64)
      platform_args=(
        --platform manylinux_2_28_x86_64
        --platform manylinux_2_17_x86_64
        --platform manylinux2014_x86_64
      )
      ;;
    linux-aarch64)
      platform_args=(
        --platform manylinux_2_28_aarch64
        --platform manylinux_2_17_aarch64
        --platform manylinux2014_aarch64
      )
      ;;
    *) echo "Unknown bundle: $bundle" >&2; exit 2 ;;
  esac

  local tmp=""
  tmp="$(mktemp -d)"
  trap '[[ -n "${tmp:-}" ]] && rm -rf "$tmp"' EXIT

  mkdir -p "$tmp/wheelhouse"
  echo "[pip] downloading ansible==$ANSIBLE_VER for $bundle (py312)"
  local -a reqs=("ansible==$ANSIBLE_VER")
  while IFS= read -r x; do
    [[ -z "$x" ]] && continue
    reqs+=("$x")
  done < <(python3 - <<PY
import json
extras=json.loads('''$ANSIBLE_EXTRA_JSON''')
for x in extras:
  print(x)
PY
)

  "$PIP_PYTHON" -m pip download \
    --only-binary=:all: \
    "${platform_args[@]}" \
    --python-version 312 \
    --implementation cp \
    --abi cp312 \
    -d "$tmp/wheelhouse" \
    "${reqs[@]}"

  if ! ls "$tmp/wheelhouse"/ansible-"$ANSIBLE_VER"-*.whl >/dev/null 2>&1; then
    echo "ansible wheel not found in wheelhouse; check pip output" >&2
    exit 3
  fi

  echo "[pack] $out_archive"
  tar -czf "$ROOT/$out_archive" -C "$tmp" wheelhouse
}

download_ubuntu_tool_debs() {
  local bundle="$1"
  local debs_dir ssh_url unzip_url ssh_path unzip_path

  debs_dir="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["ubuntuDebs"]["sshpass"].rsplit("/",1)[0])
PY
)"

  mkdir -p "$ROOT/$debs_dir"

  ssh_path="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["ubuntuDebs"]["sshpass"])
PY
)"

  unzip_path="$(python3 - <<PY
import json
with open("$MANIFEST","r",encoding="utf-8") as f:
  m=json.load(f)
print(m["bundles"]["$bundle"]["ubuntuDebs"]["unzip"])
PY
)"

  case "$bundle" in
    linux-x86_64)
      ssh_url="http://archive.ubuntu.com/ubuntu/pool/universe/s/sshpass/sshpass_${SSH_PASS_VER}_amd64.deb"
      unzip_url="http://archive.ubuntu.com/ubuntu/pool/main/u/unzip/unzip_${UNZIP_VER}_amd64.deb"
      ;;
    linux-aarch64)
      ssh_url="http://ports.ubuntu.com/ubuntu-ports/pool/universe/s/sshpass/sshpass_${SSH_PASS_VER}_arm64.deb"
      unzip_url="http://ports.ubuntu.com/ubuntu-ports/pool/main/u/unzip/unzip_${UNZIP_VER}_arm64.deb"
      ;;
    *) echo "Unknown bundle: $bundle" >&2; exit 2 ;;
  esac

  if [[ -f "$ROOT/$ssh_path" ]]; then
    echo "[skip] $ssh_path exists"
  else
    echo "[download] $ssh_url"
    curl -L --fail -o "$ROOT/$ssh_path" "$ssh_url"
  fi

  if [[ -f "$ROOT/$unzip_path" ]]; then
    echo "[skip] $unzip_path exists"
  else
    echo "[download] $unzip_url"
    curl -L --fail -o "$ROOT/$unzip_path" "$unzip_url"
  fi
}

echo "[info] manifest=$MANIFEST"
echo "[info] python=$PY_VER tag=$PY_TAG ansible=$ANSIBLE_VER tools(ubuntu)=sshpass:$SSH_PASS_VER unzip:$UNZIP_VER"

download_python linux-x86_64
download_python linux-aarch64
download_ubuntu_tool_debs linux-x86_64
download_ubuntu_tool_debs linux-aarch64

ensure_pip_python
build_wheelhouse linux-x86_64
build_wheelhouse linux-aarch64

echo "done"
