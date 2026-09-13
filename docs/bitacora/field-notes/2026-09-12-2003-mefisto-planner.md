---
fecha: 2026-09-12
hora: 20:03
sesion: mefisto-planner
tema: fallo de discovery de agentes tooling en Claude
---

## Contexto

La sesion continuo la certificacion #1180 despues de validar la migracion del
launcher OpenCode en `v0.37.13`. La matriz quedo detenida porque Claude descubrio
el comando `/mefisto:tooling`, pero no `tooling-writer` ni `tooling-reviewer`.

## Descubrimientos

- `.claude-plugin/marketplace.json` todavia instala la raiz `./`.
- Los dos agentes tooling existen en `dist/claude/agents/`, pero no en
  `agents/`, que es la superficie que carga la instalacion Claude vigente.
- OpenCode si proyecta y descubre ambos agentes desde su release activa.
- `runtime-claude.sh` no pasa el id del agente al CLI: ejecuta el rol headless
  mediante el system prompt renderizado. Esa diferencia mecanica no elimina el
  requisito de distribuir y descubrir los agentes definido por #1060,
  MEF-ADR-0053 y CA-5 de #1180.
- La raiz Claude autocontenida y el retarget del marketplace fueron diferidos
  explicitamente durante #1061. El mirror generado de `commands/tooling.md` es
  el precedente de compatibilidad mientras siga vigente `source: "./"`.

## Decisiones

- El hallazgo se clasifica como defecto de distribucion, no como excepcion del
  protocolo de certificacion.
- Se creo #1281, listo y con label `bug`, para exponer mirrors generados de los
  dos agentes en la raiz Claude actualmente instalada.
- #1180 ahora depende de #1281, recupero el label `bloqueado` y conserva el
  veredicto abierto hasta publicar otra release y repetir CA-5 desde una sesion
  Claude nueva y un baseline limpio.
- El arreglo pequeno no retargetea el marketplace ni modifica el runner o la
  distribucion OpenCode.

## Descartado

- Aceptar la ausencia en Claude como asimetria valida solo porque el runner
  headless puede inyectar el rol sin `--agent`.
- Rebajar la matriz de #1180 para inferir discovery desde archivos de
  `dist/claude/` que la instalacion real no carga.
- Retargetear inmediatamente el marketplace a `dist/claude/`: esa raiz aun no
  contiene el catalogo legacy completo, hooks, Skills, MCP y metadata necesarios
  para sustituir `./` sin regresion.
- Parchear el consumidor para simular los agentes faltantes.

## Preguntas abiertas

- Cuando planear la raiz Claude autocontenida completa y retirar los mirrors
  transitorios de comando y agentes.
- Que release posterior a #1281 se usara para repetir el discovery de #1180.

## Referencias

Issues creados: #1281.

Issues actualizados: #1180.

Fuentes: #1060, MEF-ADR-0031, MEF-ADR-0049, MEF-ADR-0050, MEF-ADR-0053 y
`docs/testing/opencode-consumer-cutover.md`.
