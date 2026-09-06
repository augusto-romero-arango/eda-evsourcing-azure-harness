---
fecha: 2026-09-05
hora: 17:32
sesion: mefisto-planner
tema: refinamiento del backlog de arquitectura neutral runtime/proveedor (#851-#875) y plan de batch
---

## Contexto

El mantenedor creo 25 drafts (#851-#875) para convertir a Mefisto en un harness portable que no dependa solo de Claude Code (OpenCode como runtime de dogfooding interno, proveedores intercambiables). Pidio revisarlos y producir un plan de refinamiento en el orden de implementacion. Durante la sesion corrio en paralelo `mefisto-batch-pipeline.sh 851 852`: ambos quedaron mergeados (PR #876, #877) mientras se refinaba el resto.

## Descubrimientos

- **Carrera refinamiento/pipeline**: el writer lee el issue al arrancar; una edicion posterior del body no la ve. El PR de #852 si incluyo la correccion del prompt del writer (`Mefisto no tiene src/`) porque el amend llego a tiempo, pero es un riesgo a tener presente cuando se refina con un batch en curso.
- **El watchdog interno es timeout duro** (`run_agent_with_watchdog`, #424): no existe deteccion de inactividad. El draft #861 hablaba de "actividad util"; lo que existe es el criterio de confianza `agent_work_is_trustworthy`.
- **No hay telemetria interna por hook**: el unico hook interno es `mefisto-scope-hook.sh` (aviso de scope); las lineas `[archivo]` de `events.log` las escribe `hooks/hooks.json` publicado sobre el consumidor.
- **OpenCode 1.18.29** (verificado en el binario y el CLI): acepta `.opencode/{agent,agents,command,commands,plugin,plugins,skill,skills}`; `opencode run` soporta `--agent --dir --format json -m --auto`; vocabulario de permisos `bash edit write patch read list glob grep question skill task lsp todowrite websearch webfetch external_directory doom_loop` con `allow|ask|deny`; los plugins son modulos JS (`tool.execute.after`, `event`, `file.edited`). Lee `AGENTS.md` y tiene fallback a `CLAUDE.md`.
- **Herdr acepta `--kind opencode`** (lista de kinds de `herdr agent start --help`): el fallback previsto en #875 no hace falta.
- **OpenAI ya conectado por OAuth** en la maquina del mantenedor; `opencode models openai` lista 15 ids.
- `claude --help`: `fable`, `opus`, `sonnet` son alias de familia; hoy planner=`fable`, investigator=`opus`, historiador=`sonnet`, comandos=`haiku`, writer=`sonnet`, reviewer=`opus`.
- El repo no depende de Node; `mefisto-release.sh` usa `python3` en 6 puntos (deuda anotada en #864).

## Decisiones

1. **Toolchain Bash + jq** para generador y validador (sin Node/Python/yq). Consecuencias: contrato neutral en JSON parseable por jq; validacion como programa jq (`jsonschema-lite.jq`, subconjunto documentado); emision de frontmatter con escalares JSON-quoted y flow mappings.
2. **Particion del ADR**: MEF-ADR-0049 fija arquitectura y rollout interno; `dist/`, distribucion GitHub-only y "version activa global" se difieren a un ADR posterior. Por eso `dist/` no se registro en #852.
3. **`.mefisto/` es integramente estado** (gitignored, fuera de la allowlist, mismo trato que `.claude/pipeline/`); el `models.example.json` vive en `src/internal/`. #857 enmienda la decision 4 del ADR (que decia `.mefisto/models.json.example`).
4. **Formato de fuente neutral A**: un `.md` por artefacto con frontmatter **JSON** entre `---` (valido como YAML 1.2), body Markdown, `$ARGUMENTS` como unico placeholder.
5. **Shim `CLAUDE.md` por import `@AGENTS.md`** (mecanismo documentado por Claude Code), no instruccion textual.
6. **Perfiles, opcion 2**: adaptador Claude `fast=haiku`, `balanced=sonnet`, `deep=heredar` (sin `model:`/`--model`); OpenCode sin tabla. Precedencia: `--models` -> `.mefisto/models.json` local -> tabla del adaptador -> herencia. El generador no lee el mapping local (determinismo). Los ids de OpenAI no se fijan en ningun issue: se eligen en #874 y quedan en el mapping local + evidencia.
7. **Sin plugin JS en OpenCode (opcion A)**: el scope temprano lo da el `edit` deny-por-defecto (#862); la telemetria la emite el runner neutral (#863). El repo no incorpora JS.
8. **Directivas de body** en el generador (#854): `{{mefisto:launch-agent <id>}}`, `{{mefisto:run <script> <args>}}` (antepone `MEFISTO_RUNTIME=<rt>` y usa la ruta shim `.claude/scripts/` como superficie estable) y `{{mefisto:command-path <id>}}`.
9. **Shims a mano con plantilla unica** (#864), no generados; `_mefisto-common.sh` se traslada con shim-`source` para conservar la propiedad de MEF-ADR-0019 seccion E.
10. **Agentes headless neutrales** `mefisto-writer`/`mefisto-reviewer` para que OpenCode ejecute cada stage bajo permisos propios (#879); Claude headless conserva `claude -p` con prompt.
11. **Particiones**: #861 -> #861 (metricas/historial/confianza) + #878 (visor); #869 -> #869 (traslado + rutas de estado) + #879 (conexion al runner).
12. `edit` de OpenCode debe permitir `.mefisto/pipeline/summaries/**` (el resumen de stage que el pipeline exige) — detectado al revisar #862.

## Descartado

- Node (`.mjs`) como toolchain del generador.
- Frontmatter YAML plano parseado con awk; sidecar JSON + MD.
- Registrar `.mefisto/**`, `.opencode/**`, `src/**`, `dist/**` como globs amplios en el gate.
- Tabla fija `deep=opus` (bajaria el planner de `fable` a `opus`) y herencia total (encarece comandos `haiku`).
- Plugin JS de OpenCode para hooks.
- Watchdog por inactividad (no existe; no se inventa).

## Preguntas abiertas

- Si OpenCode carga `CLAUDE.md` ademas de `AGENTS.md` cuando ambos existen (smoke de #855 lo registra; #868 decide `instructions`).
- Wire format exacto de `opencode run --format json`: se captura como fixture en #860.
- Sintaxis vigente de patrones de permiso de OpenCode (`bash`/`edit`/`read`) y semantica "ultima coincidencia gana": el writer de #862 la verifica en docs.
- Sustituir `python3` de `mefisto-release.sh` por awk/jq (deuda, sin issue).
- Fase publicada (dist/, GitHub-only, version activa global): ADR y backlog posteriores a #874.

## Referencias

Issues refinados a `estado:listo`: #851 (cerrado, PR #876), #852 (cerrado, PR #877), #853, #854, #855, #856, #857, #858, #859, #860, #861, #862, #863, #864, #865, #866, #867, #868, #869, #870, #871, #872, #873, #874, #875.
Issues creados: #878 (visor neutral, particion de #861), #879 (runner en tooling pipeline, particion de #869).
Titulos cambiados: #863 (sin plugin: telemetria del runner + scope temprano), #869 (traslado + rutas de estado).
Orden de batch validado con `mefisto-validate-batch-deps.sh`: 853 855 856 854 857 858 859 860 862 861 878 863 864 865 866 867 868 869 879 870 871 872 875 873 874.
Fuera de este plan: #849 y #850 (doctrina HTTP de comandos), drafts de hoy sin relacion con portabilidad.
