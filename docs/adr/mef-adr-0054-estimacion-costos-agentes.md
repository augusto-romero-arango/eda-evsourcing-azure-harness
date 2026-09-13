# MEF-ADR-0054: Estimacion reproducible del costo de agentes

- **Fecha**: 2026-09-13
- **Estado**: aceptado
- **Aplica a**: el contrato neutral de telemetria de ejecuciones de agentes y sus adaptadores de runtime, en los lados interno y publicado de MEF-ADR-0019. Define como se estima un costo comparable cuando el runtime no entrega un precio API representativo. Complementa MEF-ADR-0049 (el adaptador traduce las senales de su runtime), MEF-ADR-0050 (los consumidores solo leen el contrato neutral), MEF-ADR-0025 (sin acceso a credenciales ni caches privadas) y MEF-ADR-0030 (reserva el identificador `0054`).

## Contexto

El campo historico `cost_usd` no tiene una semantica comparable entre runtimes. Claude Code expone `total_cost_usd`; OpenCode, cuando usa OpenAI mediante OAuth de ChatGPT, sustituye el precio de su catalogo por cero y cada `step_finish.part.cost` queda en `0`. Ese valor expresa facturacion marginal de una suscripcion, no el consumo equivalente a tarifas API. Tratarlo como costo comparable ocultaria el costo relativo entre writer y reviewer y volveria enganosa la tabla de #1311.

OpenCode conserva, sin embargo, los tokens por paso y usa Models.dev como catalogo de modelos y precios. Su fuente por defecto es `https://models.opencode.ai/api.json`; el catalogo registra los IDs exactos `openai/gpt-5.6-luna`, `openai/gpt-5.6-terra` y `openai/gpt-5.6-sol` con tarifas por millon de tokens. Su formula descuenta cache del input, cobra reasoning a tarifa de output y escoge el tier de precio segun el contexto de cada llamada. Por tanto se puede producir una estimacion reproducible sin reinterpretar la autenticacion ni aceptar el cero OAuth como precio.

Como evidencia de dimension, aplicar las tarifas base registradas a #1315 produjo aproximadamente USD 0.592652 para writer Terra y USD 0.8423432 para reviewer Sol (USD 1.4349952 total), mientras el `cost_usd` observado fue cero en ambos. La cifra es una estimacion de equivalencia API, no una factura de la suscripcion.

### Alcance

Este ADR fija la semantica, formula, procedencia, refresco, degradacion y migracion del campo neutral `estimated_cost_usd`. Fija el contrato que implementaran el runner y los adaptadores, no implementa todavia la descarga del catalogo, el calculo ni las metricas.

### Que queda fuera de este ADR

- La facturacion real de una cuenta, suscripcion, API key o proveedor. Mefisto no pretende conciliar una factura.
- Consultar el auth store, configuracion privada o cache privada de Claude Code, OpenCode o cualquier proveedor.
- Fijar o duplicar en el repositorio las tarifas de un proveedor: el registro versionado durante la ejecucion es el catalogo publico descrito en la decision 3.
- Implementar los cambios de contrato, adaptadores, metricas o reportes de #1311-#1313.

## Decision

### 1. `estimated_cost_usd` es equivalencia a tarifa API, no costo marginal (CA-1)

Todo escritor nuevo de telemetria emite `estimated_cost_usd`, cuyo valor es el costo USD equivalente de los tokens consumidos a las tarifas API publicas del modelo resuelto. El campo es independiente de la forma de autenticacion, del plan de suscripcion y de la facturacion marginal que un runtime informe.

Un valor cero procedente de OAuth, incluido el que OpenCode instala para OpenAI OAuth, **no es una estimacion** y queda prohibido propagarlo como `estimated_cost_usd: 0`. Si los tokens y el modelo son resolubles, se calcula la estimacion con el catalogo; si no lo son, se usa `null` conforme a la decision 4. Un cero solo es valido cuando la formula y una tarifa API valida producen matematicamente cero tokens facturables.

El contrato neutral conserva separadas las responsabilidades:

- El adaptador traduce los eventos y contadores crudos de su runtime a modelo, tokens, contexto y partes del paso; tambien puede traducir un importe nativo cuya semantica de equivalencia API este verificada. No expone su wire format a consumidores.
- El estimador neutral resuelve tarifa y calcula `estimated_cost_usd` cuando el runtime no aporta ese importe representativo. OpenCode con OAuth sigue necesariamente esta ruta: su cero no satisface la semantica del campo.
- Pipelines, tablas, metricas y consumidores usan `estimated_cost_usd` para estimaciones y totales; no inspeccionan OAuth, `total_cost_usd`, `step_finish.part.cost` ni otro campo del runtime. La unica excepcion de lectura es el historial legacy separado que fija la decision 5.

### 2. Formula de OpenCode por paso y seleccion de tier antes de agregar la corrida (CA-2)

Las tarifas del catalogo son USD por **millón de tokens** (MTok). Para cada paso `s` traducido desde OpenCode, el estimador toma el modelo `provider/model` ya resuelto y selecciona primero el tier de precios aplicable al contexto de ese paso. No escoge un tier unico para toda la corrida: una corrida puede cruzar un umbral de contexto y sus pasos se valorizan con tiers distintos.

Con las tarifas por MTok del tier `p` y los contadores de tokens del paso, el importe es:

```text
input_no_cache_s = max(0, input_s - cache_read_s - cache_write_s)
cost_s = (
    input_no_cache_s * p.input
  + cache_read_s     * p.cache_read
  + cache_write_s    * p.cache_write
  + output_visible_s * p.output
  + reasoning_s      * p.output
) / 1_000_000

estimated_cost_usd = sum(cost_s)
```

`input_s` es el input total previo a descontar cache y tambien la medida de contexto del paso; `output_visible_s` excluye los tokens de reasoning. `reasoning_s` usa deliberadamente la tarifa `output`; no se inventa una categoria de precio adicional. La normalizacion con `max(0, ...)` evita cobrar input negativo si un runtime reporta contadores inconsistentes; la implementacion debe dejar la inconsistencia como diagnostico, sin volver negativa la estimacion. Los campos ausentes se tratan como no resolubles, no como cero, salvo que el adaptador haya declarado explicitamente que esa clase de tokens no existe para ese runtime/modelo.

La seleccion del tier compara `input_s` con los umbrales de contexto del catalogo y elige el tier de mayor umbral que satisfaga `input_s > threshold`; si ninguno aplica o el catalogo no define tiers, usa el precio base. Esta desigualdad estricta reproduce la seleccion verificada en OpenCode: un input exactamente igual al umbral todavia usa el tier anterior. Si falta el contexto o el tier seleccionado no tiene costos validos, ese paso no es resoluble y la corrida degrada a `estimated_cost_usd: null`; nunca se adivina una tarifa para aparentar precision.

### 3. Models.dev es el registro de referencia, con cache propia y validacion UTC diaria (CA-3)

Para IDs `provider/model`, el registro de referencia es Models.dev servido por `https://models.opencode.ai/api.json`. Mefisto lo consulta sin credenciales y usa los IDs exactos del catalogo; no construye nombres desde perfiles logicos ni altera el proveedor/modelo que resolvio el runtime. Esto permite, entre otros, resolver `openai/gpt-5.6-luna`, `openai/gpt-5.6-terra` y `openai/gpt-5.6-sol` contra la misma fuente publica que usa OpenCode.

La implementacion guarda una cache **propia de Mefisto** bajo `MEFISTO_STATE_DIR`. No lee ni modifica la cache de OpenCode, su directorio de configuracion, credenciales ni auth store. La cache contiene el documento validado y metadata suficiente para conocer su fecha de validacion UTC y URL de procedencia. Una cache se considera vigente solo cuando su fecha de validacion coincide con la fecha UTC actual: el primer uso posterior intenta refrescarla; los usos del mismo dia UTC pueden reutilizarla. La actualizacion se serializa con un lock propio de Mefisto para que procesos concurrentes revaliden la fecha dentro del lock y no compitan por reemplazarla.

Una actualizacion descarga a un temporal dentro del mismo directorio de estado, valida que el JSON tenga la estructura de catalogo necesaria para resolver IDs exactos `provider/model` y que cada tarifa base o de tier que pueda seleccionar la formula sea numerica, finita y no negativa, y solo entonces reemplaza la cache mediante renombre atomico en el mismo filesystem. Un fallo de red, JSON malformado, precio negativo o documento incompleto nunca destruye ni sobrescribe la ultima cache valida. La implementacion no invoca `opencode models --refresh`: ese comando es evidencia de la procedencia de OpenCode, pero refresca estado del runtime y contradiria la custodia y reproducibilidad de una cache propia.

### 4. Telemetria degradable: cache valida o `null`, nunca aborto (CA-4)

La estimacion es observabilidad auxiliar y no condiciona la ejecucion del agente ni el resultado funcional del pipeline.

| Situacion | Resultado |
|---|---|
| Catalogo actual valido y modelo/tokens/tier resolubles | Se emite el importe calculado en `estimated_cost_usd`. |
| Red o catalogo actual falla, pero existe ultima cache valida y el modelo es resoluble | Se calcula con esa cache y se registra un aviso visible de catalogo desactualizado. |
| No existe cache valida | Se emite `estimated_cost_usd: null` y un aviso visible. |
| Modelo, tokens o tier no son resolubles | Se emite `estimated_cost_usd: null` y un aviso visible. |

La corrida nunca aborta, se reintenta ni se marca fallida por descargar, validar o calcular telemetria de costo. Los avisos deben identificar la causa de degradacion sin incluir secretos, payloads de autenticacion ni datos sensibles de prompts.

### 5. Corte de contrato y lectura legacy separada (CA-5)

Desde la implementacion de este ADR, los escritores nuevos emiten **solo** `estimated_cost_usd`; no escriben el alias `cost_usd`, aunque el runtime aporte un campo con ese nombre. Los lectores aceptan indefinidamente historial que solo contenga `cost_usd`, pero lo etiquetan y presentan separado como **costo reportado legado**.

Un total estimado suma exclusivamente valores numéricos de `estimated_cost_usd`; ignora `null` y expone su cobertura/degradacion. Nunca mezcla, suma, sustituye ni renombra `cost_usd` dentro de un total estimado. Esta separacion evita tanto presentar el cero OAuth como estimacion como combinar una cifra de factura/runtime con una equivalencia API.

### 6. Rollout por dependencias y fuentes verificadas (CA-6)

El rollout debe respetar este orden, sin adelantar reportes que vuelvan a interpretar el formato crudo:

1. **Contrato neutral y runner**: añadir `estimated_cost_usd`, los contadores/tier necesarios y la semantica `null`; mantener lectura legacy separada.
2. **Adaptadores de runtime**: traducir tokens, contexto y modelo resuelto, sin propagar el cero OAuth ni consultar secretos; integrar el resolvedor/cache de Models.dev.
3. **Metricas internas**: persistir y visualizar estimados, cobertura, cache usada y degradaciones sin abortar pipelines.
4. **Lado publicado**: consumir el mismo contrato neutral y proyectar la misma distincion entre estimado y costo reportado legado.
5. **#1311-#1313**: reconstruir la tabla y comparativas solo cuando los pasos anteriores produzcan evidencia reproducible; #1311 no usa los ceros observados de #1315 como costo relativo.

Las fuentes verificadas el 2026-09-13 que fundamentan esta decision quedan fijadas a los commits `a453386e9dd3cd5089714f1f0d4576002a96d30d` de OpenCode y `dfa3c8f02fb8a3e3ad80161f9b81bc25aeb723a1` de Models.dev:

- `anomalyco/opencode`, [`packages/web/src/content/docs/models.mdx`](https://github.com/anomalyco/opencode/blob/a453386e9dd3cd5089714f1f0d4576002a96d30d/packages/web/src/content/docs/models.mdx) y [`packages/opencode/src/cli/cmd/models.ts`](https://github.com/anomalyco/opencode/blob/a453386e9dd3cd5089714f1f0d4576002a96d30d/packages/opencode/src/cli/cmd/models.ts): OpenCode usa Models.dev; `--verbose` expone costos y `--refresh` refresca su cache.
- `anomalyco/opencode`, [`packages/core/src/models-dev.ts`](https://github.com/anomalyco/opencode/blob/a453386e9dd3cd5089714f1f0d4576002a96d30d/packages/core/src/models-dev.ts): fuente por defecto `https://models.opencode.ai`, ruta `/api.json`, cache, lock y refresh.
- `anomalyco/opencode`, [`packages/opencode/src/plugin/openai/codex.ts`](https://github.com/anomalyco/opencode/blob/a453386e9dd3cd5089714f1f0d4576002a96d30d/packages/opencode/src/plugin/openai/codex.ts): OAuth de OpenAI reemplaza input/output/cache por cero.
- `anomalyco/opencode`, [`packages/opencode/src/session/session.ts`](https://github.com/anomalyco/opencode/blob/a453386e9dd3cd5089714f1f0d4576002a96d30d/packages/opencode/src/session/session.ts): formula por llamada, input total como contexto, descuento de cache, output visible separado de reasoning, reasoning a tarifa de output y seleccion estricta del tier por contexto.
- `anomalyco/models.dev`, [`gpt-5.6-luna.toml`](https://github.com/anomalyco/models.dev/blob/dfa3c8f02fb8a3e3ad80161f9b81bc25aeb723a1/providers/openai/models/gpt-5.6-luna.toml), [`gpt-5.6-terra.toml`](https://github.com/anomalyco/models.dev/blob/dfa3c8f02fb8a3e3ad80161f9b81bc25aeb723a1/providers/openai/models/gpt-5.6-terra.toml) y [`gpt-5.6-sol.toml`](https://github.com/anomalyco/models.dev/blob/dfa3c8f02fb8a3e3ad80161f9b81bc25aeb723a1/providers/openai/models/gpt-5.6-sol.toml): IDs, tarifas base y tier de contexto registrados. Los archivos de Luna y Terra citan la [documentacion de precios de OpenAI](https://developers.openai.com/api/docs/pricing) como procedencia de su corte de tarifas.

## Alternativas consideradas

### Alt a: conservar `cost_usd` como costo comun

**Descartada**: el cero de OAuth no describe el consumo equivalente API y haria parecer gratuitos pasos que tienen uso relativo significativo.

### Alt b: fijar tarifas en codigo o en el repositorio

**Descartada**: envejece silenciosamente, duplica Models.dev y no permite saber cuando se validaron los datos. La cache propia validada conserva reproducibilidad sin convertir precios externos en constantes del harness.

### Alt c: usar la cache o `opencode models --refresh` del runtime

**Descartada**: acopla Mefisto al layout y estado privado de OpenCode, puede requerir configuracion del usuario y viola la separacion de responsabilidades de MEF-ADR-0049 y la custodia de MEF-ADR-0025.

### Alt d: abortar ante catalogo no disponible

**Descartada**: una telemetria auxiliar no debe impedir un cambio funcional. La ultima cache valida o `null` preservan la continuidad y hacen visible la incertidumbre.

## Consecuencias

### Positivas

- Writer, reviewer y cualquier runtime se pueden comparar con una semantica explicita de equivalencia API.
- La procedencia, fecha UTC y validacion del catalogo hacen auditables las estimaciones.
- La degradacion evita tanto inventar costos como bloquear pipelines por observabilidad.
- El corte legacy permite leer historial sin contaminar nuevos totales estimados.

### Negativas

- La estimacion no es una factura y puede diferir de descuentos, suscripciones o precios privados.
- Una cache de hasta un dia puede conservar tarifas no actuales; el aviso de fallback debe hacerlo visible.
- Algunos runtimes pueden no aportar tokens o contexto suficientes, reduciendo la cobertura mediante `null`.

## Referencias

- MEF-ADR-0025: custodia de secretos; el catalogo publico no exige credenciales y Mefisto no lee estado privado del runtime.
- MEF-ADR-0030: esquema de identificacion y reserva de `MEF-ADR-0054` como siguiente numero libre verificado.
- MEF-ADR-0049: arquitectura neutral de runtime/proveedor; los adaptadores traducen senales de runtime al contrato neutral.
- MEF-ADR-0050: neutralidad de toda operacion; consumidores no reinterpretan wire formats ni autenticacion.
- Fuentes de OpenCode y Models.dev enumeradas en la decision 6, verificadas el 2026-09-13.
- Issue #1321: origen de este ADR; #1311-#1313 y #1315: consumidores, comparativa y evidencia de dimension relacionados.

## Control de cambios

- 2026-09-13: creacion como `aceptado` (issue #1321). Define `estimated_cost_usd` como equivalencia a tarifa API y proscribe propagar ceros OAuth (seccion 1); fija formula por paso con input no cacheado, cache read/write, output visible y reasoning a tarifa de output, y tier por contexto antes de sumar (seccion 2); adopta Models.dev por `https://models.opencode.ai/api.json` con cache propia bajo `MEFISTO_STATE_DIR`, validacion UTC diaria y reemplazo atomico posterior a validar JSON/tarifas no negativas (seccion 3); degrada a ultima cache valida o `null` con aviso sin abortar la corrida (seccion 4); corta escritores a `estimated_cost_usd` y mantiene lectura legacy separada de `cost_usd` (seccion 5); y ordena el rollout hacia contrato, adaptadores, metricas, publicado y #1311-#1313, con las fuentes verificadas (seccion 6).
