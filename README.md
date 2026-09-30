# claude-memory-system

Una "segunda memoria" para [Claude Code](https://claude.com/claude-code) guardada en un vault de [Obsidian](https://obsidian.md). Al cerrar cada sesión, un script registra lo que pasó y un curador lo destila en contexto reciente, lecciones y preferencias. Al abrir la siguiente, lo relevante se inyecta solo. Cada noche un proceso de consolidación (el "Sueño") fusiona duplicados, archiva lo viejo y repara el índice.

Todo es Markdown en tu vault: lo lees, lo editas y lo buscas desde Obsidian como cualquier otra nota.

## Requisitos

- Claude Code (CLI) con sesión iniciada
- Linux o WSL con `bash`, `git` y `python3`
- Un vault de Obsidian (basta con una carpeta; Obsidian es opcional para leerlo)
- Opcional: `systemd --user` para el Sueño nocturno, y `rclone` ≥ 1.66 para sincronizar el vault o compartir conocimiento entre máquinas

## Instalación

```bash
git clone https://github.com/wilson-romero/claude-memory-system.git
cd claude-memory-system
./install.sh              # la primera vez crea ~/.claude/memoria.env y se detiene
$EDITOR ~/.claude/memoria.env   # como mínimo: MEMORIA_VAULT_ROOT y MEMORIA_USER
./install.sh --dry-run && ./install.sh
```

El instalador añade dos hooks a `~/.claude/settings.json` (guarda antes un backup), crea la estructura en el vault, enlaza los comandos `/memory-*` e instala los timers de systemd que correspondan. Se puede volver a ejecutar sin riesgo.

Para actualizar: `/memory-update` desde Claude Code, o `./update.sh`.

## Qué hace

| Momento | Qué pasa |
|---|---|
| Inicio de sesión | Inyecta ~6 KB de contexto: memoria del proyecto actual, lo último que pasó y el índice de lecciones |
| Fin de cada turno | Guarda la nota de la sesión (script determinista) y lanza el curador en segundo plano |
| Cada noche, 03:30 | El Sueño consolida: fusiona, compacta, archiva (nunca borra) y deja un reporte |

Comandos: `/memory-load`, `/memory-save`, `/memory-promote`, `/memory-maintenance`, `/memory-update`. Ver [docs/runbook-uso.md](docs/runbook-uso.md).

## Seguridad

El curador y el Sueño son procesos `claude -p` sin nadie que apruebe sus acciones, y leen material no confiable: el transcript de la sesión cita páginas web y salidas de herramientas. Por eso arrancan sin tus settings de usuario, sin Bash, sin MCP y sin WebFetch, y **solo pueden escribir dentro del vault**. El detalle, con la medición que lo justifica, está en [docs/arquitectura.md](docs/arquitectura.md#los-procesos-headless-solo-escriben-en-el-vault).

Antes de escribir en el vault se enmascaran los formatos de credencial conocidos (tokens de GitHub, claves de Anthropic, OpenAI, AWS…), y la memoria se inyecta en cada sesión marcada como datos, no como instrucciones. Son mitigaciones: tu memoria sigue conteniendo lo que hablas con Claude, y si sincronizas el vault con una nube, esa nube guarda tus conversaciones destiladas. No pegues secretos en el chat.

## Documentación

- [docs/arquitectura.md](docs/arquitectura.md): capas del sistema, quién escribe qué y por qué
- [docs/convenciones.md](docs/convenciones.md): frontmatter, slugs e índices
- [docs/runbook-uso.md](docs/runbook-uso.md): uso diario
- [docs/runbook-admin.md](docs/runbook-admin.md): administración y resolución de problemas

## Estructura

| Carpeta | Contenido |
|---|---|
| `scripts/` | hooks (load/capture/curator), Sueño, sincronización y units de systemd |
| `skills/` | comandos `/memory-*` (se enlazan en `~/.claude/commands/`) |
| `templates/` | prompts del curador y del Sueño, y plantillas de los archivos curados |
| `migrations/` | migraciones numeradas e idempotentes del vault y la configuración |
| `config/` | `memoria.env.example`, la plantilla de configuración |

## Idioma

Los prompts, la documentación y la memoria que se genera están en español. El código y los comentarios, en inglés.

## Contribuir

Issues y pull requests son bienvenidos. Los cambios de comportamiento van acompañados de su prueba. Los commits, en inglés y con [gitmoji](https://gitmoji.dev/).

## Licencia

[MIT](LICENSE)
