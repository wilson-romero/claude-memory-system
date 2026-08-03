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

6. **Index integrity**: the index is `MEMORY.md` **plus its branches** (`MEMORY-<topic>.md`), so
   build the linked set from all of them — a file indexed in a branch is NOT an orphan. A link is
   dangling only when the path it points at **does not exist** (`os.path.exists`); most point out
   of `Memoria-CC` (`../Lecciones/…`), and comparing paths against bare filenames reports every
   one of them as broken. Also **parse** the frontmatter instead of grepping it: an unquoted
   `description:` containing `": "` breaks the YAML, and the file still looks perfect.

   ```bash
   cd "$MEMORIA_VAULT_ROOT/Memoria-CC" && python3 -c '
   import os,re,yaml
   idx=sorted(f for f in os.listdir(".") if f.startswith("MEMORY") and f.endswith(".md"))
   linked=set()
   for f in idx: linked|=set(re.findall(r"\]\(<?([^)>]+\.md)>?\)", open(f,encoding="utf-8").read()))
   actual={f for f in os.listdir(".") if f.endswith(".md") and f not in idx}
   print("dangling:",[r for r in sorted(linked) if not os.path.exists(r)])
   print("orphans:",sorted(actual-linked))
   for f in sorted(actual):
       t=open(f,encoding="utf-8").read()
       if t.startswith("---"):
           try: fm=yaml.safe_load(t.split("---",2)[1]) or {}
           except Exception as e: print("BROKEN YAML:",f); continue
           if not fm.get("description"): print("no description:",f)
   '
   ```

6b. **Index size — the silent one**. `MEMORY.md` is the only file loaded every session and it is
   read up to **~24 KB**; anything past that is **dropped with no warning**, so those entries stop
   existing for whoever reads it. On 2026-07-29 it reached **29 KB and lost 32 entries** — nothing
   was broken, no link was dead, `grep` found everything, and a third of the index simply never
   arrived. Report the size of every index file and flag `MEMORY.md` over **17 KB** (the headroom
   target), not just over the hard limit:

   ```bash
   cd "$MEMORIA_VAULT_ROOT/Memoria-CC" && wc -c MEMORY*.md | sort -n
   ```

   The fix is **never to delete entries**: move a whole thematic block to its `MEMORY-<topic>.md`
   branch and leave a one-line pointer. Moving means *moving* — the 29 KB happened because a
   previous split **copied** the blocks without removing them, leaving 80 duplicated links, two
   unreachable branches and the file just as big.

6c. **Linger — why a green timer still never runs**. A `--user` timer only fires while the user
   manager is alive, and without linger that manager dies with the login session. A nightly 03:30
   job then never runs on a machine nobody is logged into at 03:30, while `is-active` and
   `is-enabled` both stay green. Both personal machines were in that state; the dream's reports
   tracked login days, not nights.

   ```bash
   loginctl show-user "$(id -un)" -p Linger --value      # must be "yes"
   systemctl --user list-timers memoria-dream.timer --all   # LAST column: did it ever fire?
   ```

   If it is `no`, offer `loginctl enable-linger "$(id -un)"` (no sudo needed for one's own user).

6d. **Divergence with the hub** (only when `MEMORIA_KNOWLEDGE_REMOTE` is set).
   The union runs `rclone copy --ignore-existing`, which copies only files that are **missing**: it
   never clobbers, and therefore **never propagates an improvement to a file that already exists on
   the other side**. Counting files does not detect this — on 2026-07-29 both machines had the same
   493 filenames with none exclusive to either, and **10 differed in content**. Compare md5:

   ```bash
   cd "$MEMORIA_VAULT_ROOT" && find Lecciones Memoria-CC Decisiones -name '*.md' \
     -exec md5sum {} + | sort -k2 > /tmp/local.md5
   for d in Lecciones Memoria-CC Decisiones; do
     rclone md5sum "$MEMORIA_KNOWLEDGE_REMOTE/$d" | sed "s|  |  $d/|"
   done | sort -k2 > /tmp/hub.md5
   join -j2 -o 0,1.1,2.1 /tmp/local.md5 /tmp/hub.md5 | awk '$2!=$3{print $1}'
   ```

   **What this comparison can and cannot say.** It is local ↔ hub, not machine ↔ machine: a
   divergence does **not** tell you which machine introduced it, and the hub may be carrying a third
   version that neither machine has any more. Say so in the report instead of guessing.

   **Report the divergence, never resolve it in bulk.** The correct direction changes per file: on
   2026-07-29 six files were better locally (filled-in frontmatter) but one was better on the other
   side (146 lines vs 117 — it carried the correction that the local copy still denied). A blind
   copy either way would have destroyed 34 good lines. For each divergent file, measure what each
   side contributes (`comm -23` / `comm -13` over its non-empty lines) and decide file by file.
   `MEMORY*.md` (the index **and its branches**) and `_INDEX.md` are **per-machine and must
   diverge** — they are excluded from the union, so do not flag them.

6e. **Knowledge transport health** (only when `MEMORIA_KNOWLEDGE_REMOTE` is set). Same lesson as 7:
   a green timer proves the schedule, not the work.

   ```bash
   systemctl --user is-active sync-knowledge.timer
   systemctl --user is-failed sync-knowledge.service
   grep -E "union (done|FAILED)" "$HOME/.local/log/sync-knowledge.log" | tail -1
   cat "$HOME/.local/state/sync-knowledge.fails"   # consecutive unreachable runs
   ```

   Flag if the last `union done` is older than **1 day**. A non-zero fails counter that never
   returns to 0 is the signature of an expired Drive token, as opposed to a laptop that keeps
   going offline — the counter exists precisely to tell those two apart.

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
