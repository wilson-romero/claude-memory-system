# Convenciones

## Frontmatter estándar (todo archivo semántico del vault)

```yaml
---
type: feedback | project | reference | lesson | session | daily | curated | user
machine: mark-PC | PC-WILSON | BOGWROMEROCA
created: YYYY-MM-DD
updated: YYYY-MM-DD
tags: []
---
```

- `updated:` se actualiza en cada modificación (el curador y el Sueño lo hacen; a mano también).
- `machine:` siempre indica dónde se originó el contenido.

## Nombres de archivo en Memoria-CC

| Prefijo | Uso |
|---|---|
| `feedback_` | corrección de comportamiento o lección de debugging (problema → causa → solución) |
| `project_` | trabajo de feature/bug con referencias a PRs y estado de validación |
| `reference_` | runbooks, procedimientos reutilizables |
| `user_` | contexto sobre Wilson |

## MEMORY.md (índice de Memoria-CC)

- Una línea por archivo: `- [Título](archivo.md) — resumen de una línea`
- Máximo ~200 líneas; el Sueño lo poda y enriquece.
- Lo actualizan: el curador, el auto-memory nativo de Claude Code y el Sueño. El capture nunca lo toca.

## Slugs

- **vault_slug** (carpetas en `projects/` del vault): ruta sin slash inicial, `/` → `-`. Ej: `/home/mark/Code/Foo` → `home-mark-Code-Foo`.
- **cc_slug** (carpetas de Claude Code en `~/.claude/projects/`): `/`, `.` y `_` → `-`, **conservando el guion inicial**. Ej: `/home/mark/Code/Foo.bar` → `-home-mark-Code-Foo-bar`.
- Nunca mezclar: los lookups en `~/.claude/projects/` usan `cc_slug`; las rutas del vault usan `vault_slug`.

## Enlaces

Wiki-style `[[archivo]]` o `[[ruta/archivo|alias]]`. Un `[[enlace]]` a un archivo que aún no existe marca algo pendiente de escribir, no es error. El Sueño repara los rotos por renombre.

## Idiomas

- Documentación, prompts y contenido de memoria: **español**.
- Código, comentarios de código y mensajes de commit: **inglés** (commits con gitmoji, sin Co-Authored-By).
