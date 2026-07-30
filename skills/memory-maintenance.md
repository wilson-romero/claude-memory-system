---
description: Health check of the second memory system (conflicts, staleness, version)
---

Run a health check of the second memory system and report in Spanish.

## Instructions

1. Load config: `source ~/.claude/memoria.env` (gets `MEMORIA_VAULT_ROOT`, `MEMORIA_REPO_DIR`).

2. **Sync conflicts**: search the vault for leftovers:
   `find $MEMORIA_VAULT_ROOT -name "*..path*" -o -name "*.sync-conflict-*" | grep -v Archivo/conflictos`
   If any found, offer to quarantine them with `bash $MEMORIA_REPO_DIR/scripts/migrate/cleanup-conflicts.sh`.

3. **Staleness**: read the `updated:` frontmatter of each file in `$MEMORIA_VAULT_ROOT/Memoria/*.md`. Flag any older than 14 days.

4. **Version**: compare `cat $MEMORIA_REPO_DIR/VERSION` vs `grep ^VERSION= ~/.claude/memoria-state`. Also run `git -C $MEMORIA_REPO_DIR fetch --quiet && git -C $MEMORIA_REPO_DIR status -sb` to check if behind origin. If outdated, recommend `/memory-update`.

5. **Dream**: check `grep ^LAST_DREAM= ~/.claude/memoria-state` and the latest report in `$MEMORIA_VAULT_ROOT/Memoria/Suenos/`. Flag if the last dream is older than 2 days. Verify the timer: `systemctl --user is-active memoria-dream.timer`.

   A report existing is NOT proof the dream worked. **Phase 2 shells out to `claude -p`
   headless**, so a dead model, an exhausted quota or a network blip leaves a Phase-1-only
   report behind and nothing complains — the same silent-failure shape that hid a dead bisync
   for 43 days. Check the last report actually reached Phase 2:

   ```bash
   LAST=$(ls -1t "$MEMORIA_VAULT_ROOT/Memoria/Suenos/"*.md 2>/dev/null | head -1)
   systemctl --user show memoria-dream.service -p Result --value   # success?
   grep -il "fase 2\|phase 2" "$LAST"                              # did it get there?
   ```

   Report the failure mode explicitly: *"the dream ran but only completed Phase 1 — the
   consolidation did not happen"* is very different from *"the dream did not run"*. The first
   one keeps producing reports and looks healthy.

6. **Index integrity**: verify every `.md` file in `$MEMORIA_VAULT_ROOT/Memoria-CC/` (except MEMORY.md) has a line in MEMORY.md, and every line points to an existing file. Offer to fix discrepancies.

7. **Cloud sync health** (only when `MEMORIA_SYNC=rclone`). A green `.timer` proves the
   schedule fires, NOT that the sync ran — check the `.service` and the log:

   ```bash
   systemctl --user is-active obsidian-sync.timer      # schedule alive?
   systemctl --user is-failed obsidian-sync.service    # last RUN failed?
   grep -c "Bisync critical error" "$HOME/.local/log/obsidian-sync.log"
   grep "sync done" "$HOME/.local/log/obsidian-sync.log" | tail -1   # last SUCCESS
   ```

   Flag if the last `sync done` is older than **1 day**, and report how long it has been
   failing — not just that it failed. On 2026-07-29 this went unnoticed for **43 days**
   with the timer green and 806 of 885 runs aborting.

   Two specific failures worth naming in the report:
   - `cannot find prior Path1 or Path2 listings` → the bisync baseline is gone (usually
     after the vault path changed). Despite what `--resilient` says, this only recovers
     with a one-off `--resync`, which `sync-obsidian.sh` never passes. Do NOT run it
     blindly: a resync UNIONS both sides.
   - Before any `--resync`, confirm the remote holds THIS machine's vault and no other:
     `rclone check "$(dirname "$MEMORIA_VAULT_ROOT")" "$MEMORIA_SYNC_REMOTE"` — a near-zero
     match count means the remote belongs to a different vault, and syncing would merge
     two memories that must stay separate (`docs/arquitectura.md`: one vault per machine,
     never crossing). Each machine gets its OWN remote folder.

8. Report results in Spanish as a short checklist: ✅ ok / ⚠ issue + suggested action.
