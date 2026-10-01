---
fecha: 2026-09-30
hora: 05:17
sesion: mefisto-planner
tema: Refinar #1730 y #1731 (hallazgos de la certificación IaC de #1629)
---

## Contexto
Refinamiento de dos issues capturados al cerrar la certificación IaC de #1629 sobre v0.40.0.

## Descubrimientos
- #1730: el fallback de CA-4 omitía los nombres de log con variante (`tdd-pipeline.sh:381`, `tooling-pipeline.sh:302`). El colector ya da prioridad a un `log` declarado que exista, así que la escritura en los pipelines no depende de la lectura.
- #1731: todos los `ts` neutrales son UTC con `Z`; el runner los recorta con `.[11:19]` sin convertirlos. Los holds (`_pc_epoch_at`) interpretan el `HH:MM:SS` de events.log como hora local.

## Decisiones
- #1730 partido por lado: #1730 = lectura (colector); #1734 = escritura del `log` declarado en los cuatro pipelines. Sin dependencia entre ambos.
- #1731: unificar en hora local convirtiendo solo en el runner (`strflocaltime`); se descartó el offset explícito porque obligaría a tocar los parsers de hold.

## Descartado
- Mantener #1730 como un único issue con los cuatro pipelines.
- Offset explícito en events.log.

## Preguntas abiertas
- Ninguna.

## Referencias
Issues refinados: #1730, #1731. Issues creados: #1734.
