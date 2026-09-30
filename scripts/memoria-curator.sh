#!/usr/bin/env bash
# memoria-curator.sh — Claude Code Stop hook (semantic curation layer).
#
# Runs the curator as a HEADLESS `claude -p` so the hook can be configured with
# "asyncRewake": true. The turn ends immediately; this script keeps working in
# the background and only comes back to the model when the memory was NOT
# written (exit 2 → Claude Code wakes the session with our stderr as a
# system-reminder). Exit 0 stays silent.
#
# Why not the previous `type: "agent"` hook: agent hooks cannot be async, so
# every turn paid up to its 120s timeout before being released.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID: an async job that fails in silence
# stops writing memory and nobody complains. Therefore:
#   - it verifies the WORK (files whose mtime moved), never the attempt;
#   - it records a dated trace of that work (log line + LAST_CURATOR_WRITE);
#   - it exits 2 when the work did not happen, so the model says so out loud;
#   - and memoria-load.sh (SessionStart, synchronous) counts sessions since the
#     last verified write, a signal that does NOT depend on this script running.
set -uo pipefail

# Kill switch: curation is skipped while this flag file exists. Exit 0 (not 2)
# so the disabled state never wakes the session. Remove the file to re-enable.
if [ -e "${HOME}/.claude/memoria-capture.off" ]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_config

START_EPOCH=$(date +%s)
CURATOR_PROMPT_FILE="${MEMORIA_CURATOR_PROMPT:-$HOME/.claude/memoria-curator-prompt.md}"
LOCK_FILE="$HOME/.claude/memoria-curator.lock"
# Remembers which session we woke with an exit 2, so the follow-up turn can be
# told apart from any other wake (see the stop_hook_active guard below).
REWAKE_FILE="$HOME/.claude/memoria-curator-rewake"
MODEL="${MEMORIA_CURATOR_MODEL:-claude-sonnet-5}"
RUN_TIMEOUT="${MEMORIA_CURATOR_TIMEOUT:-600}"
NOTE_WAIT="${MEMORIA_CURATOR_NOTE_WAIT:-20}"

# Fail the turn's memory loudly (rewake) or quietly, always exit-coded.
fail_loud() {
  log "curator: FAILED — $1 (session ${SESSION_ID:-unknown})"
  state_set LAST_CURATOR_FAIL "$(date '+%Y-%m-%dT%H:%M:%S')"
  echo "${SESSION_ID:-unknown} $(date +%s)" > "$REWAKE_FILE" 2>/dev/null || true
  echo "La memoria curada de la sesión que acabas de terminar NO se escribió: $1 — revisa 'grep curator ${MEMORIA_LOG}'." >&2
  exit 2
}
quiet_exit() { log "curator: $1 (session ${SESSION_ID:-unknown})"; exit 0; }

# ── Hook payload ──────────────────────────────────────────────────────────────
# Same reason as capture/load for `read -t` instead of `$(cat)`: Claude Code does
# not always close the pipe, and $(cat) would wait for EOF until the timeout.
IFS= read -r -t 5 HOOK_INPUT || true
read_field() {
  echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || echo ""
}
SESSION_ID=$(read_field session_id)
CWD=$(read_field cwd)
TRANSCRIPT_PATH=$(read_field transcript_path)
STOP_HOOK_ACTIVE=$(read_field stop_hook_active)
[ -z "$CWD" ] && CWD="$HOME"

# ── Guards ────────────────────────────────────────────────────────────────────
# 1. The rewake itself produces another Stop event, with stop_hook_active=True
#    (verified on 2.1.220). Without a guard, one failure would curate in a loop,
#    one headless `claude -p` per lap.
#    But stop_hook_active is NOT ours alone: any background task notification
#    wakes the session the same way (measured on 2026-07-30). Skipping every one
#    of them would leave the last turn of such a session uncurated, so only the
#    wake WE caused — same session, recent — is skipped.
case "$STOP_HOOK_ACTIVE" in
  True|true)
    if [ -f "$REWAKE_FILE" ]; then
      read -r RW_SESSION RW_EPOCH < "$REWAKE_FILE" || true
      if [ "${RW_SESSION:-}" = "$SESSION_ID" ] \
         && [ $((START_EPOCH - ${RW_EPOCH:-0})) -lt 900 ]; then
        rm -f "$REWAKE_FILE"
        quiet_exit "skipped (this turn is our own rewake; not curating twice)"
      fi
    fi
    log "curator: stop_hook_active but not our rewake — curating anyway (session ${SESSION_ID:-unknown})"
    ;;
esac

# 2. Recursion belt. The headless child runs with "disableAllHooks": true, so it
#    fires no Stop hook of its own; this env var is the second lock in case that
#    setting ever stops being honoured.
if [ -n "${MEMORIA_CURATOR_ACTIVE:-}" ]; then
  quiet_exit "skipped (recursive invocation from the headless curator)"
fi

# 3. Sessions whose cwd is the vault itself are the maintenance ones (the dream,
#    /memory-* skills). Capture skips them for the same reason.
OBSIDIAN_TREE="$(dirname "$MEMORIA_VAULT_ROOT")"
case "$CWD" in
  "$OBSIDIAN_TREE"*) quiet_exit "skipped (cwd inside vault tree: $CWD)" ;;
esac

CLAUDE_BIN=$(find_claude)
[ -z "$CLAUDE_BIN" ] && fail_loud "no se encontró el binario claude"
[ -f "$CURATOR_PROMPT_FILE" ] && [ -s "$CURATOR_PROMPT_FILE" ] \
  || fail_loud "falta el prompt renderizado ${CURATOR_PROMPT_FILE} (corre install.sh)"

# ── Single instance: two curators editing the same curated files would clash ──
exec 9>"$LOCK_FILE"
if ! flock -w 300 9; then
  fail_loud "otro curador siguió ocupado 300s (lock ${LOCK_FILE})"
fi

state_set LAST_CURATOR_RUN "$(date '+%Y-%m-%dT%H:%M:%S')"
log "curator: start (session ${SESSION_ID:-unknown}, cwd ${CWD})"

# ── Wait for the session note capture writes (both hooks are async now) ───────
V_SLUG=$(vault_slug "$CWD")
SESSIONS_DIR="${MEMORIA_VAULT_ROOT}/projects/${V_SLUG}/sessions"
SESSION_NOTE=""
for _ in $(seq 1 "$NOTE_WAIT"); do
  SESSION_NOTE=$(find "$SESSIONS_DIR" -maxdepth 1 -name '*.md' -newermt "@$((START_EPOCH - 120))" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$SESSION_NOTE" ] && break
  sleep 1
done

SRC_NOTE="${SESSION_NOTE:-(no disponible)}"
SRC_TRANSCRIPT="(no disponible)"
# The child may read only the vault and the dirs passed with --add-dir. Handing
# it ~/.claude/projects/<slug>/ would expose every other session of the
# project, so it gets a COPY of this one transcript in a private directory.
TRANSCRIPT_DIR=$(mktemp -d)
trap 'rm -rf "$TRANSCRIPT_DIR"' EXIT
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] \
   && cp "$TRANSCRIPT_PATH" "${TRANSCRIPT_DIR}/transcript.jsonl"; then
  SRC_TRANSCRIPT="${TRANSCRIPT_DIR}/transcript.jsonl"
fi
if [ "$SRC_NOTE" = "(no disponible)" ] && [ "$SRC_TRANSCRIPT" = "(no disponible)" ]; then
  fail_loud "no hay fuente de la sesión (ni nota de capture ni transcript)"
fi

PROMPT="$(cat "$CURATOR_PROMPT_FILE")

## Fuente de la sesión que acaba de terminar

Esta ejecución es HEADLESS: la conversación NO está en tu contexto. Reconstrúyela leyendo:

1. Nota de sesión escrita por el capture determinista (resumen; empieza por aquí):
   ${SRC_NOTE}
2. Transcript completo en JSONL (úsalo con Read/Grep solo si necesitas detalle):
   ${SRC_TRANSCRIPT}

No inventes contenido que no esté en esas fuentes. Si ambas faltan o están vacías,
no escribas nada y termina con la línea de contrato SKIPPED.

## Contrato de salida (obligatorio)

Termina tu respuesta con UNA de estas dos líneas, sola en la última línea:

- CURATOR: WROTE     — escribiste o editaste al menos un archivo del vault.
- CURATOR: SKIPPED   — la sesión fue trivial y no escribiste nada.

Un script comprueba por mtime si de verdad escribiste. Decir WROTE sin haber
escrito se registra como fallo y despierta la sesión con el aviso.
"

# ── Run the curator headless ──────────────────────────────────────────────────
# vault_only_claude_args (lib/common.sh) boxes the child in: writes only inside
# the vault, reads only the vault and the transcript copy, no Bash, no MCP, and
# none of ~/.claude/settings.json. Its --settings also carries disableAllHooks,
# which keeps this child from firing the Stop hooks again and curating in
# circles (verified: with the flag the hook does not run, without it it does).
vault_only_claude_args
OUT_FILE=$(mktemp)
cd "$MEMORIA_VAULT_ROOT" || fail_loud "no se pudo entrar al vault ${MEMORIA_VAULT_ROOT}"
MEMORIA_CURATOR_ACTIVE=1 timeout "$RUN_TIMEOUT" "$CLAUDE_BIN" -p "$PROMPT" \
  --model "$MODEL" \
  "${HEADLESS_ARGS[@]}" \
  --add-dir "$TRANSCRIPT_DIR" \
  </dev/null >"$OUT_FILE" 2>&1
RC=$?
{ echo "--- curator output (session ${SESSION_ID:-unknown}, rc=${RC}) ---"; cat "$OUT_FILE"; } >> "$MEMORIA_LOG"

# ── Verify the WORK, not the attempt ─────────────────────────────────────────
# Only files in the curator's write zone, only mtimes moved after this run began.
WRITTEN=$(find "${MEMORIA_VAULT_ROOT}/Memoria" "${MEMORIA_VAULT_ROOT}/Lecciones" \
  "${MEMORIA_VAULT_ROOT}/Memoria-CC" "${MEMORIA_VAULT_ROOT}/Decisiones" \
  -name '*.md' -newermt "@${START_EPOCH}" 2>/dev/null \
  | sed "s|^${MEMORIA_VAULT_ROOT}/||" | sort | tr '\n' ' ')
WRITTEN_COUNT=$(echo "$WRITTEN" | wc -w)
SENTINEL=""
grep -q "CURATOR: WROTE" "$OUT_FILE" 2>/dev/null && SENTINEL="WROTE"
grep -q "CURATOR: SKIPPED" "$OUT_FILE" 2>/dev/null && SENTINEL="${SENTINEL:-SKIPPED}"
rm -f "$OUT_FILE"

if [ "$WRITTEN_COUNT" -gt 0 ]; then
  # Dated trace of the work DONE — the file list is the evidence, not the run.
  log "curator: WROTE ${WRITTEN_COUNT} file(s) [${WRITTEN}] (session ${SESSION_ID:-unknown}, rc=${RC}, ${MODEL})"
  state_set LAST_CURATOR_WRITE "$(date '+%Y-%m-%dT%H:%M:%S')"
  state_set SESSIONS_SINCE_CURATOR 0
  exit 0
fi

# Nothing was written. Decide whether that is legitimate.
if [ "$RC" -ne 0 ]; then
  fail_loud "el curador headless terminó con código ${RC} sin escribir nada"
fi
if [ "$SENTINEL" = "SKIPPED" ]; then
  log "curator: skipped by model (trivial session ${SESSION_ID:-unknown}); no files written"
  state_set LAST_CURATOR_SKIP "$(date '+%Y-%m-%dT%H:%M:%S')"
  exit 0
fi
if [ "$SENTINEL" = "WROTE" ]; then
  fail_loud "el curador dijo WROTE y ningún archivo del vault cambió de mtime"
fi
fail_loud "el curador terminó sin línea de contrato y sin escribir nada"
