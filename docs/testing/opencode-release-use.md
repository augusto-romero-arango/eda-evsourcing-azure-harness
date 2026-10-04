# Registro de uso de releases OpenCode

`release-use.sh` recibe JSON versionado por entrada estandar y opera sobre
`runtime-use/v1/registry.json` bajo la raiz de datos. `inspect` no crea rutas
ni toma locks. Las escrituras usan el mismo lock corto de `releases` que el
instalador y el proyector, con `expectedRevision` para detectar conflictos.

Las referencias `retain`, `execute` y `maintenance` son cooperativas. La
recuperacion solo marca una referencia terminada cuando la identidad de su
propietario y su grupo registrados se observan terminados; una observacion
desconocida conserva la referencia. No se usan TTLs, no se envian senales y
la operacion no poda releases.
