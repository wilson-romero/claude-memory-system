#!/usr/bin/env bash
# selftest-sync-knowledge.sh — exercise sync-knowledge.sh against a fake vault
# and a fake hub. No network, no Drive, no systemd.
#
# The hub is a plain directory: rclone treats a path with no ":" as a local
# remote, so the REAL script and the REAL rclone binary run — only the far end
# is faked. A harness that mocked rclone would prove nothing about the flags.
#
# Every case below was made to FAIL on purpose before being trusted (mutate the
# script as the comment says, watch the case go red, revert). A green suite that
# has never been seen red is an assertion about nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/sync-knowledge.sh"
FOLDERS=(Lecciones Memoria-CC Decisiones)

pass=0
fail=0
ok()   { echo "  ok   — $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL — $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# Builds a throwaway world and echoes its root. Every run gets its own, so a
# case can never inherit another's state.
new_world() {
    local root vault hub d
    root=$(mktemp -d)
    vault="$root/vault/Claude"
    hub="$root/hub"
    for d in "${FOLDERS[@]}"; do mkdir -p "$vault/$d" "$hub/$d"; done
    cat > "$root/memoria.env" <<EOF
MEMORIA_VAULT_ROOT="$vault"
MEMORIA_MACHINE="selftest"
MEMORIA_PROFILE="personal"
MEMORIA_KNOWLEDGE_REMOTE="$hub"
MEMORIA_KNOWLEDGE_LOG="$root/union.log"
MEMORIA_KNOWLEDGE_FAILS="$root/fails"
MEMORIA_KNOWLEDGE_LOCK="$root/lock"
EOF
    echo "$root"
}

# Runs the script against a world. HOME is redirected so the real
# ~/.claude/memoria.local.env can never leak into a test.
run_sut() {
    local root="$1"
    HOME="$root/home" MEMORIA_ENV="$root/memoria.env" bash "$SUT"
}

set_env() {  # set_env <root> <KEY> <value>
    local root="$1" key="$2" value="$3"
    grep -v "^${key}=" "$root/memoria.env" > "$root/memoria.env.tmp" || true
    mv "$root/memoria.env.tmp" "$root/memoria.env"
    echo "${key}=\"${value}\"" >> "$root/memoria.env"
}

listing() { find "$1" -type f | sort | xargs -r md5sum 2>/dev/null; }

# ── 1. Union in both directions, with an EXACT count ─────────────────────────
# The count is asserted as a number, not as "> 0": break the ': Copied (new)'
# pattern in run_copy and this case must go red even though the files arrive.
echo "1. union in both directions"
W=$(new_world)
echo "local" > "$W/vault/Claude/Lecciones/from-local.md"
echo "remote" > "$W/hub/Memoria-CC/from-hub.md"
run_sut "$W" >/dev/null 2>&1
check "the local file reached the hub" \
    "$([ -f "$W/hub/Lecciones/from-local.md" ] && echo yes || echo no)" "yes"
check "the hub file reached the vault" \
    "$([ -f "$W/vault/Claude/Memoria-CC/from-hub.md" ] && echo yes || echo no)" "yes"
check "the log reports the exact counts" \
    "$(grep -o 'union done: [0-9]* pulled, [0-9]* pushed' "$W/union.log")" \
    "union done: 1 pulled, 1 pushed"
rm -rf "$W"

# ── 2. --ignore-existing never clobbers ──────────────────────────────────────
# Drop the flag from run_copy and one of the two md5s changes.
echo "2. --ignore-existing does not overwrite either side"
W=$(new_world)
echo "the local version" > "$W/vault/Claude/Lecciones/same.md"
echo "a different, remote version" > "$W/hub/Lecciones/same.md"
before_local=$(md5sum < "$W/vault/Claude/Lecciones/same.md")
before_hub=$(md5sum < "$W/hub/Lecciones/same.md")
run_sut "$W" >/dev/null 2>&1
check "local content untouched" "$(md5sum < "$W/vault/Claude/Lecciones/same.md")" "$before_local"
check "hub content untouched"   "$(md5sum < "$W/hub/Lecciones/same.md")" "$before_hub"
rm -rf "$W"

# ── 3. Curated indexes stay put ──────────────────────────────────────────────
# Narrow the exclude back to 'MEMORY.md' and only the BRANCH assertions go red —
# which is the defect this pattern was widened to fix.
echo "3. indexes and their branches are excluded"
W=$(new_world)
for f in _INDEX.md MEMORY.md MEMORY-infra.md; do
    echo "curated" > "$W/vault/Claude/Memoria-CC/$f"
done
echo "curated elsewhere" > "$W/hub/Memoria-CC/MEMORY-shell.md"
run_sut "$W" >/dev/null 2>&1
for f in _INDEX.md MEMORY.md MEMORY-infra.md; do
    check "$f did not reach the hub" \
        "$([ -f "$W/hub/Memoria-CC/$f" ] && echo yes || echo no)" "no"
done
check "MEMORY-shell.md did not come down" \
    "$([ -f "$W/vault/Claude/Memoria-CC/MEMORY-shell.md" ] && echo yes || echo no)" "no"
rm -rf "$W"

# ── 4. The work-profile guard ────────────────────────────────────────────────
# Comment the guard out in sync-knowledge.sh and this case MUST go red. If it
# stays green, it is testing nothing and has to be fixed before it is trusted.
echo "4. profile=work refuses to sync"
W=$(new_world)
set_env "$W" MEMORIA_PROFILE work
echo "private" > "$W/vault/Claude/Lecciones/work-secret.md"
before=$(listing "$W/hub")
run_sut "$W" >/dev/null 2>&1
rc=$?
check "the hub is byte-identical afterwards" "$(listing "$W/hub")" "$before"
check "exit code is 0 (a policy, not a failure)" "$rc" "0"
check "the log says REFUSING" \
    "$(grep -c REFUSING "$W/union.log")" "1"
rm -rf "$W"

# ── 5. A transport failure is NOT a green ────────────────────────────────────
# Reinstate the old '2>/dev/null | grep -c' shape that ignored rclone's exit
# code and this case goes red: the log would say "union done: 0".
echo "5. an unreachable hub fails loudly"
W=$(new_world)
set_env "$W" MEMORIA_KNOWLEDGE_REMOTE "nonexistent-xyz:Knowledge"
set_env "$W" MEMORIA_KNOWLEDGE_FAIL_LIMIT 1
run_sut "$W" >/dev/null 2>&1
rc=$?
check "exit code is not 0" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "the log says FAILED" "$(grep -c 'FAILED' "$W/union.log")" "1"
check "the log does NOT claim a completed union" \
    "$(grep -c 'union done' "$W/union.log")" "0"
rm -rf "$W"

# ── 5b. A copy that fails on a REACHABLE hub is not a green either ───────────
# Case 5 above dies in the preflight, so it never reaches run_copy — mutation
# testing caught that: dropping the `rc` check left the whole suite green. This
# case makes the hub listable but not writable, which is the only shape that
# exercises the copy's own error handling.
echo "5b. a failing copy on a reachable hub fails loudly"
W=$(new_world)
echo "cannot be uploaded" > "$W/vault/Claude/Lecciones/blocked.md"
chmod -R a-w "$W/hub"
run_sut "$W" >/dev/null 2>&1
rc=$?
chmod -R u+w "$W/hub"                      # so mktemp -d cleanup can proceed
check "exit code is not 0" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "the log says the union FAILED" "$(grep -c 'union FAILED' "$W/union.log")" "1"
check "the log carries rclone's own error" "$(grep -c 'ERROR: copy' "$W/union.log")" "1"
rm -rf "$W"

# ── 6. Offline is tolerated, but counted ─────────────────────────────────────
# Pin the counter to a constant and the third run stays green — red.
echo "6. offline runs are counted up to the limit"
W=$(new_world)
good_hub=$(grep '^MEMORIA_KNOWLEDGE_REMOTE=' "$W/memoria.env" | cut -d'"' -f2)
set_env "$W" MEMORIA_KNOWLEDGE_REMOTE "nonexistent-xyz:Knowledge"
set_env "$W" MEMORIA_KNOWLEDGE_FAIL_LIMIT 3
run_sut "$W" >/dev/null 2>&1; rc1=$?
run_sut "$W" >/dev/null 2>&1; rc2=$?
run_sut "$W" >/dev/null 2>&1; rc3=$?
check "first run tolerated"  "$rc1" "0"
check "second run tolerated" "$rc2" "0"
check "third run fails"      "$([ "$rc3" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "the log counted them" "$(grep -c 'OFFLINE (' "$W/union.log")" "2"
set_env "$W" MEMORIA_KNOWLEDGE_REMOTE "$good_hub"
run_sut "$W" >/dev/null 2>&1
check "a good run resets the counter" "$(cat "$W/fails")" "0"
rm -rf "$W"

# ── 7. Deleting locally does not propagate (documented, not a bug) ───────────
# Turn `copy` into `sync` and the file disappears from the hub instead — red.
echo "7. a local delete does not remove the file from the hub"
W=$(new_world)
echo "a lesson" > "$W/vault/Claude/Decisiones/keep.md"
run_sut "$W" >/dev/null 2>&1
rm -f "$W/vault/Claude/Decisiones/keep.md"
run_sut "$W" >/dev/null 2>&1
check "the file is still in the hub" \
    "$([ -f "$W/hub/Decisiones/keep.md" ] && echo yes || echo no)" "yes"
check "and it came back locally" \
    "$([ -f "$W/vault/Claude/Decisiones/keep.md" ] && echo yes || echo no)" "yes"
rm -rf "$W"

# ── 8. The nesting assertion ─────────────────────────────────────────────────
# Remove the assertion and this goes red: the union would run in the shape that
# makes the vault bisync pull the hub into the vault.
echo "8. a hub nested in the vault remote is refused"
W=$(new_world)
set_env "$W" MEMORIA_SYNC_REMOTE "gdrive:Obsidian"
set_env "$W" MEMORIA_KNOWLEDGE_REMOTE "gdrive:Obsidian/Knowledge"
echo "x" > "$W/vault/Claude/Lecciones/nested.md"
run_sut "$W" >/dev/null 2>&1
check "exit code is 1" "$?" "1"
check "the log names the nesting" "$(grep -c 'nested inside' "$W/union.log")" "1"
rm -rf "$W"

# ── 9. The lock ──────────────────────────────────────────────────────────────
# Drop the `kill -0` test and the stale-lock case goes red: one hard death
# would silence every later run while systemd kept seeing exit 0.
echo "9. the lock distinguishes a live owner from a stale one"
W=$(new_world)
echo $$ > "$W/lock"                      # this test process is very much alive
echo "blocked" > "$W/vault/Claude/Lecciones/blocked.md"
run_sut "$W" >/dev/null 2>&1
check "a live lock blocks the run" \
    "$([ -f "$W/hub/Lecciones/blocked.md" ] && echo yes || echo no)" "no"

# A PID that cannot exist: the highest allowed plus one.
echo $(( $(cat /proc/sys/kernel/pid_max) + 1 )) > "$W/lock"
run_sut "$W" >/dev/null 2>&1
check "a stale lock is taken over" \
    "$([ -f "$W/hub/Lecciones/blocked.md" ] && echo yes || echo no)" "yes"
rm -rf "$W"

echo
echo "selftest: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
