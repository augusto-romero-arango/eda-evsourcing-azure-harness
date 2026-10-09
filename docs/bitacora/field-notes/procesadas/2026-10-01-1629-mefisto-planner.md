---
fecha: 2026-10-01
hora: 16:29
sesion: mefisto-planner
tema: refinar issue 1750 sobre permisos OpenCode del test-writer
---

## Contexto
Se pidio refinar #1750 tras fallos en la certificacion de Bitakora.ControlAsistencia con Mefisto v0.40.1.

## Descubrimientos
El test-writer publicado exige verificar y leer tres documentos fuera del cwd del consumidor; el adaptador OpenCode emite bash deny por defecto y external_directory deny. Los tests actuales solo verifican presencia del conocimiento y permisos declarados, no su uso efectivo.

## Decisiones
Se refino #1750 como bug publicado acotado al agente test-writer y su adaptador OpenCode, conservando denegacion por defecto y pidiendo prueba de permisos efectivos. Se marcaron ADRs 0019, 0049, 0050 y 0053.

## Descartado
No ampliar external_directory globalmente ni mezclar el diagnostico del pipeline TDD en este issue.

## Preguntas abiertas
Crear seguimiento independiente para el mensaje de fallo de scripts/tdd-pipeline.sh:951 y verificar si otros agentes leen la release fuera del worktree.

## Referencias
Issues refinados: #1750, Permitir al test-writer de OpenCode consultar la release activa.
Issues creados: ninguno.
