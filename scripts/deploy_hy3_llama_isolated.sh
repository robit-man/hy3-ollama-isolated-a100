#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SERVICE_NAME="${HY3_SERVICE_NAME:-hy3-llama-isolated}"
PORT="${HY3_PORT:-11453}"
HOST="${HY3_HOST:-127.0.0.1}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
HF_CLASS="${HY3_CLASS:-Q2_K}"
HF_FILENAME="${HY3_FILENAME:-hy3-1M-${HF_CLASS}.gguf}"
MODEL_PATH="${HY3_MODEL_PATH:-${MODELS_DIR}/${HF_FILENAME}}"
READY_TIMEOUT_SEC="${HY3_READY_TIMEOUT_SEC:-180}"
RUN_SMOKE="${HY3_RUN_SMOKE:-1}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Model file not found locally. Pulling ${HF_CLASS} first."
  HF_CLASS="$HF_CLASS" HY3_MODELS_DIR="$MODELS_DIR" HY3_FILENAME="$HF_FILENAME" \
    "${SCRIPT_DIR}/pull_hy3_gguf.sh" 0
fi

HY3_SERVICE_NAME="$SERVICE_NAME" \
  CTX_SIZE="${CTX_SIZE:-262000}" \
  PORT="$PORT" HOST="$HOST" MODEL_PATH="$MODEL_PATH" \
  "${SCRIPT_DIR}/generate_hy3_llama_service.sh" "$SERVICE_NAME" "$PORT" "$HOST" "$MODEL_PATH"

systemctl --user enable "$SERVICE_NAME.service" >/dev/null
systemctl --user restart "$SERVICE_NAME.service"

echo "Waiting for endpoint on http://${HOST}:${PORT}/health"
for _ in $(seq 1 "$READY_TIMEOUT_SEC"); do
  if curl -fsS --max-time 2 "http://${HOST}:${PORT}/health" >/dev/null 2>&1 &&
     curl -fsS --max-time 2 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "Hy3 llama endpoint up: http://${HOST}:${PORT}"
    curl -fsS "http://${HOST}:${PORT}/v1/models" | cut -c 1-600
    echo
    if [[ "$RUN_SMOKE" == "1" ]]; then
      HY3_ENDPOINT_URL="http://${HOST}:${PORT}" \
        HY3_MODEL="$MODEL_PATH" \
        HY3_EXPECTED_CTX="${CTX_SIZE:-262000}" \
        "${SCRIPT_DIR}/test_hy3_endpoint.sh"
    fi
    exit 0
  fi
  sleep 1
done

echo "ERROR: llama endpoint did not become ready in ${READY_TIMEOUT_SEC}s"
systemctl --user status "$SERVICE_NAME.service" --no-pager --full | sed -n '1,100p'
journalctl --user -u "$SERVICE_NAME.service" -n 120 --no-pager
exit 1
