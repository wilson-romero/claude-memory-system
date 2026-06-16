#!/bin/bash
# Bidirectional sync between the local Obsidian vault and a cloud remote (rclone).
# Only used on machines with MEMORIA_SYNC=rclone (e.g. PC-WILSON → Google Drive).
#
# Conflict policy (prevents *.conflict1/2 files piling up in the vault):
#   --conflict-resolve newer  → the newer file wins and keeps the canonical name
#   --conflict-loser delete   → the loser is removed from the vault, but preserved
#                               in the --backup-dir locations (no data loss)
set -euo pipefail

# Load per-machine config (installed by install.sh)
[ -f "$HOME/.claude/memoria.env" ] && source "$HOME/.claude/memoria.env"

# VAULT_LOCAL is the parent that holds the Obsidian vault root (MEMORIA_VAULT_ROOT
# points at .../Claude; rclone syncs the whole vault tree above it).
VAULT_LOCAL="${MEMORIA_SYNC_LOCAL:-$(dirname "${MEMORIA_VAULT_ROOT:-$HOME/vault/Claude}")}"
VAULT_REMOTE="${MEMORIA_SYNC_REMOTE:-gdrive:Obsidian}"
LOG_FILE="${MEMORIA_SYNC_LOG:-$HOME/.local/log/obsidian-sync.log}"
LOCK_FILE="/tmp/obsidian-sync.lock"

mkdir -p "$(dirname "$LOG_FILE")"

# Prevent concurrent syncs (manual run vs systemd timer)
if [ -f "$LOCK_FILE" ]; then
    echo "[$(date -Iseconds)] sync already running, skipping" >> "$LOG_FILE"
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "[$(date -Iseconds)] starting sync ($VAULT_LOCAL <-> $VAULT_REMOTE)" >> "$LOG_FILE"

rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" \
    --create-empty-src-dirs \
    --compare size,modtime,checksum \
    --resilient \
    --conflict-resolve newer \
    --conflict-loser delete \
    --backup-dir1 "$HOME/.local/state/obsidian-sync-conflicts" \
    --backup-dir2 "${VAULT_REMOTE%%:*}:Obsidian-sync-conflicts" \
    --log-level INFO \
    --log-file "$LOG_FILE" \
    2>> "$LOG_FILE"

echo "[$(date -Iseconds)] sync done" >> "$LOG_FILE"
