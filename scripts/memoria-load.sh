#!/usr/bin/env bash
# memoria-load.sh — Claude Code SessionStart hook.
# Reads hook JSON from stdin and injects vault context as systemMessage.
# Also: warns when the memory system repo has a newer version, and launches
# the nightly "dream" consolidation if it has not run in >24h.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_config

HOOK_INPUT=$(cat)
CWD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
[ -z "$CWD" ] && CWD="$HOME"

V_SLUG=$(vault_slug "$CWD")

PROJECT_NOTE="${MEMORIA_VAULT_ROOT}/projects/${V_SLUG}/_project.md"
CONTEXTO="${MEMORIA_VAULT_ROOT}/Memoria/contexto-reciente.md"
AGENTS_INDEX="${MEMORIA_VAULT_ROOT}/agents/_skills-index.md"
SHARED_INDEX="${MEMORIA_REPO_DIR}/shared-knowledge/INDEX.md"

# ── Version check (once a day, silent on network failure) ─────────────────────
VERSION_WARNING=""
REPO_VERSION=$(cat "${MEMORIA_REPO_DIR}/VERSION" 2>/dev/null || echo "")
INSTALLED_VERSION=$(state_get VERSION)
TODAY=$(date '+%Y-%m-%d')
if [ "$(state_get LAST_FETCH)" != "$TODAY" ] && [ -d "${MEMORIA_REPO_DIR}/.git" ]; then
  timeout 3 git -C "$MEMORIA_REPO_DIR" fetch --quiet 2>/dev/null || true
  state_set LAST_FETCH "$TODAY"
fi
if [ -d "${MEMORIA_REPO_DIR}/.git" ]; then
  BEHIND=$(git -C "$MEMORIA_REPO_DIR" rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
else
  BEHIND="0"
fi
if [ -n "$REPO_VERSION" ] && [ -n "$INSTALLED_VERSION" ] && [ "$REPO_VERSION" != "$INSTALLED_VERSION" ]; then
  VERSION_WARNING="⚠ Sistema de memoria desactualizado (instalado ${INSTALLED_VERSION}, repo ${REPO_VERSION}). Ejecuta /memory-update."
elif [ "${BEHIND:-0}" != "0" ]; then
  VERSION_WARNING="⚠ Hay ${BEHIND} commit(s) nuevos del sistema de memoria en GitHub. Ejecuta /memory-update."
fi

# ── Dream fallback: if last dream >24h ago, launch it in background ───────────
LAST_DREAM=$(state_get LAST_DREAM)
if [ "$LAST_DREAM" != "$TODAY" ] && [ -x "${SCRIPT_DIR}/memoria-dream.sh" ]; then
  nohup "${SCRIPT_DIR}/memoria-dream.sh" >> "$MEMORIA_LOG" 2>&1 &
  disown 2>/dev/null || true
fi

# ── Collect content pieces (size-capped) ──────────────────────────────────────
read_capped() {
  # $1=file $2=max_bytes — prints nothing if missing
  [ -f "$1" ] && head -c "$2" "$1" || true
}

# Last section of contexto-reciente.md: from the last "## " heading onward
CONTEXTO_TAIL=""
if [ -f "$CONTEXTO" ]; then
  CONTEXTO_TAIL=$(awk '/^## /{n=NR} {lines[NR]=$0} END{if(n) for(i=n;i<=NR;i++) print lines[i]}' "$CONTEXTO" | head -c 1500)
fi

export MB_BANNER="Máquina: ${MEMORIA_MACHINE} (perfil ${MEMORIA_PROFILE}) — vault: ${MEMORIA_VAULT_ROOT}"
export MB_WARNING="$VERSION_WARNING"
export MB_PROJECT="$(read_capped "$PROJECT_NOTE" 3000)"
export MB_CONTEXTO="$CONTEXTO_TAIL"
export MB_AGENTS="$(read_capped "$AGENTS_INDEX" 1000)"
export MB_SHARED="$(read_capped "$SHARED_INDEX" 800)"

# Build JSON safely in python (content passed via environment, never
# interpolated into code — fixes the triple-quote injection bug).
python3 - <<'PYEOF'
import json, os

parts = ["## Segunda memoria (Obsidian)", os.environ.get("MB_BANNER", "")]

warning = os.environ.get("MB_WARNING", "").strip()
if warning:
    parts.append(warning)

project = os.environ.get("MB_PROJECT", "").strip()
if project:
    parts.append("\n### Memoria del proyecto\n" + project)

contexto = os.environ.get("MB_CONTEXTO", "").strip()
if contexto:
    parts.append("\n### Contexto reciente (última entrada)\n" + contexto)

agents = os.environ.get("MB_AGENTS", "").strip()
if agents:
    parts.append("\n### Banco de agentes\n" + agents)

shared = os.environ.get("MB_SHARED", "").strip()
if shared:
    parts.append("\n### Conocimiento compartido entre equipos\n" + shared)

print(json.dumps({
    "continue": True,
    "suppressOutput": True,
    "systemMessage": "\n".join(parts),
}))
PYEOF

exit 0
