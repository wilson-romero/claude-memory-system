#!/usr/bin/env bash
# 004 — seed the state keys used by the memory watchdog (v1.3.0). Idempotent.
#
# The Stop hooks became asynchronous, so memoria-load.sh now counts sessions
# since the last VERIFIED write of each layer. Without a seed, the first five
# sessions after upgrading would trigger the "memory is not being written"
# warning even though everything works. install.sh re-merges the hooks itself,
# so this migration only touches state.
set -euo pipefail

# shellcheck disable=SC1091
source "${MEMORIA_REPO_DIR}/scripts/lib/common.sh"
load_config

NOW=$(date '+%Y-%m-%dT%H:%M:%S')
# if/then, not `[ … ] && …`: under `set -e` a false AND-list aborts the script.
for key in SESSIONS_SINCE_CAPTURE SESSIONS_SINCE_CURATOR; do
  if [ -z "$(state_get "$key")" ]; then state_set "$key" 0; fi
done
for key in LAST_CAPTURE LAST_CURATOR_WRITE; do
  if [ -z "$(state_get "$key")" ]; then state_set "$key" "$NOW"; fi
done

echo "004: watchdog state seeded"
