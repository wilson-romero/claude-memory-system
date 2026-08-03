# Runbook de uso diario

## Qué pasa automáticamente

**Al abrir una sesión de Claude Code:**
- Se inyecta contexto del vault (~6KB): máquina, memoria del proyecto actual, última entrada de contexto reciente, banco de agentes y conocimiento compartido.
- Si el sistema tiene versión nueva en GitHub, verás: `⚠ Sistema de memoria desactualizado... Ejecuta /memory-update`.
- Si el Sueño nocturno no corrió en >24h, se lanza solo en background.

**Al cerrar una sesión:**
- El script de captura guarda SIEMPRE: nota de sesión (`projects/<slug>/sessions/`), historial del proyecto, nota diaria (`daily/`), índices.
- El curador (agente) destila: contexto reciente, lecciones técnicas, feedback. Si la sesión fue trivial, no escribe nada.

**Cada 30 minutos (solo máquinas personales):**
- El conocimiento (`Lecciones/`, `Memoria-CC/`, `Decisiones/`) viaja por una carpeta compartida de Drive, así que **no hace falta que la otra máquina esté encendida**.
- Es una **unión**: solo añade. Editar una lección que ya existe al otro lado no viaja, y **borrarla en local no la borra del hub** — el siguiente ciclo la baja otra vez. Para retirar algo compartido: vaciarlo y dejar lápida.

**Cada noche a las 03:30 (o al encender el equipo si estaba apagado):**
- El Sueño repara enlaces, fusiona duplicados, archiva lo viejo y deja reporte en `Memoria/Suenos/YYYY-MM-DD.md`.

## Comandos

| Comando | Qué hace |
|---|---|
| `/memory-load` | Carga la memoria completa (perfil, preferencias, proyectos, contexto) y muestra resumen |
| `/memory-save [foco]` | Guardado manual dirigido (ej: `/memory-save la decisión sobre el API`) |
| `/memory-promote <lección>` | Comparte una lección genérica con el otro equipo (revisa, limpia datos de cliente, pide aprobación) |
| `/memory-maintenance` | Chequeo de salud: conflictos, staleness, versión, sueño, integridad del índice |
| `/memory-update` | Actualiza el sistema a la última versión del repo |

## Cómo buscar en la memoria

- **Desde Claude Code**: pídele que busque — usa Grep/Read sobre el vault. Ej: "busca en mi memoria cómo resolvimos el problema de NullPool".
- **Desde Obsidian**: búsqueda global, o navega `_index.md` → proyectos → sesiones, o `Memoria-CC/MEMORY.md` → lecciones.
- **Historial de un proyecto**: `projects/<slug>/_project.md` tiene las últimas 10 sesiones enlazadas.
- **Qué hice tal día**: `daily/YYYY-MM-DD.md`.

## Situaciones comunes

**Aviso de versión desactualizada** → ejecuta `/memory-update`. Listo.

**Conflicto de sync (archivos `..path1`, `.sync-conflict-...`)** → `/memory-maintenance` los detecta y los pone en cuarentena en `Memoria/Archivo/conflictos/`. Revisa ahí si algo se perdió.

**El Sueño archivó algo que necesito** → abre el reporte `Memoria/Suenos/YYYY-MM-DD.md` para ver qué movió y por qué; recupera el archivo moviéndolo de vuelta desde `Memoria/Archivo/` (en Obsidian o con `mv`). Nada se borra nunca.

**Quiero que Claude recuerde algo específico** → díselo directamente ("memoriza que...") o usa `/memory-save <eso>` al final de la sesión.

**El contexto inyectado se ve vacío en un proyecto nuevo** → normal: la nota `_project.md` se crea al cerrar la primera sesión en ese directorio.
