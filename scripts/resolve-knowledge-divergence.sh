#!/usr/bin/env bash
# resolve-knowledge-divergence.sh — apply the divergences that need no judgement,
# and print the ones that do.
#
# Mechanical (applied): one side's content contains the other's WHOLE. Copying
# the larger over the smaller cannot lose a line. Everything else is left alone.
#
# Judgement (printed, never touched): both sides carry lines the other lacks.
# On 2026-07-29 six such files were better on one machine and one on the other,
# so there is no safe direction to pick automatically.
#
# Default is a DRY RUN. Pass --apply to write, which also takes a backup first.
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

MEMORIA_ENV="${MEMORIA_ENV:-$HOME/.claude/memoria.env}"
# shellcheck disable=SC1090
[ -f "$MEMORIA_ENV" ] && source "$MEMORIA_ENV"

VAULT="${MEMORIA_VAULT_ROOT:?MEMORIA_VAULT_ROOT not set}"
HUB="${MEMORIA_KNOWLEDGE_REMOTE:?MEMORIA_KNOWLEDGE_REMOTE not set}"
FOLDERS=(Lecciones Memoria-CC Decisiones)
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$HOME/.local/state/knowledge-resolve-$STAMP"

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

strip() {
    grep -vE '^[[:space:]]*(modified|updated|created|originSessionId|machine):' "$1" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | sort
}

echo "===== RESOLUCION de divergencias ====="
echo "maquina : $(hostname)"
echo "fecha   : $(date -Iseconds)"
[ "$APPLY" -eq 1 ] && echo "modo    : APLICAR (respaldo en $BACKUP)" || echo "modo    : SIMULACRO (nada se escribe; usa --apply)"
echo

n_pull=0; n_push=0; n_conf=0
CONFLICTS="$TMP/conflicts.txt"
: > "$CONFLICTS"

for d in "${FOLDERS[@]}"; do
    list="$TMP/$d.list"
    (cd "$VAULT" && rclone check "$d" "$HUB/$d" \
        --exclude "_INDEX.md" --exclude "MEMORY*.md" --one-way 2>&1) \
        | grep -oE 'ERROR : [^:]+' | sed 's/ERROR : //' | sort -u > "$list"
    [ -s "$list" ] || continue

    mkdir -p "$TMP/hub/$d"
    rclone copy "$HUB/$d" "$TMP/hub/$d" --files-from "$list" >/dev/null 2>&1

    pull="$TMP/$d.pull"; push="$TMP/$d.push"
    : > "$pull"; : > "$push"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        lf="$VAULT/$d/$f"; hf="$TMP/hub/$d/$f"
        [ -f "$hf" ] || { echo "$f" >> "$push"; n_push=$((n_push+1)); continue; }
        ol=$(comm -23 <(strip "$lf") <(strip "$hf") | wc -l)
        oh=$(comm -13 <(strip "$lf") <(strip "$hf") | wc -l)
        if   [ "$oh" -eq 0 ] && [ "$ol" -gt 0 ]; then echo "$f" >> "$push"; n_push=$((n_push+1))
        elif [ "$ol" -eq 0 ] && [ "$oh" -gt 0 ]; then echo "$f" >> "$pull"; n_pull=$((n_pull+1))
        elif [ "$ol" -gt 0 ] && [ "$oh" -gt 0 ]; then
            n_conf=$((n_conf+1))
            {
                echo "### $d/$f  (+$ol solo aqui / -$oh solo en el hub)"
                echo "--- lineas que SOLO tiene esta maquina:"
                comm -23 <(strip "$lf") <(strip "$hf") | cut -c1-160 | head -8
                echo "--- lineas que SOLO tiene el hub:"
                comm -13 <(strip "$lf") <(strip "$hf") | cut -c1-160 | head -8
                echo
            } >> "$CONFLICTS"
        fi
    done < "$list"

    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$BACKUP/$d"
        # Back up every file about to be overwritten, in both directions.
        while IFS= read -r f; do [ -n "$f" ] && cp "$VAULT/$d/$f" "$BACKUP/$d/" 2>/dev/null; done < "$pull"
        while IFS= read -r f; do [ -n "$f" ] && cp "$TMP/hub/$d/$f" "$BACKUP/$d/" 2>/dev/null; done < "$push"
        [ -s "$pull" ] && rclone copy "$HUB/$d" "$VAULT/$d" --files-from "$pull" >/dev/null 2>&1
        [ -s "$push" ] && (cd "$VAULT" && rclone copy "$d" "$HUB/$d" --files-from "$push" >/dev/null 2>&1)
    fi
done

echo "MECANICOS"
echo "  bajar del hub (el hub contiene entera a la local): $n_pull"
echo "  subir al hub  (la local contiene entera a la del hub): $n_push"
[ "$APPLY" -eq 1 ] && echo "  -> APLICADOS. Respaldo de lo sobrescrito: $BACKUP"
echo
echo "CONFLICTOS QUE NECESITAN CRITERIO: $n_conf"
echo "(nada de esto se ha tocado)"
echo
cat "$CONFLICTS"
echo "===== FIN ====="
