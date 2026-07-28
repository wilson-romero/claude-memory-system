---
type: reference
machine: PC-WILSON
created: 2026-07-27
updated: 2026-07-27
tags: [openspec, flujo, validacion, code-review, metodo]
---

# Flujo de trabajo con OpenSpec — el ciclo y las puertas que se saltan solas

> Conocimiento de método, aplicable a **cualquier** proyecto que use OpenSpec. Cada puerta de abajo
> existe porque saltársela costó un fallo concreto y comprobable.

## El ciclo

```
  /opsx:explore  ─►  /opsx:propose  ─►  ⚠ VALIDACIÓN PREVIA  ─►  /opsx:apply
                                              │
                                              └─ NO es `openspec validate --strict`
                                                        │
   archivar  ◄─  sync specs  ◄─  verificar  ◄─  desplegar  ◄─  /code-review
                                  el EFECTO                  (lo lanza la PERSONA)
```

## Al empezar sesión

```bash
openspec list --json          # ¿hay changes activos? NO asumir que no
git status && git branch --show-current
```

Si hay un change activo, se continúa ese; no se abre otro en paralelo sin decirlo.

## 1. explore — pensar, no implementar

Medir contra datos y código reales. **Nunca escribir código de aplicación en este modo**; crear
artefactos de OpenSpec sí está permitido.

Trampa recurrente: **las cifras que vienen en la ficha del plan son estimaciones de cuando se
escribió la ficha, no datos.** Antes de que una cifra decida una forma de visualización o un grano
de agregación, se vuelve a medir contra la fuente. Y un `COUNT(DISTINCT x)` no autoriza ninguna
decisión de forma: hace falta la **distribución**, ponderada por la magnitud que se va a pintar.

## 2. propose — los cuatro artefactos

`proposal.md` · `design.md` · `specs/**` · `tasks.md`.

- Cada decisión del design nombra **la alternativa rechazada y por qué**.
- Los **no-objetivos se escriben con su razón**, no solo listados.
- Una decisión que depende de una medición aún no hecha se escribe como **falsable**, con la tarea
  que la mide y la instrucción de **editarla en su sitio si se revierte** — y de releer las specs,
  que es donde sobrevive la decisión muerta.

## 3. ⚠️ VALIDACIÓN PREVIA AL APPLY — la puerta que más se olvida

**`openspec validate --strict` NO es esta validación.** Solo comprueba la **forma**: que los
escenarios lleven `####`, que cada requisito tenga al menos uno, que los deltas estén bien formados.
No mira si lo que afirmas es **cierto**.

La validación previa produce explícitamente **pros / contras / sugerencias**, y **las sugerencias se
aplican a los artefactos ANTES del apply** — un artefacto corregido después ya no especifica lo que
se construyó.

### Checklist que ha encontrado bloqueantes reales

- [ ] Releer los cuatro artefactos **como un conjunto**: ¿se contradicen entre sí? ¿hay requisito sin
      tarea que lo implemente? ¿tarea que no responde a ningún requisito?
- [ ] **Leer cómo trata el código EXISTENTE el caso que el spec nuevo describe.** El error más caro
      de esta clase: escribir *"si el valor no llega, se guarda vacío"* cuando el merge vivo hace
      `COALESCE(nuevo, actual)` — es decir, **preserva**. Combinado con una columna declarada
      *opcional* en la carga, esa pareja **borra la columna entera** la primera vez que llegue un
      extracto sin ella.
- [ ] `grep` de **los llamantes reales** de lo que se toca, y **con cuántos argumentos llaman**.
      Añadir un parámetro a una función con `CREATE OR REPLACE` **no cambia su aridad**: crea una
      sobrecarga y deja ambigua la llamada existente.
- [ ] `grep` de **permisos/`GRANT`**: nombran firmas completas y **no siguen al objeto** cuando este
      cambia.
- [ ] Comprobar que **los identificadores citados existen tal cual**. Las claves de configuración
      suelen ir **cualificadas** (`tabla.columna`, no `columna`): escritas a medias no fallan, solo
      dejan de aplicar, y eso no se nota hasta que el proceso desatendido se cae de madrugada.
- [ ] Buscar **requisitos YA VIGENTES** en los specs actuales que la tarea nueva deba respetar.
- [ ] Releer proposal y tasks buscando **afirmaciones que un hallazgo acabe de volver falsas**.
- [ ] **Reproducir, no deducir**: los bloqueantes de este tipo se ven en un contenedor desechable en
      dos minutos.

## 4. apply — implementar

## 5. code-review — al TERMINAR y **ANTES de fusionar**

Sobre el diff completo del change, como unidad coherente.

- **No a mitad de la implementación**: revisa código incompleto y genera hallazgos que ya ibas a
  resolver.
- **No después de fusionar**: el diff sería de **0 líneas** y el review aprobaría la nada.
- **Lo lanza la persona**, no el agente.
- Cada hallazgo es una **hipótesis**: la fiabilidad **no se transfiere** de un hallazgo al siguiente,
  aunque los anteriores fueran ciertos.

Después: aplicar los hallazgos, y solo entonces cerrar.

## 6. Desplegar y verificar el EFECTO, no la orden

- Verificar el **efecto**, no que el comando devolviera éxito: un `200` de un hook de invalidación es
  el resultado de la orden, no la prueba de que la caché se limpió.
- Verificar por el **camino del usuario** (navegador con sesión real), no con una petición
  autenticada por cabecera, que se salta el ingress y la cookie.
- Comprobar que el proceso desatendido posterior corrió **DESPUÉS** del despliegue: comparar su
  marca de tiempo con la del commit desplegado. Una corrida anterior no verifica nada.

## 7. sync specs y archive

## Dónde poner una regla para que se cumpla

**Si la regla vive solo en la memoria de la sesión, se diluye.** Va en la **ruta de la herramienta**:
el fichero de instrucciones que el agente carga al abrir el proyecto (`AGENTS.md` / `CLAUDE.md` en la
raíz del repo — no en una subcarpeta, que solo se carga al tocarla), o en el conocimiento que se
inyecta al inicio de cada sesión.

La pregunta de control no es *"¿sé la regla?"* sino **"¿dónde la leerá quien empiece la próxima
sesión?"**. Si la respuesta es *"en mi memoria"*, la regla no está puesta.
