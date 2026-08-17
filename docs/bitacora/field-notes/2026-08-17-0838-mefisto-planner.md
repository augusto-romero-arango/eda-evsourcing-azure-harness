---
fecha: 2026-08-17
hora: 08:38
sesion: mefisto-planner
tema: refinamiento del draft #671 (capa de datos en MEF-ADR-0031 + endpoint /api/ready)
---

## Contexto

El draft #671 llego desde el consumidor Bitakora.ControlAsistencia como el segundo issue del par
declarado en su issue #399: alli ya se implemento y desplego `/api/ready` (PR #406) y aca faltaba
enmendar MEF-ADR-0031 y propagar el patron al `domain-scaffolder`. El draft traia tres decisiones
abiertas que no podian quedar delegadas al writer del pipeline.

## Descubrimientos

- Se verifico contra main que MEF-ADR-0031 no menciona la capa de datos en ninguna parte (ni
  decision ni consecuencias): el hueco que el draft afirmaba es real.
- La enmienda de #652 ya estaba integrada (PR #673, mergeado 2026-08-17 13:11 UTC): MEF-ADR-0020
  ya fija `always_on = true` como default unico con el wiring completo hasta `site_config`. La
  "dependencia blanda" del draft quedo resuelta: la enmienda del 0031 puede citar el 0020
  directamente.
- Punto de aterrizaje en `domain-scaffolder` mapeado: punto 12 del Paso 1 (`VersionCheck.cs`, el
  hermano del endpoint nuevo), Paso 2b (`ApiFixture`), Paso 6.1 (template de
  `smoke-tests-dominio.yml`) — con la arruga de idempotencia del issue #253 (el scaffolder no
  reescribe ese workflow existente), que exige nota de parche manual al estilo del #604.

## Decisiones

1. **La propagacion procede con fundamento reescrito** (defensa en profundidad: instancia nueva en
   cada deploy aun con `always_on` — 18 intentos/~36s en Programacion — y esquema sin materializar
   en el primer deploy de un dominio nuevo), no como fix medido del incidente de 74s que
   `always_on` ya previene.
2. **`ApplyAllDatabaseChangesOnStartup` no se explora por ahora** (decision explicita del usuario):
   queda en el ADR como alternativa considerada y diferida, con el historial de `mt_version` del
   consumidor (sus issues #294/#357) como motivo.
3. **No-cache del positivo como doctrina fija del marco**, sin parametro: cachear degrada la
   semantica a "llego a estar listo alguna vez" y un parametro sin caso de uso contradice
   MEF-ADR-0018.
4. **Particion en dos issues**: #671 (enmienda del ADR) y #675 (propagacion al scaffolder,
   `Depende de #671`, label `bloqueado`). El combo ADR+agente tenia precedente (#462, #604) pero
   el volumen del lado scaffolder (endpoint + probe + resx + tests + paso de poll + notas de
   idempotencia) excedia la estimacion de una pasada.
5. **Sin dependencia de #652**: retirada por ya integrada.

## Descartado

- Evaluar `ApplyAllDatabaseChangesOnStartup` de raiz en este par de issues (si algun dia se
  retoma, sera en su propio issue con su propia verificacion).
- Mantener #671 como issue unico ADR+scaffolder al estilo #462/#604.
- Declarar `Depende de #652` (quedo obsoleto al verificar el merge del PR #673).

## Preguntas abiertas

- La prueba de comprobacion del patron sigue pendiente y queda anotada en el ADR (CA-5 de #671):
  el primer deploy de un dominio nuevo contra base sin esquema materializado, capturada por el log
  `Ready OK tras N intento(s) (~Ns)` del poll. Cuando #675 se despliegue en un consumidor y nazca
  un dominio nuevo, esa medicion cierra el ciclo.

## Referencias

Issues creados: #675 (Propagar el endpoint de readiness /api/ready y su gate de poll al
domain-scaffolder — `estado:listo`, `bloqueado`).
Issues refinados: #671 (Enmendar MEF-ADR-0031 para cubrir la capa de datos con el endpoint
dedicado /api/ready — de `estado:borrador` a `estado:listo`, reescrito y acotado al ADR).
