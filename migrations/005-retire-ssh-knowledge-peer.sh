#!/usr/bin/env bash
# 005 — retire the SSH peer used by the knowledge union (v1.5.0). Idempotent.
#
# The union now goes through a shared Drive folder (MEMORIA_KNOWLEDGE_REMOTE),
# so MEMORIA_PEER/_PORT/_VAULT no longer mean anything. They must not simply be
# left behind: install.sh still sources memoria.local.env, so a stale
# MEMORIA_PEER would keep looking like live configuration to anyone reading it.
#
# The keys are RENAMED, not deleted. If the move to Drive ever has to be
# reverted, the connection details are still there — and a comment says where
# the replacement lives, so the file explains itself.
set -euo pipefail

# shellcheck disable=SC1091
source "${MEMORIA_REPO_DIR}/scripts/lib/common.sh"
load_config

LOCAL_ENV="$HOME/.claude/memoria.local.env"

if [ ! -f "$LOCAL_ENV" ] || ! grep -q '^MEMORIA_PEER' "$LOCAL_ENV"; then
  echo "005: no SSH peer to retire"
  exit 0
fi

cp "$LOCAL_ENV" "${LOCAL_ENV}.bak.$(date +%Y%m%d-%H%M%S)"
sed -i 's/^MEMORIA_PEER/MEMORIA_PEER_RETIRED/' "$LOCAL_ENV"
cat >> "$LOCAL_ENV" <<'EOF'

# MEMORIA_PEER_RETIRED* above: the knowledge union used to reach the other
# personal machine by rsync over SSH, which needed both machines awake at the
# same time. Retired in v1.5.0 — it now goes through the shared Drive folder in
# MEMORIA_KNOWLEDGE_REMOTE (config/machines/*.env). Kept for a possible revert.
EOF

log "005: retired the SSH knowledge peer (renamed to MEMORIA_PEER_RETIRED*)"
echo "005: SSH knowledge peer retired — see ${LOCAL_ENV}"
