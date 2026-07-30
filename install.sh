#!/usr/bin/env bash
# install.sh — bootstrap/refresh the Claude memory system on this machine.
# Idempotent: safe to re-run; also used by update.sh after git pull.
# Usage: install.sh [--dry-run]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say() { echo "[install] $*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY: $*"
  else
    "$@"
  fi
}

# ── 1. Dependencies ───────────────────────────────────────────────────────────
for dep in git python3; do
  command -v "$dep" >/dev/null 2>&1 || { say "ERROR: missing dependency: $dep"; exit 1; }
done

# ── 2. Per-machine config ─────────────────────────────────────────────────────
HOST=$(hostname)
MACHINE_ENV="${REPO_DIR}/config/machines/${HOST}.env"
if [ ! -f "$MACHINE_ENV" ]; then
  say "ERROR: no config for host '${HOST}'."
  say "Create ${MACHINE_ENV} from config/memoria.env.example and re-run."
  exit 1
fi
say "config: ${MACHINE_ENV} → ~/.claude/memoria.env"
run mkdir -p "$HOME/.claude"
run cp "$MACHINE_ENV" "$HOME/.claude/memoria.env"

# shellcheck disable=SC1090
source "$MACHINE_ENV"
# Machine-local overrides that must NOT be versioned (peer IP/user/SSH port).
# shellcheck disable=SC1091
[ -f "$HOME/.claude/memoria.local.env" ] && source "$HOME/.claude/memoria.local.env"
export MEMORIA_VAULT_ROOT MEMORIA_MACHINE MEMORIA_PROFILE
export MEMORIA_REPO_DIR="$REPO_DIR"
MEMORIA_STATE="$HOME/.claude/memoria-state"

if [ ! -d "$MEMORIA_VAULT_ROOT" ]; then
  say "ERROR: vault not found at ${MEMORIA_VAULT_ROOT}"
  exit 1
fi

# ── 3. Pending migrations ─────────────────────────────────────────────────────
applied() { grep -q "^MIGRATION_$1=done$" "$MEMORIA_STATE" 2>/dev/null; }
for mig in "${REPO_DIR}/migrations/"[0-9]*.sh; do
  [ -f "$mig" ] || continue
  num=$(basename "$mig" | cut -d- -f1)
  if applied "$num"; then
    say "migration ${num}: already applied"
    continue
  fi
  say "migration ${num}: running $(basename "$mig")"
  if [ "$DRY_RUN" -eq 0 ]; then
    bash "$mig"
    echo "MIGRATION_${num}=done" >> "$MEMORIA_STATE"
  fi
done

# ── 4. Skills → ~/.claude/commands/ ───────────────────────────────────────────
run mkdir -p "$HOME/.claude/commands"
for skill in "${REPO_DIR}/skills/"*.md; do
  name=$(basename "$skill")
  say "skill: ${name}"
  run ln -sf "$skill" "$HOME/.claude/commands/${name}"
done

# ── 5. Render prompts (curator + dream) ───────────────────────────────────────
CONFIDENTIALITY=""
if [ "$MEMORIA_PROFILE" = "work" ]; then
  CONFIDENTIALITY="CONFIDENCIALIDAD: esta es una máquina de TRABAJO. Nunca copies datos de clientes, credenciales ni nombres de sistemas internos fuera del vault de esta máquina. Todo lo que escribas lleva machine: ${MEMORIA_MACHINE}."
fi

render_prompt() {
  # $1=template $2=dest
  python3 - "$1" "$2" <<PYEOF
import sys, os
tpl, dest = sys.argv[1], sys.argv[2]
with open(tpl) as f:
    content = f.read()
content = (content
    .replace("{{VAULT_ROOT}}", os.environ["MEMORIA_VAULT_ROOT"])
    .replace("{{MACHINE}}", os.environ["MEMORIA_MACHINE"])
    .replace("{{PROFILE}}", os.environ["MEMORIA_PROFILE"])
    .replace("{{CONFIDENTIALITY}}", os.environ.get("CONFIDENTIALITY", "")))
with open(dest, "w") as f:
    f.write(content)
PYEOF
}

export CONFIDENTIALITY
say "render: curator + dream prompts"
if [ "$DRY_RUN" -eq 0 ]; then
  render_prompt "${REPO_DIR}/templates/curator-prompt.md.tmpl" "$HOME/.claude/memoria-curator-prompt.md"
  render_prompt "${REPO_DIR}/templates/dream-prompt.md.tmpl" "$HOME/.claude/memoria-dream-prompt.md"
fi

# ── 6. Merge hooks into ~/.claude/settings.json ───────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
say "hooks: merging into ${SETTINGS}"
if [ "$DRY_RUN" -eq 0 ]; then
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" "$REPO_DIR" "$HOME/.claude/memoria-curator-prompt.md" "$MEMORIA_VAULT_ROOT" <<'PYEOF'
import json, os, sys

settings_path, repo_dir, curator_path, vault_root = sys.argv[1:5]

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

# The curator hook is a command now, but the rendered prompt is what that command
# feeds to `claude -p`: an empty render would leave the curator writing nothing,
# so fail the install here instead.
with open(curator_path) as f:
    curator_prompt = f.read()
if not curator_prompt.strip():
    raise SystemExit(f"ERROR: rendered curator prompt is empty: {curator_path}")

load_cmd = os.path.join(repo_dir, "scripts", "memoria-load.sh")
capture_cmd = os.path.join(repo_dir, "scripts", "memoria-capture.sh")
curator_cmd = os.path.join(repo_dir, "scripts", "memoria-curator.sh")

hooks = settings.setdefault("hooks", {})

def is_ours(h):
    cmd = h.get("command", "")
    prompt = h.get("prompt", "")
    return ("memoria-load.sh" in cmd or "memoria-capture.sh" in cmd
            or "memoria-curator.sh" in cmd
            or "obsidian-load.sh" in cmd or "obsidian-sync.sh" in cmd
            or "memoria persistente de Wilson" in prompt)

# SessionStart: our loader
ss = [g for g in hooks.get("SessionStart", [])
      if not any(is_ours(h) for h in g.get("hooks", []))]
ss.append({"hooks": [{"type": "command", "command": load_cmd, "timeout": 15}]})
hooks["SessionStart"] = ss

# Stop: deterministic capture + curator, BOTH in the background so the turn is
# released immediately (v1.3.0).
#   - capture: "async" — nothing decides on its output.
#   - curator: "asyncRewake" — a command hook that runs the curator headless and
#     exits 2 when the memory was NOT written, which wakes the session with the
#     reason. It cannot be a `type: "agent"` hook any more: agent hooks accept
#     neither async nor asyncRewake, so every turn paid their 120s timeout.
# The rendered prompt still lives in ~/.claude/memoria-curator-prompt.md and the
# script reads it from there.
stop = [g for g in hooks.get("Stop", [])
        if not any(is_ours(h) for h in g.get("hooks", []))]
stop.append({"hooks": [
    {"type": "command", "command": capture_cmd, "timeout": 30, "async": True},
    {"type": "command", "command": curator_cmd, "timeout": 900, "asyncRewake": True},
]})
hooks["Stop"] = stop

# Vault permissions so the Stop-hook curator agent can write memory
# without a human to approve (headless context). Absolute paths need
# the double-slash prefix in Claude Code permission rules.
allow = settings.setdefault("permissions", {}).setdefault("allow", [])
# A Write(path) rule is NOT honoured for file permission checks: Claude Code
# prints "only Edit(path) rules are ... Edit rules cover all file-editing tools"
# on every run and ignores it. Drop it — that warning was landing inside the
# curator's own log output.
for bad in (f"Read({vault_root}/**)",
            f"Write({vault_root}/**)",
            f"Edit({vault_root}/**)",
            f"Write(/{vault_root}/**)"):
    if bad in allow:
        allow.remove(bad)
for rule in (f"Read(/{vault_root}/**)",
             f"Edit(/{vault_root}/**)"):
    if rule not in allow:
        allow.append(rule)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
print("hooks merged ok")
PYEOF
fi

# ── 7. systemd timer for the nightly dream ────────────────────────────────────
# A --user timer only fires while the user manager is alive. Without linger that
# manager dies with the login session, so a nightly 03:30 job simply never runs
# on a machine nobody is logged into at 03:30 — enabled+active the whole time.
# Both personal machines were in that state until 2026-07-29: the dream's reports
# tracked login days, not nights.
if command -v loginctl >/dev/null 2>&1; then
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = "yes" ]; then
    say "systemd: linger already enabled (user timers survive logout)"
  else
    say "systemd: enabling linger so the nightly timers survive logout"
    run loginctl enable-linger "$(id -un)" || \
      say "systemd: WARNING could not enable linger — the dream will only fire while logged in"
  fi
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  say "systemd: installing memoria-dream.{service,timer}"
  run mkdir -p "$HOME/.config/systemd/user"
  if [ "$DRY_RUN" -eq 0 ]; then
    sed "s|%h/Code/wilson-romero/claude-memory-system|${REPO_DIR}|" \
      "${REPO_DIR}/scripts/systemd/memoria-dream.service" \
      > "$HOME/.config/systemd/user/memoria-dream.service"
    cp "${REPO_DIR}/scripts/systemd/memoria-dream.timer" \
      "$HOME/.config/systemd/user/memoria-dream.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now memoria-dream.timer
  fi
else
  say "systemd: user session not available — dream relies on SessionStart fallback"
fi

# ── 7b. systemd timer for the rclone vault sync (only when MEMORIA_SYNC=rclone) ─
if [ "${MEMORIA_SYNC:-none}" = "rclone" ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    say "systemd: installing obsidian-sync.{service,timer} (rclone bisync)"
    run mkdir -p "$HOME/.config/systemd/user"
    if [ "$DRY_RUN" -eq 0 ]; then
      sed "s|%h/Code/wilson-romero/claude-memory-system|${REPO_DIR}|" \
        "${REPO_DIR}/scripts/systemd/obsidian-sync.service" \
        > "$HOME/.config/systemd/user/obsidian-sync.service"
      cp "${REPO_DIR}/scripts/systemd/obsidian-sync.timer" \
        "$HOME/.config/systemd/user/obsidian-sync.timer"
      systemctl --user daemon-reload
      systemctl --user enable --now obsidian-sync.timer
    fi
  else
    say "systemd: user session not available — rclone sync timer not installed"
  fi
fi

# ── 7c. Knowledge union with the peer personal machine (MEMORIA_PEER set) ─────
# Only Lecciones/, Memoria-CC/ and Decisiones/ travel, and only by union
# (rsync --ignore-existing). The work machine leaves MEMORIA_PEER unset and so
# stays isolated. See docs/arquitectura.md § Sincronización.
if [ -n "${MEMORIA_PEER:-}" ] && [ -n "${MEMORIA_PEER_VAULT:-}" ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    say "systemd: installing sync-knowledge.{service,timer} (peer ${MEMORIA_PEER})"
    run mkdir -p "$HOME/.config/systemd/user"
    if [ "$DRY_RUN" -eq 0 ]; then
      sed "s|%h/Code/wilson-romero/claude-memory-system|${REPO_DIR}|" \
        "${REPO_DIR}/scripts/systemd/sync-knowledge.service" \
        > "$HOME/.config/systemd/user/sync-knowledge.service"
      cp "${REPO_DIR}/scripts/systemd/sync-knowledge.timer" \
        "$HOME/.config/systemd/user/sync-knowledge.timer"
      systemctl --user daemon-reload
      systemctl --user enable --now sync-knowledge.timer
    fi
  else
    say "systemd: user session not available — knowledge union timer not installed"
  fi
else
  say "knowledge union: MEMORIA_PEER not set — this machine stays isolated"
fi

# ── 8. Record installed version ───────────────────────────────────────────────
VERSION=$(cat "${REPO_DIR}/VERSION")
if [ "$DRY_RUN" -eq 0 ]; then
  touch "$MEMORIA_STATE"
  if grep -q "^VERSION=" "$MEMORIA_STATE"; then
    sed -i "s|^VERSION=.*|VERSION=${VERSION}|" "$MEMORIA_STATE"
  else
    echo "VERSION=${VERSION}" >> "$MEMORIA_STATE"
  fi
fi

say "done — system version ${VERSION} installed on ${MEMORIA_MACHINE}"
say "verify: open a Claude Code session and check the injected context banner"
