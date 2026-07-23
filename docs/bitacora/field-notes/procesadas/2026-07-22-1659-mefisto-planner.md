---
fecha: 2026-07-22
hora: 16:59
sesion: mefisto-planner
tema: Onboarding de autenticacion (WorkOS + APIM) como capacidad del harness
---

## Contexto
El consumidor Cosmos.ControlPlane instalo WorkOS (identidad/auth/authz) + Azure API Management
como front door que valida el JWT en el borde. El pedido: crear un skill de Mefisto para instalar
WorkOS en un consumidor, incluyendo la guia de creacion de cuenta/parametrizacion en el dashboard
y las referencias de doc de WorkOS dentro del harness. Primer consumidor destino: Bitakora.ControlAsistencia.
Se exploro el repo de ControlPlane a fondo antes de planear.

## Descubrimientos
- **WorkOS no es "una cosa", son 4 capas**: (1) aprovisionamiento de identidad (puerto
  `IIdentityProvider` + adapter `WorkOsIdentityProvider`, SDK WorkOS.net 5.5.0); (2) custodia de
  la API key (patron identico a `/seed-secret`, GitHub secret -> Key Vault via infra-cd);
  (3) auth/authz en el borde (APIM Consumption + `validate-jwt`); (4) tenancy etapa (b).
- **Mefisto no tenia doctrina de edge-auth/IdP** (grep vacio de workos/apim/authkit/identity).
  ControlPlane lo resolvio con un ADR local (`ADR-0027`, "Propuesto"), no del marco.
- **Insight clave de tenancy**: MEF-ADR-0028 dejo la transicion a->b como manual porque el mapping
  de claims era "project-specific". Pero con WorkOS+APIM ese mapping vive en la politica del APIM
  (normaliza a headers canonicos `X-Tenant-Id`/`X-User-Id`), asi que el resolver del dominio es
  generico -> la migracion a->b **si es automatizable**. Instalar auth ES el momento a->b.
- **Doctrina "escribir local, aplicar en CI"** desata el orden: el codigo y el Terraform no
  necesitan los valores de WorkOS para autoria; la cuenta (long-pole humano) solo bloquea el apply.
- El issue #335 (draft sin labels, autor luisfelipediaz) ya traia el catalogo de trampas B1-B10 y
  el HCL corregido C1-C4 del APIM: es la spec del agente APIM. Su seccion E (rotacion de secretos
  con stop/start) era candidata a issue aparte, tal como el propio issue anticipaba.
- Vocabulario nuevo acordado: familia de skills `install-*` (`/install-workos`, `/install-apim`,
  `/install-auth`); "bifurcacion de dos caminos" en `/onboard` (crecer=auth / POC=sin auth) mapeada
  1:1 a las dos etapas de MEF-ADR-0028.

## Decisiones
- **Dos skills de capa + un orquestador**: `/install-workos` (identidad), `/install-apim` (borde),
  `/install-auth` (orquestador que los encadena con gate humano en medio). "Dos distintas que a
  veces van juntas".
- **La bifurcacion vive en `/onboard`** (punto de partida greenfield), registrada via
  `tenancy.strategy`; la orquestacion vive en `/install-auth`. Reparto: onboard = doctor que dice
  que camino; install-auth = el que lleva por el camino.
- **Opcion 2 (validada): flip a->b con migracion automatica del resolver, enmendando MEF-ADR-0028.**
  La enmienda levanta el limite "a->b manual" solo para el camino WorkOS+APIM.
- **MEF-ADR-0032 nuevo** como ancla de edge-auth; absorbe las referencias de doc de WorkOS.
- **Fuente de verdad: el codigo funcionando en ControlPlane por encima de la documentacion.**
- **Nombre del orquestador: `/install-auth`** (coherencia con la familia `install-*`).
- **Agentes separados de los skills** (agente identidad #338, agente APIM #335) para olas paralelas
  y revisiones limpias.

## Descartado
- Absorber el orquestador dentro de `/onboard` (opcion 2 de la pregunta de forma): se mantiene
  `/onboard` como doctor y el runner pesado sale a su propia pieza descubrible.
- Un solo mega-skill "instalar WorkOS" con las 4 capas: demasiado grande y con el gap de doctrina.
- Nombres `/setup-auth`, `/onboard-auth`, `/auth` para el orquestador.
- Flip temprano de tenancy (opcion 1) y flip tardio sin migracion (opcion 3 = status quo del ADR).

## Preguntas abiertas
- Nombres finales de archivo de los agentes: `agents/workos-identity-scaffolder.md` y
  `agents/apim-gateway-scaffolder.md` (propuestos, a confirmar al implementar).
- Version exacta de `WorkOS.net` a fijar (ControlPlane usa 5.5.0; re-verificar al implementar).
- Valores WorkOS a re-verificar contra el discovery doc en vivo (issuer, jwks_uri, nombres de
  claim) al redactar el ADR e implementar el agente APIM.

## Referencias
Issues creados:
- #336 Redactar MEF-ADR-0032 de identidad y autenticacion en el borde con WorkOS + APIM (ancla)
- #337 Enmendar MEF-ADR-0028 para automatizar la transicion a->b con migracion de resolver (dep #336)
- #338 Crear agente generador del codigo de integracion con WorkOS (dep #336)
- #339 Crear skill /install-workos (dep #336, #338)
- #340 Crear skill /install-apim (dep #336, #337, #335)
- #341 Extender /onboard con la bifurcacion de dos caminos de auth (dep #336, #337)
- #342 Crear skill orquestador /install-auth (dep #339, #340)
- #343 Corregir la siembra de secretos externos (stop/start) para reflejar rotaciones (independiente)

Issue refinado:
- #335 Crear agente generador del modulo APIM fiel al catalogo de trampas (era draft sin labels;
  acotado al agente, con B1-B10/C1-C4 preservados como spec de referencia; dep #336)
