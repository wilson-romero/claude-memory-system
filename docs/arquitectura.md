# Arquitectura del sistema de segunda memoria

## Capas y propiedad de escritura

```
┌─────────────────────────────────────────────────────────────────┐
│ VAULT (uno por máquina — el vault y su remoto, NO el conocimiento)│
│                                                                 │
│ ── CONOCIMIENTO: compartido entre las máquinas PERSONALES ────  │
│  Memoria-CC/         ← CURADOR + auto-memory nativo + SUEÑO     │
│    MEMORY*.md (índice y ramas, NO se comparten: son curados)    │
│    feedback_* project_* reference_*                             │
│  Lecciones/          ← CURADOR   (_INDEX.md NO se comparte)     │
│  Decisiones/         ← CURADOR   (_INDEX.md NO se comparte)     │
│                                                                 │
│ ── SESIÓN: por máquina, nunca cruza ─────────────────────────   │
│  Memoria/            ← CURADOR (agente) + el usuario a mano     │
│    contexto-reciente.md, proyectos-activos.md, personas.md,     │
│    preferencias.md, perfil.md                                   │
│    Archivo/          ← SUEÑO (archiva, nunca borra)             │
│    Suenos/           ← SUEÑO (reportes nocturnos)               │
│  projects/<slug>/    ← CAPTURE (script determinista) SOLAMENTE  │
│  daily/              ← CAPTURE SOLAMENTE                        │
│  agents/             ← CAPTURE SOLAMENTE                        │
│  _index.md           ← CAPTURE SOLAMENTE                        │
└─────────────────────────────────────────────────────────────────┘
```

**El conocimiento se comparte solo entre máquinas del mismo perfil de confidencialidad.** Las
personales (`personal`) lo unen automáticamente; la de **trabajo** (`work`)
**nunca cruza nada** — no declara `MEMORIA_KNOWLEDGE_REMOTE`, y además el script de unión se niega
a correr bajo `MEMORIA_PROFILE=work`. La única vía para llevarle una lección es
**promoverla** a mano con `/memory-promote`, que revisa, limpia datos de cliente y exige
aprobación de commit. Es deliberado: impide que contenido de cliente salga de la máquina de
trabajo por un automatismo.

Regla de oro: **ownership disjunto**. El capture (determinista) y el curador (agente) nunca escriben en las mismas rutas → cero conflictos aunque corran en paralelo. El Sueño solo toca capas semánticas y jamás los datos crudos.

## Flujo de una sesión

1. **SessionStart** → `memoria-load.sh` inyecta (~6KB): banner de máquina, `_project.md` del proyecto actual, última entrada de contexto-reciente, índice de agentes, índice de shared-knowledge. También: aviso de versión desactualizada y lanzamiento del Sueño si lleva >24h sin correr.
2. **Trabajo normal** — Claude puede leer cualquier archivo del vault con Read.
3. **Stop** → dos hooks, **los dos en segundo plano** (desde v1.4.0 el turno se libera al instante):
   - `memoria-capture.sh` — `"async": true`: nota de sesión, `_project.md`, daily, índices, banco de agentes. SIEMPRE corre. Nada decide sobre su salida, así que no hay razón para esperarlo.
   - `memoria-curator.sh` — `"asyncRewake": true`: lanza el curador en `claude -p` headless (destila contexto-reciente, lecciones, feedback a Memoria-CC; salida temprana si la sesión fue trivial). **No puede ser un hook `agent`**: los hooks `agent` no aceptan `async` ni `asyncRewake`, y por eso cada turno pagaba hasta sus 120 s.
4. **La garantía de que la memoria se escriba** — ver § *Hooks asíncronos sin fallo silencioso*.
5. **03:30** → `memoria-dream.timer` ejecuta el Sueño (ver abajo).

## Hooks asíncronos sin fallo silencioso

Volver asíncronos los hooks del `Stop` mueve el riesgo: **un trabajo en segundo plano que falla en
silencio deja de escribir memoria y nada se queja** — el mismo fallo del `.timer` verde que estuvo 43
días sin hacer su trabajo. Tres piezas lo cubren, y ninguna confía en la anterior:

1. **Se verifica el TRABAJO, no el intento.** `memoria-curator.sh` mide qué archivos de
   `Memoria/`, `Lecciones/`, `Memoria-CC/` y `Decisiones/` cambiaron de `mtime` **después** de
   arrancar la corrida. Solo si hay al menos uno escribe la marca fechada
   `LAST_CURATOR_WRITE` y registra en el log **la lista de archivos**. El curador además debe
   cerrar con una línea de contrato (`CURATOR: WROTE` / `CURATOR: SKIPPED`); decir `WROTE` sin
   que ningún `mtime` se mueva **es un fallo**, no un éxito.
2. **El aviso viaja de vuelta al modelo.** El hook es `asyncRewake`, así que **salir con código 2**
   despierta la sesión con el motivo en un system-reminder. Si el curador salió bien, no dice nada.
   El turno que provoca ese despertar llega con `stop_hook_active: true`, y ahí el script sale de
   inmediato: sin esa guarda un fallo curaría en bucle, un `claude -p` por vuelta. Ojo —
   `stop_hook_active` **no es solo nuestro**: cualquier notificación de tarea en segundo plano
   despierta la sesión igual (medido el 2026-07-30). Por eso solo se salta **el despertar que
   provocamos nosotros**, identificado por sesión y hora en `~/.claude/memoria-curator-rewake`;
   los demás se curan con normalidad, o el último turno de esas sesiones se quedaría sin memoria.
3. **Un contador que NO depende de los hooks asíncronos.** `memoria-load.sh` (SessionStart, y este
   sí es síncrono) suma 1 a `SESSIONS_SINCE_CAPTURE` y `SESSIONS_SINCE_CURATOR` en cada sesión que
   empieza; capture y curador **solo los ponen a 0 tras verificar su escritura**. A las
   `MEMORIA_MISS_ALERT_AFTER` (5 por defecto) sesiones sin trabajo verificado, el banner de inicio
   avisa con la fecha de la última escritura real. Si dejara de contar, desaparecería el banner de
   contexto: un fallo **visible**, no silencioso.

El curador headless corre con `--settings '{"disableAllHooks": true, permissions…}'`: sin eso su
propio `Stop` volvería a lanzar el curador (recursión), y sin las reglas `Read()`/`Edit()` del vault
un prompt de permiso en modo `-p` equivale a una denegación. Hay una segunda guarda de recursión por
si `disableAllHooks` dejara de honrarse (`MEMORIA_CURATOR_ACTIVE`) y un `flock` que impide que dos
curadores editen los mismos archivos curados a la vez.

## El Sueño (consolidación nocturna)

- **Fase 1** (determinista, sin tokens): repara enlaces `[[rotos]]` (solo correcciones inequívocas), detecta huérfanos y duplicados, pone en cuarentena archivos de conflicto de sync, audita MEMORY.md.
- **Fase 2** (`claude -p` headless, `claude-sonnet-5`): fusiona duplicados, compacta contexto-reciente (>30 días → `Archivo/contexto-YYYY-MM.md`), archiva lo obsoleto (NUNCA borra), enriquece el índice. No tiene Bash: los archivados los **pide** en `Memoria/Archivo/_mover.txt` (`origen => destino`) y el script los aplica solo si van de una zona curada a `Memoria/Archivo/`.
- Reporte auditable en `Memoria/Suenos/YYYY-MM-DD.md`. Máx 10 archivos por noche.
- Solo corre si hubo actividad desde el último sueño.

## Los procesos headless solo escriben en el vault

El curador y la Fase 2 del Sueño trabajan sin nadie que apruebe nada y leen material **no confiable**: el transcript incluye páginas web y salidas de herramientas, que pueden traer instrucciones. Por eso los dos arrancan con `vault_only_claude_args` (`scripts/lib/common.sh`):

- `--restricted` → el hijo **no hereda** `~/.claude/settings.json` (ni su `defaultMode`, ni sus reglas `allow`, ni sus hooks);
- `--strict-mcp-config` y `--tools "Read,Edit,Write,Glob,Grep"` → sin MCP, sin Bash, sin WebFetch;
- `--permission-mode dontAsk` + `Edit(/<vault>/**)` → solo escribe dentro del vault; el resto se deniega;
- lee solo el vault (su cwd) y, en el curador, una **copia** del transcript en un directorio temporal pasado con `--add-dir`.

Medido en 2.1.285: con el antiguo `--allowedTools "Read,Write,Edit,Glob,Grep"` el hijo copió un fichero de fuera del vault hacia dentro **sin ninguna denegación**; con estos flags `Read` y `Grep` quedan en `permission_denials`. Una regla `Read()` para un único fichero fuera del cwd **no** se respetó, y por eso el transcript va copiado y no por regla.

## Sincronización

Hay **tres** mecanismos, y cada uno existe porque el contenido que mueve tiene una semántica distinta. Confundirlos borra datos.

### 1. Vault ↔ nube (por máquina) — `sync-obsidian.sh`

Cada máquina con su propia carpeta remota (`MEMORIA_SYNC_REMOTE`, p. ej. `gdrive:Obsidian-portatil` y `gdrive:Obsidian-sobremesa`). Una máquina cuyo vault ya sincroniza otra herramienta (OneDrive, Obsidian Sync…) declara `MEMORIA_SYNC=onedrive` o `none` y queda fuera: `install.sh` no le despliega timer de vault. **Nunca compartir una carpeta remota de VAULT entre dos máquinas**: sus vaults no son intercambiables (`contexto-reciente.md` llegó a pesar 87 KB en una y 571 KB en otra, `projects/` 195 vs 522 archivos) y `--conflict-resolve newer` haría desaparecer un lado en silencio.

> La carpeta del mecanismo 2 **sí** se comparte, y no contradice lo anterior: lleva solo
> conocimiento append-only, se une con `copy --ignore-existing` (que no sobrescribe ni borra) y
> no toca nada curado. Lo peligroso no es compartir: es compartir **con `bisync`** contenido que
> tiene un dueño por máquina.

Los conflictos de bisync se respaldan en `<remoto de la máquina>-sync-conflicts`. Antes iban todos a `gdrive:Obsidian-sync-conflicts`, así que dos máquinas podían pisarse la única copia de un fichero que bisync ya había borrado en local.

### 2. Conocimiento ↔ máquina personal — `sync-knowledge.sh`

`Lecciones/`, `Memoria-CC/` y `Decisiones/` **sí** se comparten entre las máquinas **personales**, porque el objetivo del sistema es que ese conocimiento esté disponible venga Claude Code de donde venga. Sin esto el conocimiento se parte: en julio de 2026, de 478 archivos entre dos máquinas, **solo 1 coincidía**.

El transporte es un **hub**, no un peer: una única carpeta compartida en Drive
(`MEMORIA_KNOWLEDGE_REMOTE`, p. ej. `gdrive:Claude-Knowledge`) contra la que cada máquina personal
empuja y de la que baja. Ninguna máquina conoce a la otra. Antes era `rsync` sobre SSH directo al
peer, que exigía **las dos encendidas a la vez**: de 87 ejecuciones registradas, **40 no hicieron
nada** porque la otra estaba apagada. El hub quita esa condición y, de paso, es una copia off-site
del conocimiento.

El hub es **hermano** de los remotos de vault, nunca hijo: colgado de `gdrive:Obsidian/…`, el bisync
del mecanismo 1 se lo bajaría dentro del vault y la siguiente unión volvería a subir la copia.
`sync-knowledge.sh` se niega a correr en esa forma.

Es **unión, no sincronización**: `rclone copy --ignore-existing` en ambos sentidos. Un archivo = una
lección, se escribe una vez y casi no se edita, así que `--ignore-existing` **solo puede añadir —
nunca sobrescribe ni borra**. Sin conflictos, sin baseline, sin `--resync`.

`_INDEX.md` y `MEMORY*.md` quedan **excluidos**: son resúmenes curados —`MEMORY.md` y sus ramas
`MEMORY-<tema>.md`—, no artefactos append-only; copiarlos a ciegas los estropea. Los fusiona el
curador o el Sueño.

> ⚠️ **El precio de `--ignore-existing`: la unión trae ficheros NUEVOS, no propaga MEJORAS.**
> Editar una lección que ya existe en la otra máquina no viaja **nunca** — se queda anclada
> donde nació. Y el chequeo barato no lo ve: el **2026-07-29** las dos máquinas tenían los
> **mismos 493 nombres, ninguno exclusivo, y 10 diferían en contenido**. Contar ficheros da
> verde; la comprobación válida es **md5 por fichero** (la hace `/memory-maintenance`).
>
> Al reconciliar, **la dirección correcta cambia por fichero** y por eso `sync-knowledge.sh`
> **reporta pero no resuelve**: ese día 6 ficheros estaban mejor en una máquina y **1 estaba
> mejor en la otra** (146 líneas contra 117: llevaba la corrección que la copia local
> todavía negaba). Una copia en bloque en cualquier sentido habría borrado conocimiento bueno.

> ⚠️ **Y borrar en local no borra en el hub**: el siguiente pull resucita el fichero. Retirar
> conocimiento compartido es **vaciarlo y dejar lápida**, no borrarlo. Con el peer SSH pasaba
> lo mismo; lo que cambia es que ahora hay un tercer sitio donde vive la copia.

Se activa solo en las máquinas que declaren `MEMORIA_KNOWLEDGE_REMOTE` en su `~/.claude/memoria.env`. Si el hub no responde —WiFi caído, portátil en el tren— registra `OFFLINE (n/3)` y sale con 0; a partir de `MEMORIA_KNOWLEDGE_FAIL_LIMIT` intentos seguidos sale con **1** y el servicio se pone rojo. Ese contador es lo que distingue "sin red un rato" de "el token de Drive caducó", que es la forma en que este sistema ya perdió 43 días en verde.

**Una máquina de trabajo queda aislada por dos vías independientes**: no declara `MEMORIA_KNOWLEDGE_REMOTE`, y además `sync-knowledge.sh` **se niega a correr con `MEMORIA_PROFILE=work`** aunque alguien se lo configure por error. La configuración sola era la protección hasta v1.5.0, y una configuración está a una edición de estar mal.

### 3. El sistema (este repo)

Repositorio público y **genérico**: no lleva la configuración ni la memoria de nadie. `update.sh` = pull + migraciones + re-render. Lo propio de cada usuario vive fuera del repo:

- la configuración, en `~/.claude/memoria.env` (la crea `install.sh` desde `config/memoria.env.example`);
- el conocimiento promovido, en `MEMORIA_SHARED_DIR` (por defecto `~/.claude/shared-knowledge`), cuyo `INDEX.md` se inyecta en cada sesión. `/memory-promote` escribe ahí tras revisar y limpiar datos de cliente; es la vía para llevar una lección genérica **a la máquina de trabajo**, que no participa de la unión. Si esa carpeta es un repo git privado del usuario, la promoción propone además el commit.

### Regla para decidir el mecanismo

| Contenido | Semántica | Herramienta |
|---|---|---|
| Append-only (una lección = un archivo) | **unión** | `rclone copy --ignore-existing` a un hub compartido |
| Curado y mutable (contexto, índices) | dueño único o fusión manual | nunca bisync compartido |
| Estado local de la máquina | copia a su nube | `rclone bisync` con remoto propio |

## Versionado

`VERSION` (semver) + `migrations/NNN-*.sh` idempotentes + estado por máquina en `~/.claude/memoria-state`. El SessionStart avisa cuando hay versión nueva (git fetch 1×/día, timeout 3s, falla silenciosa).
