---
fecha: 2026-09-12
hora: 20:46
sesion: mefisto-planner
tema: refinamiento del modo ejecutable de stream-watch
---

## Contexto

Se solicito refinar #1284, reportado desde Bitakora.ControlAsistencia despues
de que el pane Claude de Herdr mostrara `Permission denied` al intentar iniciar
el visor `scripts/stream-watch.sh` con Mefisto `v0.37.13`.

## Descubrimientos

- La copia raiz `scripts/stream-watch.sh` esta versionada como `100644` y
  `scripts/herdr-pipeline.sh` la invoca directamente en sus lineas 421 y 423.
- `.claude-plugin/marketplace.json` todavia carga `source: "./"`, por lo que
  Claude recibe esa copia sin bit de ejecucion.
- `dist/claude/scripts/stream-watch.sh` y
  `dist/opencode/scripts/stream-watch.sh` ya estan en `100755`; el generador
  declara el asset con modo `0755`.
- El defecto no afecta al paquete OpenCode generado. La afirmacion inicial de
  que ninguna instalacion tuvo el bit era demasiado amplia.
- `scripts/tests/test-stream-watch.sh` sourcea el visor y prueba sus funciones,
  pero no valida que el archivo pueda ejecutarse directamente como exige
  Herdr.

## Decisiones

- #1284 queda limitado al modo Git de la copia raiz y una precondicion
  ejecutable en el test existente.
- El test debe comprobar `-x` e invocar `"$TARGET" --help` sin anteponer
  `bash`; asi ejerce exactamente el contrato del invocador.
- No se modifican `herdr-pipeline.sh`, el contenido del visor, el generador ni
  los instaladores.
- La corrida real sobre marketplace Claude se conserva en #1181; se agrego
  #1284 como dependencia directa.
- #1284 conserva `bug`, `tipo:tooling` y `estado:listo`, con cuatro CAs
  verificables y estimacion menor a 30 minutos.

## Descartado

- Cambiar las invocaciones de Herdr a `bash stream-watch.sh`: evitaria el
  sintoma, pero mantendria incorrecto el modo del script ejecutable publicado.
- Agregar `chmod` en el instalador: la causa vive en el modo Git de la raiz
  Claude, no en la instalacion.
- Crear un grep global que infiera cuales scripts son invocados directamente:
  seria fragil y generaria excepciones para scripts llamados por interprete o
  normalizados durante el empaquetado.
- Exigir una instalacion marketplace real dentro del issue de implementacion:
  esa evidencia ya pertenece a la certificacion #1181.

## Preguntas abiertas

- Que release corregida reunira #1281, #1283 y #1284 para repetir #1180/#1181.

## Referencias

Issues creados: ninguno.

Issues refinados: #1284.

Issues actualizados: #1181.

Fuentes: `scripts/herdr-pipeline.sh`, `scripts/stream-watch.sh`,
`scripts/tests/test-stream-watch.sh`, MEF-ADR-0019, MEF-ADR-0031,
MEF-ADR-0050, MEF-ADR-0053 y la documentacion oficial de `git update-index`.
