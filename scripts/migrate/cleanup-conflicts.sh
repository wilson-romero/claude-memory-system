#!/usr/bin/env bash
# cleanup-conflicts.sh — quarantine sync-conflict artifacts (..pathN,
# .sync-conflict-*) into <vault>/Memoria/Archivo/conflictos/.
# Non-destructive: files are moved, never deleted. Prints what it did.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

DEST="${MEMORIA_VAULT_ROOT}/Memoria/Archivo/conflictos"
mkdir -p "$DEST"

FOUND=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "quarantine: $f"
  mv -f "$f" "$DEST/"
  FOUND=$((FOUND + 1))
done < <(find "$MEMORIA_VAULT_ROOT" \
          -path "$DEST" -prune -o \
          -path "*/.obsidian" -prune -o \
          -type f \( -name "*..path[0-9]*" -o -name "*.sync-conflict-*" \) -print 2>/dev/null)

echo "conflicts quarantined: $FOUND"
