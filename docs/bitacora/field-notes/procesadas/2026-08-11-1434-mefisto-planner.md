---
fecha: 2026-08-11
hora: 14:34
sesion: mefisto-planner
tema: refinamiento del #587 -- doctrina GET vs QUERY (RFC 10008), paginacion y filtros de las read APIs
---

## Contexto

El usuario pidio refinar el #587 con investigacion exhaustiva del metodo HTTP QUERY (nuevo en el protocolo), incluyendo POCs, antes de fijar postura. El draft venia de la sesion del 2026-08-06 (refinamiento del #583) con el numero de RFC "por confirmar".

## Descubrimientos

- **RFC 10008 confirmado**: "The HTTP QUERY Method", junio 2026, Proposed Standard (ex draft-ietf-httpbis-safe-method-w-body-14). Verificado contra rfc-editor.org y el datatracker.
- Semantica clave del RFC: seguro + idempotente + body; `Content-Type` obligatorio (MUST fail sin el); tabla de codigos 400/415/422/406 en seccion 2.1; seccion 2.8 respalda que la **paginacion viva dentro del formato de query** (no en Range headers); seccion 4 confirma que QUERY **siempre dispara preflight CORS** (no es CORS-safelisted).
- **POCs ejecutados (net10 + Core Tools 4.6.0 local)**: el host de Azure Functions isolated worker registra y enruta `HttpTrigger(..., "query")` con body intacto (GET no coincidente responde 404, no 405); Kestrel/`MapMethods` OK; `HttpClient` con `new HttpMethod("QUERY")` OK; curl OK.
- **APIM permite metodos no estandar por contrato**: "Typical Http Methods like GET, PUT, POST but not limited by only them" (REST API reference, ApiOperation).
- **OpenAPI 3.2** ya tiene campo `query` dedicado en el Path Item.
- **Hallazgo de campo**: la politica CORS global del `apim-gateway-scaffolder` enumera allowed-methods sin QUERY -- un SPA se caeria en el preflight.
- **Bug preexistente descubierto (#610)**: el modulo `apim-function-api` del scaffolder no declara ningun recurso `azurerm_api_management_api_operation` -- Microsoft Learn confirma que sin operaciones APIM responde 404 a todo ("API Management won't expose any operations until you allow them"). ControlPlane (fuente de verdad de MEF-ADR-0032, `infraestructura/aplicacion/gateway.tf`) SI declara una operacion explicita por endpoint (`POST /Tenants`); el scaffolder perdio la pieza al generalizar. Independiente de QUERY.

## Decisiones

- **Postura confirmada por el usuario**: la doctrina debe fijar un criterio de corte **decidible** de cuando GET y cuando QUERY. GET para `Obtener{X}` por id y `Listar{X}s` con filtros planos de igualdad; QUERY para filtros estructurados (AND/OR, rangos, listas) y paginacion por cursor.
- Paginacion: keyset/cursor como default del marco, offset como excepcion documentada (Rule of Three) -- el detalle fino lo fija el ADR que el issue produce.
- El #587 se reescribio con la investigacion embebida (el writer no re-investiga), 6 CAs, y paso a `estado:listo`. Retitulado: ya no "explorar" sino "fijar la doctrina".
- El touchpoint CORS de APIM se separo en issue propio (#608, borrador + bloqueado, depende de #587): otro componente, otra ancla ADR.
- Tres gates NO VERIFICADO quedan como CA del ADR (patron MEF-ADR-0032 seccion 8): front-end de App Service en Azure real, reenvio QUERY por APIM Consumption, CORS.

- **Trilogia completa del read-side avanzado**: #583 (el planner CAPTURA filtros/paginacion), #587 (la doctrina/mecanica GET vs QUERY), #609 (el planner SUGIERE el verbo y conduce la conversacion de filtros/paginadores aplicando el criterio del ADR). #609 nace `estado:listo` + `bloqueado` (depende de #583 y #587); en un batch secuencial va de ultimo.
- **#610 (bug, listo, sin bloqueo)**: reparar el mecanismo de operaciones APIM del modulo `apim-function-api`. Recomendacion del refinamiento: operaciones wildcard por verbo (`GET /*`, `POST /*`, patron documentado en Microsoft Learn) en vez de explicitas por endpoint -- las explicitas romperian la aditividad CA-6 del scaffolder (cada Function nueva tocaria infra). Decision final como CA-1 del issue.
- **#608 ampliado, retitulado y refinado a `estado:listo`**: pasa de "solo CORS" a "las consecuencias del verbo QUERY en el gateway" (operacion QUERY sobre el mecanismo del #610 + CORS + gate end-to-end). Depende de #587 y #610. Dos decisiones confirmadas por el usuario: (1) CORS por **enumeracion explicita** (`<method>QUERY</method>`), descartando el `*` que la doc oficial admite -- se preserva deny-by-default; (2) **retroactividad**: el fix aplica a instalaciones nuevas; para gateways existentes el agente detecta `apim.tf` sin QUERY y reporta el delta manual sin editarlo (aditividad CA-6). No hay gateways del scaffolder en campo hoy (ControlPlane usa HCL propio), costo real del delta: cero.
- Precision de componente pedida por el usuario ("skill de infra"): el touchpoint de provision APIM es el agente `apim-gateway-scaffolder` (via `/install-apim`), no `/infra` ni `/infra-base`.

## Descartado

- QUERY como **unica** via de `Listar{X}s` (agresiva): GET sigue optimo para filtros planos (cache sin friccion, cero preflight, tooling universal).
- QUERY como mero opt-in futuro (conservadora): el eslabon critico del stack ya funciona hoy y el RFC es estandar propuesto publicado.
- Incluir el fix CORS en el #587: componente distinto, se autobloquearia con la doctrina.

## Preguntas abiertas

- Comportamiento del front-end de App Service en Azure real ante el verbo QUERY (el POC solo valida el host local/Kestrel) -- gate empirico del ADR.

## Referencias

Issues creados: #608 (consecuencias QUERY en el gateway APIM, listo + bloqueado por #587 y #610); #609 (receta GET vs QUERY del planner, listo + bloqueado por #583 y #587); #610 (bug: operaciones APIM faltantes en apim-function-api, listo, sin bloqueo).
Issues refinados: #587 (borrador -> listo), #608 (borrador -> listo).
POCs (no versionados, /tmp local): Function App net10 con trigger "query", cliente HttpClient QUERY, minimal API Kestrel.
