# Runbook de administración

## Agregar una máquina nueva

1. Clonar el repo donde quieras (`git clone https://github.com/wilson-romero/claude-memory-system.git`).
2. Ejecutar `./install.sh` una vez: crea `~/.claude/memoria.env` desde `config/memoria.env.example` y se detiene. Editarlo (vault, `MEMORIA_USER`, perfil personal/work, tipo de sync). Un fork que quiera versionar sus configuraciones puede usar `config/machines/<hostname>.env`, que tiene prioridad.
   - Si el perfil es **`personal`**, añadir `MEMORIA_KNOWLEDGE_REMOTE` con el mismo hub que tus demás máquinas (p. ej. `gdrive:Claude-Knowledge`) para que entre en la unión de conocimiento. Debe ser **hermano** de `MEMORIA_SYNC_REMOTE`, nunca estar dentro.
   - Si el perfil es **`work`**, dejarlo sin declarar: esa máquina no participa (y el script se niega igualmente por perfil). Se le lleva conocimiento con `/memory-promote`.
   - Antes de habilitar nada, comprobar que ve el hub de las demás: `rclone lsd <hub>` debe listar `Lecciones`, `Memoria-CC` y `Decisiones`. Si sale vacío, esa máquina está en OTRA cuenta de Drive.
3. `./install.sh --dry-run` para revisar, luego `./install.sh`.
4. Verificar: abrir sesión de Claude Code → debe aparecer el banner de la máquina.

## Escribir una migración

1. Crear `migrations/NNN-descripcion.sh` (siguiente número libre, dos dígitos mínimo).
2. Debe ser **idempotente** (correrla dos veces no duplica nada) y usar las variables `MEMORIA_VAULT_ROOT`, `MEMORIA_MACHINE`, `MEMORIA_REPO_DIR` del entorno.
3. Subir versión en `VERSION` (semver).
4. Commit/push. Cada instalación la aplicará con `/memory-update`.

## Estructura de los hooks (en ~/.claude/settings.json)

- `SessionStart` → command `scripts/memoria-load.sh` (timeout 15s, síncrono: inyecta contexto y **vigila** que la memoria se siga escribiendo)
- `Stop` → los dos en segundo plano, el turno no espera a ninguno:
  - command `scripts/memoria-capture.sh` (30s, `"async": true`)
  - command `scripts/memoria-curator.sh` (900s, `"asyncRewake": true`) — lanza el curador en `claude -p` headless y **sale con código 2 si la memoria no se escribió**, lo que despierta la sesión con el motivo. Antes era un hook `agent` de 120s: los `agent` no aceptan `async`.
- `install.sh` los re-mergea de forma segura: hace backup `settings.json.bak.<timestamp>`, elimina solo los hooks propios (identificados por nombre de script o firma del prompt curador, incluida la del hook `agent` legado) y preserva todo lo demás. **Si cambia la forma del hook, cámbiala aquí**: una reinstalación reescribe el bloque entero.
- Variables opcionales (en `~/.claude/memoria.env`): `MEMORIA_CURATOR_MODEL` y `MEMORIA_DREAM_MODEL` (default `claude-sonnet-5`), `MEMORIA_CURATOR_TIMEOUT` (600s), `MEMORIA_MISS_ALERT_AFTER` (5 sesiones).

## Archivos de estado

| Archivo | Contenido |
|---|---|
| `~/.claude/memoria.env` | config de la máquina (fuera del repo) |
| `~/.claude/memoria-state` | `VERSION=`, `MIGRATION_NNN=done`, `LAST_DREAM=`, `LAST_FETCH=` |
| `~/.claude/memoria-curator-prompt.md` | prompt curador renderizado |
| `~/.claude/memoria-dream-prompt.md` | prompt del Sueño renderizado |

## Troubleshooting

**Logs**: `tail -50 ~/.local/log/memoria-cc.log` (capture, dream, load).

**El capture no escribe** → probar a mano:
`echo '{"cwd":"/ruta/proyecto","session_id":"test","transcript_path":""}' | bash scripts/memoria-capture.sh` y revisar el log.

**El banner avisa "La memoria NO se escribe: … lleva N sesiones sin trabajo verificado"** → el
contador de `memoria-load.sh` no se ha reseteado, así que capture o el curador llevan N sesiones sin
escribir nada comprobable. Diagnóstico, en este orden:
1. `grep -E "curator|capture" ~/.local/log/memoria-cc.log | tail -30` — cada corrida del curador deja
   `curator: WROTE <n> file(s) [lista]`, `curator: skipped by model (trivial …)` o `curator: FAILED — <motivo>`.
2. Probar el curador a mano (corre en primer plano, tarda ~1 min):
   `echo '{"cwd":"/ruta/proyecto","session_id":"test","transcript_path":"","stop_hook_active":false}' | bash scripts/memoria-curator.sh; echo "exit=$?"`
   Sale 0 si escribió o si la sesión era trivial; sale 2 con el motivo en stderr si no.
3. Si son 5 sesiones triviales seguidas el aviso es un falso positivo: `LAST_CURATOR_SKIP` en
   `~/.claude/memoria-state` lo delata. Resetear a mano con
   `sed -i 's/^SESSIONS_SINCE_CURATOR=.*/SESSIONS_SINCE_CURATOR=0/' ~/.claude/memoria-state`.

**El Sueño no corre** → `systemctl --user status memoria-dream.timer`; forzar con `bash scripts/memoria-dream.sh --force`. Si falta el binario claude o el prompt renderizado, la Fase 2 se salta (queda en el log) pero la Fase 1 siempre corre.

**`update.sh` falla con "not fast-forward"** → tu clon tiene commits locales que el remoto no tiene. Resolver a mano: `git -C $MEMORIA_REPO_DIR pull --rebase` tras revisar `git log --oneline HEAD..@{u}`.

**Conflictos de sync de nube** (rclone/OneDrive) → los artefactos van a cuarentena en `Memoria/Archivo/conflictos/` (los mueve el Sueño o `/memory-maintenance`). El capture escribe atómico (tmp+mv) para minimizarlos. Con `MEMORIA_SYNC=rclone` el bisync corre cada 15 min (`systemctl --user status obsidian-sync.timer`, log en `~/.local/log/obsidian-sync.log`).

**Sync rclone (máquinas personales) versionado en el repo**: el script `scripts/sync-obsidian.sh` y sus units `scripts/systemd/obsidian-sync.{service,timer}` ahora viven en el repo y los despliega `install.sh` cuando `MEMORIA_SYNC=rclone` (lee `MEMORIA_SYNC_REMOTE`, default `gdrive:Obsidian`). Política de conflicto **`--conflict-resolve newer` + `--conflict-loser delete`**: ante divergencia gana el archivo más nuevo (conserva el nombre canónico) y el perdedor se borra del vault pero queda respaldado en `--backup-dir` (`~/.local/state/obsidian-sync-conflicts` y `<MEMORIA_SYNC_REMOTE>-sync-conflicts`, una carpeta por máquina desde v1.5.0: antes las dos escribían en la misma y podían pisarse la única copia superviviente). Esto evita que se acumulen archivos `*.conflict1/2` en el vault. Si aparecen `*.conflict*` legados (creados antes de esta política), restaurar el canónico si falta su base y mover el resto a cuarentena. Las máquinas con `MEMORIA_SYNC=onedrive` o `none` no usan este script.

**Restaurar settings.json** → `ls ~/.claude/settings.json.bak.*` y copiar el backup deseado.

## Política de retención

- `Memoria/Archivo/` — permanente (es la red de seguridad del Sueño; no vaciar).
- `settings.json.bak.*` — conservar los últimos 3.
- Reportes `Suenos/` — el propio Sueño puede archivarlos pasados 90 días.
