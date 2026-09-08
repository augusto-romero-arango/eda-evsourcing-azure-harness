---
fecha: 2026-09-07
hora: 19:18
sesion: mefisto-planner
tema: Refinamiento del issue 798 sobre identidad en smoke tests multi-tenant
---

## Contexto
Se refino el draft #798, creado desde una investigacion del consumidor Bitakora.ControlAsistencia, para decidir como deben operar los smoke tests de dominio despues de la transicion a la etapa (b) de tenancy.

## Descubrimientos
- El incidente que origino el draft no fue causado por headers ausentes: los fixtures del consumidor ya enviaban identidad y el defecto real era `ProxyTenantResolver`, corregido doctrinalmente por #802.
- El harness conserva un gap distinto: el `ApiFixture` que genera `domain-scaffolder` no agrega `X-Tenant-Id`/`X-User-Id`, y `ServiceBusFixture.PublishAsync` no agrega las `ApplicationProperties` `tenant-id`/`user_id` que consume `TenantContextMiddleware`.
- MEF-ADR-0013 y `smoke-test-writer` tampoco fijan hoy el transporte de una identidad sintetica para la etapa (b).

## Decisiones
- #798 se acoto a una enmienda doctrinal de MEF-ADR-0013, con un solo componente principal.
- Los smoke tests de dominio seguiran llamando directamente a las Function Apps; no obtendran tokens de WorkOS ni pasaran por APIM.
- La suite usara una identidad sintetica configurable y la propagara por ambos canales: headers HTTP y propiedades de Service Bus.
- Los defaults doctrinales son `tenant-smoke` y `smoke-tests`; no requieren sembrar una organizacion en WorkOS porque el flujo no atraviesa el IdP.
- La identidad puede enviarse incondicionalmente: la etapa (a) la ignora y la etapa (b) la consume.
- La implementacion posterior debe partirse por componente: `domain-scaffolder` para proyectos nuevos y `/install-apim` para suites existentes migradas de (a) a (b).

## Descartado
- Hacer pasar toda la suite de dominio por APIM con un token real de WorkOS: acopla la verificacion black-box del backend al IdP y duplica el gate de borde que ya conserva el checklist post-deploy de `/install-apim`.
- Cerrar #798 como totalmente resuelto por #802: aquel issue corrigio `ProxyTenantResolver`, pero no el transporte de identidad ausente en los fixtures genericos del harness.
- Combinar doctrina y los dos componentes de implementacion en #798: no pasa la revision de complejidad simplificada.

## Preguntas abiertas
- Crear y refinar los dos issues de implementacion que consumiran la enmienda de #798.
- La obtencion o transporte de function keys queda fuera de #798 y debe evaluarse por separado si aparece evidencia de un gap en el scaffold generico.

## Referencias
Issues creados: ninguno.

Drafts refinados: #798 - Enmendar MEF-ADR-0013 para fijar identidad sintetica en smoke tests multi-tenant.
