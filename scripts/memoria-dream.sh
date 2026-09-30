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

# The child gets no Bash at all. It used to have Bash(mv:*) to retire files,
# but a prefix rule cannot bound the DESTINATION: `mv <vault>/x.md ~/.bashrc`
# matches it. Moves are REQUESTED in a manifest and applied below by
# apply_dream_moves, which only accepts curated-zone → Memoria/Archivo/.
MOVES_FILE="${ARCHIVE_DIR}/_mover.txt"
rm -f "$MOVES_FILE"
vault_only_claude_args
cd "$MEMORIA_VAULT_ROOT"
if timeout 600 "$CLAUDE_BIN" -p "$PROMPT" \
    --model claude-sonnet-5 \
    "${HEADLESS_ARGS[@]}" \
    </dev/null >> "$MEMORIA_LOG" 2>&1; then
  log "dream: phase 2 done"
else
  log "dream: phase 2 failed or timed out (will retry next night)"
fi

# ── Apply the moves phase 2 requested ─────────────────────────────────────────
# Validation is the point: source must be a regular file (not a symlink) in a
# curated zone, destination a new .md under Memoria/Archivo/, both resolved
# without symlinks, at most 10 per night (the prompt's own limit).
if [ -f "$MOVES_FILE" ]; then
  MOVES_RESULT=$(python3 - "$MEMORIA_VAULT_ROOT" "$MOVES_FILE" <<'PYEOF'
import os, sys
vault = os.path.realpath(sys.argv[1])
archive = os.path.join(vault, "Memoria", "Archivo")
zones = ("Memoria", "Memoria-CC", "Lecciones", "Decisiones")
done = 0

def inside(path, root):
    return os.path.commonpath([path, root]) == root

for raw in open(sys.argv[2], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split(" => ")
    if len(parts) != 2:
        print(f"REJECTED (formato): {line}")
        continue
    src_rel, dst_rel = (p.strip() for p in parts)
    src = os.path.join(vault, src_rel)
    dst = os.path.normpath(os.path.join(vault, dst_rel))
    src_real = os.path.realpath(src)
    reason = None
    if done >= 10:
        reason = "límite de 10 movimientos"
    elif os.path.isabs(src_rel) or os.path.isabs(dst_rel):
        reason = "ruta absoluta"
    elif os.path.islink(src) or not os.path.isfile(src):
        reason = "el origen no es un archivo regular"
    elif not inside(src_real, vault) or os.path.relpath(src_real, vault).split(os.sep)[0] not in zones:
        reason = "origen fuera de las zonas curadas"
    elif inside(src_real, archive):
        reason = "el origen ya está archivado"
    elif not dst.endswith(".md") or not inside(dst, archive) or dst == archive:
        reason = "destino fuera de Memoria/Archivo/"
    elif not inside(os.path.realpath(os.path.dirname(dst)), archive):
        reason = "el destino atraviesa un enlace simbólico"
    elif os.path.lexists(dst):
        reason = "el destino ya existe"
    if reason:
        print(f"REJECTED ({reason}): {line}")
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.rename(src_real, dst)
    done += 1
    print(f"MOVED: {src_rel} => {os.path.relpath(dst, vault)}")
PYEOF
  )
  rm -f "$MOVES_FILE"
  while IFS= read -r line; do [ -n "$line" ] && log "dream: $line"; done <<< "$MOVES_RESULT"
  printf '\n### Movimientos aplicados por el script\n\n```\n%s\n```\n' \
    "${MOVES_RESULT:-(ninguno)}" >> "$REPORT"
fi

state_set LAST_DREAM "$TODAY"
exit 0
