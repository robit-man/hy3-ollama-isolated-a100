#!/usr/bin/env bash
set -euo pipefail

# Deploy and eval a Hy3 GGUF model into /srv/hy3.
# It starts a private ollama serve bound to a private port so OLLAMA_MODELS=/srv/hy3
# is guaranteed for this run.

MODEL_REPO="hf.co/satgeze/Hy3-1M-GGUF"
DEFAULT_MODELS_DIR="/srv/hy3"
EVAL_PROMPT="Give a one sentence explanation of what a language model is."
OLLAMA_PORT=11450
OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}"

declare -A MODEL_BYTES=(
  [IQ2_M]=96019311104
  [MTP-IQ2_M]=100008834592
  [MTP-Q3_XXS]=117335832096
  [MTP-Q2_K]=111376119328
  [MTP-Q3_K_M]=144948000288
  [MTP-Q4_K_M]=182560831008
  [MTP-Q5_K_M]=213423044128
  [MTP-Q6_K]=246214145568
  [Q2_K]=107386595616
)

ORDER_BY_QUALITY=(
  IQ2_M
  MTP-IQ2_M
  MTP-Q3_XXS
  MTP-Q2_K
  MTP-Q3_K_M
  MTP-Q4_K_M
  MTP-Q5_K_M
  MTP-Q6_K
  Q2_K
)

get_total_gpu_free_gib() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo 0
    return
  fi
  local free_mib
  free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print int(s)}')
  if [[ -z "${free_mib}" || "${free_mib}" == "0" ]]; then
    echo 0
    return
  fi
  echo $(( free_mib / 1024 ))
}

choose_class() {
  local total_gib="$1"
  local selected=""
  for cls in "${ORDER_BY_QUALITY[@]}"; do
    local bytes="${MODEL_BYTES[$cls]}"
    local required_gib
    required_gib=$(awk -v b="$bytes" 'BEGIN {printf "%0.0f", (b / 1024.0 / 1024.0 / 1024.0) * 1.25}')
    if (( required_gib <= total_gib )); then
      selected="$cls"
    fi
  done
  echo "$selected"
}

wait_for_ollama() {
  local attempts=0
  until curl -s --max-time 2 "http://${OLLAMA_HOST}/api/version" >/dev/null; do
    sleep 1
    attempts=$((attempts+1))
    if (( attempts > 45 )); then
      return 1
    fi
  done
}

usage() {
  cat <<'EOF'
Usage:
  ./deploy_hy3.sh [class|auto] [models_dir]

class:
  One of: IQ2_M, MTP-IQ2_M, MTP-Q3_XXS, MTP-Q2_K, MTP-Q3_K_M, MTP-Q4_K_M, MTP-Q5_K_M, MTP-Q6_K, Q2_K
  or "auto" to select highest-quality class that likely fits available GPU memory.
EOF
}

REQUEST_CLASS="${1:-auto}"
MODELS_DIR="${2:-${DEFAULT_MODELS_DIR}}"

if [[ "$REQUEST_CLASS" == "-h" || "$REQUEST_CLASS" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$REQUEST_CLASS" != "auto" && -z "${MODEL_BYTES[$REQUEST_CLASS]:-}" ]]; then
  echo "Unknown class: $REQUEST_CLASS"
  usage
  exit 1
fi

mkdir -p "$MODELS_DIR"
if [[ ! -w "$MODELS_DIR" ]]; then
  echo "ERROR: cannot write to ${MODELS_DIR}."
  exit 1
fi

if [[ "${REQUEST_CLASS}" == "auto" ]]; then
  GPU_FREE_GIB=$(get_total_gpu_free_gib)
  if (( GPU_FREE_GIB == 0 )); then
    GPU_FREE_GIB=80
    echo "No GPU telemetry available; defaulting to 80 GiB for auto-class selection."
  fi
  REQUEST_CLASS="$(choose_class "$GPU_FREE_GIB")"
fi

if [[ -z "$REQUEST_CLASS" ]]; then
  echo "No model class fits current GPU free-memory estimate."
  exit 1
fi

REQUEST_BYTES="${MODEL_BYTES[$REQUEST_CLASS]}"
REQUEST_GIB=$(awk -v b="$REQUEST_BYTES" 'BEGIN {printf "%0.2f", b / 1024.0 / 1024.0 / 1024.0}')
echo "Selected class: ${REQUEST_CLASS} (${REQUEST_GIB} GiB)"

MODEL="${MODEL_REPO}:${REQUEST_CLASS}"
echo "Model: ${MODEL}"
echo "Serving Ollama from: ${MODELS_DIR}"

TMP_LOG=$(mktemp)
cleanup() {
  if [[ -n "${OLLAMA_PID:-}" ]] && ps -p "${OLLAMA_PID}" >/dev/null 2>&1; then
    kill "${OLLAMA_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

export OLLAMA_MODELS="$MODELS_DIR"
export OLLAMA_HOST="$OLLAMA_HOST"

echo "Starting dedicated ollama serve on ${OLLAMA_HOST}"
OLLAMA_ORIG_HOST="${OLLAMA_HOST}"
ollama serve >"${TMP_LOG}" 2>&1 &
OLLAMA_PID=$!

if ! wait_for_ollama; then
  echo "Failed to start ollama serve on ${OLLAMA_HOST}"
  cat "${TMP_LOG}"
  exit 1
fi

echo "Pulling ${MODEL} ..."
if ! OLLAMA_HOST="${OLLAMA_HOST}" ollama pull "${MODEL}"; then
  echo "Pull failed for ${MODEL}"
  echo "Tip: check network access and model class availability."
  exit 1
fi

echo "Running eval prompt:"
echo "$EVAL_PROMPT"
OLLAMA_HOST="${OLLAMA_HOST}" ollama run "${MODEL}" "$EVAL_PROMPT" | head -n 20

echo "Done. Model is available at OLLAMA_MODELS=${MODELS_DIR} via ${OLLAMA_HOST}"
