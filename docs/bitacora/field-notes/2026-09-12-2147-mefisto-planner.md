---
fecha: 2026-09-12
hora: 21:47
sesion: mefisto-planner
tema: cierre de certificacion multi-runtime y desbloqueo de tooling E2E
---

## Contexto

Se consolido la evidencia acumulada de instalacion, identidad y discovery de Claude y OpenCode en el consumidor sintetico privado sobre la release corregida `v0.37.14`.

## Descubrimientos

- La release `v0.37.14` restauro el discovery de `tooling-writer` y `tooling-reviewer` en ambos runtimes.
- La identidad de Claude y OpenCode quedo `aligned` sobre la misma version y commit fuente.
- El cierre de #1180 habilita las corridas funcionales E2E, pero no constituye por si solo el veredicto final de #1066.
- La primera corrida Claude revelo que el marker canonico `.mefisto/pipeline/.plugin-root` puede contener la release OpenCode que inicio sesion mas recientemente; el preambulo Claude lo trataba como candidato definitivo y no alcanzaba su mirror valido.
- `herdr-workspace.sh` comprueba solo `.claude/harness.config.json` para advertir sobre onboarding, aunque MEF-ADR-0053 fija `.mefisto/harness.config.json` como ruta canonica.

## Decisiones

- Se emitio `PASA` integral para los seis criterios de aceptacion de #1180 y se cerro como `completed`.
- Se retiro inicialmente `bloqueado` de #1181 porque #1179, #1180, #1283 y #1284 estaban cerrados.
- Los dos issues fixture requeridos por #1181 deben crearse y gestionarse desde `mefisto-consumer-certification` con el planner publicado; el planner interno no realiza esa operacion cross-repo.
- El aborto de resolucion Claude y el falso warning de Herdr son defectos independientes: se crearon #1293 y #1294, se agregaron como dependencias de #1181 y se restauro `bloqueado`.
- Ambas corridas de #1181 deben repetirse desde el inicio sobre una release nueva; no se acepta parchear markers o scripts en el consumidor.

## Descartado

- No se ejecutaron corridas `/mefisto:tooling` dentro de #1180: pertenecen exclusivamente a #1181.
- No se parcheo el consumidor para suplir capacidades del harness.

## Preguntas abiertas

- Falta implementar #1293 y #1294, publicar una release nueva y repetir las corridas Claude/OpenCode de #1181.
- #1066 permanece bloqueado hasta obtener y auditar ese expediente E2E.

## Referencias

Issues creados: #1293, #1294.

Issues cerrados: #1180.

Issues desbloqueados y bloqueados de nuevo tras la corrida: #1181.

Release certificada: `v0.37.14`.
