---
description: Load the user's full memory from the Obsidian vault of this machine
---

Load the user's persistent memory from this machine's Obsidian vault.

## Instructions

1. Get the vault root: run `cat ~/.claude/memoria.env` and use `MEMORIA_VAULT_ROOT` (call it `$VAULT` below).
   From the same file take `MEMORIA_PERFIL_FILE` (default `perfil.md`) and `MEMORIA_PREFS_FILE`
   (default `preferencias.md`): vaults older than v2 keep these two files under their own names.

2. Read these files with the Read tool, in order (skip silently any that don't exist):
   - `$VAULT/Memoria/$MEMORIA_PERFIL_FILE` — personal profile, accounts, equipment (optional)
   - `$VAULT/Memoria/$MEMORIA_PREFS_FILE` — behavior preferences
   - `$VAULT/Memoria/proyectos-activos.md` — active projects and status
   - `$VAULT/Memoria/contexto-reciente.md` — recent events (focus on last 2-3 weeks)
   - `$VAULT/Memoria-CC/MEMORY.md` — index of saved memories (scan titles only)

3. Show the user a summary in Spanish using this exact format:

---
**Memoria cargada** — [today's date] — [machine name from MEMORIA_MACHINE]

**Proyectos activos:** [list with name + status, one line each]

**Contexto reciente:** [2-4 bullets of the most relevant recent events]

**Preferencias activas:** [2-3 most important behavior preferences]

**Listo para trabajar.**
---

If a file doesn't exist or is empty, say so in the summary. Do not invent information.
