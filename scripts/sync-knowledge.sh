#!/usr/bin/env bash
# sync-knowledge.sh — keep the KNOWLEDGE folders identical across Wilson's two
# personal machines (mark-PC and PC-WILSON), without merging their vaults.
#
# Why not just point both machines at the same rclone remote: their session
# state legitimately differs (Memoria/contexto-reciente.md is 571 KB on one and
# 87 KB on the other, projects/ is 522 vs 195 files). A shared remote with
# --conflict-resolve newer would silently drop one side's curated files.
#
# Knowledge is different: one file = one lesson/reference, written once and
# rarely edited. So a two-way union with --ignore-existing is the correct
# semantics — it can only ever add, never overwrite or delete.
#
# Indexes (_INDEX.md, MEMORY.md) are excluded on purpose: they are curated
# summaries, not append-only artifacts, and must be merged by the curator.
set -uo pipefail

[ -f "$HOME/.claude/memoria.env" ] && source "$HOME/.claude/memoria.env"
# Peer config lives OUTSIDE the repo: it carries an IP, a user and an SSH port.
# install.sh writes memoria.env from the versioned machine config and would
# overwrite anything added there, so the peer goes in its own local file.
[ -f "$HOME/.claude/memoria.local.env" ] && source "$HOME/.claude/memoria.local.env"

VAULT="${MEMORIA_VAULT_ROOT:?MEMORIA_VAULT_ROOT not set}"
PEER="${MEMORIA_PEER:-}"                      # e.g. mark@192.168.1.11
PEER_PORT="${MEMORIA_PEER_PORT:-22}"
PEER_VAULT="${MEMORIA_PEER_VAULT:-}"          # e.g. ~/vault/Claude
LOG="${MEMORIA_KNOWLEDGE_LOG:-$HOME/.local/log/sync-knowledge.log}"
FOLDERS=(Lecciones Memoria-CC Decisiones)

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

if [ -z "$PEER" ] || [ -z "$PEER_VAULT" ]; then
    log "SKIP: MEMORIA_PEER/MEMORIA_PEER_VAULT not configured on this machine"
    exit 0
fi

SSH="ssh -p ${PEER_PORT} -o BatchMode=yes -o ConnectTimeout=8"

# The peer is a personal laptop/desktop: being off is normal, not an error.
if ! $SSH "$PEER" true 2>/dev/null; then
    log "peer ${PEER} unreachable — skipping (this is normal when it is off)"
    exit 0
fi

added_in=0
added_out=0
for d in "${FOLDERS[@]}"; do
    # Pull: peer → local. --ignore-existing means we never clobber local edits.
    out=$(rsync -a --ignore-existing --itemize-changes \
        --exclude '_INDEX.md' --exclude 'MEMORY.md' \
        -e "$SSH" "${PEER}:${PEER_VAULT}/${d}/" "${VAULT}/${d}/" 2>/dev/null | grep -c '^>f' || true)
    added_in=$((added_in + out))

    # Push: local → peer.
    out=$(rsync -a --ignore-existing --itemize-changes \
        --exclude '_INDEX.md' --exclude 'MEMORY.md' \
        -e "$SSH" "${VAULT}/${d}/" "${PEER}:${PEER_VAULT}/${d}/" 2>/dev/null | grep -c '^<f' || true)
    added_out=$((added_out + out))
done

log "union done: ${added_in} file(s) pulled from ${PEER}, ${added_out} pushed"
