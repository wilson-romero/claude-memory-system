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

# --conflict-resolve / --conflict-loser / --resilient need rclone >= 1.66.
# Debian/Ubuntu ship 1.60 in /usr/bin, so prefer a newer build if one exists and
# fail loudly instead of letting bisync die on "unknown flag" every 5 minutes.
RCLONE_BIN="${MEMORIA_RCLONE:-}"
if [ -z "$RCLONE_BIN" ]; then
    for cand in /usr/local/bin/rclone "$(command -v rclone 2>/dev/null)"; do
        [ -x "$cand" ] || continue
        RCLONE_BIN="$cand"
        break
    done
fi
if [ -z "$RCLONE_BIN" ]; then
    echo "[$(date -Iseconds)] ERROR: rclone not found" >> "$LOG_FILE"
    exit 1
fi
RCLONE_VER=$("$RCLONE_BIN" version 2>/dev/null | head -1 | sed 's/rclone v//')
if [ "$(printf '%s\n1.66.0\n' "$RCLONE_VER" | sort -V | head -1)" != "1.66.0" ]; then
    echo "[$(date -Iseconds)] ERROR: ${RCLONE_BIN} is v${RCLONE_VER}; this script needs >= 1.66 for --conflict-resolve/--resilient. Install a newer rclone (https://rclone.org/install/) or set MEMORIA_RCLONE." >> "$LOG_FILE"
    exit 1
fi

# Prevent concurrent syncs (manual run vs systemd timer).
# The lock holds the owner PID: `trap EXIT` does NOT run on SIGKILL or an OOM
# kill, so a plain -f test would let one hard death silence every later run
# ("sync already running") while systemd kept seeing exit 0 — the same
# die-in-green failure this script already had with rclone's --resilient.
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "[$(date -Iseconds)] sync already running (pid $lock_pid), skipping" >> "$LOG_FILE"
        exit 0
    fi
    echo "[$(date -Iseconds)] stale lock from pid ${lock_pid:-unknown}, taking over" >> "$LOG_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "[$(date -Iseconds)] starting sync ($VAULT_LOCAL <-> $VAULT_REMOTE)" >> "$LOG_FILE"

"$RCLONE_BIN" bisync "$VAULT_LOCAL" "$VAULT_REMOTE" \
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
