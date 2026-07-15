---
fecha: 2026-07-15
hora: 13:03
sesion: mefisto-planner
tema: Refinar #275 (enrutamiento multi-destinatario por correlation filter) - desglose en epico de 3
---

## Contexto
El draft #275 (cross-repo desde `Cosmos-SincoERP/Cosmos.ControlPlane`, issues #22/#61 de ese repo) proponia soportar el envio de un evento publico a N destinatarios distintos via un solo topic + N subscriptions, cada una con un correlation filter de igualdad sobre una application property (clave de enrutamiento, un `bundleId` reverse-DNS). Chocaba con tres piezas del marco: doctrina (ADR-0001), tooling de infra (modulo service-bus) y tooling de publicacion (wrapper del paquete externo).

## Descubrimientos
- **ADR-0001 razono solo sobre filtrado por TIPO de evento** (`docs/adr/0001-*.md:15-26,55-56`): rechazo los filtros SQL del modelo "topic por dominio" por complejidad operativa. El eje de #275 (un evento, N destinatarios, filtro por destinatario, IGUALDAD) es ortogonal y usa un mecanismo distinto. La enmienda es coherente, no contradictoria.
- **El modulo service-bus SI trae un escape-hatch `SqlFilter` latente** (`agents/infra-base-scaffolder.md:400-468`): `topics_config.filter` -> `azurerm_servicebus_subscription_rule` con `filter_type = "SqlFilter"`. Nadie lo usa (siempre `filter = null`) y contradice el "Sin filtros SQL" de ADR-0001. Deuda doctrinal a reconciliar. NO soporta `correlation_filter`.
- **Provider AzureRM soporta `correlation_filter`** (API Microsoft.ServiceBus 2024-01-01): bloque con `properties` (mapa user-defined), `correlation_id`, `session_id`, `label`, `to`, etc.; >=1 property requerida.
- **Microsoft Learn** recomienda correlation filters sobre SQL ("much more efficient") y confirma que los filtros no leen el body (la clave viaja en el sobre). Fundamenta el ADR y la premisa del punto 3.
- **El wrapper de publicacion expone solo `PublishAsync(events)` y `PublishAsync(groupId, events)`** (verificado via el DSL de test `docs/testing/harness-cheatsheet.md:160-178`; `groupId` -> AMQP `group-id` -> `SessionId`). NO hay overload para application properties arbitrarias. La interfaz vive en el paquete externo (`Cosmos.EventDriven.Abstractions`/`.CritterStack.AzureServiceBus` 1.3.0), fuera de este repo -> capacidad requiere evolucion del paquete (verificado-indirectamente; precedente ADR-0024 Alt 4).

## Decisiones
- **Desglosar** (no refinar como uno), replicando el patron del epico #269 -> ADR-0026 (fundacional cerrado + #270 infra + #271 endpoint + #272 guia productor). Aqui no hay "endpoint" porque el filtro es declarativo en la subscription y no cambia el trigger consumidor.
- **ADR-0027 nuevo** (no enmienda pura a ADR-0001), siguiendo el precedente de ADR-0026: primitiva/eje complementario en su propio ADR + cross-ref minima a ADR-0001 (acota "Sin filtros SQL" sin eliminar doctrina vigente). ADR-0027 es el siguiente numero libre (verificado: 0026 es el mas alto).
- **Opcion 1** para la clave de enrutamiento: application property custom via `correlation_filter.properties`; capacidad diferida a evolucion del paquete externo. Issue (c) queda como guia + tracking cross-repo.
- El ADR NO hardcodea `bundleId`: fija el concepto de "clave de enrutamiento" (application property string, igualdad, nombrada por el flujo, reverse-DNS recomendado).
- Reusar #275 como fundacional (a), preservando su `## Origen`. (b) y (c) creados frescos con `bloqueado` y `Depende de #275`.

## Descartado
- **Opcion 2** (reusar `groupId`/`SessionId` como clave de routing): funcionaria sin tocar el paquete, pero conflaciona la clave de enrutamiento con la clave de serializacion de fan-in (SessionId, reservado por ADR-0026). Descartada por deuda semantica.
- Enmienda pura a ADR-0001 sin ADR nuevo: enturbiaria la doctrina raiz limpia de topic-por-evento.
- Fusionar todo en un solo issue: 3 componentes distintos, (c) no entregable hoy (bloqueado por paquete), CAs > 6 y heterogeneos.

## Preguntas abiertas
- (c) queda bloqueado end-to-end por el paquete externo: cuando se evolucione `Cosmos.EventDriven.Abstractions`/`.CritterStack.AzureServiceBus` para exponer application properties, reabrir (c) para la guia completa. Coordinar con el downstream (Cosmos.ControlPlane).
- Reconciliacion del `SqlFilter` latente del modulo (parte de #277): removerlo o documentarlo como prohibido — decision fina al implementar, guiada por ADR-0027.

## Referencias
Issues creados/refinados:
- #275 [estado:listo] Fijar ADR-0027: enrutamiento multi-destinatario de un evento por correlation filter de igualdad (fundacional; refinado desde borrador cross-repo).
- #277 [estado:listo, bloqueado] Ensenar a la capa de infra a generar y validar subscriptions con correlation filter de igualdad (depende de #275).
- #278 [estado:listo, bloqueado] Documentar el estampado de la clave de enrutamiento como application property en la guia del productor (depende de #275).

Grafo de dependencias:
- #275 (fundacional) -> bloquea #277 y #278
- #277 y #278 independientes entre si (paralelizables tras cerrar #275)
