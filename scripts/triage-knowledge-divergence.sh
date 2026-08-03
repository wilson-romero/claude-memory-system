#!/usr/bin/env bash
# triage-knowledge-divergence.sh — classify the files whose content differs
# between this vault and the shared knowledge hub. READ-ONLY: it downloads hub
# copies to a temp dir and prints a report. It never writes to the vault or the
# hub, and never resolves anything.
#
# Why this exists: the union is `rclone copy --ignore-existing`, which adds
# files and NEVER propagates an edit to a file that already exists on the other
# side. So two machines converge on the same file NAMES and can still drift
# apart in content — 10 files on 2026-07-29, 44 by 2026-08-03.
#
# Why it does not fix them: the correct direction changes per file. On
# 2026-07-29 six files were better on one machine and one on the other, so a
# bulk copy either way would have destroyed knowledge. This tool measures what
# each side contributes and leaves the decision to a human.
#
# The `modified:` frontmatter line is ignored: it differs on every edited file
# and says nothing about content.
set -uo pipefail

MEMORIA_ENV="${MEMORIA_ENV:-$HOME/.claude/memoria.env}"
# shellcheck disable=SC1090
[ -f "$MEMORIA_ENV" ] && source "$MEMORIA_ENV"

VAULT="${MEMORIA_VAULT_ROOT:?MEMORIA_VAULT_ROOT not set}"
HUB="${MEMORIA_KNOWLEDGE_REMOTE:?MEMORIA_KNOWLEDGE_REMOTE not set}"
FOLDERS=(Lecciones Memoria-CC Decisiones)

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# Content lines only: drop the frontmatter timestamp and blank lines.
strip() { grep -v '^  *modified:' "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | sort; }

n_local=0; n_hub=0; n_conflict=0
echo "===== TRIAJE de divergencias con el hub ====="
echo "maquina : $(hostname)"
echo "fecha   : $(date -Iseconds)"
echo "hub     : $HUB"
echo

for d in "${FOLDERS[@]}"; do
    # rclone check names every file that differs or is missing on the far side.
    list="$TMP/$d.list"
    (cd "$VAULT" && rclone check "$d" "$HUB/$d" \
        --exclude "_INDEX.md" --exclude "MEMORY*.md" --one-way 2>&1) \
        | grep -oE 'ERROR : [^:]+' | sed 's/ERROR : //' | sort -u > "$list"

    count=$(wc -l < "$list")
    echo "--- $d: $count fichero(s) que difieren ---"
    [ "$count" -eq 0 ] && { echo; continue; }

    # One transfer for the whole folder rather than one call per file: Drive
    # answers a burst of requests with 403 rateLimitExceeded.
    mkdir -p "$TMP/hub/$d"
    rclone copy "$HUB/$d" "$TMP/hub/$d" --files-from "$list" >/dev/null 2>&1

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        lf="$VAULT/$d/$f"
        hf="$TMP/hub/$d/$f"
        if [ ! -f "$hf" ]; then
            printf '  %-11s %s (no esta en el hub)\n' "SOLO-LOCAL" "$f"
            n_local=$((n_local + 1)); continue
        fi
        only_local=$(comm -23 <(strip "$lf") <(strip "$hf") | wc -l)
        only_hub=$(comm -13 <(strip "$lf") <(strip "$hf") | wc -l)

        if   [ "$only_hub" -eq 0 ]  && [ "$only_local" -gt 0 ]; then
            verdict="LOCAL-GANA"; n_local=$((n_local + 1))
        elif [ "$only_local" -eq 0 ] && [ "$only_hub" -gt 0 ]; then
            verdict="HUB-GANA";   n_hub=$((n_hub + 1))
        elif [ "$only_local" -eq 0 ] && [ "$only_hub" -eq 0 ]; then
            verdict="SOLO-FECHA"  # differs only in the ignored metadata
        else
            verdict="CONFLICTO";  n_conflict=$((n_conflict + 1))
        fi
        printf '  %-11s +%-4s -%-4s %s\n' "$verdict" "$only_local" "$only_hub" "$f"
    done < "$list"
    echo
done

echo "===== RESUMEN ====="
echo "LOCAL-GANA : $n_local   (la copia de esta maquina contiene entera a la del hub)"
echo "HUB-GANA   : $n_hub     (la del hub contiene entera a la local)"
echo "CONFLICTO  : $n_conflict   (cada lado aporta lineas que el otro no tiene — decide una persona)"
echo
echo "Lectura: +N = lineas que solo tiene esta maquina, -N = solo el hub."
echo "Este informe NO resuelve nada. Nada se ha escrito."
echo "===== FIN ====="
