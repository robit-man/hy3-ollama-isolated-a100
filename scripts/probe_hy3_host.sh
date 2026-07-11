#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${HY3_PROBE_OUT_DIR:-${HY3_CAPABILITY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hy3}}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
MIN_A100_COUNT="${HY3_PROBE_MIN_A100_COUNT:-3}"
STRICT="${HY3_PROBE_STRICT:-0}"

mkdir -p "$OUT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is required"
command -v df >/dev/null 2>&1 || die "df is required"

GPU_CSV="$(mktemp)"
trap 'rm -f "$GPU_CSV"' EXIT
nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.free,compute_cap \
  --format=csv,noheader,nounits > "$GPU_CSV" ||
  die "nvidia-smi could not query GPU capabilities"

A100_IDS=()
A100_NAMES=()
A100_TOTAL_MIB=()
A100_FREE_MIB=()
TOTAL_GPU_COUNT=0
DRIVER_VERSION=""

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

while IFS=',' read -r index name driver total free compute_cap; do
  [[ -n "${index:-}" ]] || continue
  index="$(trim "$index")"
  name="$(trim "$name")"
  driver="$(trim "$driver")"
  total="$(trim "$total")"
  free="$(trim "$free")"
  compute_cap="$(trim "$compute_cap")"
  TOTAL_GPU_COUNT=$((TOTAL_GPU_COUNT + 1))
  [[ -z "$DRIVER_VERSION" ]] && DRIVER_VERSION="$driver"
  if [[ "$name" == *A100* ]]; then
    A100_IDS+=("$index")
    A100_NAMES+=("$name")
    A100_TOTAL_MIB+=("$total")
    A100_FREE_MIB+=("$free")
  fi
done < "$GPU_CSV"

join_csv() { local IFS=','; printf '%s' "$*"; }
A100_ID_LIST="$(join_csv "${A100_IDS[@]}")"
A100_NAME_LIST="$(join_csv "${A100_NAMES[@]}")"
A100_TOTAL_LIST="$(join_csv "${A100_TOTAL_MIB[@]}")"
A100_FREE_LIST="$(join_csv "${A100_FREE_MIB[@]}")"
A100_COUNT="${#A100_IDS[@]}"

OS_ID=""
OS_VERSION_ID=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
fi

CUDA_VERSION=""
if command -v nvcc >/dev/null 2>&1; then
  CUDA_VERSION="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([^,]*\).*/\1/p' | tail -n 1)"
fi

NCCL_LIBRARY=""
NCCL_HEADER=""
if command -v ldconfig >/dev/null 2>&1; then
  NCCL_LIBRARY="$(ldconfig -p 2>/dev/null | awk '/libnccl\.so/{print $NF; exit}')"
fi
for candidate in /usr/include/nccl.h /usr/include/x86_64-linux-gnu/nccl.h \
  /usr/local/cuda/include/nccl.h /usr/local/cuda-*/include/nccl.h; do
  if [[ -f "$candidate" ]]; then NCCL_HEADER="$candidate"; break; fi
done
NCCL_AVAILABLE=0
[[ -n "$NCCL_LIBRARY" && -n "$NCCL_HEADER" ]] && NCCL_AVAILABLE=1

SYSTEMD_USER_STATE="unavailable"
if command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_USER_STATE="$(systemctl --user is-system-running 2>/dev/null || true)"
  [[ -n "$SYSTEMD_USER_STATE" ]] || SYSTEMD_USER_STATE="unavailable"
fi
LINGER="unknown"
if command -v loginctl >/dev/null 2>&1; then
  LINGER="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  [[ -n "$LINGER" ]] || LINGER="unknown"
fi

MODEL_ROOT="$(readlink -f "$MODELS_DIR" 2>/dev/null || printf '%s' "$MODELS_DIR")"
if [[ -d "$MODEL_ROOT" ]]; then
  MODEL_FREE_KIB="$(df -Pk "$MODEL_ROOT" | awk 'NR == 2 {print $4}')"
else
  MODEL_FREE_KIB=""
fi

TOPOLOGY_FILE="$OUT_DIR/nvidia-topology.txt"
nvidia-smi topo -m > "$TOPOLOGY_FILE" 2>&1 || warn "could not collect GPU topology"
CAPTURED_AT="$(date -u +%FT%TZ)"
CAPABILITIES_ENV="$OUT_DIR/capabilities.env"

cat > "$CAPABILITIES_ENV" <<EOF2
CAPTURED_AT=$CAPTURED_AT
HOST_USER=$USER
HOST_OS_ID=$OS_ID
HOST_OS_VERSION_ID=$OS_VERSION_ID
HOST_ARCH=$(uname -m)
DRIVER_VERSION=$DRIVER_VERSION
CUDA_VERSION=$CUDA_VERSION
TOTAL_GPU_COUNT=$TOTAL_GPU_COUNT
A100_COUNT=$A100_COUNT
A100_IDS=$A100_ID_LIST
A100_NAMES=$(printf '%q' "$A100_NAME_LIST")
A100_TOTAL_MIB=$A100_TOTAL_LIST
A100_FREE_MIB=$A100_FREE_LIST
NCCL_AVAILABLE=$NCCL_AVAILABLE
NCCL_LIBRARY=$NCCL_LIBRARY
NCCL_HEADER=$NCCL_HEADER
SYSTEMD_USER_STATE=$SYSTEMD_USER_STATE
USER_LINGER=$LINGER
MODEL_DIR=$MODELS_DIR
MODEL_ROOT=$MODEL_ROOT
MODEL_FREE_KIB=$MODEL_FREE_KIB
TOPOLOGY_FILE=$TOPOLOGY_FILE
EOF2

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg captured_at "$CAPTURED_AT" --arg user "$USER" \
    --arg os "$OS_ID" --arg os_version "$OS_VERSION_ID" \
    --arg arch "$(uname -m)" --arg driver "$DRIVER_VERSION" \
    --arg cuda "$CUDA_VERSION" --arg a100_ids "$A100_ID_LIST" \
    --arg a100_names "$A100_NAME_LIST" --arg nccl_library "$NCCL_LIBRARY" \
    --arg nccl_header "$NCCL_HEADER" --arg systemd "$SYSTEMD_USER_STATE" \
    --arg linger "$LINGER" --arg model_dir "$MODELS_DIR" \
    --arg model_root "$MODEL_ROOT" --arg topology "$TOPOLOGY_FILE" \
    --argjson total_gpu_count "$TOTAL_GPU_COUNT" \
    --argjson a100_count "$A100_COUNT" \
    --argjson nccl_available "$NCCL_AVAILABLE" \
    '{
      captured_at: $captured_at, user: $user,
      os: {id: $os, version_id: $os_version, arch: $arch},
      cuda: {driver: $driver, toolkit: $cuda},
      gpus: {total: $total_gpu_count, a100_count: $a100_count,
        a100_ids: $a100_ids, a100_names: $a100_names},
      nccl: {available: ($nccl_available == 1), library: $nccl_library,
        header: $nccl_header},
      systemd_user: {state: $systemd, linger: $linger},
      model_storage: {requested: $model_dir, resolved: $model_root},
      topology_file: $topology
    }' > "$OUT_DIR/capabilities.json"
fi

CUDA_DISPLAY="$CUDA_VERSION"; A100_DISPLAY="$A100_ID_LIST"; FREE_DISPLAY="$MODEL_FREE_KIB"
[[ -n "$CUDA_DISPLAY" ]] || CUDA_DISPLAY="not found"
[[ -n "$A100_DISPLAY" ]] || A100_DISPLAY="none"
[[ -n "$FREE_DISPLAY" ]] || FREE_DISPLAY="unknown"
NCCL_LABEL="not available"
[[ "$NCCL_AVAILABLE" == "1" ]] && NCCL_LABEL="available"
cat > "$OUT_DIR/capabilities.md" <<EOF3
# Hy3 host capabilities

- Captured: $CAPTURED_AT
- User: $USER
- OS: $OS_ID $OS_VERSION_ID
- Architecture: $(uname -m)
- NVIDIA driver: $DRIVER_VERSION
- CUDA toolkit: $CUDA_DISPLAY
- GPUs: $TOTAL_GPU_COUNT total; $A100_COUNT A100
- A100 ids: $A100_DISPLAY
- NCCL: $NCCL_LABEL
- systemd user state: $SYSTEMD_USER_STATE
- user linger: $LINGER
- model directory: $MODELS_DIR
- resolved model directory: $MODEL_ROOT
- free model filesystem KiB: $FREE_DISPLAY

See nvidia-topology.txt for the complete GPU topology.
EOF3

echo "Host capability probe written to $OUT_DIR"
echo "A100_COUNT=$A100_COUNT A100_IDS=$A100_ID_LIST"
echo "CUDA_VERSION=$CUDA_DISPLAY DRIVER_VERSION=$DRIVER_VERSION"
echo "NCCL_AVAILABLE=$NCCL_AVAILABLE"
echo "SYSTEMD_USER_STATE=$SYSTEMD_USER_STATE USER_LINGER=$LINGER"

if [[ "$STRICT" == "1" ]] && (( A100_COUNT < MIN_A100_COUNT )); then
  die "found $A100_COUNT A100 GPUs; need at least $MIN_A100_COUNT"
fi
