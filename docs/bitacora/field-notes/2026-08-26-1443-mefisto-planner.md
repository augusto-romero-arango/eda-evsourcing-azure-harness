---
fecha: 2026-08-26
hora: 14:43
sesion: mefisto-planner
tema: refinamiento de los drafts de alertas/sampler del worker + mecanismo de experimentos por modelo
---

## Contexto

Sesion en dos partes. Primera: refinamiento de los drafts #679 y #680 (creados
desde el consumidor Bitakora.ControlAsistencia el 2026-08-17, con el contexto
del experimento de falla inducida de su issue #412). Segunda: exploracion y
desglose de un mecanismo para asignar modelos por stage en los pipelines
(tooling y TDD, publicados e internos) y correr variantes paralelas del mismo
issue, como base de pruebas de desempeno del harness comparando modelos.

## Descubrimientos

- El canon ya genera una alerta `exception_spike` **global** en el modulo
  `monitoring` de `infra-base-scaffolder` (sin filtro por `cloud_RoleName`,
  umbral >50/PT5M). El acotamiento "por bordes" que cego al worker fue decision
  del consumidor — pero el canon es igual de ciego en la practica: el umbral
  >50 es inalcanzable para el perfil del daemon (backoff x shards; maximo
  medido 30/bin en caida total con 3 shards).
- El hallazgo 3 del draft #680 (alertas condicionadas a `requests`) **no aplica
  al canon**; verificado y documentado en el `## Alcance` de #680.
- La simetria write-side del defecto del sampler de logs es **parcial**: sin
  filtro estructural de spans, la supresion alli es ratio-dependiente. El flip
  de `EnableTraceBasedLogsSampler` es estrictamente neutral-o-beneficioso para
  la visibilidad de errores, asi que la pregunta empirica no era decisiva.
- Mecanismo actual de modelos por stage: los tooling (ambos lados) hardcodean
  `reviewer=opus`/resto=`sonnet` en un `case` de `run_agent` y pasan `--model`;
  el TDD invoca `claude -p --agent <agente>` **sin** `--model` (manda el
  frontmatter `model:` del agente). La captura stream-json ya registra el
  modelo efectivo por stage (evento `init`) y los metrics-report lo extraen:
  la mitad de medicion del experimento ya existia, faltaba el control.
- Un archivo runtime unico (`.claude/pipeline/models.json`) resulto mal diseno
  para el caso real: es estado global y las variantes paralelas del mismo issue
  se pisarian. La asignacion debe viajar con la invocacion (flags), no con el
  repo.

## Decisiones

- **#679** (listo): alerta dedicada del worker con umbral **>5/PT5M/PT5M**,
  como recurso standalone en el wiring opt-in del entorno (Paso 2.3b de
  `infra-base-scaffolder`) + 2 outputs nuevos del modulo `monitoring`; enmienda
  a MEF-ADR-0034 seccion 8; gate de deteccion declarado *parcialmente
  verificado*.
- **#680** (listo, bug): re-alcanzado al hallazgo 2 — flip
  `EnableTraceBasedLogsSampler = false` en el seam del worker + guardrail +
  regla absoluta + seccion nueva en MEF-ADR-0038. Volumen de logs pasa a ser
  valor del consumidor via ILogger filtering.
- **#700** (listo, bug, bloqueado por #680): mismo paquete en el write-side
  (`ComposicionServicios{PascalCase}` + `ComposicionContenedorTests`).
- **Mecanismo de experimentos por modelo** (serie #708-#713): dos flags
  ortogonales por invocacion — `--models 'agente=modelo,...'` (override por
  stage; claves = nombre de agente que `run_agent` recibe; sin flag, defaults
  byte a byte) y `--variant <label>` (sufijo en worktree/rama/logs/tmux, SIN
  PR y SIN mutar el issue: ramas de comparacion). Desglose por feature x
  pipeline: #708 models-tooling-pub (crea parser en `_pipeline-common.sh`),
  #712 models-tdd (depende de #708; gate empirico de precedencia `--model` CLI
  vs frontmatter bajo `--agent`), #709 models-interno (copia propia en
  `_mefisto-common.sh`, MEF-ADR-0019), #710 variant-tooling-pub (helper de
  validacion), #713 variant-tdd (depende de #710), #711 variant-interno.
- Las variantes internas no tocan la doctrina secuencial del batch: no mergean.

## Descartado

- Umbral >0 y ventana PT15M para la alerta de #679; filtros Warning+ por
  categoria JasperFx en el seam (#680 opcion B); alternativa solo-doctrinal
  para el write-side (#700).
- `.claude/pipeline/models.json` como mecanismo de asignacion de modelos
  (estado global, incompatible con variantes paralelas).
- Token de modelos en `harness.config.json` (persistente/committeable, mal
  encaje por-corrida) y variables de entorno (plomeria fragil hacia tmux).
- La **nota de metodo** (verificar alertas contra falsos negativos con falla
  inducida, no solo contra ruido; "desplegado != probado") quedo sin capturar
  por decision del usuario. Si reaparece, es doctrina candidata a ADR.

## Preguntas abiertas

- ¿La doctrina de verificacion de deteccion merece generalizarse en un ADR?
- Gate del #712: ¿`--model` del CLI precede al frontmatter `model:` bajo
  `--agent`? Se resuelve empiricamente en ese issue (evento `init`).
- Pendientes deliberados de la serie de experimentos (para cuando el mecanismo
  pruebe valor en el campo): orquestador `/experiment <issue>` que lance N
  variantes al estilo `/parallel`, y vista comparativa de variantes en
  `metrics-report`/`mefisto-metrics-report`.

## Referencias

Issues creados: #700, #708, #709, #710, #711, #712, #713
Issues refinados a `estado:listo`: #679, #680 (+`bug`), #700 (+`bug`, `bloqueado`)
Series de experimentos: #708/#709/#710/#711 listos; #712 (bloqueado por #708),
#713 (bloqueado por #710)
Issues cerrados: ninguno
