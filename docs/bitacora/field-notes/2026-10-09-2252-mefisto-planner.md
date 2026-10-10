---
fecha: 2026-10-09
hora: 22:52
sesion: mefisto-planner
tema: titulo en el resumen del lote, limpieza de #2157 y licenciamiento del repo
---

## Contexto
Continuacion de la sesion de las 22:24 (PR #2221): refinar #2220 y su par, limpiar el ultimo borrador del backlog y revisar el licenciamiento del repo.

## Descubrimientos
- El historial (`pipeline-history.jsonl`) ya trae el `title` en el lado interno y en tdd/tooling publicados: el titulo en el resumen del lote no toca el contrato.
- El repo se contradice en su licencia: `LICENSE` es MIT, `plugin.json` y `README.md` dicen PROPRIETARY, y el repo es publico.
- `LICENSE` y `NOTICE` no estan en `is_path_in_mefisto_scope`: hay que registrarlos antes de modificarlos (MEF-ADR-0019 seccion E).
- Riesgo de titularidad patrimonial: Ley 23 de 1982 art. 20 (mod. Ley 1450 de 2011 art. 28) presume la transferencia al empleador o contratante salvo pacto escrito. A verificar con un abogado o con Sincosoft.

## Decisiones
- #2220 (interno) y #2224 (publicado) en `estado:listo`: titulo del issue en el resumen del sequential.
- #2157 cerrado como not planned: era una idea guardada, no trabajo.
- Licencia Apache-2.0 (sobre MIT) por `NOTICE`, aviso de cambios, licencia de patentes y clausula de marcas, manteniendo uso comercial libre: #2230 (registro de scope) y #2231 (relicencia, bloqueado).

## Descartado
- Mantener MIT; licencias copyleft.

## Preguntas abiertas
- Titularidad patrimonial de Mefisto frente a Sincosoft antes de lanzar #2231.
- DCO para contribuciones externas, si llegan.

## Referencias
Issues: #2220, #2224 (listos); #2157 (cerrado); #2230, #2231 (borradores)
