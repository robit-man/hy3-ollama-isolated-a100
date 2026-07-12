#!/usr/bin/env bash
# Non-destructive regression test for bin/hy3. All external commands are
# replaced with local fakes; it never talks to systemd, GPUs, or the endpoint.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLI="${REPO_DIR}/bin/hy3"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.config/hy3"
CALLS="$TMP_DIR/calls"
CONFIG="$TMP_DIR/home/.config/hy3/hy3-test-llama.env"

cat > "$CONFIG" <<'EOF'
MODEL_PATH=/srv/hy3/test.gguf
HOST=127.0.0.1
PORT=11499
EOF

cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HY3_TEST_CALLS"
case " $* " in
  *" show "*) printf '4242\n' ;;
  *" is-active "*) exit 3 ;;
  *" is-enabled "*) exit 1 ;;
esac
EOF
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HY3_TEST_CALLS"
printf '{"status":"ok"}\n'
EOF
cat > "$TMP_DIR/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
printf '0, test-gpu, 1, 999\n'
EOF
chmod +x "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/nvidia-smi"

run() {
  HOME="$TMP_DIR/home" \
  HY3_CONFIG_FILE="$CONFIG" \
  HY3_SERVICE_NAME=hy3-test \
  HY3_SYSTEMCTL_BIN="$TMP_DIR/bin/systemctl" \
  HY3_CURL_BIN="$TMP_DIR/bin/curl" \
  HY3_NVIDIA_SMI_BIN="$TMP_DIR/bin/nvidia-smi" \
  HY3_TEST_CALLS="$CALLS" \
  HY3_READY_TIMEOUT_SEC=1 \
  "$CLI" "$@"
}

status_output="$(run status)"
printf '%s' "$status_output" | rg -q 'Hy3 service: hy3-test.service'
printf '%s' "$status_output" | rg -q 'Endpoint:    http://127.0.0.1:11499'

run load --yes >/dev/null
rg -qx -- '--user start hy3-test.service' "$CALLS"

run restart --yes >/dev/null
rg -qx -- '--user restart hy3-test.service' "$CALLS"

run kill --yes >/dev/null
rg -qx -- '--user stop --no-block hy3-test.service' "$CALLS"
rg -qx -- '--user kill --kill-who=all --signal=SIGKILL hy3-test.service' "$CALLS"

printf 'Hy3 control tests passed.\n'
