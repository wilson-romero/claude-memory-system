#!/usr/bin/env bash
# common.sh — shared helpers for the Claude memory system scripts.
# Source this file; do not execute it.

MEMORIA_ENV="${MEMORIA_ENV:-$HOME/.claude/memoria.env}"
MEMORIA_STATE="${MEMORIA_STATE:-$HOME/.claude/memoria-state}"

# Load per-machine config with safe defaults.
load_config() {
  if [ -f "$MEMORIA_ENV" ]; then
    # shellcheck disable=SC1090
    source "$MEMORIA_ENV"
  fi
  : "${MEMORIA_VAULT_ROOT:?MEMORIA_VAULT_ROOT not set — run install.sh first}"
  MEMORIA_MACHINE="${MEMORIA_MACHINE:-$(hostname)}"
  MEMORIA_PROFILE="${MEMORIA_PROFILE:-personal}"
  MEMORIA_REPO_DIR="${MEMORIA_REPO_DIR:-$HOME/Code/wilson-romero/claude-memory-system}"
  MEMORIA_LOG="${MEMORIA_LOG:-$HOME/.local/log/memoria-cc.log}"
  mkdir -p "$(dirname "$MEMORIA_LOG")"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$MEMORIA_LOG"
}

# Slug used INSIDE the vault (legacy remote convention, no leading dash):
#   /home/mark/Code/Foo -> home-mark-Code-Foo
vault_slug() {
  echo "$1" | sed 's|^/||; s|/|-|g'
}

# Slug used by Claude Code for ~/.claude/projects/ (leading dash kept,
# dots and underscores also become dashes):
#   /home/mark/Code/Foo.bar -> -home-mark-Code-Foo-bar
cc_slug() {
  echo "$1" | sed 's|[/._]|-|g'
}

# Atomic write: read stdin, write to tmp file in target dir, then mv.
# Avoids partial files being picked up by rclone/OneDrive mid-write.
atomic_write() {
  local target="$1"
  local dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir"
  tmp=$(mktemp "${dir}/.tmp.XXXXXX")
  cat > "$tmp"
  mv -f "$tmp" "$target"
}

# Read a key from the state file (KEY=VALUE lines).
state_get() {
  [ -f "$MEMORIA_STATE" ] || { echo ""; return; }
  grep "^$1=" "$MEMORIA_STATE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Set a key in the state file.
state_set() {
  local key="$1" value="$2"
  touch "$MEMORIA_STATE"
  if grep -q "^${key}=" "$MEMORIA_STATE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$MEMORIA_STATE"
  else
    echo "${key}=${value}" >> "$MEMORIA_STATE"
  fi
}

# Flags for a headless `claude -p` that may only WRITE inside the vault.
# Fills the array HEADLESS_ARGS; run the child with the vault as its cwd.
#
# Its input (session transcripts, notes curated from them, the knowledge hub)
# is untrusted: a web page or tool output quoted in a session can carry
# instructions. A bare `--allowedTools Read,Write,Edit` approves those tools on
# ANY path — measured on 2.1.285: a child asked to copy a file from outside the
# vault into it did so with zero permission denials. So the child is boxed in:
#   --restricted          ignores ~/.claude/settings.json (its defaultMode,
#                         allow rules and hooks do not leak into the child)
#   --strict-mcp-config   no MCP servers, hence no MCP write/fetch tools
#   --tools               the only tools that exist; no Bash, no WebFetch
#   dontAsk               anything not allowed below is denied, not asked
#   Edit(/<vault>/**)     the only write permission (covers Write too)
# Reads are allowed only in the working directories: the vault (cwd) plus any
# --add-dir the caller passes. A Read() rule for a single file outside them was
# NOT honoured in the same test, which is why the curator hands over a COPY of
# the transcript in a private directory instead of a rule for its real path.
vault_only_claude_args() {
  local settings
  settings=$(python3 - "$MEMORIA_VAULT_ROOT" <<'PYEOF'
import json, sys
vault = sys.argv[1]
print(json.dumps({
    "disableAllHooks": True,
    "permissions": {"allow": [f"Edit(/{vault}/**)"]},
}))
PYEOF
)
  HEADLESS_ARGS=(--restricted --strict-mcp-config
    --tools "Read,Edit,Write,Glob,Grep"
    --permission-mode dontAsk
    --settings "$settings")
}

# Locate the claude binary (not on PATH in non-interactive shells).
find_claude() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then
    echo "$HOME/.local/bin/claude"
  else
    echo ""
  fi
}
