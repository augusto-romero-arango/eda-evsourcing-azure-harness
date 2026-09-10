---
fecha: 2026-09-10
hora: 08:13
sesion: mefisto-planner
tema: Refinamiento del backend real usado por setup-github-ci
---

## Contexto

El consumidor privado de certificación creó correctamente su backend Terraform `dev` con naming CAF mediante Mefisto v0.37.2. La configuración posterior de CI OIDC falló al asignar el rol de datos sobre el tfstate porque `setup-github-ci.sh` combinó la Storage real con un Resource Group legacy inexistente. El fallo originó #1208.

## Descubrimientos

- `setup-github-ci.sh` fija `TFSTATE_RG="${HARNESS_RG_PREFIX}-tfstate"`, aunque resuelve `storage_account_name` desde `infra/environments/*/backend.tf`.
- `_pipeline-common.sh` ya contiene los lectores puros gemelos `read_backend_storage_account_name` y `read_backend_resource_group_name`.
- Resolver ambos valores de forma independiente no basta cuando existen varios ambientes: RG y Storage forman una pareja del mismo backend efectivo.
- La corrida parcial dejó app/SP, `Contributor` y `Role Based Access Control Administrator` condicionado; no dejó rol de datos ni credenciales federadas. No se persistieron IDs en la evidencia.

## Decisiones

- Refinar #1208 como un único issue del script publicado `setup-github-ci.sh`.
- Resolver una única pareja completa RG/Storage antes del primer efecto Azure; ausencia, incompletitud o ambigüedad fallan temprano.
- Conservar backends legacy por sus literales versionados, no recomputando nombres desde el config actual.
- Exigir una prueba hermética nueva con `az` y `gh` stubbeados que cubra CAF, legacy, entrada inválida y reejecución parcial.
- Mantener #1180 bloqueado hasta una release nueva y una repetición idempotente; no completar manualmente Azure para simular éxito.

## Descartado

- Crear manualmente el role assignment y las federated credentials faltantes: ocultaría un defecto de la release observada.
- Borrar la app/SP y los roles ya creados: el contrato del bootstrap es idempotente y la repetición debe demostrarlo.
- Elegir el primer RG y la primera Storage encontrados por separado: permitiría mezclar ambientes.
- Modificar `_pipeline-common.sh` sin necesidad: los lectores requeridos ya existen y tienen cobertura.

## Preguntas abiertas

- Tras integrar #1208 debe publicarse un nuevo patch e instalarse en el consumidor antes de reintentar `setup-github-ci.sh`.
- `infra/environments/dev/backend.tf` sigue sin commit en el consumidor y debe viajar posteriormente por PR, junto con la infraestructura base.

## Referencias

Issues creados: #1208. Issue refinado: #1208. Issue bloqueado: #1180. Release observada: v0.37.2.
