#!/usr/bin/env bash
# Install the Hy3 operator console in the current user's PATH. This script
# deliberately does not start, stop, or restart any model service.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SOURCE="${REPO_DIR}/bin/hy3"
DEST_DIR="${HY3_BIN_DIR:-${HOME}/.local/bin}"
DEST="${DEST_DIR}/hy3"

[[ -f "$SOURCE" ]] || { printf 'hy3 control source is missing: %s\n' "$SOURCE" >&2; exit 1; }
mkdir -p "$DEST_DIR"
install -m 0755 "$SOURCE" "$DEST"

printf 'Installed Hy3 console: %s\n' "$DEST"
printf 'Run `hy3` to open the service console, or `hy3 status` for a read-only check.\n'
