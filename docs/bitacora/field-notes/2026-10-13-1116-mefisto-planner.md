---
fecha: 2026-10-13
hora: 11:16
sesion: mefisto-planner
tema: Refinar #2384 (.mefisto/appinsights.env sin provision ni diagnostico)
---

## Contexto
Refinamiento del borrador #2384, capturado desde el consumidor Bitakora.ControlAsistencia: `/mefisto:bug` no pudo delegar en `bug-investigator` porque faltaba `.mefisto/appinsights.env`.

## Descubrimientos
- El gate de `tooling-pipeline.sh` es un blocklist (`is_path_in_consumer_blocklist`) y ya admite `.mefisto/appinsights.env`; el hueco era solo el texto "ALCANCE PERMITIDO" de los prompts del writer y del reviewer.
- La ubicacion legacy real era `$SCRIPT_DIR/.env` dentro del paquete instalado (cache por version, podado por `/upgrade`); la que sobrevive es `scripts/.env` del consumidor.
- `purge-store.sh` ya resuelve el RG desde el config y descubre recursos por tipo con `az resource list`: es el patron a reutilizar para la provision.
- La seccion 4 de MEF-ADR-0053 (contrato canonico `.mefisto/` del consumidor) no enumera `appinsights.env`.

## Decisiones
- Partir #2384 en cuatro issues: diagnostico (#2384), provision con az (#2387, depende de #2384), prompts de tooling (#2385), aviso legacy (#2386).
- Severidad: FALTA solo si existe `infra/environments/`; NO VERIFICADO en greenfield; `FUNCTIONAPP_NAMES` vacio es INFO.
- Provision desde `az` (no Terraform ni plantilla), modos `--preview/--apply`, nunca sobrescribe, ambiguedad exige flag.
- Aviso legacy solo para `scripts/.env` del consumidor que declare `APPINSIGHTS_APP=`.

## Descartado
- Detectar el `.env` legacy en el cache del plugin (casi siempre ya podado).
- Leer nombres desde Terraform (`terraform output` exige init/backend; nombres interpolados).

## Preguntas abiertas
- Enmendar MEF-ADR-0053 para incluir `.mefisto/appinsights.env` en el contrato canonico (ofrecido como borrador, sin decidir).

## Referencias
Issues refinados/creados: #2384, #2385, #2386, #2387 (los cuatro en estado:listo).
