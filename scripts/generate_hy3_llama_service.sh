#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-hy3-llama-isolated}"
PORT="${2:-11453}"
HOST="${3:-127.0.0.1}"
MODEL_PATH="${4:-/srv/hy3/hy3-1M-Q2_K.gguf}"

if [[ -z "${MODEL_PATH}" || ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: model file missing: $MODEL_PATH"
  exit 1
fi

LLAMA_SERVER_BIN="${5:-/home/roko/Documents/Projects/Adjacent/llama.cpp/build/bin/llama-server}"
if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server binary not executable: $LLAMA_SERVER_BIN"
  exit 1
fi

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
FIT="${FIT:-off}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
LOG_VERBOSITY="${LOG_VERBOSITY:-2}"
LOG_FILE="${LOG_FILE:-$HOME/.config/hy3/${SERVICE_NAME}.log}"
CPU_MOE="${CPU_MOE:-0}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2}"

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hy3"
mkdir -p "$UNIT_DIR" "$CONFIG_DIR"

UNIT_FILE="$UNIT_DIR/${SERVICE_NAME}.service"
ENV_FILE="$CONFIG_DIR/${SERVICE_NAME}-llama.env"

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

cat > "$ENV_FILE" <<EOF2
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
FIT=${FIT}
LOG_VERBOSITY=${LOG_VERBOSITY}
CACHE_TYPE_K=${CACHE_TYPE_K}
CACHE_TYPE_V=${CACHE_TYPE_V}
CPU_MOE=${CPU_MOE}
LOG_FILE=${LOG_FILE}
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}
NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-all}
CUDA_DEVICE_ORDER=${CUDA_DEVICE_ORDER:-PCI_BUS_ID}
EOF2

START_CMD="${LLAMA_SERVER_BIN} --log-file ${LOG_FILE} --log-verbosity ${LOG_VERBOSITY} --host ${HOST} --port ${PORT} --model ${MODEL_PATH} --ctx-size ${CTX_SIZE} --n-gpu-layers ${N_GPU_LAYERS} --split-mode ${SPLIT_MODE} --tensor-split ${TENSOR_SPLIT} --device ${GPU_DEVICES} --main-gpu ${MAIN_GPU} --threads ${THREADS} --batch-size ${BATCH_SIZE} --ubatch-size ${UBATCH_SIZE} --fit ${FIT} --cache-type-k ${CACHE_TYPE_K} --cache-type-v ${CACHE_TYPE_V} --parallel ${PARALLEL} --threads-batch ${THREADS_BATCH} --poll-batch ${POLL_BATCH}"
if [[ "$CONT_BATCHING" == "1" ]]; then
  START_CMD+=" --cont-batching"
else
  START_CMD+=" --no-cont-batching"
fi
if [[ "$CPU_MOE" == "1" ]]; then
  START_CMD+=" --cpu-moe"
fi

cat > "$UNIT_FILE" <<EOF3
[Unit]
Description=Hy3 isolated llama-server endpoint (${SERVICE_NAME})
StartLimitIntervalSec=60
StartLimitBurst=10
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/hy3/${SERVICE_NAME}-llama.env
ExecStart=${START_CMD}
Restart=always
RestartSec=2
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF3

systemctl --user daemon-reload

echo "Generated llama-server service: ${UNIT_FILE}"
echo "Generated env file: ${ENV_FILE}"
echo "Start with: systemctl --user enable --now ${SERVICE_NAME}.service"
