#!/usr/bin/env bash
# memoria-capture.sh — Claude Code Stop hook (deterministic capture layer).
# Reads session JSON from stdin, writes session/project/daily notes and
# regenerates indexes in the Obsidian vault. Never blocks the session:
# any failure exits 0.
# Ported from BOGWROMEROCA's obsidian-sync.sh with fixes:
#   - slug bug: ~/.claude/projects/ lookups now use cc_slug (leading dash)
#   - atomic writes (tmp + mv) to avoid sync conflicts
#   - per-machine config via ~/.claude/memoria.env
set -uo pipefail
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_config

VAULT_ROOT="$MEMORIA_VAULT_ROOT"
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"

# Claude Code delivers the hook payload as a single JSON line but does NOT always
# close the pipe afterwards. `$(cat)` waits for EOF, so on the Stop event it blocked
# until the 30s hook timeout killed the script — 39 runs in a row died here without
# writing anything, which is why session capture kept coming out empty.
#
# `read -t` returns as soon as the line arrives and is bounded when the pipe stays
# open. On timeout bash still assigns whatever it read, so `|| true` keeps the data
# instead of discarding it.
IFS= read -r -t 5 HOOK_INPUT || true

SESSION_ID=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null || echo "unknown")
CWD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || echo "")

[ -z "$CWD" ] && CWD="$HOME"

# Never capture sessions whose cwd is inside the vault itself —
# they create recursive noise folders (e.g. projects/home-mark-vault-Claude).
OBSIDIAN_TREE="$(dirname "$MEMORIA_VAULT_ROOT")"
case "$CWD" in
  "$OBSIDIAN_TREE"*)
    log "capture: skipped (cwd inside vault tree: $CWD)"
    exit 0
    ;;
esac

PROJECT_SLUG=$(vault_slug "$CWD")
CC_PROJECT_SLUG=$(cc_slug "$CWD")

PROJECT_DISPLAY=$(echo "$CWD" | awk -F/ '{n=NF; if(n>=2) print $(n-1)"/"$n; else print $n}')
[ -z "$PROJECT_DISPLAY" ] && PROJECT_DISPLAY="home/mark"

DATE_SLUG=$(date '+%Y-%m-%d')
TIME_SLUG=$(date '+%H%M%S')
DATETIME_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

SESSION_DIR="${VAULT_ROOT}/projects/${PROJECT_SLUG}/sessions"
PROJECT_NOTE="${VAULT_ROOT}/projects/${PROJECT_SLUG}/_project.md"
SESSION_NOTE="${SESSION_DIR}/${DATE_SLUG}-${TIME_SLUG}.md"
DAILY_NOTE="${VAULT_ROOT}/daily/${DATE_SLUG}.md"
INDEX_NOTE="${VAULT_ROOT}/_index.md"
AGENTS_DIR="${VAULT_ROOT}/agents/skills"
AGENTS_INDEX="${VAULT_ROOT}/agents/_skills-index.md"

mkdir -p "${SESSION_DIR}" "${VAULT_ROOT}/daily" "${AGENTS_DIR}"

# ── Parse transcript JSONL ────────────────────────────────────────────────────
PARSE_RESULT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  PARSE_RESULT=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import sys, json
from collections import Counter

transcript_path = sys.argv[1]
user_msgs = []
assistant_final = ""
assistant_messages = []
tool_uses = []
files_touched = set()
agent_invocations = []

try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg = entry.get("message", {})
            role = msg.get("role", "")
            content = msg.get("content", [])

            if role == "user":
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_result":
                            continue
                        if isinstance(block, str):
                            user_msgs.append(block[:300])
                        elif isinstance(block, dict) and block.get("type") == "text":
                            user_msgs.append(block.get("text", "")[:300])
                elif isinstance(content, str):
                    user_msgs.append(content[:300])

            elif role == "assistant":
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            t = block.get("text", "")
                            if t.strip():
                                assistant_messages.append(t)
                                assistant_final = t
                        elif block.get("type") == "tool_use":
                            tool_name = block.get("name", "")
                            tool_uses.append(tool_name)
                            inp = block.get("input", {})
                            if isinstance(inp, dict):
                                for fkey in ("file_path", "path", "notebook_path"):
                                    if fkey in inp:
                                        files_touched.add(inp[fkey])
                                if tool_name in ("Agent", "Task"):
                                    agent_invocations.append({
                                        "subagent_type": inp.get("subagent_type", "general-purpose"),
                                        "description": inp.get("description", ""),
                                        "prompt_snippet": (inp.get("prompt", "")[:200] if isinstance(inp.get("prompt"), str) else "")
                                    })

except Exception as e:
    print(f"ERROR_PARSE: {e}")
    sys.exit(0)

goal = user_msgs[0] if user_msgs else "(sin prompts registrados)"
print(f"GOAL<<HEREDOC_END\n{goal}\nHEREDOC_END")

files_list = "\n".join(f"- `{f}`" for f in sorted(files_touched)) if files_touched else ""
print(f"FILES<<HEREDOC_END\n{files_list}\nHEREDOC_END")

tools_str = ", ".join(f"{t}×{c}" for t, c in Counter(tool_uses).most_common(7)) if tool_uses else ""
print(f"TOOLS<<HEREDOC_END\n{tools_str}\nHEREDOC_END")

snippet = (assistant_final[:600].replace("\n", " ") + "…") if assistant_final else ""
print(f"SNIPPET<<HEREDOC_END\n{snippet}\nHEREDOC_END")

learnings = []
for msg in assistant_messages:
    for line in msg.split("\n"):
        lower = line.lower()
        if any(kw in lower for kw in ["aprendiz", "lección", "important", "clave", "recomend", "mejor práctica", "nota:", "tener en cuenta", "considerar"]):
            cleaned = line.strip("# -•*").strip()
            if len(cleaned) > 20:
                learnings.append(cleaned[:200])
learnings_text = "\n".join(f"- {l}" for l in learnings[:10]) if learnings else ""
print(f"LEARNINGS<<HEREDOC_END\n{learnings_text}\nHEREDOC_END")

print(f"AGENTS_JSON<<HEREDOC_END\n{json.dumps(agent_invocations)}\nHEREDOC_END")
PYEOF
  ) 2>/dev/null || PARSE_RESULT=""
fi

extract_block() {
  local key="$1"
  echo "$PARSE_RESULT" | python3 -c "
import sys
content = sys.stdin.read()
key = '$key'
start = content.find(key + '<<HEREDOC_END\n')
if start == -1:
    print('')
    sys.exit(0)
start += len(key) + len('<<HEREDOC_END\n')
end = content.find('\nHEREDOC_END', start)
print(content[start:] if end == -1 else content[start:end])
" 2>/dev/null || echo ""
}

GOAL=$(extract_block "GOAL")
FILES=$(extract_block "FILES")
TOOLS=$(extract_block "TOOLS")
SNIPPET=$(extract_block "SNIPPET")
LEARNINGS=$(extract_block "LEARNINGS")
AGENTS_JSON=$(extract_block "AGENTS_JSON")

# ── Project memory files (FIX: use Claude Code's real slug, leading dash) ─────
MEMORY_CONTENT=""
MEMORY_DIR="${CLAUDE_PROJECTS_DIR}/${CC_PROJECT_SLUG}/memory"
if [ -d "$MEMORY_DIR" ]; then
  for mfile in "${MEMORY_DIR}"/*.md; do
    [ -f "$mfile" ] || continue
    MEMORY_CONTENT+="### $(basename "$mfile")
$(cat "$mfile")

"
  done
fi

# ── Git state ─────────────────────────────────────────────────────────────────
GIT_BRANCH=""
GIT_STATUS=""
GIT_LOG=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "unknown")
  GIT_STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -20 || echo "")
  GIT_LOG=$(git -C "$CWD" log --oneline -5 2>/dev/null || echo "")
fi

# ── Session note (atomic) ─────────────────────────────────────────────────────
atomic_write "${SESSION_NOTE}" <<MDEOF
---
type: session
machine: ${MEMORIA_MACHINE}
session_id: ${SESSION_ID}
project: ${PROJECT_DISPLAY}
project_slug: ${PROJECT_SLUG}
created: ${DATE_SLUG}
updated: ${DATE_SLUG}
tags:
  - claude-code
  - ${PROJECT_SLUG}
---

# Sesión ${DATETIME_HUMAN}

**Proyecto:** [[projects/${PROJECT_SLUG}/_project|${PROJECT_DISPLAY}]]

## Objetivo de la sesión
${GOAL:-*(no registrado)*}

## Archivos tocados
${FILES:-*(ninguno detectado)*}

## Herramientas usadas
${TOOLS:-*(no detectadas)*}

## Último mensaje de Claude (fragmento)
${SNIPPET:-*(no disponible)*}

## Aprendizajes y lecciones
${LEARNINGS:-*(no se detectaron aprendizajes explícitos en esta sesión)*}

## Estado git
**Branch:** ${GIT_BRANCH:-*(no es repositorio git)*}

\`\`\`
${GIT_STATUS}
\`\`\`

**Últimos commits:**
\`\`\`
${GIT_LOG}
\`\`\`

## Metadatos
- Session ID: \`${SESSION_ID}\`
- Transcript: \`${TRANSCRIPT_PATH}\`
MDEOF

# ── Project note (atomic) ─────────────────────────────────────────────────────
SESSION_HISTORY=$(ls -1t "${SESSION_DIR}"/*.md 2>/dev/null | head -10 | while read -r f; do
  fname=$(basename "$f" .md)
  echo "- [[projects/${PROJECT_SLUG}/sessions/${fname}|${fname}]]"
done)

atomic_write "${PROJECT_NOTE}" <<MDEOF
---
type: project
machine: ${MEMORIA_MACHINE}
project: ${PROJECT_DISPLAY}
project_slug: ${PROJECT_SLUG}
updated: ${DATE_SLUG}
tags:
  - claude-code
  - proyecto
---

# Proyecto: ${PROJECT_DISPLAY}

**Path:** \`${CWD}\`
**Última sesión:** [[projects/${PROJECT_SLUG}/sessions/${DATE_SLUG}-${TIME_SLUG}|${DATETIME_HUMAN}]]

## Memoria de Claude Code
${MEMORY_CONTENT:-*(sin archivos de memoria del proyecto)*}

## Historial de sesiones
${SESSION_HISTORY:-*(sin sesiones previas)*}
MDEOF

# ── Daily note ────────────────────────────────────────────────────────────────
if [ ! -f "${DAILY_NOTE}" ]; then
  atomic_write "${DAILY_NOTE}" <<MDEOF
---
type: daily
machine: ${MEMORIA_MACHINE}
created: ${DATE_SLUG}
updated: ${DATE_SLUG}
tags:
  - claude-code
  - diario
---

# Sesiones Claude Code — ${DATE_SLUG}

## Sesiones del día

## Aprendizajes del día

MDEOF
fi

SESSION_LINE="- ${TIME_SLUG} [[projects/${PROJECT_SLUG}/sessions/${DATE_SLUG}-${TIME_SLUG}|${PROJECT_DISPLAY}]] — ${GOAL:0:80}"
python3 - "${DAILY_NOTE}" "${SESSION_LINE}" <<'PYEOF'
import sys
path, new_line = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
marker = "## Aprendizajes del día"
if marker in content:
    content = content.replace(marker, f"{new_line}\n\n{marker}")
else:
    content += f"\n{new_line}\n"
with open(path, "w") as f:
    f.write(content)
PYEOF

if [ -n "$LEARNINGS" ]; then
  python3 - "${DAILY_NOTE}" "$LEARNINGS" "$PROJECT_DISPLAY" <<'PYEOF'
import sys
path, learnings, project = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
section = f"\n### {project}\n{learnings}\n"
marker = "## Aprendizajes del día"
if marker in content:
    idx = content.find(marker) + len(marker)
    content = content[:idx] + section + content[idx:]
with open(path, "w") as f:
    f.write(content)
PYEOF
fi

# ── Agents knowledge bank ─────────────────────────────────────────────────────
if [ -n "$AGENTS_JSON" ] && [ "$AGENTS_JSON" != "[]" ]; then
  python3 - "${AGENTS_DIR}" "${AGENTS_JSON}" "${DATE_SLUG}" "${PROJECT_DISPLAY}" "${MEMORIA_MACHINE}" <<'PYEOF'
import sys, json, os

agents_dir, agents_json, date_slug, project_display, machine = sys.argv[1:6]

try:
    invocations = json.loads(agents_json)
except Exception:
    sys.exit(0)

by_type = {}
for inv in invocations:
    by_type.setdefault(inv.get("subagent_type", "general-purpose"), []).append(inv)

for agent_type, uses in by_type.items():
    agent_file = os.path.join(agents_dir, f"{agent_type}.md")
    if not os.path.exists(agent_file):
        with open(agent_file, "w") as f:
            f.write(f"""---
type: reference
machine: {machine}
agent_type: {agent_type}
created: {date_slug}
updated: {date_slug}
tags:
  - claude-code
  - agente
---

# Agente: {agent_type}

## Descripción
*(se completa con el uso registrado abajo)*

## Historial de uso

""")
    with open(agent_file, "a") as f:
        f.write(f"\n### {date_slug} — {project_display}\n")
        for i, use in enumerate(uses, 1):
            desc = use.get("description", "")
            snippet = use.get("prompt_snippet", "")
            f.write(f"- **Tarea {i}** ({use.get('subagent_type','')}): {desc}\n")
            if snippet:
                f.write(f"  - Prompt: `{snippet[:120]}…`\n")
        f.write("\n")
PYEOF
fi

# ── Regenerate agents index (atomic) ──────────────────────────────────────────
{
  echo "---"
  echo "type: reference"
  echo "machine: ${MEMORIA_MACHINE}"
  echo "updated: ${DATE_SLUG}"
  echo "tags:"
  echo "  - claude-code"
  echo "  - agentes"
  echo "---"
  echo ""
  echo "# Banco de Conocimiento — Agentes y Skills"
  echo ""
  echo "| Agente | Usos registrados | Última sesión |"
  echo "|--------|-----------------|---------------|"
  for afile in "${AGENTS_DIR}"/*.md; do
    [ -f "$afile" ] || continue
    aname=$(basename "$afile" .md)
    uses=$(grep -c "^### " "$afile" 2>/dev/null || echo 0)
    last=$(grep "^### " "$afile" 2>/dev/null | tail -1 | sed 's/^### //' || echo "-")
    echo "| [[agents/skills/${aname}\\|${aname}]] | ${uses} | ${last} |"
  done
} | atomic_write "${AGENTS_INDEX}"

# ── Regenerate main index (atomic) ────────────────────────────────────────────
{
  echo "---"
  echo "type: reference"
  echo "machine: ${MEMORIA_MACHINE}"
  echo "updated: ${DATE_SLUG}"
  echo "tags:"
  echo "  - claude-code"
  echo "  - index"
  echo "---"
  echo ""
  echo "# Claude Code — Índice de Conocimiento (${MEMORIA_MACHINE})"
  echo ""
  echo "## Sesiones recientes"
  find "${VAULT_ROOT}/projects" -name "*.md" ! -name "_project.md" \
    -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -10 | while read -r _ fpath; do
    rel="${fpath#"${VAULT_ROOT}"/}"
    fname=$(basename "$fpath" .md)
    echo "- [[${rel%.md}|${fname}]]"
  done || true
  echo ""
  echo "## Proyectos activos"
  for pdir in "${VAULT_ROOT}/projects"/*/; do
    [ -d "$pdir" ] || continue
    pname=$(basename "$pdir")
    session_count=$(find "${pdir}sessions" -name '*.md' 2>/dev/null | wc -l || echo 0)
    echo "- [[projects/${pname}/_project|${pname}]] (${session_count} sesiones)"
  done
  echo ""
  echo "## Notas diarias recientes"
  ls -1t "${VAULT_ROOT}/daily/"*.md 2>/dev/null | head -7 | while read -r f; do
    fname=$(basename "$f" .md)
    echo "- [[daily/${fname}|${fname}]]"
  done || true
  echo ""
  echo "## Banco de agentes"
  echo "→ [[agents/_skills-index|Ver índice de agentes y skills]]"
} | atomic_write "${INDEX_NOTE}"

# Dated trace of the work DONE (the note exists), not of the attempt. The
# SessionStart watchdog compares this against the sessions it has counted, so a
# capture that silently stops running is reported instead of going unnoticed.
state_set LAST_CAPTURE "$(date '+%Y-%m-%dT%H:%M:%S')"
state_set SESSIONS_SINCE_CAPTURE 0

log "capture: session ${SESSION_ID} → ${SESSION_NOTE}"
exit 0
