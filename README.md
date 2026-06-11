# claude-memory-system

Sistema unificado de "segunda memoria" Obsidian para Claude Code, desplegado en los equipos de Wilson (PC-WILSON personal, BOGWROMEROCA trabajo). Los vaults son **separados por máquina** (confidencialidad); el **sistema es el mismo** y vive en este repo.

## Instalación en una máquina nueva

```bash
git clone git@github.com:wilson-romero/claude-memory-system.git ~/Code/wilson-romero/claude-memory-system
cd ~/Code/wilson-romero/claude-memory-system
cp config/memoria.env.example config/machines/$(hostname).env   # editar rutas
./install.sh --dry-run && ./install.sh
```

## Actualizar a la última versión

```bash
/memory-update        # desde Claude Code
# o:
./update.sh
```

## Documentación

- [docs/arquitectura.md](docs/arquitectura.md) — capas del sistema y quién escribe qué
- [docs/convenciones.md](docs/convenciones.md) — frontmatter, slugs, índices
- [docs/runbook-uso.md](docs/runbook-uso.md) — uso diario
- [docs/runbook-admin.md](docs/runbook-admin.md) — administración y troubleshooting

## Estructura

| Carpeta | Contenido |
|---|---|
| `scripts/` | hooks (load/capture), proceso nocturno (dream), systemd, migraciones one-time |
| `skills/` | comandos `/memory-*` (symlink a `~/.claude/commands/`) |
| `templates/` | prompts del curador y del sueño, plantillas de archivos curados |
| `migrations/` | migraciones numeradas e idempotentes del vault/config |
| `config/machines/` | configuración por máquina (vault, perfil) |
| `shared-knowledge/` | lecciones técnicas genéricas compartidas entre máquinas (sin datos de cliente) |
