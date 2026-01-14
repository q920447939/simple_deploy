#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install_control_runtime.sh --python-archive <path> --python-install-dir <dir> --python-bin <path> --ansible-wheelhouse-archive <path> --ansible-version <ver> --ansible-venv <dir> [--ansible-extra <spec>]... [--sshpass-deb <path>] [--unzip-deb <path>]

Idempotent:
  - If python3.12 exists, python install is skipped.
  - If <ansible-venv>/bin/ansible-playbook exists, ansible install is skipped.
EOF
}

PY_ARCHIVE=""
PY_INSTALL_DIR=""
PY_BIN=""
WHEELHOUSE_ARCHIVE=""
ANSIBLE_VERSION=""
ANSIBLE_VENV=""
SSH_PASS_DEB=""
UNZIP_DEB=""
ANSIBLE_EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python-archive) PY_ARCHIVE="${2:-}"; shift 2 ;;
    --python-install-dir) PY_INSTALL_DIR="${2:-}"; shift 2 ;;
    --python-bin) PY_BIN="${2:-}"; shift 2 ;;
    --ansible-wheelhouse-archive) WHEELHOUSE_ARCHIVE="${2:-}"; shift 2 ;;
    --ansible-version) ANSIBLE_VERSION="${2:-}"; shift 2 ;;
    --ansible-venv) ANSIBLE_VENV="${2:-}"; shift 2 ;;
    --ansible-extra) ANSIBLE_EXTRA+=("${2:-}"); shift 2 ;;
    --sshpass-deb) SSH_PASS_DEB="${2:-}"; shift 2 ;;
    --unzip-deb) UNZIP_DEB="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$PY_ARCHIVE" || -z "$PY_INSTALL_DIR" || -z "$PY_BIN" || -z "$WHEELHOUSE_ARCHIVE" || -z "$ANSIBLE_VERSION" || -z "$ANSIBLE_VENV" ]]; then
  usage
  exit 2
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 3; }
}

need_cmd bash
need_cmd tar
need_cmd mkdir
need_cmd rm
need_cmd chmod

install_python() {
  if command -v python3.12 >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -f "$PY_ARCHIVE" ]]; then
    echo "python archive not found: $PY_ARCHIVE" >&2
    exit 4
  fi

  local tmp
  tmp="$(mktemp -d)"

  mkdir -p "$(dirname "$PY_INSTALL_DIR")"
  rm -rf "$PY_INSTALL_DIR"
  mkdir -p "$PY_INSTALL_DIR"

  tar -xzf "$PY_ARCHIVE" -C "$tmp"
  if [[ ! -d "$tmp/python" ]]; then
    echo "unexpected python archive layout (missing python/)" >&2
    exit 5
  fi

  mv "$tmp/python" "$PY_INSTALL_DIR"
  rm -rf "$tmp"

  cat >"$PY_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PYTHONHOME="$PY_INSTALL_DIR"
exec "$PY_INSTALL_DIR/bin/python3.12" "\$@"
EOF
  chmod 0755 "$PY_BIN"
}

install_ansible() {
  if [[ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]]; then
    return 0
  fi

  if [[ ! -f "$WHEELHOUSE_ARCHIVE" ]]; then
    echo "ansible wheelhouse archive not found: $WHEELHOUSE_ARCHIVE" >&2
    exit 6
  fi

  need_cmd "$PY_BIN"

  local wheel_dir
  wheel_dir="$(mktemp -d)"
  tar -xzf "$WHEELHOUSE_ARCHIVE" -C "$wheel_dir"

  local find_links="$wheel_dir/wheelhouse"
  if [[ ! -d "$find_links" ]]; then
    # allow archives that extract wheels directly into root
    find_links="$wheel_dir"
  fi

  rm -rf "$ANSIBLE_VENV"
  "$PY_BIN" -m venv "$ANSIBLE_VENV"

  local pkgs=("ansible==$ANSIBLE_VERSION")
  if [[ ${#ANSIBLE_EXTRA[@]} -gt 0 ]]; then
    pkgs+=("${ANSIBLE_EXTRA[@]}")
  fi
  "$ANSIBLE_VENV/bin/python" -m pip install --no-index --find-links "$find_links" "${pkgs[@]}"

  rm -rf "$wheel_dir"
}

install_tools_best_effort() {
  if command -v unzip >/dev/null 2>&1; then
    : # ok
  else
    if [[ -n "${UNZIP_DEB:-}" && -f "${UNZIP_DEB:-}" && -x "$(command -v dpkg || true)" ]]; then
      if ! dpkg -i "$UNZIP_DEB" >/dev/null 2>&1; then
        echo "WARN: failed to install unzip from deb: $UNZIP_DEB" >&2
      fi
    fi
  fi

  if command -v sshpass >/dev/null 2>&1; then
    : # ok
  else
    if [[ -n "${SSH_PASS_DEB:-}" && -f "${SSH_PASS_DEB:-}" && -x "$(command -v dpkg || true)" ]]; then
      if ! dpkg -i "$SSH_PASS_DEB" >/dev/null 2>&1; then
        echo "WARN: failed to install sshpass from deb: $SSH_PASS_DEB" >&2
      fi
    fi
  fi
}

install_python
install_ansible
install_tools_best_effort

echo "ok"
