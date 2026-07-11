#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HY3_CONFIG_FILE:-${SCRIPT_DIR}/configs/hy3-a100-hybrid.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-/home/roko/Documents/Projects/Adjacent/llama.cpp/build/bin/llama-server}"
MODEL_PATH="${MODEL_PATH:-/srv/hy3/hy3-1M-Q2_K.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-11453}"
CTX_SIZE="${CTX_SIZE:-262000}"
N_GPU_LAYERS="${N_GPU_LAYERS:-all}"
SPLIT_MODE="${SPLIT_MODE:-layer}"
TENSOR_SPLIT="${TENSOR_SPLIT:-1,1,1}"
GPU_DEVICES="${GPU_DEVICES:-CUDA0,CUDA1,CUDA2}"
MAIN_GPU="${MAIN_GPU:-0}"
THREADS="${THREADS:-32}"
BATCH_SIZE="${BATCH_SIZE:-2048}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
PARALLEL="${PARALLEL:-1}"
THREADS_BATCH="${THREADS_BATCH:-32}"
POLL_BATCH="${POLL_BATCH:-0}"
CONT_BATCHING="${CONT_BATCHING:-0}"
FLASH_ATTN="${FLASH_ATTN:-on}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
KV_OFFLOAD="${KV_OFFLOAD:-1}"
FIT="${FIT:-off}"
CPU_MOE="${CPU_MOE:-0}"
N_CPU_MOE="${N_CPU_MOE:-0}"
PERF="${PERF:-1}"
METRICS="${METRICS:-1}"
WARMUP="${WARMUP:-1}"
NO_CONTEXT_SHIFT="${NO_CONTEXT_SHIFT:-1}"
JINJA="${JINJA:-1}"
CHAT_TEMPLATE_FILE="${CHAT_TEMPLATE_FILE:-}"
SPEC_TYPE="${SPEC_TYPE:-none}"
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-3}"
SPEC_DRAFT_P_MIN="${SPEC_DRAFT_P_MIN:-0.75}"
LOG_VERBOSITY="${LOG_VERBOSITY:-2}"
LOG_FILE="${LOG_FILE:-${HOME}/.config/hy3/hy3-llama-${PORT}.log}"
REQUIRE_GPU_COUNT="${REQUIRE_GPU_COUNT:-3}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2}"
CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES:-0,1,2}"
PID_FILE="${PID_FILE:-${XDG_RUNTIME_DIR:-/tmp}/hy3-llama-server-${PORT}.pid}"
STDERR_FILE="${STDERR_FILE:-${LOG_FILE}.stderr}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-180}"
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-600}"

normalize_device_list() {
  local raw="$1"
  IFS=',' read -r -a parts <<< "${raw// /}"
  local out=()
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("CUDA${part}")
    elif [[ -n "$part" ]]; then
      out+=("$part")
    fi
  done
  local IFS=','
  echo "${out[*]}"
}

GPU_DEVICES="$(normalize_device_list "$GPU_DEVICES")"
GPU_COUNT="$(awk -F',' '{print NF}' <<< "$GPU_DEVICES")"

if [[ "$REQUIRE_GPU_COUNT" =~ ^[0-9]+$ ]] && (( GPU_COUNT < REQUIRE_GPU_COUNT )); then
  echo "ERROR: ${GPU_COUNT} CUDA devices configured; ${REQUIRE_GPU_COUNT} required."
  echo "GPU_DEVICES=${GPU_DEVICES} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
  exit 1
fi

export CUDA_VISIBLE_DEVICES CUDA_DEVICE_ORDER NVIDIA_VISIBLE_DEVICES

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
  echo "http://${HOST}:${PORT}"
}

build_server_args() {
  SERVER_ARGS=(
    "$LLAMA_SERVER_BIN"
    --log-file "$LOG_FILE"
    --log-verbosity "$LOG_VERBOSITY"
    --host "$HOST"
    --port "$PORT"
    --model "$MODEL_PATH"
    --ctx-size "$CTX_SIZE"
    --n-gpu-layers "$N_GPU_LAYERS"
    --split-mode "$SPLIT_MODE"
    --tensor-split "$TENSOR_SPLIT"
    --device "$GPU_DEVICES"
    --main-gpu "$MAIN_GPU"
    --threads "$THREADS"
    --batch-size "$BATCH_SIZE"
    --ubatch-size "$UBATCH_SIZE"
    --parallel "$PARALLEL"
    --threads-batch "$THREADS_BATCH"
    --poll-batch "$POLL_BATCH"
    --fit "$FIT"
    --flash-attn "$FLASH_ATTN"
    --cache-type-k "$CACHE_TYPE_K"
    --cache-type-v "$CACHE_TYPE_V"
  )

  if [[ "$CONT_BATCHING" == "1" ]]; then
    SERVER_ARGS+=(--cont-batching)
  else
    SERVER_ARGS+=(--no-cont-batching)
  fi
  if [[ "$KV_OFFLOAD" == "1" ]]; then
    SERVER_ARGS+=(--kv-offload)
  else
    SERVER_ARGS+=(--no-kv-offload)
  fi
  if [[ "$CPU_MOE" == "1" ]]; then
    SERVER_ARGS+=(--cpu-moe)
  elif [[ "$N_CPU_MOE" =~ ^[1-9][0-9]*$ ]]; then
    SERVER_ARGS+=(--n-cpu-moe "$N_CPU_MOE")
  fi
  if [[ "$PERF" == "1" ]]; then
    SERVER_ARGS+=(--perf)
  else
    SERVER_ARGS+=(--no-perf)
  fi
  if [[ "$METRICS" == "1" ]]; then
    SERVER_ARGS+=(--metrics)
  fi
  if [[ "$WARMUP" == "1" ]]; then
    SERVER_ARGS+=(--warmup)
  else
    SERVER_ARGS+=(--no-warmup)
  fi
  if [[ "$NO_CONTEXT_SHIFT" == "1" ]]; then
    SERVER_ARGS+=(--no-context-shift)
  fi
  if [[ "$JINJA" == "1" ]]; then
    SERVER_ARGS+=(--jinja)
  else
    SERVER_ARGS+=(--no-jinja)
  fi
  if [[ -n "$CHAT_TEMPLATE_FILE" ]]; then
    SERVER_ARGS+=(--chat-template-file "$CHAT_TEMPLATE_FILE")
  fi
  if [[ "$SPEC_TYPE" != "none" ]]; then
    SERVER_ARGS+=(
      --spec-type "$SPEC_TYPE"
      --spec-draft-n-max "$SPEC_DRAFT_N_MAX"
      --spec-draft-p-min "$SPEC_DRAFT_P_MIN"
    )
  fi
}

wait_for_server() {
  local deadline="$1"
  local start_ts
  start_ts="$(date +%s)"
  local url
  url="$(server_url)"
  while (( $(date +%s) - start_ts < deadline )); do
    if curl -fsS --max-time 2 "${url}/health" >/dev/null 2>&1 &&
       curl -fsS --max-time 2 "${url}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_server() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 0
  fi

  local old_pid
  old_pid="$(<"$PID_FILE")"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "Stopping owned llama-server pid=${old_pid}"
    kill "$old_pid" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      if ! kill -0 "$old_pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    if kill -0 "$old_pid" >/dev/null 2>&1; then
      kill -9 "$old_pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$PID_FILE"
}

print_config() {
  echo "Hy3 llama-server configuration:"
  echo "  endpoint: ${HOST}:${PORT}"
  echo "  model: ${MODEL_PATH}"
  echo "  CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES}"
  echo "  devices: ${GPU_DEVICES}"
  echo "  split: ${SPLIT_MODE} tensor-split=${TENSOR_SPLIT}"
  echo "  gpu layers: ${N_GPU_LAYERS} fit=${FIT} cpu-moe=${CPU_MOE}/${N_CPU_MOE}"
  echo "  context: ${CTX_SIZE} slots=${PARALLEL} cont-batching=${CONT_BATCHING}"
  echo "  flash-attn: ${FLASH_ATTN} KV=${CACHE_TYPE_K}/${CACHE_TYPE_V} offload=${KV_OFFLOAD}"
  echo "  MTP: ${SPEC_TYPE} n-max=${SPEC_DRAFT_N_MAX} p-min=${SPEC_DRAFT_P_MIN}"
}

start_server() {
  stop_server
  build_server_args
  print_config
  mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
  echo "Starting llama-server at $(server_url)"
  nohup "${SERVER_ARGS[@]}" >"$STDERR_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  if wait_for_server "$READY_TIMEOUT_SEC"; then
    echo "Server ready: $(server_url)"
  else
    echo "ERROR: server failed to become ready in ${READY_TIMEOUT_SEC}s"
    tail -n 120 "$LOG_FILE" 2>/dev/null || true
    tail -n 80 "$STDERR_FILE" 2>/dev/null || true
    return 1
  fi
}

run_server_foreground() {
  build_server_args
  print_config
  mkdir -p "$(dirname "$LOG_FILE")"
  exec "${SERVER_ARGS[@]}"
}

status_server() {
  local url
  url="$(server_url)"
  if curl -fsS --max-time 2 "${url}/health" >/dev/null 2>&1; then
    echo "hy3-server is up: ${url}"
    curl -fsS --max-time 2 "${url}/v1/models"
    echo
    return 0
  fi
  echo "hy3-server is not responding at ${url}"
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
  safe_prompt="${safe_prompt//\$'\\n'/\\n}"

  curl -fsS --max-time "$CURL_TIMEOUT_SEC" -X POST "${url}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_PATH}\",\"prompt\":\"${safe_prompt}\",\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}"
  echo
}

case "$ACTION" in
  start)
    start_server
    ;;
  foreground)
    run_server_foreground
    ;;
  test)
    status_server
    run_prompt "math" "What is 7 * 8? Answer with only the number." 16
    run_prompt "code" "Write a one-line JSON object with field msg saying hello." 40
    ;;
  start-and-test)
    start_server
    run_prompt "math" "What is 7 * 8? Answer with only the number." 16
    run_prompt "code" "Write a one-line JSON object with field msg saying hello." 40
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
    echo "Usage: $(basename "$0") [start|foreground|stop|status|test|restart]"
    echo "       $(basename "$0") start-and-test"
    echo "Env overrides: LLAMA_SERVER_BIN MODEL_PATH HOST PORT CTX_SIZE N_GPU_LAYERS SPLIT_MODE TENSOR_SPLIT GPU_DEVICES MAIN_GPU THREADS BATCH_SIZE UBATCH_SIZE PARALLEL THREADS_BATCH POLL_BATCH CONT_BATCHING FLASH_ATTN CACHE_TYPE_K CACHE_TYPE_V KV_OFFLOAD FIT CPU_MOE N_CPU_MOE SPEC_TYPE"
    exit 1
    ;;
esac
