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

## Transiciones y exclusiones

- `acquire` crea una referencia `active` capturando la identidad del PID. Un
  `retain` protege su release; `execute` bloquea mantenimiento durante toda la
  corrida; `maintenance` bloquea nuevos `execute` y otro mantenimiento.
- `reserve` crea un hijo `reserved` con el mismo release, tipo, corrida y
  proyecto del padre. `attach` captura un unico propietario antes del trabajo
  y no permite cambiar `bindingDigest`. `finish` exige la identidad viva del
  propietario (o la del padre para retirar su reserva), cierra solo ese id y
  conserva sus hijos.
- `reconcile` exige revision esperada. Solo cierra propietarios observados
  `gone`, grupos observados vacios y grafos sin hijos pendientes. Reboot
  verificable y PID reciclado cuentan como terminacion; cobertura desconocida,
  observacion desconocida, hijos vivos y reservas ambiguas conservan.

Cada escritura se serializa con `releases/.operation.lock`; la contencion de
ese mutex corto (`LOCK_BUSY`) se distingue de la exclusion del protocolo
(`SEMANTIC_BUSY`). El lock abandonado no se rompe automaticamente. Los callers
pueden exigir `capabilities.protocol == "release-use-v1"` y
`reservedAttachBeforeWork == true` para rechazar launchers anteriores.

La salida publica ids, identidades de release y estados, pero no metadata de
procesos, rutas de configuracion ni credenciales. Es coordinacion local entre
procesos del mismo usuario, no autenticacion ni consentimiento administrativo.
