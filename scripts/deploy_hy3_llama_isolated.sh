#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${HY3_SERVICE_NAME:-hy3-llama-isolated}"
PORT="${HY3_PORT:-11453}"
HOST="${HY3_HOST:-127.0.0.1}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
HF_CLASS="${HY3_CLASS:-Q2_K}"
HF_FILENAME="${HY3_FILENAME:-hy3-1M-${HF_CLASS}.gguf}"
MODEL_PATH="${MODELS_DIR}/${HF_FILENAME}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Model file not found locally. Pulling first."
  HF_CLASS="$HF_CLASS" HY3_MODELS_DIR="$MODELS_DIR" /home/roko/Documents/Projects/Adjacent/hy3/scripts/pull_hy3_gguf.sh 0
fi

/home/roko/Documents/Projects/Adjacent/hy3/scripts/generate_hy3_llama_service.sh "$SERVICE_NAME" "$PORT" "$HOST" "$MODEL_PATH"

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME.service"

echo "Waiting for endpoint on http://${HOST}:${PORT}/v1/models"
for i in $(seq 1 30); do
  if curl -sS --max-time 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "hy3 llama endpoint up: http://${HOST}:${PORT}/v1/models"
    curl -sS "http://${HOST}:${PORT}/v1/models" | sed 's/\\n/ /g' | cut -c 1-360
    echo
    exit 0
  fi
  sleep 1
done


echo "ERROR: llama endpoint did not become ready in 30s"
systemctl --user status "$SERVICE_NAME.service" --no-pager --full | sed -n '1,80p'
exit 1
