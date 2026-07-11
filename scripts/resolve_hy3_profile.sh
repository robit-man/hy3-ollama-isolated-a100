#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HY3_CAPABILITY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hy3}"
CAPABILITY_ENV="${HY3_CAPABILITY_ENV:-$STATE_DIR/capabilities.env}"
MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
REQUESTED_CLASS="${HY3_CLASS_REQUESTED:-auto}"
TIER="${HY3_TIER:-auto}"
QUALIFICATION_POLICY="${HY3_QUALIFICATION:-auto}"
UPGRADE="${HY3_UPGRADE:-0}"
CTX_SIZE="${HY3_CTX_SIZE:-262000}"
SERVICE_NAME="${HY3_SERVICE_NAME:-hy3-llama-live}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$HOME/Documents/Projects/Adjacent/llama.cpp/build/bin/llama-server}"
HF_REPO="${HF_REPO:-satgeze/Hy3-1M-GGUF}"
MTP_POLICY="${HY3_MTP:-auto}"
RESERVE_MIB="${HY3_RESERVE_MIB:-1024}"
KV_Q8_AT_262K_MIB="${HY3_KV_Q8_AT_262K_MIB:-44032}"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

command -v jq >/dev/null 2>&1 || die "jq is required for Hy3 profile resolution"
command -v curl >/dev/null 2>&1 || die "curl is required for Hy3 profile resolution"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is required for Hy3 profile resolution"
[[ -f "$CAPABILITY_ENV" ]] || die "capability inventory missing: $CAPABILITY_ENV"
# shellcheck disable=SC1090
source "$CAPABILITY_ENV"

[[ "$REQUESTED_CLASS" == auto || "$REQUESTED_CLASS" =~ ^(IQ2_M|Q2_K|MTP-IQ2_M|MTP-IQ3_XXS|MTP-Q2_K|MTP-Q3_K_M|MTP-Q4_K_M|MTP-Q5_K_M|MTP-Q6_K)$ ]] ||
  die "unsupported Hy3 class: $REQUESTED_CLASS"
case "$TIER" in speed|balanced|quality|auto) ;; *) die "unsupported tier: $TIER" ;; esac
case "$QUALIFICATION_POLICY" in auto|full-gpu|hybrid) ;; *) die "unsupported qualification: $QUALIFICATION_POLICY" ;; esac
case "$MTP_POLICY" in auto|on|off) ;; *) die "unsupported MTP policy: $MTP_POLICY" ;; esac

CATALOG_JSON="$(mktemp)"
trap 'rm -f "$CATALOG_JSON"' EXIT
REMOTE_SOURCE="hf-api"
if ! curl -fsSL --retry 2 --connect-timeout 10 \
  "https://huggingface.co/api/models/$HF_REPO/tree/main?recursive=false" > "$CATALOG_JSON"; then
  REMOTE_SOURCE="fallback-catalog"
  cat > "$CATALOG_JSON" <<'EOF2'
[
  {"path":"hy3-1M-IQ2_M.gguf","size":96019311104},
  {"path":"hy3-1M-MTP-IQ2_M.gguf","size":100008834592},
  {"path":"hy3-1M-MTP-IQ3_XXS.gguf","size":117335832096},
  {"path":"hy3-1M-MTP-Q2_K.gguf","size":111376119328},
  {"path":"hy3-1M-MTP-Q3_K_M.gguf","size":144948000288},
  {"path":"hy3-1M-MTP-Q4_K_M.gguf","size":182560831008},
  {"path":"hy3-1M-MTP-Q5_K_M.gguf","size":213423044128},
  {"path":"hy3-1M-MTP-Q6_K.gguf","size":246214145568},
  {"path":"hy3-1M-Q2_K.gguf","size":107386595616}
]
EOF2
fi
CATALOG_SOURCE="$REMOTE_SOURCE"

declare -A BYTES
while IFS=$'\t' read -r path bytes; do
  [[ -n "$path" ]] || continue
  class="$path"
  class="${class#hy3-1M-}"
  class="${class%.gguf}"
  BYTES["$class"]="$bytes"
done < <(jq -r '.[] | select(.path | test("^hy3-1M-.*\\.gguf$")) | [.path,.size] | @tsv' "$CATALOG_JSON")
(( ${#BYTES[@]} > 0 )) || die "no Hy3 GGUF candidates returned by $HF_REPO"

CURRENT_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/hy3/$SERVICE_NAME-llama.env"
CURRENT_MODEL=""
CURRENT_CLASS=""
CURRENT_PID=0
CURRENT_GPU_PROFILE=0
CURRENT_SERVICE_ACTIVE=0
if [[ -f "$CURRENT_ENV" ]]; then
  CURRENT_MODEL="$(sed -n 's/^MODEL_PATH=//p' "$CURRENT_ENV" | head -n 1)"
  CURRENT_CLASS="$(basename "$CURRENT_MODEL" | sed -n 's/^hy3-1M-\(.*\)\.gguf$/\1/p')"
  CURRENT_NGL="$(sed -n 's/^N_GPU_LAYERS=//p' "$CURRENT_ENV" | head -n 1)"
  CURRENT_FIT="$(sed -n 's/^FIT=//p' "$CURRENT_ENV" | head -n 1)"
  CURRENT_CPU_MOE="$(sed -n 's/^CPU_MOE=//p' "$CURRENT_ENV" | head -n 1)"
  if [[ "$CURRENT_NGL" == "all" && "$CURRENT_FIT" == "off" && "$CURRENT_CPU_MOE" != "1" ]]; then
    CURRENT_GPU_PROFILE=1
  fi
fi
if command -v systemctl >/dev/null 2>&1; then
  CURRENT_PID="$(systemctl --user show "$SERVICE_NAME.service" -p MainPID --value 2>/dev/null || printf '0')"
  if systemctl --user is-active --quiet "$SERVICE_NAME.service"; then
    CURRENT_SERVICE_ACTIVE=1
  fi
fi

MTP_RUNTIME=0
MTP_HELP=""
if [[ -x "$LLAMA_SERVER_BIN" ]]; then
  MTP_HELP="$($LLAMA_SERVER_BIN --help 2>&1 || true)"
fi
if [[ "$MTP_POLICY" == "on" ]]; then
  if [[ -x "$LLAMA_SERVER_BIN" ]]; then
    [[ "$MTP_HELP" == *draft-mtp* ]] ||
      die "MTP was explicitly requested but $LLAMA_SERVER_BIN does not advertise draft-mtp"
    MTP_RUNTIME=1
  else
    MTP_RUNTIME=1
  fi
elif [[ "$MTP_POLICY" == "auto" ]]; then
  if [[ "$MTP_HELP" == *draft-mtp* ]]; then
    MTP_RUNTIME=1
  elif [[ ! -x "$LLAMA_SERVER_BIN" && "${LLAMA_CPP_BRANCH:-hy3-mtp}" == "hy3-mtp" ]]; then
    MTP_RUNTIME=1
  fi
fi

case "$TIER" in
  speed) CANDIDATES=(IQ2_M Q2_K MTP-IQ2_M MTP-Q2_K) ;;
  balanced) CANDIDATES=(IQ2_M Q2_K MTP-IQ2_M MTP-Q2_K MTP-IQ3_XXS) ;;
  quality|auto) CANDIDATES=(MTP-Q6_K MTP-Q5_K MTP-Q4_K_M MTP-Q3_K_M MTP-Q2_K MTP-IQ3_XXS MTP-IQ2_M Q2_K IQ2_M) ;;
esac
if [[ "$REQUESTED_CLASS" != auto ]]; then CANDIDATES=("$REQUESTED_CLASS"); fi

IFS=',' read -r -a GPU_IDS <<< "$A100_IDS"
IFS=',' read -r -a GPU_TOTALS <<< "$A100_TOTAL_MIB"
GPU_COUNT="$A100_COUNT"
[[ "$GPU_COUNT" =~ ^[1-9][0-9]*$ ]] || die "invalid A100_COUNT=$GPU_COUNT"

non_hy3_used_mib() {
  local gpu_id="$1"
  local used=0
  local pid name memory
  while IFS=',' read -r pid name memory; do
    pid="$(trim "$pid")"
    memory="$(trim "$memory")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$CURRENT_PID" ]] && continue
    [[ "$memory" =~ ^[0-9]+$ ]] || continue
    used=$((used + memory))
  done < <(nvidia-smi -i "$gpu_id" --query-compute-apps=pid,name,used_memory \
    --format=csv,noheader,nounits 2>/dev/null || true)
  printf '%s' "$used"
}

fits_full_gpu() {
  local model_bytes="$1"
  local weight_mib=$((model_bytes / 1048576))
  local kv_mib=$((KV_Q8_AT_262K_MIB * CTX_SIZE / 262144))
  local weight_per=$(((weight_mib * 105 + 99) / 100 / GPU_COUNT))
  local kv_per=$(((kv_mib + GPU_COUNT - 1) / GPU_COUNT))
  local required=$((weight_per + kv_per + RESERVE_MIB))
  local i non_hy3 total available
  SELECTED_REQUIRED_MIB="$required"
  SELECTED_KV_MIB="$kv_mib"
  for ((i = 0; i < GPU_COUNT; i++)); do
    non_hy3="$(non_hy3_used_mib "${GPU_IDS[$i]}")"
    total="${GPU_TOTALS[$i]}"
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    available=$((total - non_hy3 - RESERVE_MIB))
    (( available >= required )) || return 1
  done
  return 0
}

SELECTED_CLASS=""
SELECTED_BYTES=""
SELECTED_FILENAME=""
SELECTED_TIER=""
SELECTED_QUALIFICATION=""
SELECTED_REASON=""
SELECTED_REQUIRED_MIB=0
SELECTED_KV_MIB=0

if [[ "$REQUESTED_CLASS" == auto && "$UPGRADE" != "1" &&
      "$CURRENT_SERVICE_ACTIVE" == "1" &&
      "$CURRENT_GPU_PROFILE" == "1" && -n "$CURRENT_CLASS" &&
      -n "${BYTES[$CURRENT_CLASS]:-}" && -s "$CURRENT_MODEL" &&
      ( "$TIER" == "auto" || "$TIER" == "balanced" ) ]]; then
  SELECTED_CLASS="$CURRENT_CLASS"
  SELECTED_BYTES="$(stat -Lc '%s' "$CURRENT_MODEL")"
  SELECTED_FILENAME="hy3-1M-$SELECTED_CLASS.gguf"
  SELECTED_TIER="existing"
  SELECTED_QUALIFICATION="full-gpu"
  SELECTED_REASON="keeping active qualified model $CURRENT_MODEL; use --upgrade or HY3_UPGRADE=1 to select a higher-ranked candidate"
fi

if [[ -z "$SELECTED_CLASS" ]]; then
  for candidate in "${CANDIDATES[@]}"; do
    [[ -n "${BYTES[$candidate]:-}" ]] || continue
    if [[ "$candidate" == MTP-* && "$MTP_RUNTIME" != "1" ]]; then
      [[ "$REQUESTED_CLASS" != auto ]] && warn "skipping $candidate because MTP runtime support is unavailable"
      continue
    fi
    if [[ "$QUALIFICATION_POLICY" != "hybrid" ]] && fits_full_gpu "${BYTES[$candidate]}"; then
      SELECTED_CLASS="$candidate"
      SELECTED_BYTES="${BYTES[$candidate]}"
      SELECTED_FILENAME="hy3-1M-$candidate.gguf"
      SELECTED_TIER="$TIER"
      SELECTED_QUALIFICATION="full-gpu"
      SELECTED_REASON="candidate fits every selected A100 at requested context with all layers on CUDA"
      break
    fi
    if [[ "$QUALIFICATION_POLICY" == "hybrid" ]]; then
      SELECTED_CLASS="$candidate"
      SELECTED_BYTES="${BYTES[$candidate]}"
      SELECTED_FILENAME="hy3-1M-$candidate.gguf"
      SELECTED_TIER="$TIER"
      SELECTED_QUALIFICATION="hybrid"
      SELECTED_REASON="candidate selected with explicit hybrid qualification; CPU weight fallback is permitted"
      break
    fi
  done
fi

[[ -n "$SELECTED_CLASS" ]] ||
  die "no $TIER candidate qualifies for $GPU_COUNT A100s at context $CTX_SIZE; use --context lower, --qualification hybrid, or an explicit smaller class"

SELECTED_MTP=0
[[ "$SELECTED_CLASS" == MTP-* ]] && SELECTED_MTP=1
PROFILE_N_GPU_LAYERS=all
PROFILE_FIT=off
if [[ "$SELECTED_QUALIFICATION" == "hybrid" ]]; then
  PROFILE_N_GPU_LAYERS=auto
  PROFILE_FIT=on
fi
PROFILE_SPEC_TYPE=none
[[ "$SELECTED_MTP" == "1" ]] && PROFILE_SPEC_TYPE=draft-mtp

fits_full_gpu "$SELECTED_BYTES" || true
PROFILE_ENV="$STATE_DIR/profile.env"
PROFILE_JSON="$STATE_DIR/profile.json"
{
  printf 'SELECTED_CLASS=%q\n' "$SELECTED_CLASS"
  printf 'SELECTED_FILENAME=%q\n' "$SELECTED_FILENAME"
  printf 'SELECTED_BYTES=%q\n' "$SELECTED_BYTES"
  printf 'SELECTED_TIER=%q\n' "$SELECTED_TIER"
  printf 'SELECTED_QUALIFICATION=%q\n' "$SELECTED_QUALIFICATION"
  printf 'SELECTED_REASON=%q\n' "$SELECTED_REASON"
  printf 'SELECTED_REQUIRED_MIB=%q\n' "$SELECTED_REQUIRED_MIB"
  printf 'SELECTED_KV_MIB=%q\n' "$SELECTED_KV_MIB"
  printf 'SELECTED_MTP=%q\n' "$SELECTED_MTP"
  printf 'PROFILE_N_GPU_LAYERS=%q\n' "$PROFILE_N_GPU_LAYERS"
  printf 'PROFILE_FIT=%q\n' "$PROFILE_FIT"
  printf 'PROFILE_SPEC_TYPE=%q\n' "$PROFILE_SPEC_TYPE"
  printf 'CATALOG_SOURCE=%q\n' "$CATALOG_SOURCE"
  printf 'HF_REPO=%q\n' "$HF_REPO"
} > "$PROFILE_ENV"

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg requested_class "$REQUESTED_CLASS" \
    --arg selected_class "$SELECTED_CLASS" \
    --arg filename "$SELECTED_FILENAME" \
    --arg tier "$SELECTED_TIER" \
    --arg qualification "$SELECTED_QUALIFICATION" \
    --arg reason "$SELECTED_REASON" \
    --arg catalog_source "$CATALOG_SOURCE" \
    --arg hf_repo "$HF_REPO" \
    --argjson bytes "$SELECTED_BYTES" \
    --argjson required_mib "$SELECTED_REQUIRED_MIB" \
    --argjson kv_mib "$SELECTED_KV_MIB" \
    --argjson mtp "$SELECTED_MTP" \
    --arg n_gpu_layers "$PROFILE_N_GPU_LAYERS" \
    --arg fit "$PROFILE_FIT" \
    --arg spec_type "$PROFILE_SPEC_TYPE" \
    '{requested_class:$requested_class, selected_class:$selected_class, filename:$filename,
      bytes:$bytes, tier:$tier, qualification:$qualification, reason:$reason,
      required_mib:$required_mib, kv_mib:$kv_mib, mtp:$mtp,
      n_gpu_layers:$n_gpu_layers, fit:$fit, spec_type:$spec_type,
      catalog_source:$catalog_source, hf_repo:$hf_repo}' > "$PROFILE_JSON"
fi

printf 'HY3 profile: requested=%s tier=%s selected=%s qualification=%s mtp=%s\n' \
  "$REQUESTED_CLASS" "$TIER" "$SELECTED_CLASS" "$SELECTED_QUALIFICATION" "$SELECTED_MTP"
printf 'HY3 profile: file=%s bytes=%s context=%s kv_q8_mib=%s required_mib=%s\n' \
  "$SELECTED_FILENAME" "$SELECTED_BYTES" "$CTX_SIZE" "$SELECTED_KV_MIB" "$SELECTED_REQUIRED_MIB"
printf 'HY3 profile: layers=%s fit=%s spec_type=%s\n' \
  "$PROFILE_N_GPU_LAYERS" "$PROFILE_FIT" "$PROFILE_SPEC_TYPE"
printf 'HY3 profile reason: %s\n' "$SELECTED_REASON"
printf 'HY3 profile catalog: %s\n' "$CATALOG_SOURCE"
