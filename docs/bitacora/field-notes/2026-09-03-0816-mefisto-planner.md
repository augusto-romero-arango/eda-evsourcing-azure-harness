---
fecha: 2026-09-03
hora: 08:16
sesion: mefisto-planner
tema: Coercion de argumentos string en la extension MCP -- refinar #840 y desglosar en #841/#842/#843
---

## Contexto

Refinar el draft #840 ("Cubrir la coercion de fechas de la extension MCP en el scaffolder"), creado tras
el bug del consumidor Bitakora.ControlAsistencia: `registrar_colaborador` y `listar_colaboradores`
rechazaban toda fecha valida porque `Microsoft.Azure.Functions.Worker.Extensions.Mcp` 1.6.0 convierte
`"2026-09-01"` en `DateTimeOffset` y lo re-serializa como `"09/01/2026 00:00:00 +00:00"` cuando el
parametro es `string`. El usuario pidio anclar el refinamiento a la implementacion exitosa del PR #591
del consumidor.

## Descubrimientos

- **Causa raiz verificada en upstream `main`** (2026-09-03): `DictionaryStringObjectJsonConverter.ReadString`
  (`TryGetDateTimeOffset` + `Guid.TryParse`) y `McpInputConversionHelper` (fallback
  `Convert.ToString(InvariantCulture)` con destino `string`). El issue upstream #129 se cerro "completed"
  el 2025-11-25, pero el fix solo reemplazo el `null` por ese `ToString`; no preserva el texto original
  (pregunta de pharring 2025-11-26 sin respuesta). No se abre issue upstream (decision del experto).
- **El consumidor no uso el helper por tool del draft: uso un middleware.** `ArgumentosCrudosMcpMiddleware`
  (`IFunctionsWorkerMiddleware`) lee el JSON crudo de `context.BindingContext.BindingData[<trigger>]` --
  donde el host deja los argumentos verbatim -- y reemplaza `context.Items["ToolInvocationContext"]` por
  una copia con las hojas `string` restauradas. Recupera fecha **y** GUID (el helper no podia recuperar
  casing/formato de un GUID), no toca firmas ni `inputSchema`, fail-open si upstream cambia internals.
- **Orden de middlewares importa** (hallazgo del reviewer del PR #591, verificado por decompilacion de
  `Microsoft.Azure.Functions.Worker.Core` 2.52.0): debe ir despues de `ConfigureFunctionsWebApplication()`
  y **antes de cualquier middleware que haga `BindInputAsync<ToolInvocationContext>`**, porque ese bind
  cachea en `IBindingCache` bajo el nombre del parametro (`context`) y la tool recibiria el diccionario
  coercionado. En el scaffold hoy ninguno binde (`AutorizacionMcpMiddleware` lee `GetHttpContext()`),
  pero el consumidor si agrego uno despues (`IdentidadTenantMcpMiddleware`).
- `ToolInvocationContext` (worker) es `public class` con propiedades `init`: el nucleo del middleware es
  testeable en nivel 1 sin `FunctionContext`.
- **Evidencia de exito**: PR #591 mergeado 2026-09-03 12:52; `Deploy MCP Comandos`/`Deploy MCP Consultas`
  (con job `smoke-tests` encadenado) en `success` sobre `ad802d8`; unit 48/48 y 82/82.
- El smoke del scaffold (`ejemplo_listar`) tiene exactamente la forma que dejo pasar el bug: tool call
  sin parametros + error path del `.resx`. Ningun parametro fecha/identificador en la tool de ejemplo.
- Gap lateral: el gate de cobertura (`_pipeline-common.sh`, clasificacion MCP del issue #788) dejo
  `Infraestructura/*Middleware.cs` como "sin clasificar" en el PR del consumidor; solo reconoce `*Api.cs`.

## Decisiones

- **Desglose en cuatro issues** (el draft tocaba agente publicado + dos ADRs + doctrina implicita para
  otros agentes; un solo componente principal por issue):
  - **#840** (refinado, `estado:listo` + `bug`): `agents/mcp-scaffolder.md` -- item nuevo
    `Infraestructura/ArgumentosCrudosMcpMiddleware.cs` (siempre se genera), `UseMiddleware` en ambas
    variantes de `Program.cs` como primer middleware propio con comentario de posicion, unit tests del
    nucleo en Paso 4, coherencia de `description`/`commands/scaffold-mcp.md`/README. 5 CAs.
  - **#841** (`estado:listo`): enmendar MEF-ADR-0047 (restriccion conocida de la extension, conclusion
    normativa: middleware + parametros siguen `string`, clausula de reverificacion como la decision 7)
    y MEF-ADR-0048 (la tool call real ejercita con valor valido cada parametro fecha/identificador;
    el error path no la sustituye). Bloquea #843.
  - **#842** (`estado:listo`, `bloqueado` por #840): `ejemplo_listar` gana `fecha_referencia` opcional
    con validacion `yyyy-MM-dd`, `.resx`, unit tests, y smoke del camino valido con eco exacto -- para
    que un scaffold fresco detecte en su primer deploy si el middleware quedo fail-open.
  - **#843** (`estado:listo`, `bloqueado` por #841): operacionalizar en `smoke-test-writer`, `reviewer`
    y `planner`, mismo patron de #789.
- Orden de batch sugerido: #840 -> #841 -> #842 -> #843 (solo por `## Dependencias`; compartir
  `mcp-scaffolder.md` entre #840 y #842 no impone nada extra en `/mefisto-sequential`).
- Las plantillas del scaffold citan el issue upstream #129 y el nombre del converter como Decision
  Delta, nunca issues de Mefisto ni del consumidor (regla ya vigente en `mcp-scaffolder`, MEF-ADR-0044).
- El middleware se documenta como **temporal** ("mientras upstream coercione strings"); retirarlo sera
  un issue aparte con reverificacion.

## Descartado

- Helper por tool sobre `context.Arguments` (propuesta original del draft, workaround sugerido en
  upstream #129): no recupera casing/formato de GUID, acepta variantes que la tool no promete, y obliga
  a tocar cada tool y cada parametro futuro.
- Parametro `DateTimeOffset` (valor invalido pasa a error de protocolo, contra MEF-ADR-0047 d.4),
  parametro `object` (rompe `type: string` del `inputSchema`), bajar version del paquete (la coercion
  existe desde 1.0.0-preview.7).
- Fundir #841 y #843 en uno (como hizo #789): se prefirio ADR primero, agentes despues, para que los
  agentes citen doctrina ya escrita.

## Preguntas abiertas

- Draft pendiente de crear: clasificar `Infraestructura/*Middleware.cs` de servidores MCP en el gate
  de cobertura (`_pipeline-common.sh`), hoy "sin clasificar".
- Del lado del consumidor: el fixture `ArgumentosValidos` de `RegistrarColaboradorSmokeTests` manda
  `numero_identificacion` como GUID `N` mayusculas; con el middleware ya llega intacto, pero conviene
  confirmar que el assert `Contain(numeroIdentificacion)` del PR #591 sigue verde en los proximos runs.
- Cuando una version futura de la extension preserve el texto: issue de retiro del middleware con
  reverificacion (doctrina en #841).

## Referencias

Issues creados: #841, #842, #843
Issues refinados: #840 (`estado:borrador` -> `estado:listo`, + `bug`)
Fuentes: Azure/azure-functions-mcp-extension#129; upstream `main`
`Serialization/DictionaryStringObjectJsonConverter.cs`, `Converters/McpInputConversionHelper.cs`,
`Abstractions/ToolInvocationContext.cs`; Bitakora.ControlAsistencia issue #586 / PR #591.
