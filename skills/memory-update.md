---
description: Update the second memory system on this machine to the latest version
---

Update the memory system to the latest version from the git repo.

## Instructions

1. Load config: `source ~/.claude/memoria.env`.

2. Run `bash $MEMORIA_REPO_DIR/update.sh` and show the output.

3. If it fails on `git pull --ff-only` (diverged branches), show `git -C $MEMORIA_REPO_DIR status` and `git log --oneline -5` for both local and origin, explain the divergence to the user in Spanish, and ask how to proceed — never force-push or reset without their approval.

4. On success, confirm in Spanish: new version (from `$MEMORIA_REPO_DIR/VERSION`), migrations applied (from the installer output), and that hooks were re-merged.
