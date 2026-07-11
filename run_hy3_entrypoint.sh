#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="/home/roko/Documents/Projects/Adjacent/hy3"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-/home/roko/Documents/Projects/Adjacent/llama.cpp/build/bin/llama-server}"
MODEL_PATH="${MODEL_PATH:-/srv/hy3/hy3-1M-Q2_K.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-11450}"
CTX_SIZE="${CTX_SIZE:-262000}"
N_GPU_LAYERS="${N_GPU_LAYERS:-81}"
SPLIT_MODE="${SPLIT_MODE:-layer}"
TENSOR_SPLIT="${TENSOR_SPLIT:-1,1,1}"
GPU_DEVICES="${GPU_DEVICES:-CUDA0,CUDA1,CUDA2}"
MAIN_GPU="${MAIN_GPU:-0}"
THREADS="${THREADS:-32}"
BATCH_SIZE="${BATCH_SIZE:-512}"
UBATCH_SIZE="${UBATCH_SIZE:-256}"
PARALLEL="${PARALLEL:-8}"
THREADS_BATCH="${THREADS_BATCH:-32}"
POLL_BATCH="${POLL_BATCH:-1}"
CONT_BATCHING="${CONT_BATCHING:-1}"
LOG_VERBOSITY="${LOG_VERBOSITY:-2}"
CPU_MOE="${CPU_MOE:-0}"
FIT="${FIT:-off}"
LOG_FILE="${LOG_FILE:-/tmp/hy3-llama-server.log}"
PID_FILE="${PID_FILE:-/tmp/hy3-llama-server.pid}"
STDERR_FILE="${STDERR_FILE:-/tmp/hy3-llama-server.err}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-${GPU_DEVICES}}"
CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES:-all}"
export CUDA_VISIBLE_DEVICES CUDA_DEVICE_ORDER NVIDIA_VISIBLE_DEVICES

normalize_device_list() {
  local raw="$1"
  IFS=',' read -r -a parts <<< "${raw// /}"
  local out=()
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("CUDA${part}")
    else
      out+=("$part")
    fi
  done
  local IFS=','
  echo "${out[*]}"
}

GPU_DEVICES="$(normalize_device_list "$GPU_DEVICES")"

if [[ "$CUDA_VISIBLE_DEVICES" == "${GPU_DEVICES}" ]]; then
  CUDA_VISIBLE_DEVICES="0,1,2"
fi

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server binary not executable: $LLAMA_SERVER_BIN"
  exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: model not found: $MODEL_PATH"
  exit 1
fi

ACTION="${1:-start}"

server_url() {
  echo "http://$HOST:$PORT"
}

stop_server() {
  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PID_FILE")"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
      echo "Stopping previous server pid=$old_pid"
      kill "$old_pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        if ! kill -0 "$old_pid" >/dev/null 2>&1; then
          break
        fi
        sleep 0.2
      done
      kill -9 "$old_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE"
  fi

  local pids
  pids="$(pgrep -f "${LLAMA_SERVER_BIN}" || true)"
  if [[ -n "$pids" ]]; then
    pkill -f "${LLAMA_SERVER_BIN}" || true
  fi
}

wait_for_server() {
  local deadline="$1"
  local start_ts
  start_ts="$(date +%s)"
  local url
  url="$(server_url)"
  while (( $(date +%s) - start_ts < deadline )); do
    if curl -sS --max-time 2 "$url/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

run_prompt() {
  local label="$1"
  local prompt="$2"
  local max_tokens="$3"
  local url
  url="$(server_url)"
  echo "== ${label} =="

  local safe_prompt
  safe_prompt="${prompt//\\/\\\\}"
  safe_prompt="${safe_prompt//\"/\\\"}"
  safe_prompt="${safe_prompt//$'\n'/\\n}"

  curl -sS -X POST "$url/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_PATH\",\"prompt\":\"${safe_prompt}\",\"max_tokens\":$max_tokens,\"temperature\":0.2}" |
    sed -n '1,8p'
}

start_server() {
  stop_server

  echo "Starting llama-server at $HOST:$PORT"
  echo "  model: $MODEL_PATH"
    echo "  devices: $GPU_DEVICES"
    echo "  main-gpu: $MAIN_GPU"
    echo "  ctx-size: $CTX_SIZE"
    echo "  split-mode: $SPLIT_MODE"
    echo "  tensor-split: $TENSOR_SPLIT"
    echo "  parallel slots: $PARALLEL"
    echo "  cont-batching: $CONT_BATCHING"
    echo "  threads-batch: $THREADS_BATCH"
    echo "  poll-batch: $POLL_BATCH"
    echo "  n-gpu-layers: $N_GPU_LAYERS"

  mkdir -p "$(dirname "$LOG_FILE")"

  nohup "$LLAMA_SERVER_BIN" \
    --log-file "$LOG_FILE" \
    --log-verbosity "$LOG_VERBOSITY" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_PATH" \
    --ctx-size "$CTX_SIZE" \
    --n-gpu-layers "$N_GPU_LAYERS" \
    --split-mode "$SPLIT_MODE" \
    --tensor-split "$TENSOR_SPLIT" \
    --device "$GPU_DEVICES" \
    --main-gpu "$MAIN_GPU" \
    --threads "$THREADS" \
    --batch-size "$BATCH_SIZE" \
    --ubatch-size "$UBATCH_SIZE" \
    --parallel "$PARALLEL" \
    --threads-batch "$THREADS_BATCH" \
    --poll-batch "$POLL_BATCH" \
    --cache-type-k "${CACHE_TYPE_K:-q8_0}" \
    --cache-type-v "${CACHE_TYPE_V:-q8_0}" \
    --fit "$FIT" \
    $( [[ "$CONT_BATCHING" == "1" ]] && echo --cont-batching || echo --no-cont-batching ) \
    $( [[ "$CPU_MOE" == "1" ]] && echo --cpu-moe ) \
    >"$LOG_FILE" 2>"$STDERR_FILE" &

  pid=$!
  echo "$pid" > "$PID_FILE"

  if wait_for_server 30; then
    echo "Server ready: $(server_url)"
  else
    echo "Server failed to come up in 30s"
    echo "--- $LOG_FILE (tail) ---"
    tail -n 80 "$LOG_FILE" || true
    exit 1
  fi
}

status_server() {
  local url
  url="$(server_url)"
  if curl -sS --max-time 2 "$url/v1/models" >/dev/null 2>&1; then
    echo "hy3-server is up: $url"
    return 0
  else
    echo "hy3-server is not responding at $url"
    return 1
  fi
}

case "$ACTION" in
  start)
    start_server
    ;;
  test)
    if ! status_server; then
      start_server
    fi
    run_prompt "math" "What is 7 * 8?" 16
    run_prompt "code" "Write a one-line JSON object with field msg saying hello" 40
    run_prompt "story" "Write one sentence about a robot and a coder" 40
    ;;
  start-and-test)
    start_server
    run_prompt "math" "What is 7 * 8?" 16
    run_prompt "code" "Write a one-line JSON object with field msg saying hello" 40
    run_prompt "story" "Write one sentence about a robot and a coder" 40
    ;;
  stop)
    stop_server
    echo "Stopped"
    ;;
  status)
    status_server
    ;;
  restart)
    start_server
    ;;
  *)
    echo "Usage: $(basename "$0") [start|stop|status|test|restart]"
    echo "       $(basename "$0") start-and-test"
    echo "Env overrides: LLAMA_SERVER_BIN MODEL_PATH HOST PORT CTX_SIZE N_GPU_LAYERS SPLIT_MODE TENSOR_SPLIT GPU_DEVICES MAIN_GPU THREADS BATCH_SIZE UBATCH_SIZE PARALLEL THREADS_BATCH POLL_BATCH CONT_BATCHING CPU_MOE"
    exit 1
    ;;
esac
