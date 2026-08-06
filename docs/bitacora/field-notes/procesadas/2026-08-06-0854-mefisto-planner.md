---
fecha: 2026-08-06
hora: 08:54
sesion: mefisto-planner
tema: cierre del plan de composicion por rol (batch restante) + refinamiento del gate ciego a docs de tooling-pipeline
---

## Contexto

Sesion de seguimiento del plan 2026-08-05 (composicion de ensamblados por rol + demolicion capa EDA). El usuario pidio (1) revisar lo ya implementado y armar el sequential con lo faltante, y (2) refinar el draft #568 llegado del consumidor Bitakora.ControlAsistencia.

## Descubrimientos

- **Estado del batch de la sesion anterior**: 8 de 11 issues ya mergeados (#548->PR560, #550->PR558, #553->PR567, #554->PR570, #555->PR571, #557->PR572, #561->PR573, #552->PR565). Quedaban #559, #562 y #563, los tres `estado:listo` pero con label `bloqueado` obsoleto (sus dependencias #548 y #561 ya habian cerrado).
- **El bug de #568 es mas amplio que lo reportado en el draft**: el allowlist desincronizado no esta solo en el gate `HAS_UNSTAGED` (L536/559 de `tooling-pipeline.sh`); tambien en `auto_commit_if_needed` (L464-468, chequeo + loop de `git add` -- sin arreglarlo, el fix del gate dejaria el PR sin los cambios docs-only) y en la heuristica de recuperacion de `run_agent` (L422). Tres listas a mano, todas distintas entre si.
- **La seguridad de scope no vive en esos filtros**: `validate_consumer_scope_changes` (`_pipeline-common.sh:630`) revisa todo el diff contra el blocklist -- por eso ampliar la deteccion al patron de exclusion no debilita la frontera MEF-ADR-0019.
- **`.claude/settings.json` no contamina una deteccion amplia**: el pipeline lo restaura con `git checkout` antes de cada chequeo (L457/525/555).

## Decisiones

1. **Batch restante**: `/mefisto-sequential 559 562 563` (orden de las field notes anteriores; sin dependencias entre si -- #562 y #563 comparten `CLAUDE.md` pero el motor secuencial lo cubre con el sync verificado entre eslabones).
2. **Quitados los labels `bloqueado`** de #559/#562/#563 tras verificar que #548 y #561 cerraron.
3. **#568 se refina al patron de exclusion, no al fix minimo**: adoptar en los 4 puntos el patron de `scaffold-pipeline.sh:301` (`-- . ':!.claude/pipeline'`) elimina por construccion la desincronizacion con la allowlist del skill; completar las listas a mano habria reincidido en la familia de fallo que #485 y #406 ya pagaron. Confirmado por el usuario.
4. **El `git add` del auto-commit sigue excluyendo `pipeline-state/` y `.claude/pipeline/`** (MEF-ADR-0017): la deteccion se amplia, el commit no versiona runtime.
5. **El gate de compilacion (filtro `'*.cs' '*.csproj'`) queda fuera del alcance de #568**: filtra por extension a proposito, no es de la misma familia.

## Descartado

- **Fix minimo para #568** (anadir `docs/`, `.claude/harness.config.json` y archivos de raiz a las tres listas): reincide por tercera vez en la enfermedad de listas a mano.

## Preguntas abiertas

- El caso latente documentado en #485 (writer que produce SOLO una senal en `pipeline-state/` gitignored) sigue latente con el patron nuevo -- git status no ve rutas gitignored. Aceptado, no empeora.
- Las mismas listas a mano podrian existir en otros pipelines publicados (`tdd-pipeline.sh` usa `tests/ src/`, que alli SI es su allowlist real): no se detecto sintoma, no se planeo barrido. Revisar solo si aparece un abort equivalente en otro carril.

## Referencias

Issues creados: ninguno.
Issues refinados: #568 (draft del consumidor -> `estado:listo` + `bug`, retitulado "Unificar por exclusion los filtros de cambios de tooling-pipeline.sh (gate, auto-commit, recuperacion)").
Issues desbloqueados: #559, #562, #563 (label `bloqueado` retirado).
Batch sugerido: `/mefisto-sequential 559 562 563`; #568 independiente, via `/mefisto-tooling 568`.
