# Arquitectura del sistema de segunda memoria

## Capas y propiedad de escritura

```
┌─────────────────────────────────────────────────────────────────┐
│ VAULT (uno por máquina)                                         │
│                                                                 │
│ ── CONOCIMIENTO: compartido entre las máquinas PERSONALES ────  │
│  Memoria-CC/         ← CURADOR + auto-memory nativo + SUEÑO     │
│    MEMORY.md (índice, NO se comparte: es resumen curado)        │
│    feedback_* project_* reference_*                             │
│  Lecciones/          ← CURADOR   (_INDEX.md NO se comparte)     │
│  Decisiones/         ← CURADOR   (_INDEX.md NO se comparte)     │
│                                                                 │
│ ── SESIÓN: por máquina, nunca cruza ─────────────────────────   │
│  Memoria/            ← CURADOR (agente) + Wilson a mano         │
│    contexto-reciente.md, proyectos-activos.md, personas.md,     │
│    preferencias-jarvis.md, wilson-perfil.md                     │
│    Archivo/          ← SUEÑO (archiva, nunca borra)             │
│    Suenos/           ← SUEÑO (reportes nocturnos)               │
│  projects/<slug>/    ← CAPTURE (script determinista) SOLAMENTE  │
│  daily/              ← CAPTURE SOLAMENTE                        │
│  agents/             ← CAPTURE SOLAMENTE                        │
│  _index.md           ← CAPTURE SOLAMENTE                        │
└─────────────────────────────────────────────────────────────────┘
```

**El conocimiento se comparte solo entre máquinas del mismo perfil de confidencialidad.** Las
personales (`personal`) lo unen automáticamente; la de **trabajo** (`work`, BOGWROMEROCA)
**nunca cruza nada** — no declara `MEMORIA_PEER`. La única vía para llevarle una lección es
**promoverla** a mano con `/memory-promote`, que revisa, limpia datos de cliente y exige
aprobación de commit. Es deliberado: impide que contenido de cliente salga de la máquina de
trabajo por un automatismo.

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

Hay **tres** mecanismos, y cada uno existe porque el contenido que mueve tiene una semántica distinta. Confundirlos borra datos.

### 1. Vault ↔ nube (por máquina) — `sync-obsidian.sh`

Cada máquina con su propia carpeta remota: `mark-PC` → `gdrive:Obsidian`, `PC-WILSON` → `gdrive:Obsidian-PC-WILSON`, `BOGWROMEROCA` → OneDrive vía symlink. **Nunca compartir una carpeta remota entre dos máquinas**: sus vaults no son intercambiables (`contexto-reciente.md` llegó a pesar 87 KB en una y 571 KB en otra, `projects/` 195 vs 522 archivos) y `--conflict-resolve newer` haría desaparecer un lado en silencio.

### 2. Conocimiento ↔ máquina personal — `sync-knowledge.sh`

`Lecciones/`, `Memoria-CC/` y `Decisiones/` **sí** se comparten entre las máquinas **personales**, porque el objetivo del sistema es que ese conocimiento esté disponible venga Claude Code de donde venga. Sin esto el conocimiento se parte: en julio de 2026, de 478 archivos entre `mark-PC` y `PC-WILSON`, **solo 1 coincidía**.

Es **unión, no sincronización**: `rsync -a --ignore-existing` en ambos sentidos. Un archivo = una lección, se escribe una vez y casi no se edita, así que `--ignore-existing` **solo puede añadir — nunca sobrescribe ni borra**. Sin conflictos, sin baseline, sin `--resync`.

`_INDEX.md` y `MEMORY.md` quedan **excluidos**: son resúmenes curados, no artefactos append-only; copiarlos a ciegas los estropea. Los fusiona el curador o el Sueño.

> ⚠️ **El precio de `--ignore-existing`: la unión trae ficheros NUEVOS, no propaga MEJORAS.**
> Editar una lección que ya existe en la otra máquina no viaja **nunca** — se queda anclada
> donde nació. Y el chequeo barato no lo ve: el **2026-07-29** las dos máquinas tenían los
> **mismos 493 nombres, ninguno exclusivo, y 10 diferían en contenido**. Contar ficheros da
> verde; la comprobación válida es **md5 por fichero** (la hace `/memory-maintenance`).
>
> Al reconciliar, **la dirección correcta cambia por fichero** y por eso `sync-knowledge.sh`
> **reporta pero no resuelve**: ese día 6 ficheros estaban mejor en `mark-PC` y **1 estaba
> mejor en `PC-WILSON`** (146 líneas contra 117: llevaba la corrección que la copia local
> todavía negaba). Una copia en bloque en cualquier sentido habría borrado conocimiento bueno.

Se activa solo en las máquinas que declaren `MEMORIA_PEER` / `MEMORIA_PEER_VAULT` en su `.env`. Si el peer está apagado —normal en equipos personales— registra y sale con 0. **BOGWROMEROCA (trabajo) no declara peer**, y así queda aislada.

### 3. El sistema (este repo)

Git privado en GitHub. `update.sh` = pull + migraciones + re-render. **`shared-knowledge/`** viaja con el repo; promoción solo manual con `/memory-promote` (revisión + scrub de datos de cliente + aprobación de commit) — es la vía para llevar una lección genérica **a la máquina de trabajo**, que no participa de la unión.

### Regla para decidir el mecanismo

| Contenido | Semántica | Herramienta |
|---|---|---|
| Append-only (una lección = un archivo) | **unión** | `rsync --ignore-existing` |
| Curado y mutable (contexto, índices) | dueño único o fusión manual | nunca bisync compartido |
| Estado local de la máquina | copia a su nube | `rclone bisync` con remoto propio |

## Versionado

`VERSION` (semver) + `migrations/NNN-*.sh` idempotentes + estado por máquina en `~/.claude/memoria-state`. El SessionStart avisa cuando hay versión nueva (git fetch 1×/día, timeout 3s, falla silenciosa).
