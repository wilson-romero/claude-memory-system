#!/usr/bin/env bash
# memoria-dream.sh — nightly "sleep" consolidation for the memory vault.
# Phase 1 (deterministic, no tokens): repair [[links]], detect orphans and
#   duplicate candidates, quarantine sync-conflict files, audit MEMORY.md.
# Phase 2 (semantic, claude -p headless): merge duplicates, compact old
#   context, archive irrelevant content (never delete), improve the index.
# Writes an auditable report to <vault>/Memoria/Suenos/YYYY-MM-DD.md.
# Usage: memoria-dream.sh [--force] [--phase1-only]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
load_config

FORCE=0
PHASE1_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --phase1-only) PHASE1_ONLY=1 ;;
  esac
done

TODAY=$(date '+%Y-%m-%d')
REPORT_DIR="${MEMORIA_VAULT_ROOT}/Memoria/Suenos"
REPORT="${REPORT_DIR}/${TODAY}.md"
ARCHIVE_DIR="${MEMORIA_VAULT_ROOT}/Memoria/Archivo"
mkdir -p "$REPORT_DIR" "$ARCHIVE_DIR/conflictos"

# ── Single instance ───────────────────────────────────────────────────────────
# The "already ran today" test below is a check-then-act, not a guard. On
# 2026-09-15 four dreams read "no report yet" within the same four seconds
# (08:22:54 - 08:25:59), all four passed it, and all four paid for phase 2:
# 49% of the day's token quota spent four times on the same consolidation.
# Losing this race is the normal outcome, not a failure — another dream is
# doing exactly this work — so it exits 0 without waiting.
DREAM_LOCK="$HOME/.claude/memoria-dream.lock"
exec 8>"$DREAM_LOCK"
if ! flock -n 8; then
  log "dream: another dream already holds the lock, skipping"
  exit 0
fi

# ── Skip if no activity since last dream (unless --force) ─────────────────────
LAST_DREAM=$(state_get LAST_DREAM)
if [ "$FORCE" -eq 0 ] && [ -n "$LAST_DREAM" ]; then
  NEWER=$(find "${MEMORIA_VAULT_ROOT}/daily" "${MEMORIA_VAULT_ROOT}/projects" \
    -name '*.md' -newermt "$LAST_DREAM" 2>/dev/null | head -1)
  if [ -z "$NEWER" ]; then
    log "dream: no activity since ${LAST_DREAM}, skipping"
    exit 0
  fi
fi
if [ -f "$REPORT" ] && [ "$FORCE" -eq 0 ]; then
  log "dream: already ran today (${REPORT}), skipping"
  exit 0
fi

# Claimed BEFORE the work, not after it. memoria-load.sh (SessionStart) launches
# a dream whenever LAST_DREAM is not today; while the stamp waited for phase 2 to
# finish, every session opened in those ~10 minutes launched one more.
state_set LAST_DREAM "$TODAY"

log "dream: starting (phase 1)"

# ── Phase 1: deterministic repair ─────────────────────────────────────────────
FINDINGS=$(python3 - "$MEMORIA_VAULT_ROOT" "$ARCHIVE_DIR" "$MEMORIA_MACHINE" <<'PYEOF'
import sys, os, re, shutil, difflib
from datetime import datetime

vault, archive_dir, machine = sys.argv[1], sys.argv[2], sys.argv[3]
report = {"fixed_links": [], "broken_links": [], "orphans": [],
          "duplicates": [], "conflicts_quarantined": [], "index_fixed": []}

# Raw data dirs are never modified by the dream
RAW_DIRS = (os.path.join(vault, "projects"), os.path.join(vault, "daily"))
SKIP_DIRS = {".obsidian", ".sync-conflicts", ".trash"}

md_files = {}   # relpath (no .md) -> abspath
for root, dirs, files in os.walk(vault):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for fn in files:
        if fn.endswith(".md"):
            ap = os.path.join(root, fn)
            rel = os.path.relpath(ap, vault)[:-3]
            md_files[rel] = ap

basenames = {}  # basename (no .md) -> [relpaths]
for rel in md_files:
    basenames.setdefault(os.path.basename(rel), []).append(rel)

# 1. Quarantine sync-conflict files (move, never delete)
for root, dirs, files in os.walk(vault):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not root.startswith(archive_dir)]
    for fn in files:
        if re.search(r"\.\.path\d+$", fn) or ".sync-conflict-" in fn:
            src = os.path.join(root, fn)
            dst = os.path.join(archive_dir, "conflictos", fn)
            try:
                shutil.move(src, dst)
                report["conflicts_quarantined"].append(os.path.relpath(src, vault))
            except Exception:
                pass

# 2. Repair broken [[links]] outside raw dirs (only unambiguous fixes)
link_re = re.compile(r"\[\[([^\]|#]+)(\|[^\]]*)?\]\]")
for rel, ap in list(md_files.items()):
    if any(ap.startswith(rd) for rd in RAW_DIRS):
        continue
    try:
        with open(ap) as f:
            content = f.read()
    except Exception:
        continue
    changed = False
    def fix(m):
        global changed
        target = m.group(1).strip()
        alias = m.group(2) or ""
        if target.endswith("\\"):
            # table-escaped pipe ([[x\|alias]]) — not a broken link
            return m.group(0)
        if target in md_files or os.path.basename(target) in basenames:
            return m.group(0)
        cands = difflib.get_close_matches(os.path.basename(target), list(basenames), n=2, cutoff=0.85)
        if len(cands) == 1 and len(basenames[cands[0]]) == 1:
            new = basenames[cands[0]][0]
            report["fixed_links"].append(f"{rel}: [[{target}]] → [[{new}]]")
            changed = True
            return f"[[{new}{alias}]]"
        report["broken_links"].append(f"{rel}: [[{target}]]")
        return m.group(0)
    new_content = link_re.sub(fix, content)
    if changed and new_content != content:
        tmp = ap + ".tmp-dream"
        with open(tmp, "w") as f:
            f.write(new_content)
        os.replace(tmp, ap)

# 3. Index audit: dangling entries + files missing from the index.
#    The index is MEMORY.md *plus its branches* (MEMORY-<topic>.md): it outgrows the
#    context read limit and gets split, so a file indexed in a branch is NOT an orphan.
#    And a link is only dangling if the path it points at does not exist — most point
#    out of Memoria-CC (../Lecciones/...), so comparing paths against bare filenames
#    reports every one of them as dangling and invites the model to delete them.
mcc = os.path.join(vault, "Memoria-CC")
memory_md = os.path.join(mcc, "MEMORY.md")
if os.path.isdir(mcc) and os.path.isfile(memory_md):
    indexes = sorted(fn for fn in os.listdir(mcc)
                     if fn.startswith("MEMORY") and fn.endswith(".md"))
    linked = set()
    for fn in indexes:
        with open(os.path.join(mcc, fn)) as f:
            linked |= set(re.findall(r"\]\(<?([^)>]+\.md)>?\)", f.read()))
    actual = {fn for fn in os.listdir(mcc)
              if fn.endswith(".md") and fn not in indexes}
    for rel in sorted(linked):
        if not os.path.exists(os.path.join(mcc, rel)):
            report["index_fixed"].append(f"entrada colgante en el índice: {rel}")
    for fn in sorted(actual - linked):
        report["orphans"].append(f"Memoria-CC/{fn} (sin entrada en el índice)")

    # 4. Duplicate candidates by similar filename stems
    stems = sorted(actual)
    seen = set()
    for i, a in enumerate(stems):
        for b in stems[i+1:]:
            if (a, b) in seen:
                continue
            ratio = difflib.SequenceMatcher(None, a, b).ratio()
            if ratio > 0.72:
                report["duplicates"].append(f"Memoria-CC/{a} ~ Memoria-CC/{b} ({ratio:.0%})")
                seen.add((a, b))

for key, items in report.items():
    print(f"{key.upper()}:{len(items)}")
    for it in items[:30]:
        print(f"  - {it}")
PYEOF
) || FINDINGS="(phase 1 error)"

# ── Write phase-1 report ──────────────────────────────────────────────────────
atomic_write "$REPORT" <<MDEOF
---
type: reference
machine: ${MEMORIA_MACHINE}
created: ${TODAY}
updated: ${TODAY}
tags:
  - sueno
  - mantenimiento
---

# Sueño — ${TODAY}

## Fase 1: reparación determinista

\`\`\`
${FINDINGS}
\`\`\`

## Fase 2: consolidación semántica

*(pendiente)*
MDEOF

log "dream: phase 1 done"

if [ "$PHASE1_ONLY" -eq 1 ]; then
  state_set LAST_DREAM "$TODAY"
  exit 0
fi

# ── Phase 2: semantic consolidation via headless claude ───────────────────────
CLAUDE_BIN=$(find_claude)
if [ -z "$CLAUDE_BIN" ]; then
  log "dream: claude binary not found, phase 2 skipped"
  state_set LAST_DREAM "$TODAY"
  exit 0
fi

DREAM_PROMPT_FILE="$HOME/.claude/memoria-dream-prompt.md"
if [ ! -f "$DREAM_PROMPT_FILE" ]; then
  log "dream: rendered dream prompt missing, phase 2 skipped"
  state_set LAST_DREAM "$TODAY"
  exit 0
fi

PROMPT="$(cat "$DREAM_PROMPT_FILE")

## Hallazgos de la Fase 1 (entrada para tu trabajo)

${FINDINGS}

## Reporte a actualizar
${REPORT}
"

# disableAllHooks: without it this child fires the Stop hook when it finishes and
# spawns a full curator of its own. On 2026-09-15 that turned four dreams into
# four extra curators (20% of the quota) curating a session that was itself a
# memory job. MEMORIA_CURATOR_ACTIVE is the second belt, read by the curator's
# recursion guard. The curator has carried this flag since it went headless.
DREAM_CHILD_SETTINGS='{"disableAllHooks": true}'

cd "$MEMORIA_VAULT_ROOT"
if MEMORIA_CURATOR_ACTIVE=1 timeout 600 "$CLAUDE_BIN" -p "$PROMPT" \
    --model claude-sonnet-5 \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash(mv:*),Bash(ls:*)" \
    --settings "$DREAM_CHILD_SETTINGS" \
    >> "$MEMORIA_LOG" 2>&1; then
  log "dream: phase 2 done"
else
  log "dream: phase 2 failed or timed out (will retry next night)"
fi

state_set LAST_DREAM "$TODAY"
exit 0
