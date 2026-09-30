---
description: Promote a generic technical lesson to shared-knowledge (a folder you can carry to machines outside the knowledge union)
---

Promote a lesson from this machine's vault to the shared-knowledge folder, so machines that do not join the knowledge union (e.g. a work machine) can receive it. The folder is `$MEMORIA_SHARED_DIR` (default `~/.claude/shared-knowledge`); every session injects its `INDEX.md`. How it travels between machines is up to the user: a private git repo is the usual choice.

Lesson to promote: $ARGUMENTS

## Instructions

1. Load config: `source ~/.claude/memoria.env`, and set `MEMORIA_SHARED_DIR` to `$HOME/.claude/shared-knowledge` if it is empty.

2. Locate the lesson (in `$MEMORIA_VAULT_ROOT/Lecciones/` or `$MEMORIA_VAULT_ROOT/Memoria-CC/`) and read it.

3. **Scrub it**: rewrite the content removing ALL client/employer-specific data — client names, internal system names, credentials, URLs, IPs, people. Keep only the generic technical lesson (problem, root cause, solution, commands with placeholders). If the lesson cannot be made generic, STOP and tell the user why.

4. Show the user the scrubbed version and ask for confirmation before writing.

5. Write it to `$MEMORIA_SHARED_DIR/<slug>.md` with frontmatter (`type: reference`, `machine:` origin, dates), and add a one-line entry to `$MEMORIA_SHARED_DIR/INDEX.md` (create both the folder and the index if missing).

6. If `$MEMORIA_SHARED_DIR` is a git repository, propose the commit to the user (e.g. `Add shared lesson: <slug>`), and only commit/push after their explicit approval. If it is not, tell them where the file is.

7. Remind them: another machine gets the lesson once its `$MEMORIA_SHARED_DIR` holds it (e.g. after a `git pull` there).
