---
fecha: 2026-09-12
hora: 19:02
sesion: mefisto-planner
tema: Refinamiento del gate por SHA ante reintentos de contenedor
---

## Contexto

Se refino el draft #1271, creado desde una investigacion en el consumidor
`augusto-romero-arango/Bitakora.ControlAsistencia`. El gate de `/api/version`
agotaba sus 120 segundos mientras App Service Linux descartaba un primer
contenedor fallido y levantaba correctamente el mismo artefacto en un segundo
intento.

## Descubrimientos

- La implementacion vigente de `domain-scaffolder` no coincide con el bucle
  contado descrito por el issue del consumidor: su `ApiFixture.cs` ya mide por
  reloj mediante `TimeSpan` y un deadline, reintenta cada 5 segundos y compara
  el campo `sha` de forma exacta y case-insensitive. El defecto es el presupuesto
  de 120 segundos.
- `mcp-scaffolder` si conserva la variante de 60 intentos cada 2 segundos y
  estima el tiempo como `i*2`; necesita una propagacion distinta.
- MEF-ADR-0031 acopla textualmente los 120 segundos de `/api/ready` al timeout
  de `/api/version`. El primero sondea la capa de datos y debe conservarse en
  120 segundos; ampliar el segundo obliga a separar sus justificaciones.
- La fuente oficial de App Service documenta para
  `WEBSITES_CONTAINER_START_TIME_LIMIT` un default de 230 segundos en Linux y
  el reintento de plataforma tras fallar el startup attempt:
  https://learn.microsoft.com/azure/app-service/reference-app-settings
- La lectura activa de `StartupLogs` no es una mejora pequena del mensaje:
  requiere OIDC, permisos de callers y parsing temporal de archivos anexados.

## Decisiones

- Se partio el trabajo por componente principal para cumplir la revision de
  complejidad simplificada: #1271 fija doctrina, #1273 la propaga a
  `domain-scaffolder` y #1274 a `mcp-scaffolder`.
- El presupuesto canonico sera 420 segundos: 230 segundos del limite default de
  plataforma + unos 95 segundos de teardown/reinicio observados + 92 segundos
  del peor swap sano observado, redondeados desde unos 417 segundos.
- #1273 y #1274 quedan `estado:listo` pero con label `bloqueado`, porque ambos
  dependen de la enmienda #1271.
- Los tres issues tienen cinco criterios verificables, un solo componente
  principal y lado publicado decidido. No existe scaffolder interno que deba
  mantenerse en paridad (MEF-ADR-0019).
- El timeout orientara manualmente a
  `https://<app>.scm.azurewebsites.net/api/vfs/LogFiles/StartupLogs/`, sin leer
  Kudu ni pedir credenciales nuevas.

## Descartado

- Mantener ADR, domain-scaffolder y mcp-scaffolder en #1271: excedia un
  componente principal y mezclaba dos implementaciones diferentes.
- Convertir `domain-scaffolder` de conteo a reloj: ya usa reloj; esa afirmacion
  provenia del estado particular del consumidor, no del harness actual.
- Ampliar tambien `/api/ready`: cubre otro riesgo y conserva su presupuesto de
  120 segundos.
- Crear ahora un draft para leer activamente los `StartupLogs`: queda como idea
  pendiente por decision del usuario.
- Fallar rapido al detectar el primer contenedor fallido: App Service puede
  repararlo por reintento automatico, por lo que produciria el mismo falso rojo
  con mejor mensaje.

## Preguntas abiertas

- Si la orientacion manual a Kudu demuestra valor insuficiente, retomar en un
  draft independiente el diagnostico activo, verificando primero OIDC, permisos
  heredados por `workflow_call` y seleccion del ultimo bloque de cold start.
- La coincidencia del SHA en el template MCP usa hoy busqueda del texto dentro
  del body, mientras el dominio deserializa el campo `sha`. No se amplio el
  alcance de #1274 para corregir esa diferencia porque no explica el timeout
  investigado.

## Referencias

Issues creados: #1273, #1274

Draft refinado: #1271

Evidencia de consumidor:
- https://github.com/augusto-romero-arango/Bitakora.ControlAsistencia/issues/674
- https://github.com/augusto-romero-arango/Bitakora.ControlAsistencia/actions/runs/34722573915
- https://github.com/augusto-romero-arango/Bitakora.ControlAsistencia/blob/main/docs/bitacora/field-notes/2026-09-12-1852-planner.md
