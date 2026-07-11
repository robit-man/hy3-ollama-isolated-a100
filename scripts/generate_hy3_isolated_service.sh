#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-hy3-isolated}"
PORT="${2:-11452}"
HOST="${3:-127.0.0.1}"
MODELS_DIR="${4:-/srv/hy3}"
OLLAMA_BIN="${5:-$(command -v ollama || true)}"

if [[ -z "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not found"
  echo "Install ollama or set OLLAMA_BIN / pass as argument."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not available"
  exit 1
fi

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hy3"
mkdir -p "$UNIT_DIR" "$CONFIG_DIR"

UNIT_FILE="$UNIT_DIR/${SERVICE_NAME}.service"
ENV_FILE="$CONFIG_DIR/${SERVICE_NAME}.env"

cat > "$ENV_FILE" <<EOF2
OLLAMA_HOST=${HOST}:${PORT}
OLLAMA_MODELS=${MODELS_DIR}
CUDA_VISIBLE_DEVICES=0,1,2
CUDA_DEVICE_ORDER=PCI_BUS_ID
NVIDIA_VISIBLE_DEVICES=0,1,2
EOF2

cat > "$UNIT_FILE" <<EOF2
[Unit]
Description=Hy3 isolated Ollama endpoint (${SERVICE_NAME})
StartLimitIntervalSec=60
StartLimitBurst=10
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/hy3/${SERVICE_NAME}.env
ExecStart=${OLLAMA_BIN} serve
Restart=always
RestartSec=2
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF2

systemctl --user daemon-reload

echo "Generated service: ${UNIT_FILE}"
echo "Generated environment: ${ENV_FILE}"
echo "Start with: systemctl --user enable --now ${SERVICE_NAME}.service"
