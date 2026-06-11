---
description: Promote a generic technical lesson to shared-knowledge (synced between machines via git)
---

Promote a lesson from this machine's vault to `shared-knowledge/` in the memory system repo, so the other machine receives it via git.

Lesson to promote: $ARGUMENTS

## Instructions

1. Load config: `source ~/.claude/memoria.env`.

2. Locate the lesson (in `$MEMORIA_VAULT_ROOT/Lecciones/` or `$MEMORIA_VAULT_ROOT/Memoria-CC/`) and read it.

3. **Scrub it**: rewrite the content removing ALL client/employer-specific data — client names, internal system names, credentials, URLs, IPs, people. Keep only the generic technical lesson (problem, root cause, solution, commands with placeholders). If the lesson cannot be made generic, STOP and tell Wilson why.

4. Show Wilson the scrubbed version and ask for confirmation before writing.

5. Write it to `$MEMORIA_REPO_DIR/shared-knowledge/<slug>.md` with frontmatter (`type: reference`, `machine:` origin, dates), and add a one-line entry to `$MEMORIA_REPO_DIR/shared-knowledge/INDEX.md`.

6. Propose the commit to Wilson (English message with gitmoji, e.g. `:bulb: Add shared lesson: <slug>`), and only commit/push after his explicit approval.

7. Remind him: the other machine will get it on its next `/memory-update` or session-start fetch warning.
