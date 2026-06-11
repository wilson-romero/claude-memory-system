#!/usr/bin/env bash
# update.sh — bring this machine to the latest version of the memory system.
# git pull (ff-only) + re-run the idempotent installer (migrations included).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[update] pulling latest version..."
git -C "$REPO_DIR" pull --ff-only

echo "[update] running installer..."
bash "${REPO_DIR}/install.sh"

echo "[update] now at version $(cat "${REPO_DIR}/VERSION")"
