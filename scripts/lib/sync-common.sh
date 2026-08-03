#!/usr/bin/env bash
# sync-common.sh — helpers shared by the two sync scripts (vault bisync and
# knowledge union). Source this file; do not execute it.
#
# Both helpers were paid for by a real failure, which is why they live here
# instead of being copied into each script.

# find_rclone <min_version> <log_file>
#
# Echoes the path of a usable rclone binary, or writes an error to the log and
# returns 1. MEMORIA_RCLONE overrides the search.
#
# The minimum version is a PARAMETER because the two callers need different
# ones: bisync's --conflict-resolve/--conflict-loser/--resilient landed in
# 1.66, while `copy --ignore-existing` works on anything current. Hardcoding
# 1.66 for both would kill the knowledge union on a machine whose rclone is
# perfectly capable of running it.
#
# Debian/Ubuntu ship 1.60 in /usr/bin, so a newer build in /usr/local/bin wins,
# and a too-old one fails loudly instead of letting rclone die on "unknown
# flag" once per timer tick.
find_rclone() {
    local min_version="$1" log_file="$2"
    local bin="${MEMORIA_RCLONE:-}" cand ver

    if [ -z "$bin" ]; then
        for cand in /usr/local/bin/rclone "$(command -v rclone 2>/dev/null)"; do
            [ -x "$cand" ] || continue
            bin="$cand"
            break
        done
    fi
    if [ -z "$bin" ]; then
        echo "[$(date -Iseconds)] ERROR: rclone not found" >> "$log_file"
        return 1
    fi

    ver=$("$bin" version 2>/dev/null | head -1 | sed 's/rclone v//')
    if [ "$(printf '%s\n%s\n' "$ver" "$min_version" | sort -V | head -1)" != "$min_version" ]; then
        echo "[$(date -Iseconds)] ERROR: ${bin} is v${ver}; this script needs >= ${min_version}. Install a newer rclone (https://rclone.org/install/) or set MEMORIA_RCLONE." >> "$log_file"
        return 1
    fi

    echo "$bin"
}

# acquire_lock <lock_file> <log_file>
#
# Returns 1 when another run of the same script is alive (caller should exit 0).
# Sets the EXIT trap that removes the lock.
#
# The lock holds the owner PID rather than merely existing: `trap EXIT` does
# NOT run on SIGKILL or an OOM kill, so a plain -f test would let one hard
# death silence every later run ("already running") while systemd kept seeing
# exit 0 — a die-in-green failure this system has already had once.
acquire_lock() {
    local lock_file="$1" log_file="$2" lock_pid

    if [ -f "$lock_file" ]; then
        lock_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "[$(date -Iseconds)] already running (pid $lock_pid), skipping" >> "$log_file"
            return 1
        fi
        echo "[$(date -Iseconds)] stale lock from pid ${lock_pid:-unknown}, taking over" >> "$log_file"
    fi

    echo $$ > "$lock_file"
    # shellcheck disable=SC2064  # expand the path now, not at trap time
    trap "rm -f '$lock_file'" EXIT
}
