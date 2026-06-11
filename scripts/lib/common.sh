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
