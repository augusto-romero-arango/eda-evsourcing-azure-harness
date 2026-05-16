---
fecha: 2026-05-15
hora: 20:40
sesion: mefisto-planner
tema: skill interno de release/publicacion del plugin
---

## Contexto

El usuario quiere automatizar el ciclo de release del plugin Mefisto: hoy se hace a mano (editar `plugin.json`, mover `[Unreleased]` del CHANGELOG, taggear, pushear), y aunque hay cuatro tags (`v0.1.0..v0.2.0`) ningun GitHub Release esta publicado. Se busca un skill interno que reciba `patch|minor|major`, calcule el SemVer, prepare el CHANGELOG y publique el release con esas notas como cuerpo.

## Descubrimientos

- El `CHANGELOG.md` actual ya sigue Keep a Changelog (es-ES) + SemVer y declara la convencion en el header. No hace falta introducir formato nuevo.
- `gh release list` esta vacio pese a existir 4 tags: confirma que la pieza faltante es la publicacion del release (no el tag).
- El link de comparacion del pie `[Unreleased]` esta desactualizado (apunta a `v0.1.0...HEAD` cuando ya estamos en `v0.2.0`). El skill, en su primer uso, corregira esto como efecto colateral.
- `marketplace.json` no tiene campo `version`; solo se bumpea `plugin.json`.
- La convencion del repo "nunca commit directo a main" obliga a partir el flujo en dos fases (prepare via PR + publish desde main al dia). Se documenta como decision explicita.

## Decisiones

- **Nombre del skill**: `/mefisto-release` (mas idiomatico que `/mefisto-publish`; alineado con git-flow/conventional-changelog).
- **Flujo en dos fases detectadas por estado**:
  - prepare: cuando `plugin.json.version == ultimo tag` -> crea rama `release/vX.Y.Z`, mueve unreleased, bumpea, abre PR.
  - publish: cuando `plugin.json.version > ultimo tag` -> taggea y publica GitHub Release.
  La fase se detecta automaticamente; el usuario solo pasa `patch|minor|major` en la primera invocacion.
- **Implementacion partida** en `.claude/commands/mefisto-release.md` (orquestacion) + `.claude/scripts/mefisto-release.sh` (logica bash con parseo de CHANGELOG y semver). Replica el estilo de `mefisto-merge.md` + `mefisto-tooling-pipeline.sh`.
- **Idempotencia**: aborta si ya existe tag o release para la version objetivo, o si hay cambios sin commitear / remoto adelantado.

## Descartado

- **Single-shot con commit directo a main**: descartado por contradecir el contrato del repo. Aunque para releases es comun saltarse PRs, mantener la regla universal simplifica auditoria y permite revisar el bump antes de publicarlo.
- **Skill publicado equivalente**: no aplica. El versionado del propio plugin solo tiene sentido dentro del repo de Mefisto.

## Preguntas abiertas

- Cuando arranque la fase prepare por primera vez, sera valido bumpear a `0.3.0` aunque `[Unreleased]` del CHANGELOG este vacio (no hay nada que liberar todavia). Se decidio que el skill aborte si esta vacio; el ejecutor debe poblar `[Unreleased]` antes de invocar. Si despues vemos que es friccion innecesaria, lo relajamos a "permitir bump vacio con advertencia".
- Etiqueta del PR de release (p.ej. `tipo:tooling`): se decidira en implementacion. No bloquea el issue.

## Referencias

Issues creados:
- #3 - Anadir skill interno /mefisto-release para versionar y publicar el plugin
