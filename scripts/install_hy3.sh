#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${HY3_CAPABILITY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hy3}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
MODEL_CLASS="${HY3_CLASS:-auto}"
TIER="${HY3_TIER:-auto}"
QUALIFICATION_POLICY="${HY3_QUALIFICATION:-auto}"
UPGRADE="${HY3_UPGRADE:-0}"
MTP_POLICY="${HY3_MTP:-auto}"
HF_REPO="${HF_REPO:-satgeze/Hy3-1M-GGUF}"
SERVICE_NAME="${HY3_SERVICE_NAME:-hy3-llama-live}"
HOST="${HY3_HOST:-127.0.0.1}"
PORT="${HY3_PORT:-11453}"
CTX_SIZE="${HY3_CTX_SIZE:-262000}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-${REPO_DIR}/../llama.cpp}"
BUILD_DIR="${LLAMA_BUILD_DIR:-${LLAMA_CPP_DIR}/build}"
REQUIRE_A100_COUNT="${HY3_REQUIRE_A100_COUNT:-3}"
INSTALL_SYSTEM_DEPS="${HY3_INSTALL_SYSTEM_DEPS:-1}"
INSTALL_NCCL="${HY3_INSTALL_NCCL:-0}"
REQUIRE_NCCL="${HY3_REQUIRE_NCCL:-0}"
UPDATE_SOURCE="${HY3_UPDATE_SOURCE:-0}"
SKIP_BUILD=0
SKIP_PULL=0
SKIP_RESTART=0
DRY_RUN=0
ENABLE_LINGER=0
RUN_SMOKE=1
READY_TIMEOUT_SEC="${HY3_READY_TIMEOUT_SEC:-240}"
CUDA_ARCHITECTURES="${HY3_CUDA_ARCHITECTURES:-80}"

usage() {
  cat <<'EOF2'
Usage: scripts/install_hy3.sh [options]

Capability-aware end-to-end installer for the local Hy3 llama.cpp endpoint.

Options:
  --dry-run                 Probe and print the deployment plan only.
  --no-system-packages      Do not install missing apt build dependencies.
  --no-build                Reuse the existing llama.cpp build.
  --no-pull                 Require the model file to already exist.
  --no-restart              Generate the service but do not restart it.
  --no-smoke                Skip the post-deploy API/GPU smoke test.
  --install-nccl            Attempt to install libnccl2/libnccl-dev when apt provides them.
  --require-nccl            Fail unless NCCL headers and libraries are available.
  --update-source           Fetch and fast-forward the custom llama.cpp branch.
  --enable-linger           Enable systemd user lingering for this account.
  --class CLASS             GGUF class or auto, default auto.
  --tier TIER               auto, speed, balanced, or quality, default auto.
  --qualification MODE      auto, full-gpu, or hybrid, default auto.
  --upgrade                 Force auto selection to consider a higher-ranked tier.
  --mtp MODE                auto, on, or off, default auto.
  --hf-repo REPO            Hugging Face GGUF repository, default satgeze/Hy3-1M-GGUF.
  --models-dir PATH         Model directory, default /srv/hy3.
  --service NAME            User systemd service name, default hy3-llama-live.
  --port PORT               Endpoint port, default 11453.
  --context TOKENS          Server context cap, default 262000.
  --llama-cpp-dir PATH      llama.cpp checkout, default ../llama.cpp.
  --help                    Show this help.

The default profile requires three A100 GPUs, uses layer split, all GPU layers,
one request slot, q8 KV, and refuses CPU-MoE/unified-memory fallback.
EOF2
}

log() { printf '[hy3-install] %s\n' "$*"; }
warn() { printf '[hy3-install] WARNING: %s\n' "$*" >&2; }
die() { printf '[hy3-install] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-system-packages) INSTALL_SYSTEM_DEPS=0 ;;
    --no-build) SKIP_BUILD=1 ;;
    --no-pull) SKIP_PULL=1 ;;
    --no-restart) SKIP_RESTART=1 ;;
    --no-smoke) RUN_SMOKE=0 ;;
    --install-nccl) INSTALL_NCCL=1 ;;
    --require-nccl) REQUIRE_NCCL=1 ;;
    --update-source) UPDATE_SOURCE=1 ;;
    --enable-linger) ENABLE_LINGER=1 ;;
    --class) shift; MODEL_CLASS="${1:?missing value for --class}" ;;
    --tier) shift; TIER="${1:?missing value for --tier}" ;;
    --qualification) shift; QUALIFICATION_POLICY="${1:?missing value for --qualification}" ;;
    --upgrade) UPGRADE=1 ;;
    --mtp) shift; MTP_POLICY="${1:?missing value for --mtp}" ;;
    --hf-repo) shift; HF_REPO="${1:?missing value for --hf-repo}" ;;
    --models-dir) shift; MODELS_DIR="${1:?missing value for --models-dir}" ;;
    --service) shift; SERVICE_NAME="${1:?missing value for --service}" ;;
    --port) shift; PORT="${1:?missing value for --port}" ;;
    --context) shift; CTX_SIZE="${1:?missing value for --context}" ;;
    --llama-cpp-dir) shift; LLAMA_CPP_DIR="${1:?missing value for --llama-cpp-dir}"; BUILD_DIR="$LLAMA_CPP_DIR/build" ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
  shift
done

REQUESTED_CLASS="$MODEL_CLASS"
LLAMA_SERVER_BIN="$BUILD_DIR/bin/llama-server"
CAPABILITY_ENV="$STATE_DIR/capabilities.env"

[[ "$(id -u)" -ne 0 ]] || die "run as the target service user, not root"
[[ -n "${XDG_RUNTIME_DIR:-}" ]] || die "XDG_RUNTIME_DIR is not set; run from the target user's login session"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

for command_name in bash awk sed grep stat sha256sum find mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command missing: $command_name"
done
systemctl --user show-environment >/dev/null 2>&1 || die "user systemd is unavailable for $USER"

SYSTEMD_STATE="$(systemctl --user is-system-running 2>/dev/null || true)"
case "$SYSTEMD_STATE" in
  running|degraded) ;;
  *) die "user systemd state is $SYSTEMD_STATE" ;;
esac
[[ "$SYSTEMD_STATE" == "running" ]] || warn "user systemd is degraded; unrelated user units may remain unhealthy"

APT_PACKAGES=(build-essential cmake git curl jq pkg-config libssl-dev ripgrep iproute2)
missing_packages=()
for command_name in cmake git curl jq pkg-config rg ss; do
  command -v "$command_name" >/dev/null 2>&1 || missing_packages+=("$command_name")
done
if (( ${#missing_packages[@]} > 0 )); then
  [[ "$INSTALL_SYSTEM_DEPS" == "1" ]] || die "missing build dependencies: ${missing_packages[*]}"
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required for missing dependencies"
  command -v sudo >/dev/null 2>&1 || die "sudo is required for missing dependencies"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "dry-run would install base packages: ${missing_packages[*]}"
  else
    log "installing missing base packages: ${missing_packages[*]}"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
  fi
fi

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is missing; install a working NVIDIA driver first"
command -v nvcc >/dev/null 2>&1 || die "nvcc is missing; install a compatible CUDA toolkit first"

NCCL_PREAVAILABLE=0
NCCL_LIBRARY_PRE=""
NCCL_HEADER_PRE=""
if command -v ldconfig >/dev/null 2>&1; then
  NCCL_LIBRARY_PRE="$(ldconfig -p 2>/dev/null | awk '/libnccl\.so/{print $NF; exit}')"
fi
for candidate in /usr/include/nccl.h /usr/include/x86_64-linux-gnu/nccl.h \
  /usr/local/cuda/include/nccl.h /usr/local/cuda-*/include/nccl.h; do
  if [[ -f "$candidate" ]]; then NCCL_HEADER_PRE="$candidate"; break; fi
done
[[ -n "$NCCL_LIBRARY_PRE" && -n "$NCCL_HEADER_PRE" ]] && NCCL_PREAVAILABLE=1

if [[ "$INSTALL_NCCL" == "1" || "$REQUIRE_NCCL" == "1" ]] &&
   [[ "$NCCL_PREAVAILABLE" != "1" ]]; then
  if command -v apt-cache >/dev/null 2>&1 &&
     apt-cache show libnccl-dev >/dev/null 2>&1 &&
     command -v sudo >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
      warn "dry-run would install libnccl2 and libnccl-dev"
    else
      log "installing NCCL development packages"
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libnccl2 libnccl-dev
    fi
  else
    warn "apt does not expose libnccl-dev; use the NVIDIA CUDA repository for NCCL"
  fi
elif [[ "$INSTALL_NCCL" == "1" || "$REQUIRE_NCCL" == "1" ]]; then
  log "NCCL already present; no package install needed"
fi

mkdir -p "$STATE_DIR"
log "probing host capabilities"
HY3_PROBE_OUT_DIR="$STATE_DIR" HY3_MODELS_DIR="$MODELS_DIR" \
  HY3_PROBE_MIN_A100_COUNT="$REQUIRE_A100_COUNT" HY3_PROBE_STRICT=0 \
  "$SCRIPT_DIR/probe_hy3_host.sh"

[[ -f "$CAPABILITY_ENV" ]] || die "capability probe did not produce $CAPABILITY_ENV"
# shellcheck disable=SC1090
source "$CAPABILITY_ENV"

if (( A100_COUNT < REQUIRE_A100_COUNT )); then
  die "found $A100_COUNT A100 GPUs ($A100_IDS), need at least $REQUIRE_A100_COUNT"
fi
if [[ "$REQUIRE_NCCL" == "1" && "$NCCL_AVAILABLE" != "1" ]]; then
  die "NCCL was required but headers/library were not detected"
fi

log "resolving Hy3 model profile"
HY3_CAPABILITY_ENV="$CAPABILITY_ENV" HY3_MODELS_DIR="$MODELS_DIR" \
  HY3_CLASS_REQUESTED="$MODEL_CLASS" HY3_TIER="$TIER" \
  HY3_QUALIFICATION="$QUALIFICATION_POLICY" HY3_UPGRADE="$UPGRADE" \
  HY3_MTP="$MTP_POLICY" HY3_CTX_SIZE="$CTX_SIZE" \
  HY3_SERVICE_NAME="$SERVICE_NAME" HF_REPO="$HF_REPO" \
  LLAMA_SERVER_BIN="$LLAMA_SERVER_BIN" \
  "$SCRIPT_DIR/resolve_hy3_profile.sh"
# shellcheck disable=SC1090
source "$STATE_DIR/profile.env"
MODEL_CLASS="$SELECTED_CLASS"
MODEL_FILENAME="$SELECTED_FILENAME"
MODEL_PATH="$MODELS_DIR/$MODEL_FILENAME"

GPU_DEVICES=""
TENSOR_SPLIT=""
for ((i = 0; i < A100_COUNT; i++)); do
  [[ -z "$GPU_DEVICES" ]] && GPU_DEVICES="CUDA$i" || GPU_DEVICES="$GPU_DEVICES,CUDA$i"
  [[ -z "$TENSOR_SPLIT" ]] && TENSOR_SPLIT="1" || TENSOR_SPLIT="$TENSOR_SPLIT,1"
done

MODEL_BYTES="$SELECTED_BYTES"

mkdir -p "$MODELS_DIR" || die "cannot create model directory $MODELS_DIR"
MODEL_ROOT="$(readlink -f "$MODELS_DIR" 2>/dev/null || printf '%s' "$MODELS_DIR")"
FREE_KIB="$(df -Pk "$MODEL_ROOT" | awk 'NR == 2 {print $4}')"
if [[ "$MODEL_BYTES" != "0" ]]; then
  REQUIRED_KIB=$((MODEL_BYTES / 1024 + 10 * 1024 * 1024))
  (( FREE_KIB >= REQUIRED_KIB )) ||
    die "only $FREE_KIB KiB free on $MODEL_ROOT; need at least $REQUIRED_KIB KiB"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run deployment plan:"
  log "  model: $MODEL_PATH"
  log "  requested class/tier: $REQUESTED_CLASS/$TIER"
  log "  selected profile: $SELECTED_CLASS ($SELECTED_QUALIFICATION, mtp=$SELECTED_MTP)"
  log "  qualification reason: $SELECTED_REASON"
  log "  catalog: $CATALOG_SOURCE"
  log "  service: $SERVICE_NAME on $HOST:$PORT"
  log "  A100 ids: $A100_IDS"
  log "  CUDA devices: $GPU_DEVICES"
  log "  split: layer tensor-split=$TENSOR_SPLIT"
  log "  context: $CTX_SIZE slots=1"
  log "  NCCL available: $NCCL_AVAILABLE (required=$REQUIRE_NCCL)"
  log "  build: $([[ "$SKIP_BUILD" == "1" ]] && printf 'reuse' || printf 'build')"
  log "  pull: $([[ "$SKIP_PULL" == "1" ]] && printf 'require existing' || printf 'pull if absent')"
  exit 0
fi

if [[ "$SKIP_PULL" == "1" ]]; then
  [[ -s "$MODEL_PATH" ]] || die "model missing: $MODEL_PATH"
elif [[ -s "$MODEL_PATH" ]]; then
  log "model already present: $MODEL_PATH"
else
  log "pulling $MODEL_CLASS into $MODELS_DIR"
  HF_REPO="$HF_REPO" HY3_MODELS_DIR="$MODELS_DIR" HY3_CLASS="$MODEL_CLASS" HY3_FILENAME="$MODEL_FILENAME" \
    "$SCRIPT_DIR/pull_hy3_gguf.sh" 0
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
  [[ -x "$LLAMA_SERVER_BIN" ]] || die "llama-server missing: $LLAMA_SERVER_BIN"
else
  log "building custom llama.cpp server"
  LLAMA_CPP_DIR="$LLAMA_CPP_DIR" LLAMA_BUILD_DIR="$BUILD_DIR" \
    UPDATE_SOURCE="$UPDATE_SOURCE" REQUIRE_NCCL="$REQUIRE_NCCL" \
    CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
    "$SCRIPT_DIR/build_llama_cpp_hy3.sh"
fi

if command -v ss >/dev/null 2>&1; then
  LISTENER="$(ss -ltnp 2>/dev/null | rg ":$PORT\\b" || true)"
  if [[ -n "$LISTENER" ]] && ! systemctl --user is-active --quiet "$SERVICE_NAME.service"; then
    die "port $PORT is occupied by a non-$SERVICE_NAME process: $LISTENER"
  fi
fi

log "generating systemd user service"
HY3_CONFIG_FILE="$REPO_DIR/configs/hy3-a100-hybrid.env" \
  CUDA_VISIBLE_DEVICES="$A100_IDS" NVIDIA_VISIBLE_DEVICES="$A100_IDS" \
  GPU_DEVICES="$GPU_DEVICES" TENSOR_SPLIT="$TENSOR_SPLIT" \
  CTX_SIZE="$CTX_SIZE" N_GPU_LAYERS="$PROFILE_N_GPU_LAYERS" SPLIT_MODE=layer PARALLEL=1 \
  CONT_BATCHING=0 FIT="$PROFILE_FIT" CPU_MOE=0 FLASH_ATTN=on \
  CACHE_TYPE_K=q8_0 CACHE_TYPE_V=q8_0 SPEC_TYPE="$PROFILE_SPEC_TYPE" \
  REQUIRE_GPU_COUNT="$REQUIRE_A100_COUNT" LOG_FILE="$HOME/.config/hy3/$SERVICE_NAME.log" \
  "$SCRIPT_DIR/generate_hy3_llama_service.sh" \
  "$SERVICE_NAME" "$PORT" "$HOST" "$MODEL_PATH" "$LLAMA_SERVER_BIN"

if [[ "$ENABLE_LINGER" == "1" ]]; then
  command -v loginctl >/dev/null 2>&1 || die "loginctl is required for --enable-linger"
  log "enabling user lingering for $USER"
  sudo loginctl enable-linger "$USER"
fi

if [[ "$SKIP_RESTART" != "1" ]]; then
  log "enabling and restarting $SERVICE_NAME.service"
  systemctl --user enable "$SERVICE_NAME.service" >/dev/null
  systemctl --user restart "$SERVICE_NAME.service"
  healthy=0
  for _ in $(seq 1 "$READY_TIMEOUT_SEC"); do
    if curl -fsS --max-time 2 "http://$HOST:$PORT/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  (( healthy == 1 )) || die "service did not become healthy; inspect journalctl --user -u $SERVICE_NAME.service"
  if [[ "$RUN_SMOKE" == "1" ]]; then
    HY3_ENDPOINT_URL="http://$HOST:$PORT" HY3_MODEL="$MODEL_PATH" \
      HY3_EXPECTED_CTX="$CTX_SIZE" "$SCRIPT_DIR/test_hy3_endpoint.sh"
  fi
else
  log "restart skipped; generated files are ready"
fi

MODEL_SHA256="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"
cat > "$STATE_DIR/install.manifest" <<EOF3
INSTALLED_AT=$(date -u +%FT%TZ)
REPO_DIR=$REPO_DIR
SERVICE_NAME=$SERVICE_NAME
HOST=$HOST
PORT=$PORT
MODEL_CLASS=$MODEL_CLASS
REQUESTED_CLASS=$REQUESTED_CLASS
SELECTED_CLASS=$SELECTED_CLASS
SELECTED_TIER=$SELECTED_TIER
QUALIFICATION=$SELECTED_QUALIFICATION
QUALIFICATION_REASON=$SELECTED_REASON
SELECTED_MTP=$SELECTED_MTP
MODEL_PATH=$MODEL_PATH
MODEL_SHA256=$MODEL_SHA256
CTX_SIZE=$CTX_SIZE
CUDA_VISIBLE_DEVICES=$A100_IDS
GPU_DEVICES=$GPU_DEVICES
TENSOR_SPLIT=$TENSOR_SPLIT
NCCL_AVAILABLE=$NCCL_AVAILABLE
CATALOG_SOURCE=$CATALOG_SOURCE
PROFILE_ENV=$STATE_DIR/profile.env
PROFILE_JSON=$STATE_DIR/profile.json
LLAMA_CPP_DIR=$LLAMA_CPP_DIR
LLAMA_SERVER_BIN=$LLAMA_SERVER_BIN
CAPABILITIES_ENV=$CAPABILITY_ENV
EOF3

log "installation complete"
log "endpoint: http://$HOST:$PORT"
log "manifest: $STATE_DIR/install.manifest"
log "capabilities: $STATE_DIR/capabilities.json"
