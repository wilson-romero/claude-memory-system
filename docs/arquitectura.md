# Arquitectura del sistema de segunda memoria

## Capas y propiedad de escritura

```
┌─────────────────────────────────────────────────────────────────┐
│ VAULT (uno por máquina, nunca cruza)                            │
│                                                                 │
│  Memoria/            ← CURADOR (agente) + Wilson a mano         │
│    contexto-reciente.md, proyectos-activos.md, personas.md,     │
│    preferencias-jarvis.md, wilson-perfil.md                     │
│    Archivo/          ← SUEÑO (archiva, nunca borra)             │
│    Suenos/           ← SUEÑO (reportes nocturnos)               │
│  Memoria-CC/         ← CURADOR + auto-memory nativo + SUEÑO     │
│    MEMORY.md (índice) + feedback_* project_* reference_*        │
│  Lecciones/          ← CURADOR                                  │
│  projects/<slug>/    ← CAPTURE (script determinista) SOLAMENTE  │
│  daily/              ← CAPTURE SOLAMENTE                        │
│  agents/             ← CAPTURE SOLAMENTE                        │
│  _index.md           ← CAPTURE SOLAMENTE                        │
└─────────────────────────────────────────────────────────────────┘
```

Regla de oro: **ownership disjunto**. El capture (determinista) y el curador (agente) nunca escriben en las mismas rutas → cero conflictos aunque corran en paralelo. El Sueño solo toca capas semánticas y jamás los datos crudos.

## Flujo de una sesión

1. **SessionStart** → `memoria-load.sh` inyecta (~6KB): banner de máquina, `_project.md` del proyecto actual, última entrada de contexto-reciente, índice de agentes, índice de shared-knowledge. También: aviso de versión desactualizada y lanzamiento del Sueño si lleva >24h sin correr.
2. **Trabajo normal** — Claude puede leer cualquier archivo del vault con Read.
3. **Stop** → dos hooks:
   - `memoria-capture.sh` (30s): nota de sesión, `_project.md`, daily, índices, banco de agentes. SIEMPRE corre.
   - Curador (agente, 120s): destila contexto-reciente, lecciones, feedback a Memoria-CC. Salida temprana si la sesión fue trivial.
4. **03:30** → `memoria-dream.timer` ejecuta el Sueño (ver abajo).

## El Sueño (consolidación nocturna)

- **Fase 1** (determinista, sin tokens): repara enlaces `[[rotos]]` (solo correcciones inequívocas), detecta huérfanos y duplicados, pone en cuarentena archivos de conflicto de sync, audita MEMORY.md.
- **Fase 2** (`claude -p` headless, modelo haiku): fusiona duplicados, compacta contexto-reciente (>30 días → `Archivo/contexto-YYYY-MM.md`), archiva lo obsoleto (NUNCA borra), enriquece el índice.
- Reporte auditable en `Memoria/Suenos/YYYY-MM-DD.md`. Máx 10 archivos por noche.
- Solo corre si hubo actividad desde el último sueño.

## Sincronización

- **Contenido del vault**: cada máquina con su nube (PC-WILSON: rclone bisync → Google Drive cada 15 min; BOGWROMEROCA: OneDrive vía symlink). El contenido nunca cruza máquinas.
- **El sistema** (este repo): git privado en GitHub. `update.sh` = pull + migraciones + re-render.
- **shared-knowledge/**: viaja con el repo; promoción solo manual con `/memory-promote` (revisión + scrub de datos de cliente + aprobación de commit).

## Versionado

`VERSION` (semver) + `migrations/NNN-*.sh` idempotentes + estado por máquina en `~/.claude/memoria-state`. El SessionStart avisa cuando hay versión nueva (git fetch 1×/día, timeout 3s, falla silenciosa).
