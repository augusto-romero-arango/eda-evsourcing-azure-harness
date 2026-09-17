---
fecha: 2026-09-16
hora: 14:06
sesion: mefisto-planner
tema: Refinamiento del comando implement neutral publicado
---

## Contexto
Se refino #1410 para migrar el entrypoint TDD legacy a la fuente neutral publicada y proyectarlo en Claude y OpenCode.

## Descubrimientos
Los adaptadores ya emiten un unico preambulo de package root por artefacto y `tmux-pipeline.sh` ya valida y propaga `--models`, `--variant` y un solo `--scaffold-domain`. La fuente neutral puede obtener `namespacePrefix` mediante `{{mefisto:config-path}}`.

## Decisiones
El comando acepta solo tipos TDD, alinea dependencias con las lineas canonicas de `tooling`, elimina `SCAFFOLD_FLAG` y describe dos despachos neutrales. Queda `estado:listo` y `bloqueado` por #1407.

## Descartado
Se retiro MEF-ADR-0031 por no gobernar esta migracion. Se descarto extraer cualquier `#N` de Dependencias y conservar resolucion manual de markers/cache en el comando.

## Preguntas abiertas
Ninguna para #1410.

## Referencias
Issues refinados: #1410 Migrar implement a fuente neutral publicada. Dependencia: #1407. Bloqueado: #1411.
