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

6. **Index integrity**: verify every `.md` file in `$MEMORIA_VAULT_ROOT/Memoria-CC/` (except MEMORY.md) has a line in MEMORY.md, and every line points to an existing file. Offer to fix discrepancies.

7. Report results in Spanish as a short checklist: ✅ ok / ⚠ issue + suggested action.
