#!/usr/bin/env bash
set -euo pipefail

VENV_DIR="${VENV_DIR:-/opt/weka-temp-venv}"
LOG_FILE="${LOG_FILE:-/var/log/weka-venv-setup.log}"
DEPS=(${DEPS:-boto3 requests psutil})

mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

echo "[$(date -Is)] setting up venv at $VENV_DIR"

retry() {
  local n=0 max="${1:-5}"; shift
  until "$@"; do
    n=$((n+1))
    [[ $n -ge $max ]] && return 1
    sleep $((n*2))
  done
}

install_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    retry 5 apt-get update -y
    retry 5 apt-get install -y --no-install-recommends python3 python3-venv python3-pip ca-certificates curl
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    retry 5 dnf -y install python3 python3-pip ca-certificates curl
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    retry 5 yum -y install python3 python3-pip ca-certificates curl
    return
  fi

  echo "No supported package manager found (apt/dnf/yum)" >&2
  exit 1
}

install_prereqs

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install -U pip setuptools wheel
"$VENV_DIR/bin/python" -m pip install -U "${DEPS[@]}"

"$VENV_DIR/bin/python" - <<'PY'
import boto3, requests
print("boto3", boto3.__version__)
print("requests", requests.__version__)
PY

echo "[$(date -Is)] done"

