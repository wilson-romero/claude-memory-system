#!/usr/bin/env bash
# 006 — keep curated files with legacy names reachable (v2.1.1). Idempotent.
#
# Since efb41ad the curator prompt and /memory-load use generic names
# (Memoria/preferencias.md, Memoria/perfil.md). Vaults created before that use
# their own names (e.g. preferencias-jarvis.md, wilson-perfil.md). Without this,
# the curator silently starts a second, empty preferences file and /memory-load
# skips the real one ("skip silently any that don't exist").
#
# Files are NOT renamed: hundreds of notes link to the legacy names. Instead the
# detected name is written to memoria.env, which install.sh and the skills read.
set -euo pipefail

# shellcheck disable=SC1091
source "${MEMORIA_REPO_DIR}/scripts/lib/common.sh"
load_config

ENV_FILE="${MEMORIA_ENV:-$HOME/.claude/memoria.env}"
CURATED="${MEMORIA_VAULT_ROOT}/Memoria"

# $1=var  $2=generic name  $3=glob for legacy candidates
detect() {
  local var="$1" generic="$2" pattern="$3"
  if grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
    echo "006: ${var} already set"
    return
  fi
  if [ -f "${CURATED}/${generic}" ]; then
    echo "006: ${generic} exists — nothing to do"
    return
  fi
  local matches=()
  local f
  for f in "${CURATED}"/${pattern}; do
    [ -f "$f" ] && matches+=("$(basename "$f")")
  done
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "006: ${var}: ${#matches[@]} candidates for ${pattern} — left at default ${generic}"
    return
  fi
  [ -f "${ENV_FILE}.bak.006" ] || cp "$ENV_FILE" "${ENV_FILE}.bak.006"
  printf '\n# Legacy curated file name detected by migrations/006 (default: %s)\n%s="%s"\n' \
    "$generic" "$var" "${matches[0]}" >> "$ENV_FILE"
  log "006: ${var}=${matches[0]}"
  echo "006: ${var}=\"${matches[0]}\" written to ${ENV_FILE}"
}

detect MEMORIA_PREFS_FILE preferencias.md 'preferencias*.md'
detect MEMORIA_PERFIL_FILE perfil.md '*perfil*.md'
