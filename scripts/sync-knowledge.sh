#!/usr/bin/env bash
# sync-knowledge.sh — keep the KNOWLEDGE folders identical across Wilson's
# personal machines (mark-PC and PC-WILSON), without merging their vaults.
#
# Topology: hub-and-spoke, not peer-to-peer. Every personal machine pushes to
# and pulls from ONE shared Drive folder (MEMORIA_KNOWLEDGE_REMOTE); no machine
# knows about any other. The transport used to be rsync over SSH straight to
# the peer, which required both machines to be awake at the same time: 40 of 87
# recorded runs did nothing because the other machine was off. A hub removes
# that requirement entirely, and doubles as an off-site copy of the knowledge.
#
# Why the hub is a SIBLING of the vault remotes, never a child: gdrive:Obsidian
# and gdrive:Obsidian-PC-WILSON are bisynced whole. A hub under either of them
# would be pulled back down INSIDE the vault, and the next union would push the
# copy up again. The nesting assertion below refuses to run in that shape.
#
# Why not point both machines at one shared VAULT remote instead: their session
# state legitimately differs (Memoria/contexto-reciente.md is 571 KB on one and
# 87 KB on the other, projects/ is 522 vs 195 files). Bisync with
# --conflict-resolve newer would silently drop one side's curated files.
#
# Knowledge is different: one file = one lesson/reference, written once and
# rarely edited. So a two-way union with `copy --ignore-existing` is the correct
# semantics — it can only ever add, never overwrite or delete. Two consequences
# to keep in mind, both deliberate:
#   - an EDIT to a file that already exists on the other side never propagates
#     (/memory-maintenance reports the md5 divergence; it is resolved by hand);
#   - deleting a file locally does not delete it from the hub, so the next pull
#     brings it back. Retiring shared knowledge means emptying the file and
#     leaving a tombstone, not removing it.
#
# Indexes (_INDEX.md, MEMORY*.md) are excluded on purpose: they are curated
# summaries — MEMORY.md and its MEMORY-<topic>.md branches — not append-only
# artifacts, and must be merged by the curator.
set -uo pipefail

MEMORIA_ENV="${MEMORIA_ENV:-$HOME/.claude/memoria.env}"
# shellcheck disable=SC1090
[ -f "$MEMORIA_ENV" ] && source "$MEMORIA_ENV"
# Kept for local overrides. The SSH peer that used to live here was retired in
# v1.5.0 (migrations/005); a remote name is not sensitive, so the knowledge
# config is versioned in config/machines/*.env like everything else.
# shellcheck disable=SC1090
[ -f "$HOME/.claude/memoria.local.env" ] && source "$HOME/.claude/memoria.local.env"

VAULT="${MEMORIA_VAULT_ROOT:?MEMORIA_VAULT_ROOT not set}"
PROFILE="${MEMORIA_PROFILE:-personal}"
REMOTE="${MEMORIA_KNOWLEDGE_REMOTE:-}"          # e.g. gdrive:Claude-Knowledge
VAULT_REMOTE="${MEMORIA_SYNC_REMOTE:-}"
LOG="${MEMORIA_KNOWLEDGE_LOG:-$HOME/.local/log/sync-knowledge.log}"
FAILS_FILE="${MEMORIA_KNOWLEDGE_FAILS:-$HOME/.local/state/sync-knowledge.fails}"
FAIL_LIMIT="${MEMORIA_KNOWLEDGE_FAIL_LIMIT:-3}"
LOCK_FILE="${MEMORIA_KNOWLEDGE_LOCK:-/tmp/sync-knowledge.lock}"
FOLDERS=(Lecciones Memoria-CC Decisiones)
EXCLUDES=(--exclude "_INDEX.md" --exclude "MEMORY*.md")

mkdir -p "$(dirname "$LOG")" "$(dirname "$FAILS_FILE")"
log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

# --- Guards, cheapest first ------------------------------------------------

# The work machine never joins the union. Knowledge reaches it only through
# /memory-promote, which scrubs client data and asks for approval. This check
# comes BEFORE reading the remote on purpose: it has to hold even if someone
# configures MEMORIA_KNOWLEDGE_REMOTE on that machine by mistake. Config alone
# used to be the whole isolation, and config is one edit away from wrong.
if [ "$PROFILE" = "work" ]; then
    log "REFUSING: profile=work — knowledge never leaves this machine automatically (use /memory-promote)"
    exit 0
fi

if [ -z "$REMOTE" ]; then
    log "SKIP: MEMORIA_KNOWLEDGE_REMOTE not configured on this machine"
    exit 0
fi

# An impossible configuration, not a passing circumstance: fail loudly.
if [ -n "$VAULT_REMOTE" ]; then
    case "$REMOTE" in
        "$VAULT_REMOTE"/*|"$VAULT_REMOTE")
            log "ERROR: knowledge remote ${REMOTE} is nested inside the vault remote ${VAULT_REMOTE}; bisync would pull the hub into the vault"
            exit 1 ;;
    esac
    case "$VAULT_REMOTE" in
        "$REMOTE"/*)
            log "ERROR: vault remote ${VAULT_REMOTE} is nested inside the knowledge remote ${REMOTE}"
            exit 1 ;;
    esac
fi

# shellcheck source=lib/sync-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sync-common.sh"

# `copy --ignore-existing` has been in rclone forever; do NOT inherit bisync's
# 1.66 floor, which would kill the union on a machine that can run it fine.
RCLONE_BIN=$(find_rclone 1.60.0 "$LOG") || exit 1

acquire_lock "$LOCK_FILE" "$LOG" || exit 0

# --- Preflight: offline is tolerated, but counted ---------------------------
#
# A laptop on a train and an expired Drive token look identical for one run.
# Without a counter the choice is between a red service every time the WiFi
# drops and a green one forever after the token dies — and this system has
# already lost 43 days to the second kind.
fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)
[[ "$fails" =~ ^[0-9]+$ ]] || fails=0

if ! err=$("$RCLONE_BIN" lsd "$REMOTE" --max-depth 1 --retries 1 \
        --low-level-retries 1 --timeout 20s 2>&1 >/dev/null); then
    fails=$((fails + 1))
    echo "$fails" > "$FAILS_FILE"
    # Collapse the whole stderr onto one line rather than keeping its last one:
    # Google's quota error wraps, and its last line is ", rateLimitExceeded" —
    # true, and useless to whoever reads the log at 02:00.
    why=$(echo "$err" | tr '\n' ' ' | tr -s ' ' | cut -c1-300)
    if [ "$fails" -lt "$FAIL_LIMIT" ]; then
        log "OFFLINE (${fails}/${FAIL_LIMIT}): ${REMOTE} unreachable — ${why}"
        exit 0
    fi
    log "FAILED: ${REMOTE} unreachable after ${fails} consecutive attempts — ${why}"
    exit 1
fi
echo 0 > "$FAILS_FILE"

# --- The union -------------------------------------------------------------

# Logged BEFORE any work: a run killed by systemd's TimeoutStartSec dies on
# SIGTERM without reaching any of the lines below, so without this the union
# log shows nothing at all and only systemd knows the run existed. Measured —
# the first seed was killed at 173 of 584 files and left no trace here.
log "starting union (${VAULT} <-> ${REMOTE})"

failed=0
pulled=0
pushed=0

# Echoes "<rclone exit code> <files copied>". The exit code travels back with
# the count, and not in a variable, because the caller reads this through a
# command substitution — a subshell, where any `failed=1` would be discarded.
# That is not hypothetical: it shipped, and the selftest caught it exiting 0
# after a copy that had already logged its own error.
#
# The count never decides anything. Errors are reported through the code and
# the log, which is exactly what the old rsync version got wrong when it turned
# a broken transport into a cheerful "0 files".
run_copy() {
    local src="$1" dst="$2" runlog n rc
    runlog=$(mktemp)

    "$RCLONE_BIN" copy "$src" "$dst" --ignore-existing "${EXCLUDES[@]}" \
        --log-level INFO --log-file "$runlog" --stats 0
    rc=$?

    if [ $rc -ne 0 ]; then
        log "ERROR: copy ${src} -> ${dst} exited ${rc}"
        tail -20 "$runlog" | while IFS= read -r line; do log "  | $line"; done
    fi

    n=$(grep -c ': Copied (new)' "$runlog" 2>/dev/null || true)
    rm -f "$runlog"
    echo "${rc} ${n:-0}"
}

for d in "${FOLDERS[@]}"; do
    mkdir -p "${VAULT}/${d}"          # rclone refuses a missing local source

    read -r rc n <<< "$(run_copy "${VAULT}/${d}" "${REMOTE}/${d}")"
    [ "$rc" -ne 0 ] && failed=1
    pushed=$((pushed + n))

    read -r rc n <<< "$(run_copy "${REMOTE}/${d}" "${VAULT}/${d}")"
    [ "$rc" -ne 0 ] && failed=1
    pulled=$((pulled + n))
done

if [ "$failed" -ne 0 ]; then
    log "union FAILED: ${pulled} pulled, ${pushed} pushed before the error (hub ${REMOTE})"
    exit 1
fi

log "union done: ${pulled} pulled, ${pushed} pushed (hub ${REMOTE})"
