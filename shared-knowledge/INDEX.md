# Conocimiento compartido entre equipos

Lecciones técnicas genéricas (sin datos de cliente) promovidas con `/memory-promote`. Este índice se inyecta al inicio de cada sesión en ambas máquinas.

## Método

- [Flujo de trabajo con OpenSpec](openspec-flujo-de-trabajo.md) — el ciclo completo y las puertas que se saltan solas. **`openspec validate --strict` comprueba la FORMA, no la verdad**: la validación previa al apply es un paso aparte, con su checklist. El `/code-review` va **al terminar** el change y **antes de fusionar** (después el diff es 0 líneas), y **lo lanza la persona**. Verificar el **efecto**, no que el comando devolviera éxito. Y al final: dónde poner una regla para que se cumpla.
