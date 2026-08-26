---
fecha: 2026-08-26
hora: 14:43
sesion: mefisto-planner
tema: refinamiento de los drafts de alertas y muestreo de logs del worker de proyecciones
---

## Contexto

Sesion de refinamiento sobre los dos drafts creados desde el consumidor
Bitakora.ControlAsistencia el 2026-08-17 (#679 y #680), ambos con mas de 7 dias
en borrador. Traian contexto de campo rico: el experimento de falla inducida del
consumidor (su issue #412, Postgres detenido ~14 min) que midio la capacidad de
deteccion real de la alerta del worker de proyecciones.

## Descubrimientos

- El canon ya genera una alerta `exception_spike` **global** en el modulo
  `monitoring` de `infra-base-scaffolder` (todas las `exceptions`, sin filtro por
  `cloud_RoleName`, umbral >50/PT5M). El framing del draft ("el worker quedo fuera
  al acotar por bordes") era del consumidor, no del canon — pero el canon es
  igual de ciego en la practica: el umbral >50 es inalcanzable para el perfil del
  daemon (backoff x shards; maximo medido 30/bin en caida total con 3 shards).
- El hallazgo 3 del draft #680 (alertas condicionadas a `requests`, ciegas a
  agentes de fondo) **no aplica al canon**: la alerta global va sobre
  `exceptions`. Verificado y documentado en el `## Alcance` de #680 para que
  nadie lo re-investigue.
- La simetria write-side del defecto del sampler de logs es **parcial**: el
  write-side no tiene filtro estructural de spans (solo capa de ratio,
  MEF-ADR-0038 seccion 6), asi que la supresion de logs de error alli es
  ratio-dependiente, no estructural. Con el default 1.0 no se pierde nada.
- Razonamiento que destrabo #700 sin experimento: el flip de
  `EnableTraceBasedLogsSampler` es estrictamente neutral-o-beneficioso para la
  visibilidad de errores (fuera de span pasa siempre; dentro de span no
  muestreado, lo salva), asi que la pregunta empirica "¿donde se emiten los
  LogError?" no era decisiva.

## Decisiones

- **#679**: umbral **>5 / PT5M / PT5M** (opcion A; dispara en los 4 bins medidos
  y en falla sostenida con 1 shard; tolera blips de 1-3 excepciones). Ubicacion:
  recurso standalone en el wiring opt-in del entorno (Paso 2.3b de
  `infra-base-scaffolder`, gate `projections.enabled`) + 2 outputs nuevos del
  modulo `monitoring` (`application_insights_id`, `action_group_id`) con nota
  brownfield estilo `log_analytics_workspace_id`. Enmienda a MEF-ADR-0034
  seccion 8 en el mismo issue. Gate de deteccion declarado como *parcialmente
  verificado* (familia lock 1:1; familia highwater suprimida hasta #680).
- **#680**: re-alcanzado al hallazgo 2. Opcion A: flip
  `EnableTraceBasedLogsSampler = false` en el seam del worker + guardrail en el
  config-test + extension de la regla absoluta 10 + seccion nueva en
  MEF-ADR-0038. El volumen de logs pasa a gobernarlo el filtering de ILogger
  (valor del consumidor) — frontera mecanismo/valor de MEF-ADR-0038 seccion 1.
- **#700**: mismo paquete que #680 aplicado al write-side
  (`ComposicionServicios{PascalCase}` + guardrail en `ComposicionContenedorTests`
  + regla del agente + extension del ADR). **Depende de #680** (la seccion del
  ADR que extiende la crea #680): label `bloqueado`; en batch secuencial #680 va
  antes. #679 es independiente de ambos.

## Descartado

- Umbral >0 y ventana PT15M para la alerta de #679 (opciones B y C).
- Filtros Warning+ por categoria JasperFx/Marten en el seam del worker (opcion B
  de #680): acoplaba el seam a nombres de categorias internas fragiles entre
  versiones.
- Alternativa solo-doctrinal para el write-side (#700): dejaba viva la misma
  clase de defecto que #680 corrige, mas una asimetria permanente entre seams.
- La **nota de metodo** del draft original de #680 (toda alerta nueva debe
  verificarse contra falsos negativos con falla inducida, no solo contra ruido;
  "desplegado != probado") quedo sin capturar por decision del usuario ("no mas
  drafts"). Si reaparece, es doctrina candidata para el ADR que gobierne alertas.

## Preguntas abiertas

- ¿La doctrina de verificacion de deteccion (falla inducida) merece generalizarse
  en un ADR, o basta el precedente puntual del gate declarado en #679?
- El guardrail del flip (asercion sobre `AzureMonitorExporterOptions` desde el
  contenedor) tiene la mecanica por verificar contra el paquete pinneado — los
  writers de #680/#700 deben validarla por decompilacion (precedente de
  MEF-ADR-0038 seccion 3).

## Referencias

Issues creados: #700 (draft -> refinado a listo en la misma sesion)
Issues refinados a `estado:listo`: #679, #680 (+`bug`), #700 (+`bug`, `bloqueado`)
Issues cerrados: ninguno
