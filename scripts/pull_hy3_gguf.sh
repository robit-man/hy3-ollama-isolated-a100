#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="${HY3_MODELS_DIR:-/srv/hy3}"
HF_REPO="${HF_REPO:-satgeze/Hy3-1M-GGUF}"
HF_CLASS="${HF_CLASS:-Q2_K}"
HF_FILENAME="${HF_FILENAME:-hy3-1M-${HF_CLASS}.gguf}"
TARGET="${MODELS_DIR}/${HF_FILENAME}"
LATEST_LINK="${MODELS_DIR}/hy3-1M-latest.gguf"
ACTIVE_LINK="${MODELS_DIR}/hy3-active.gguf"
FORCE="${1:-0}"

if [[ "$FORCE" != "0" && "$FORCE" != "1" ]]; then
  echo "Usage: $0 [0|1]"
  echo "  0: skip download if file exists"
  echo "  1: force refresh"
  exit 2
fi

mkdir -p "$MODELS_DIR"
if [[ ! -w "$MODELS_DIR" ]]; then
  echo "ERROR: cannot write to ${MODELS_DIR}"
  exit 1
fi

if [[ "$FORCE" == "1" ]] || [[ ! -f "$TARGET" ]]; then
  HF_URL="https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILENAME}"
  TMP_FILE="${TARGET}.tmp"
  echo "Downloading ${HF_URL} -> ${TARGET}"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$HF_REPO" "$HF_FILENAME" --local-dir "$MODELS_DIR" --local-dir-use-symlinks False
    if [[ ! -f "$TARGET" ]]; then
      echo "ERROR: huggingface-cli did not place ${HF_FILENAME} under ${MODELS_DIR}"
      exit 1
    fi
  else
    echo "huggingface-cli not found, using direct curl"
    curl -L --fail-with-body --retry 3 --retry-delay 2 -o "$TMP_FILE" "$HF_URL"
    mv "$TMP_FILE" "$TARGET"
  fi
fi

if [[ ! -s "$TARGET" ]]; then
  echo "ERROR: model missing or empty: ${TARGET}"
  exit 1
fi

ln -sfn "$TARGET" "$LATEST_LINK"
ln -sfn "$TARGET" "$ACTIVE_LINK"

echo "Model ready: $TARGET"
echo "Bytes: $(stat -c%s "$TARGET")"
echo "sha256: $(sha256sum "$TARGET" | cut -d' ' -f1)"

echo "HF_REPO=${HF_REPO}" > "${MODELS_DIR}/hy3-active.manifest"
echo "HF_CLASS=${HF_CLASS}" >> "${MODELS_DIR}/hy3-active.manifest"
echo "HF_FILENAME=${HF_FILENAME}" >> "${MODELS_DIR}/hy3-active.manifest"
echo "MODEL_PATH=${TARGET}" >> "${MODELS_DIR}/hy3-active.manifest"
echo "FREED_AT=$(date -u +%FT%TZ)" >> "${MODELS_DIR}/hy3-active.manifest"
