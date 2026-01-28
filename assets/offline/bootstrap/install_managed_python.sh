#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install_managed_python.sh --python-archive <path> --python-install-dir <dir> --python-bin <path>

Idempotent:
  - If <python-bin> exists and version is 3.12, install is skipped.
EOF
}

PY_ARCHIVE=""
PY_INSTALL_DIR=""
PY_BIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python-archive) PY_ARCHIVE="${2:-}"; shift 2 ;;
    --python-install-dir) PY_INSTALL_DIR="${2:-}"; shift 2 ;;
    --python-bin) PY_BIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$PY_ARCHIVE" || -z "$PY_INSTALL_DIR" || -z "$PY_BIN" ]]; then
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

has_python312() {
  if [[ -x "$PY_BIN" ]]; then
    "$PY_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[:2]==(3,12) else 3)' >/dev/null 2>&1
    return $?
  fi
  return 1
}

install_python() {
  if has_python312; then
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

install_python
echo "ok"
