# Runbook de administración

## Agregar una máquina nueva

1. Clonar el repo: `git clone git@github.com:wilson-romero/claude-memory-system.git ~/Code/wilson-romero/claude-memory-system`
2. Crear `config/machines/$(hostname).env` desde `config/memoria.env.example` (vault, perfil personal/work, tipo de sync).
3. `./install.sh --dry-run` para revisar, luego `./install.sh`.
4. Commit del nuevo `.env` (con aprobación de Wilson) para que quede versionado.
5. Verificar: abrir sesión de Claude Code → debe aparecer el banner de la máquina.

## Escribir una migración

1. Crear `migrations/NNN-descripcion.sh` (siguiente número libre, dos dígitos mínimo).
2. Debe ser **idempotente** (correrla dos veces no duplica nada) y usar las variables `MEMORIA_VAULT_ROOT`, `MEMORIA_MACHINE`, `MEMORIA_REPO_DIR` del entorno.
3. Subir versión en `VERSION` (semver).
4. Commit/push (con aprobación). La otra máquina la aplicará con `/memory-update`.

## Estructura de los hooks (en ~/.claude/settings.json)

- `SessionStart` → command `scripts/memoria-load.sh` (timeout 15s)
- `Stop` → command `scripts/memoria-capture.sh` (30s) + agent con el prompt curador renderizado (120s)
- `install.sh` los re-mergea de forma segura: hace backup `settings.json.bak.<timestamp>`, elimina solo los hooks propios (identificados por nombre de script o firma del prompt) y preserva todo lo demás.

## Archivos de estado

| Archivo | Contenido |
|---|---|
| `~/.claude/memoria.env` | config de la máquina (copiada de `config/machines/`) |
| `~/.claude/memoria-state` | `VERSION=`, `MIGRATION_NNN=done`, `LAST_DREAM=`, `LAST_FETCH=` |
| `~/.claude/memoria-curator-prompt.md` | prompt curador renderizado |
| `~/.claude/memoria-dream-prompt.md` | prompt del Sueño renderizado |

## Troubleshooting

**Logs**: `tail -50 ~/.local/log/memoria-cc.log` (capture, dream, load).

**El capture no escribe** → probar a mano:
`echo '{"cwd":"/ruta/proyecto","session_id":"test","transcript_path":""}' | bash scripts/memoria-capture.sh` y revisar el log.

**El Sueño no corre** → `systemctl --user status memoria-dream.timer`; forzar con `bash scripts/memoria-dream.sh --force`. Si falta el binario claude o el prompt renderizado, la Fase 2 se salta (queda en el log) pero la Fase 1 siempre corre.

**`update.sh` falla con "not fast-forward"** → alguien commiteó en ambas máquinas. Resolver a mano: `git -C $MEMORIA_REPO_DIR pull --rebase` tras revisar `git log --oneline HEAD..@{u}`.

**Conflictos de sync de nube** (rclone/OneDrive) → los artefactos van a cuarentena en `Memoria/Archivo/conflictos/` (los mueve el Sueño o `/memory-maintenance`). El capture escribe atómico (tmp+mv) para minimizarlos. En PC-WILSON el bisync corre cada 15 min (`systemctl --user status obsidian-sync.timer`, log en `~/.local/log/obsidian-sync.log`).

**Sync rclone (PC-WILSON) versionado en el repo**: el script `scripts/sync-obsidian.sh` y sus units `scripts/systemd/obsidian-sync.{service,timer}` ahora viven en el repo y los despliega `install.sh` cuando `MEMORIA_SYNC=rclone` (lee `MEMORIA_SYNC_REMOTE`, default `gdrive:Obsidian`). Política de conflicto **`--conflict-resolve newer` + `--conflict-loser delete`**: ante divergencia gana el archivo más nuevo (conserva el nombre canónico) y el perdedor se borra del vault pero queda respaldado en `--backup-dir` (`~/.local/state/obsidian-sync-conflicts` y `<remote>:Obsidian-sync-conflicts`). Esto evita que se acumulen archivos `*.conflict1/2` en el vault. Si aparecen `*.conflict*` legados (creados antes de esta política), restaurar el canónico si falta su base y mover el resto a cuarentena. Nota: BOGWROMEROCA usa OneDrive (otro mecanismo), no este script.

**Restaurar settings.json** → `ls ~/.claude/settings.json.bak.*` y copiar el backup deseado.

## Política de retención

- `Memoria/Archivo/` — permanente (es la red de seguridad del Sueño; no vaciar).
- Backups `obsidian-*.sh.bak` en BOGWROMEROCA — borrar tras 1 semana estable del sistema nuevo.
- `settings.json.bak.*` — conservar los últimos 3.
- Reportes `Suenos/` — el propio Sueño puede archivarlos pasados 90 días.
