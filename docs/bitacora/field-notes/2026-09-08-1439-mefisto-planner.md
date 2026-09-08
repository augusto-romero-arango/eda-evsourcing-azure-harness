---
fecha: 2026-09-08
hora: 14:39
sesion: mefisto-planner
tema: refinamiento de observabilidad interactiva OpenCode (#1059)
---

## Contexto

Se inicio para llevar el draft #1059 a `estado:listo`, verificando su alcance contra el contrato neutral de hooks ya entregado por #1057 y contra la arquitectura de distribucion publicada de MEF-ADR-0053.

## Descubrimientos

- #1057 define exactamente seis comportamientos vigentes; no define fin de sesion, permisos/notificaciones, compactacion, modelo, metricas ni errores de proveedor. La matriz declara `plan.completed` como no soportado en OpenCode.
- `generate-published-adapters.sh` reclama y reemplaza cada raiz `dist/<runtime>/` completa. Un generador independiente que escriba `dist/opencode/plugins/` perderia su salida en la siguiente regeneracion.
- El checkout fija `@opencode-ai/plugin` y SDK 1.18.29. Sus tipos exponen `event`, `tool.execute.after`, `client.app.log`, `PluginInput.directory` y `PluginInput.worktree`, coherentes con la matriz de #1057.
- El mecanismo de proyeccion global de #1091 debe decidir como el plugin conserva la identidad de la release activa; #1059 no puede adivinarla desde cwd o caches.

## Decisiones

- Limitar #1059 a los seis bindings de #1057 y retirar del alcance la telemetria amplia que el draft suponia.
- Crear #1104 como prerequisito generico para que cada adaptador contribuya assets suplementarios al mismo staging y raiz generada, sin que el core conozca formatos o runtimes.
- Hacer que #1059 dependa de #1104, #1075, #1091 y #1099; conservar `bloqueado` mientras esas dependencias sigan abiertas.
- Generar el plugin como `dist/opencode/plugins/mefisto-observability.js`, escribir solo estado canonico `.mefisto/pipeline/` y dejar el smoke global real a #1066.
- Marcar #1059 y #1104 como `estado:listo`: ambos tienen seis CAs homogeneos, componente principal claro, verificaciones concretas, dependencias declaradas y ADRs enumerados.

## Descartado

- Incluir en #1059 la extension transversal del generador: mezclaba compositor, adaptador y plugin en una tarea demasiado grande.
- Mezclar el plugin durante #1052: romperia el contrato de `dist/opencode/` como distribucion generada completa.
- Implementar eventos que #1057 no declara o inventar un sustituto para `plan.completed`.
- Mantener en #1059 el smoke de instalacion global; la certificacion reproducible multi-runtime ya pertenece a #1066.

## Preguntas abiertas

- #1091 debe fijar el mecanismo concreto de proyeccion y la forma de conservar la identidad de la release activa antes de implementar #1059.
- Los fixtures de #1059 deben fijar el campo efectivo de exit status que OpenCode 1.18.29 entrega a `tool.execute.after`; si no existe, el adaptador debe degradar de forma visible y no inferir un resultado desde output completo.

## Referencias

Issues creados: #1104 `Permitir assets suplementarios en el generador publicado`.

Drafts refinados: #1059 `Implementar la observabilidad interactiva de OpenCode`.
