#!/usr/bin/env bash
# 002 — normalize frontmatter across semantic memory folders. Idempotent.
set -euo pipefail

python3 "${MEMORIA_REPO_DIR}/scripts/migrate/add-frontmatter.py" \
  "${MEMORIA_MACHINE}" \
  "${MEMORIA_VAULT_ROOT}/Memoria" \
  "${MEMORIA_VAULT_ROOT}/Memoria-CC" \
  "${MEMORIA_VAULT_ROOT}/Lecciones" \
  "${MEMORIA_VAULT_ROOT}/daily"

echo "002: frontmatter ok"
