---
fecha: 2026-10-01
hora: 16:33
sesion: mefisto-planner
tema: Permisos OpenCode del test-writer y estrategia de CI (de CI por PR a nightly)
---

## Contexto
Refinamiento de #1750 (denegaciones del test-writer en OpenCode, campo Bitakora.ControlAsistencia) y de #1755 (CI en macOS). La conversacion derivo a la estrategia completa de CI: rojos en Linux, espera del CI en los merges, y como bajar la duracion de la suite (~32 min).

## Descubrimientos
- OpenCode evalua `permission.bash` por nodo `command`: lo denegado en el preambulo no es el `if` sino `uname`, el lanzador, `pwd -P` y `export`. El preambulo es comun a 11 agentes publicados.
- Ningun test del repo ejecuta un runtime real: todos usan stubs. Los tests de permisos validan la forma del JSON, no la evaluacion efectiva; por eso el bug paso.
- En OpenCode 1.18.29 `external_directory` es `PermissionRuleConfig` (mapa de patrones), verificado en `@opencode-ai/sdk` types.gen.d.ts:1341.
- `gh pr checks --json` expone `bucket` (pass|fail|pending|skipping|cancel).
- Duraciones reales (run 36937867139): 216 tests, 41 min de trabajo; el carril publicado marca 31.7 min; test mas largo 191 s (test-tdd-agents.sh).
- `~/.config/opencode/opencode.jsonc` puede tener API keys; credenciales del runtime en `~/.local/share/opencode`.

## Decisiones
- Sin OpenCode/Claude real en pruebas: verificacion por test de contrato que simula la evaluacion de permisos.
- Ningun PR corre tests. La suite completa corre en una nightly a las 3 AM (UTC-5, cron '0 8 * * *'), en un solo job secuencial. Se retira la espera del CI de batch, release y /mefisto-merge, y se elimina el helper.
- No se paralelizan tests (riesgo de estado compartido) ni se reparte en shards.
- Issue automatico ante fallo de la nightly, con label `nightly-rojo`, dedup por comentario y auto-cierre al volver a verde.
- Ruleset de main sin check requerido.
- Coverage (kcov) se retira: sin suite en la plataforma real no aporta valor.
- Lecturas externas en OpenCode por lista blanca: raiz de datos de Mefisto + ~/.config/opencode/{agents,commands,skills}; nada de opencode.jsonc, plugins ni credenciales.

## Descartado
- #1759 (seguir esperando el CI), #1765 (omitir suite en PRs de docs), #1767 (auditoria de independencia), #1768 (pool de workers), #1769 (--shard), #1770 (matriz de shards): not planned.
- #1764: duplicado de #1761.
- Seleccion de tests afectados por PR y lista negra de secretos para external_directory.

## Preguntas abiertas
- Persistencia de MEFISTO_PACKAGE_ROOT entre llamadas bash en OpenCode (CA-5 de #1750 exige fuente).
- Sintaxis de patrones de ruta de external_directory (expansion de ~) y si bash queda contenido por external_directory (CA-1/CA-3 de #1761).
- Retrasos de schedule y deshabilitado por inactividad de GitHub (CA-2 de #1766).

## Referencias
Listos: #1750 (bloqueado por #1761), #1757, #1761, #1766, #1746 (bloqueado por #1766), #1773 (bloqueado por #1766), #1755 (ya entregado).
Borradores: #1756, #1771.
Cerrados: #1759, #1764, #1765, #1767, #1768, #1769, #1770.
