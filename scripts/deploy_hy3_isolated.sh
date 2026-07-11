#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${HY3_SERVICE_NAME:-hy3-isolated}"
PORT="${HY3_PORT:-11452}"
HOST="${HY3_HOST:-127.0.0.1}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
HF_CLASS="${HY3_CLASS:-Q2_K}"
HF_FILENAME="${HY3_FILENAME:-hy3-1M-${HF_CLASS}.gguf}"
OLLAMA_BIN="${HY3_OLLAMA_BIN:-$(command -v ollama || true)}"

if [[ -z "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not found"
  exit 1
fi

if [[ ! -f "${MODELS_DIR}/${HF_FILENAME}" ]]; then
  echo "Model file not found locally. Pulling first."
  HF_CLASS="$HF_CLASS" HY3_MODELS_DIR="$MODELS_DIR" /home/roko/Documents/Projects/Adjacent/hy3/scripts/pull_hy3_gguf.sh 0
else
  echo "Model already present at ${MODELS_DIR}/${HF_FILENAME}"
fi

/home/roko/Documents/Projects/Adjacent/hy3/scripts/generate_hy3_isolated_service.sh "$SERVICE_NAME" "$PORT" "$HOST" "$MODELS_DIR" "$OLLAMA_BIN"

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME.service"

echo "Waiting for endpoint on http://${HOST}:${PORT}/api/tags"
for i in $(seq 1 25); do
  if curl -sS --max-time 2 "http://${HOST}:${PORT}/api/tags" >/dev/null 2>&1; then
    echo "hy3 endpoint up: http://${HOST}:${PORT}/api/tags"
    curl -sS "http://${HOST}:${PORT}/api/tags"
    exit 0
  fi
  sleep 1
done

echo "ERROR: hy3 service did not become ready in 25 seconds"
systemctl --user status "$SERVICE_NAME.service" --no-pager --full | sed -n '1,80p'
exit 1
