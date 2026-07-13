#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${HY3_CONFIG_FILE:-${SCRIPT_DIR}/configs/hy3-a100-hybrid.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

SERVICE_NAME="${1:-hy3-llama-isolated}"
PORT="${2:-${PORT:-11453}}"
HOST="${3:-${HOST:-127.0.0.1}}"
MODEL_PATH="${4:-${MODEL_PATH:-/srv/hy3/hy3-1M-Q2_K.gguf}}"
LLAMA_SERVER_BIN="${5:-${LLAMA_SERVER_BIN:-/home/roko/Documents/Projects/Adjacent/llama.cpp/build/bin/llama-server}}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: model file missing: $MODEL_PATH"
  exit 1
fi
if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server binary not executable: $LLAMA_SERVER_BIN"
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not available"
  exit 1
fi

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
LOG_FILE="${LOG_FILE:-${HOME}/.config/hy3/${SERVICE_NAME}.log}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2}"
CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES:-0,1,2}"
REQUIRE_GPU_COUNT="${REQUIRE_GPU_COUNT:-3}"
HY3_IDLE_TIMEOUT_SEC="${HY3_IDLE_TIMEOUT_SEC:-300}"
HY3_LOAD_TIMEOUT_SEC="${HY3_LOAD_TIMEOUT_SEC:-600}"
HY3_STOP_TIMEOUT_SEC="${HY3_STOP_TIMEOUT_SEC:-300}"
HY3_BACKEND_PORT="${HY3_BACKEND_PORT:-$((PORT + 1))}"

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
  exit 1
fi

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hy3"
mkdir -p "$UNIT_DIR" "$CONFIG_DIR"

UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
ENV_FILE="${CONFIG_DIR}/${SERVICE_NAME}-llama.env"

cat > "$ENV_FILE" <<EOF2
HY3_CONFIG_FILE=${CONFIG_FILE}
MODEL_PATH=${MODEL_PATH}
HOST=${HOST}
PORT=${PORT}
LLAMA_SERVER_BIN=${LLAMA_SERVER_BIN}
CTX_SIZE=${CTX_SIZE}
N_GPU_LAYERS=${N_GPU_LAYERS}
SPLIT_MODE=${SPLIT_MODE}
TENSOR_SPLIT=${TENSOR_SPLIT}
GPU_DEVICES=${GPU_DEVICES}
MAIN_GPU=${MAIN_GPU}
THREADS=${THREADS}
BATCH_SIZE=${BATCH_SIZE}
UBATCH_SIZE=${UBATCH_SIZE}
PARALLEL=${PARALLEL}
THREADS_BATCH=${THREADS_BATCH}
POLL_BATCH=${POLL_BATCH}
CONT_BATCHING=${CONT_BATCHING}
FLASH_ATTN=${FLASH_ATTN}
CACHE_TYPE_K=${CACHE_TYPE_K}
CACHE_TYPE_V=${CACHE_TYPE_V}
KV_OFFLOAD=${KV_OFFLOAD}
FIT=${FIT}
CPU_MOE=${CPU_MOE}
N_CPU_MOE=${N_CPU_MOE}
PERF=${PERF}
METRICS=${METRICS}
WARMUP=${WARMUP}
NO_CONTEXT_SHIFT=${NO_CONTEXT_SHIFT}
JINJA=${JINJA}
CHAT_TEMPLATE_FILE=${CHAT_TEMPLATE_FILE}
SPEC_TYPE=${SPEC_TYPE}
SPEC_DRAFT_N_MAX=${SPEC_DRAFT_N_MAX}
SPEC_DRAFT_P_MIN=${SPEC_DRAFT_P_MIN}
LOG_VERBOSITY=${LOG_VERBOSITY}
LOG_FILE=${LOG_FILE}
REQUIRE_GPU_COUNT=${REQUIRE_GPU_COUNT}
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}
CUDA_DEVICE_ORDER=${CUDA_DEVICE_ORDER}
NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES}
HY3_IDLE_TIMEOUT_SEC=${HY3_IDLE_TIMEOUT_SEC}
HY3_LOAD_TIMEOUT_SEC=${HY3_LOAD_TIMEOUT_SEC}
HY3_STOP_TIMEOUT_SEC=${HY3_STOP_TIMEOUT_SEC}
HY3_BACKEND_PORT=${HY3_BACKEND_PORT}
EOF2

cat > "$UNIT_FILE" <<EOF3
[Unit]
Description=Hy3 isolated llama-server endpoint (${SERVICE_NAME})
StartLimitIntervalSec=60
StartLimitBurst=5
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/scripts/hy3_on_demand_proxy.py
Restart=on-failure
RestartSec=5
TimeoutStartSec=infinity
TimeoutStopSec=300
KillSignal=SIGINT
KillMode=process
OOMPolicy=stop
LimitNOFILE=65535
TasksMax=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF3

systemctl --user daemon-reload

echo "Generated llama-server service: ${UNIT_FILE}"
echo "Generated env file: ${ENV_FILE}"
echo "Start with: systemctl --user enable --now ${SERVICE_NAME}.service"
