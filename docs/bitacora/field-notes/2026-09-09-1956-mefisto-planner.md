---
fecha: 2026-09-09
hora: 19:56
sesion: mefisto-planner
tema: Refinamiento y desglose de la visibilidad de modelos por pipeline
---

## Contexto

Se retomo el draft #1074, creado antes de cerrar la cadena de neutralizacion
#1045-#1063, para verificar su causa raiz contra el codigo vigente y llevarlo a
Definition of Ready. El dolor operativo sigue presente: durante una corrida, la
consola no declara consistentemente el modelo seleccionado para cada stage.

## Descubrimientos

- El tooling interno ya resuelve `MODEL_WRITER` y `MODEL_REVIEWER` antes de
  `run_agent`, pero su linea visible conserva `Invocando <agente>...`.
- El tooling publicado ya resuelve un modelo concreto y lo entrega al runner
  neutral, pero no emite una linea visible antes del bucle de intentos.
- TDD combina stages normales en `run_agent` con remediaciones directas 4b/4c;
  su evidencia `MODELS:` existe solo cuando se usa `--models`.
- IaC y scaffold heredan `model:` del frontmatter publicado sin resolverlo para
  observabilidad. Los 20 agentes publicados declaran hoy esa clave.
- `scripts/_pipeline-common.sh` no ofrece un resolutor de esa metadata. La ruta
  debe derivarse del archivo sourceado y no del `cwd` del consumidor.
- #1062 y #1063 estan cerrados; el label `bloqueado` de #1074 habia quedado
  obsoleto. #1066 no tiene solapamiento tecnico con esta mejora.

## Decisiones

- Se descarto conservar los cinco pipelines en #1074 porque excedia un
  componente principal y una pasada menor a 30 minutos.
- #1074 queda limitado a la paridad de tooling interno/publicado. Ambos lados
  permanecen juntos porque representan la misma operacion y separar uno dejaria
  una UX distinta entre el repo de Mefisto y sus consumidores.
- El resolutor de `model:` queda como fundamento independiente en #1185.
- TDD, IaC y scaffold quedan en #1186, #1187 y #1188 respectivamente; los tres
  dependen de #1185 y conservan `estado:listo` + `bloqueado`.
- La decision historica de ejecutar #1074 despues de la cadena de neutralizacion
  se considera satisfecha. No se agrega una dependencia artificial de #1066.
- La mejora es solo de observabilidad: no cambia argv, precedencia de modelos,
  reintentos, hold, reanudacion ni desenlaces de stage.

## Descartado

- Mantener el scope monolitico original de #1074.
- Duplicar el parsing de frontmatter dentro de TDD, IaC y scaffold.
- Reutilizar el parser de frontmatter neutral interno desde el paquete
  publicado, lo que cruzaria la separacion de MEF-ADR-0019.
- Tratar #1066 como dependencia de orden sin una relacion tecnica real.

## Preguntas abiertas

Ninguna para el refinamiento. Tras cerrar #1185, los labels `bloqueado` de
#1186-#1188 podran retirarse.

## Referencias

Issues refinados: #1074.

Issues creados: #1185, #1186, #1187, #1188.

ADRs aplicables: MEF-ADR-0019, MEF-ADR-0049, MEF-ADR-0050.
