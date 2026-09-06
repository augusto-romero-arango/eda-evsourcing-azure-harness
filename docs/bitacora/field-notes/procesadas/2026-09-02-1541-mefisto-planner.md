---
fecha: 2026-09-02
hora: 15:41
sesion: mefisto-planner
tema: Refinar #832 (enmienda MEF-ADR-0032 s.9) y #833 (prosa de mcp-scaffolder) a estado:listo
---

## Contexto
Tercera pasada de la sesion registrada en `2026-09-02-1444` (PR #830) y su continuacion (PR #834). El usuario pidio refinar los dos drafts que quedaron de la quinta desviacion del PRM.

## Descubrimientos
- MEF-ADR-0032 seccion 9 tenia texto **obsoleto**, no solo faltante: "una operacion de la misma API" (linea 124) describe el PRM como operacion de la API del servidor, cuando desde #820 vive en la API compartida `mcp-prm` al nivel del host (RFC 9728 s.3.1). La enmienda deja de ser puramente aditiva.
- El codigo que genera `mcp-scaffolder` no deriva la URL publica del PRM (el `WWW-Authenticate` lo emite APIM): en #833 solo hay prosa que corregir, en tres lugares (comentario del `.cs`, README, nota del Paso 7).

## Decisiones
- #832 (`estado:listo`, sin dependencia bloqueante): 6 CAs -- reemplazar el texto obsoleto en el cuerpo (nunca marcar "obsoleto"; solo el control de cambios lo registra), parrafo "Ubicacion del PRM: fuera del well-known de RFC 9728 por restriccion de APIM" con la evidencia del pionero, descubrimiento **exclusivo** por `resource_metadata` (fallback por convencion no soportado), extension de "Consistencia byte a byte" a la URL del PRM, entrada de control de cambios, fragmentos `832.changed.md` + `832.adr-index.md`. El ADR fija el path concreto (`well-known/oauth-protected-resource/<path>`), coherente con su estilo (ya nombra `/runtime/webhooks/mcp`, `x-functions-key`).
- #833 (`estado:listo`, `bug`, `bloqueado`, `Depende de #831`): por MEF-ADR-0044 el comentario del `.cs` se **reduce** a la ruta efectiva del worker bajo `/api/` (el mapeo del borde no es Context Delta del worker); la explicacion completa va al README. 4 CAs; `Route` del `HttpTrigger` no cambia.

## Descartado
- Que #832 dependa de #831 o viceversa: el ADR documenta una decision ya aplicada en el consumidor; el orden no importa tecnicamente.
- Reescribir en el `.cs` generado la ubicacion concreta del borde: acoplaria el worker a un detalle del gateway que puede cambiar.

## Preguntas abiertas
- Ninguna nueva.

## Referencias
Issues refinados: #832 (`estado:listo`), #833 (`estado:listo`, `bloqueado` por #831)
Issues creados: ninguno
Orden de batch sugerido: #827 -> #831 -> #833; #832 en cualquier posicion
