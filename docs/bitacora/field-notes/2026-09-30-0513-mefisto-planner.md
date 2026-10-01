---
fecha: 2026-09-30
hora: 05:13
sesion: mefisto-planner
tema: Refinar #1730 (PR y log de corridas terminadas en work-status) tras la revision de consistencia de issues listos
---

## Contexto
La sesion empezo con una revision de consistencia de todos los issues `estado:listo`: se creo #1687 (separar la delegacion completa y la puntual de launch-agent) y se ajustaron #1650, #1652, #1653, #1655, #1657, #1662, #1669, #1671, #1672 y #1681. Despues se refino #1730, el unico gap (CA-4) por el que la certificacion IaC de #1629 sobre `v0.40.0` dio `NO PASA`: `/work-status` no muestra el PR ni el log de las corridas infra terminadas.

## Descubrimientos
- El PR si esta en `pipeline-history.jsonl` (`iac-pipeline.sh:754`), pero `work-status-collect.sh` lo pierde: al armar `detail` prioriza `environment` sobre `pr` (`:501-509`) y no expone `pr` en `history[]` (`:511-522`).
- El comando `work-status` se contradice: no lista `pr` entre los campos de `history[]` (`:31`), pero en `:73` pide usarlo.
- El log sale `null` en toda entrada terminada, no solo en infra: ninguna trae `log` ni `stage`, `reconstruct_log` corta sin stage (`:127`) y solo conoce nombres por stage. TDD y Tooling tienen el mismo fallo, que el borrador no mencionaba.
- El log de scaffold lleva PID (`scaffold-<ts>-<pid>.log`) y no se puede reconstruir desde el historial.

## Decisiones
- Titulo generalizado: "Reflejar el PR y el log de las corridas terminadas en work-status"; labels `bug`, `tipo:tooling` y `estado:listo`; 6 CA.
- Fallback de reconstruccion del log de corrida para infra, tdd y tooling.
- Los cuatro pipelines (iac, tdd, tooling y scaffold) declaran `log` en toda entrada terminal del historial (`completed` y `failed`, y ademas `blocked` en TDD). El colector prioriza el log declarado y solo reconstruye para el historial previo.
- `detail` combinado en el colector (`env:dev, PR #66`) mas el campo `pr`.
- #1629 declara "Depende de #1730" y lleva `bloqueado`.
- No se reordena la prioridad del fallback para las entradas `failed` previas.

## Descartado
- Arreglar solo infra dejando TDD y Tooling como un fallo conocido abierto.
- Pintar `pr` en una columna propia del render del comando (obligaba a cambiar el render y su test).

## Preguntas abiertas
- #1731 (zona horaria de `events.log`) sigue como borrador no bloqueante.

## Referencias
Issues refinados: #1730. Issues ajustados: #1629 (dependencia y bloqueado), #1650, #1652, #1653, #1655, #1657, #1662, #1669, #1671, #1672 y #1681. Issue creado: #1687.
