---
fecha: 2026-10-13
hora: 15:31
sesion: mefisto-planner
tema: Refinar #2394 (bump del pin a Cosmos 3.1.0 / Marten 9.23.0)
---

## Contexto
#2394 nacio como borrador en el refinamiento de #2390: el pin del marco (Cosmos.* 2.1.0 / Marten 9.12.0) no tiene la opcion de tolerancia a huecos y esta afectado por GHSA-rfx3-98h7-v3xp / CVE-2026-75513.

## Descubrimientos
- Diff de API publica 2.1.0 vs 3.1.0 (PoC con MetadataLoadContext): solo rompe Cosmos.MultiTenancy (ITenantResolver -> ITenantContext + OrganizationMembershipId + TenancyHeaders.OrganizationMembershipId); CritterStack suma solo aditivos.
- CritterStack 2.1.0 consume ITenantResolver y 3.1.0 ITenantContext desde DI: rename y bump son atomicos.
- Decompilado (ilspycmd en sandbox): UnitOfWorkMiddleware.Before() estampa user_id y organization_membership_id en cada append; senders y DeliveryOptions en cada mensaje. OrganizationMembershipId se lee siempre.
- organization_membership_id no es claim por defecto de WorkOS AuthKit: requiere JWT Template (doc oficial de WorkOS).
- Namespaces del seam del worker sin cambios en Marten 9.23.0 (PoC por ejecucion); DurabilityMetricsEnabled existe en Wolverine 6.27.1.
- Patron reutilizable: herramienta de diff de API con MetadataLoadContext + ilspycmd con --tool-path en el sandbox, sin tocar el entorno global.

## Decisiones
- Cuatro issues: #2394 (pins + rename en codigo emitido + ADR-0003), #2397 (WorkOS JWT Template + header en APIM + ADR-0032), #2398 (derivacion MCP + ADR-0047), #2399 (barrido doctrinal ITenantContext).
- OrganizationMembershipId estricto como TenantId/UserId; SetDerivedIdentity con tercer parametro obligatorio; mono-tenant devuelve "membresia-no-autenticada".
- Consumidores existentes migran a mano (referencia: Bitakora commit 64d289c1).

## Descartado
- Membership tolerante (cadena vacia) y parametro opcional en SetDerivedIdentity.
- Un solo issue de propagacion (borde + MCP).

## Preguntas abiertas
- Ninguna en los issues; orden de batch sugerido: 2394 -> 2397 -> 2398, con 2399 y 2395 despues de 2394 (2395 tambien tras 2390).

## Referencias
Issues: #2394, #2397, #2398, #2399 (listos); relacionados #2390, #2395.
