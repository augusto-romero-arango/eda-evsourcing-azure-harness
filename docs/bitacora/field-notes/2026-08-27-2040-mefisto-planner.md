---
fecha: 2026-08-27
hora: 20:40
sesion: mefisto-planner
tema: Refinamiento del draft de purga de store en dev (#725) y revision de backlog listo
---

## Contexto
Draft cross-repo #725 (consumidor Bitakora.ControlAsistencia): skill agentico de purga de store de dominio en dev, originado en el incidente del issue #433 del consumidor (deploy sin purga, 3 dias de smoke rojos con nulls silenciosos por 42804 de `mt_version`). Sesion pedida para refinarlo a `estado:listo`.

## Descubrimientos
- Los "candidatos a tokens nuevos en `harness.config.json`" del draft son **todos derivables**: el secreto es siempre `marten-connection` (MEF-ADR-0025), el schema es el dominio en snake_case (`domain-scaffolder`), y server Postgres / Key Vault / Container App del worker / Function App se descubren via `az resource list` sobre el RG de `infraResourceGroupPrefix` (agnostico a naming CAF/legacy, MEF-ADR-0045). Cero tokens nuevos.
- Un skill de purga **no contradice** MEF-ADR-0036 seccion 5: la operacionaliza. Requiere enmienda (mecanismo canonico) sin cambiar la regla "la purga pertenece al mismo despliegue".
- El label `bloqueado` de #722 estaba caducado: su dependencia #718 ya esta cerrada.

## Decisiones
- **Corte hibrido** (eleccion del usuario): skill agentico para diagnostico/confirmacion/validacion + script bash determinista para lo destructivo (patron `/seed-secret` -> `seed-secret.sh`). La "experiencia agentica de punta a punta" del consumidor se cumple igual: el script es detalle interno.
- **Desglose en dos issues por capa**: #725 reconvertido en el script `scripts/purge-store.sh` (valor independiente: es la operacion manual que MEF-ADR-0036 s5 ya prescribe) y #743 nuevo para el skill `commands/purge-store.md` + enmienda ADR, dependiente de #725 con label `bloqueado`.
- La guarda anti-prod y el trap de limpieza del firewall van codificados en bash, no sujetos a juicio del LLM.
- `--dry-run` del script como insumo de la confirmacion humana del skill.

## Descartado
- Via completamente agentica (agente ejecutando `az`/`psql` con juicio): un `DROP SCHEMA CASCADE` decidido por un LLM es donde el marco prefiere determinismo.
- Tokens nuevos en `harness.config.json` para server/KV/worker/mapa schema->FA: derivables, ver Descubrimientos.
- Issue separado para la enmienda de MEF-ADR-0036: viaja en #743 como consecuencia del skill.

## Preguntas abiertas
- Quitar el label `bloqueado` caducado de #722 (dependencia #718 cerrada): sugerido, quedo sin ejecutar en esta sesion.
- Orden de batch sugerido sin ejecutar: `/mefisto-sequential 725 743` (el validador de deps reconoce que el orden resuelve la dependencia), o `726 722 725 743`.

## Referencias
Issues creados: #743 (Crear el skill /purge-store que diagnostica, confirma y valida la purga de store en dev)
Issues refinados: #725 (draft -> Crear el script determinista de purga de store de dominio en dev, `estado:listo`)
Relacionados: #718 (cerrado, mismo episodio), #722/#726 (backlog listo revisado)
