---
fecha: 2026-08-04
hora: 11:43
sesion: mefisto-planner
tema: Refinamiento de #443 (sintaxis posicional en el bloque bash de /onboard)
---

## Contexto

Se pidio decidir cual refinar primero entre #443 y #463, y luego refinar el elegido.

Comparacion: #443 es un **bug** con mecanismo probado (#436, cerrado, dejo el patron de
extraccion + guard) y preguntas abiertas resolubles leyendo codigo; #463 es una **decision
de politica** (doctrina de sampling de telemetria) cuyas cinco preguntas abiertas requieren
decision de producto, con alcance sin definir y riesgo de arrastrar un ADR nuevo. Se
prioriza #443.

## Descubrimientos

**El defecto de #443 esta ACTIVO, no latente.** Era la pregunta abierta que decidia la
prioridad. Resuelta empiricamente barriendo `~/.claude/projects/`:

- Entrega real de `/mefisto:onboard` **sin argumentos** en el consumidor MiControlPlane
  (`89479588-…jsonl`, 2026-07-08T15:08:22Z, plugin 0.7.0): el modelo recibio
  `estado=""; shift; item="$*"` donde el disco dice `estado="$1"`.
- **Sin argumentos, `$1` se sustituye por cadena vacia**; `$*` y `$#` llegan intactos. Es un
  dato nuevo: #436 solo habia probado la sustitucion **con** argumentos (`$1` -> `437`).
- De las entregas reales del slash command en todo el historial, **1 de 1 llego corrupta**.

**Matiz que se documento en el issue**: en esa misma corrida el modelo **reparo** la linea al
ejecutarla (el `tool_use` Bash muestra `$1` correcto) y el checklist salio bien. La
corrupcion existe en la entrega pero su materializacion depende de que el modelo copie
verbatim. Agravante hallado: `commands/onboard.md` declara `model: haiku` en frontmatter —
el modelo mas propenso a copiar literal es justo el de este skill.

**Otras tres preguntas abiertas, resueltas leyendo el repo:**

- *Pasos opt-in*: no hay acoplamiento. El heredoc corre en subshell y no exporta nada; los 4
  bloques opt-in re-resuelven `PLUGIN_ROOT` y se activan por la **salida** del diagnostico.
- *Blocklist publicado*: la ausencia de `scripts/` en `is_path_in_consumer_blocklist` es
  deliberada (el consumidor tiene su propio `scripts/`). Y `scripts/*` si esta en la
  allowlist interna -> **no aplica el corte en dos PRs de MEF-ADR-0019 §E**. Nada que
  registrar.
- *Alcance del guard*: corriendo el guard de #436 sobre los 21 skills de `commands/`,
  `onboard.md` es el unico que dispara. El fix no arrastra otros archivos.

**Dato de infraestructura de tests**: Mefisto no tiene `.github/`; las 22 suites las corre el
writer/reviewer de `/mefisto-tooling` al cerrar. El precedente de stubs de `gh`
(`test-pipeline-resolver.sh`) solo aplica a **funciones sourceadas**; un script ejecutable
necesitaria stubs por `PATH`, patron inexistente hoy en el repo.

## Decisiones

1. **Refinar #443 antes que #463.**
2. **Extraer el heredoc a `scripts/onboard-diagnose.sh`**, no reescribir solo las 5 lineas.
   Razon: la alternativa barata deja ~385 lineas sin prueba y el siguiente `$N` expuesto. El
   molde ya existe (`source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"`, 12 scripts
   publicados) y elimina la env var `PLUGIN_COMMON`.
3. **CA-4 (cobertura con stubs) se queda en #443**, contra la recomendacion del planner de
   partirlo a un issue aparte. Decision explicita del dueño. Mitigacion aplicada: se acoto
   CA-4 al emisor de filas y a la verificacion de secretos — **no** cobertura de las 9
   secciones — y se dejo en notas tecnicas la alternativa de hacer el script sourceable para
   reusar el precedente barato de stubs en vez de estrenar el de `PATH`.
4. #443 pasa a `estado:listo` con 5 CAs.

## Revision de complejidad

- Conteo de CAs: **5** (<= 6). OK.
- Un solo componente principal: el skill `onboard` (3 archivos, un componente). OK.
- Sin ambiguedad de ubicacion: lado publicado, decidido. OK.
- CAs verificables: OK.
- **Estimacion < 30 min: NO se cumple.** CA-4 estrena tecnica de testing. Riesgo aceptado
  conscientemente por el dueño (ver decision 3). Si el pipeline se atasca en CA-4, el corte
  natural sigue siendo sacarlo a un issue dependiente.

## Descartado

- **Partir CA-4 a issue aparte**: propuesto y rechazado por el dueño.
- **Reescribir solo las 5 lineas** (alternativa barata): descartada por dejar el archivo sin
  cobertura y el mecanismo abierto.
- **Tocar `model: haiku`**: no se cambia; tras la extraccion el skill queda mas simple y
  haiku sigue siendo apropiado. Se documenta solo como agravante del riesgo.

## Preguntas abiertas

- Ninguna en #443.
- #463 sigue en `estado:borrador` con sus cinco preguntas de politica intactas. Antes de
  refinarlo conviene decidir si el marco opina sobre sampling o delega al consumidor: de eso
  depende si es un issue de 1 agente o un desglose con ADR nueva.

## Referencias

Issues refinados: **#443** (`estado:borrador` -> `estado:listo`)
Issues creados: ninguno
Relacionados: #436 (cerrado, mecanismo y patron), #463 (sigue en borrador), #256,
MEF-ADR-0019, MEF-ADR-0025
