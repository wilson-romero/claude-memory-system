#!/usr/bin/env bash
# 003 — quarantine sync-conflict artifacts (non-destructive). Idempotent.
set -euo pipefail

bash "${MEMORIA_REPO_DIR}/scripts/migrate/cleanup-conflicts.sh"

echo "003: conflicts quarantined"
