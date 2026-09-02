---
fecha: 2026-09-02
hora: 15:19
sesion: mefisto-planner
tema: Segunda pasada de #827 con la quinta desviacion (path del PRM sin punto inicial) tras el cierre de #575 del pionero
---

## Contexto
Continuacion de la sesion registrada en `2026-09-02-1444-mefisto-planner.md` (PR #830). Mientras se refinaba #827, el pionero Bitakora.ControlAsistencia aplico #575 (PR #579): el apply fallo en rojo creando la API PRM compartida con `path = ".well-known/oauth-protected-resource"` (`400 ValidationError` sin campo, run 33662634923) y se corrigio con hotfix `a54ac6b` (`well-known/...` sin punto inicial; re-apply verde run 33663796193). El comentario llego a #827 como "quinta desviacion" y el usuario pidio volver a refinar con esa evidencia.

## Descubrimientos
- **APIM rechaza un `path` de `azurerm_api_management_api` con punto inicial.** Regla server-side no documentada: la doc REST de Api - Create Or Update solo declara min/maxLength para `properties.path`. Punto a mitad de path si es valido (`api/.well-known/...` del pionero aplico siempre). Invisible para `validate`/`plan`, igual que las otras cuatro regresiones.
- El PRM del marco deja la ubicacion well-known de RFC 9728 seccion 3. El descubrimiento se garantiza **solo** por el `resource_metadata` del `WWW-Authenticate` (seccion 5.1), que es lo que la spec de autorizacion MCP exige parsear. Eso es doctrina y no estaba escrita: MEF-ADR-0032 seccion 9 no fija URL para el PRM.
- Un apply que destruye la API PRM vieja y falla al crear la nueva deja el 401 apuntando a un 404: las reconexiones OAuth caen en ese intervalo; las sesiones con token vigente siguen (`validate-jwt` no cambia). Aplica a cualquier cambio futuro del path del PRM compartido.
- El codigo que genera `mcp-scaffolder` no deriva la URL publica del PRM (el `WWW-Authenticate` lo emite APIM); solo su prosa (comentario del `.cs`, README, nota del Paso 7) afirma la ubicacion con punto.

## Decisiones
- **Separar**, revirtiendo el "uno solo" de la primera pasada: con la quinta desviacion #827 pasaba a ~11 CAs y mezclaba dos causas raiz (reconstruccion sin repo de referencia vs. regla server-side de APIM). #827 queda con las 4 regresiones (5 CAs; su CA-6 sobre la nota NO VERIFICADO se retiro) y `Bloquea #831`.
- **#831** (`estado:listo`, `bloqueado`, `Depende de #827`): path sin punto en 3c.2 con la regla documentada; variable `mcp_prm_api_path = azurerm_api_management_api.mcp_prm.path` para que `prm_url` coincida con la API por construccion (opcional del comentario, adoptado); correccion de los 5 comentarios/regla 21 que afirmaban la ubicacion con punto; nota 1272 -> `VERIFICADO` con los dos runs; checklist post-deploy con los dos `curl`; advertencia del intervalo sin PRM durante el apply.
- **#832** (draft ADR): enmendar MEF-ADR-0032 seccion 9 con la ubicacion del PRM y el descubrimiento exclusivo por `resource_metadata`. Sin dependencia bloqueante (nada del cuerpo queda obsoleto; solo se agrega).
- **#833** (draft, `bloqueado`, `Depende de #831`): alinear la prosa de `mcp-scaffolder` (lineas 543-544, 1264-1266, 2504-2506); `Route` del worker no cambia.

## Descartado
- Absorber la quinta desviacion en #827 (decidido en la primera pasada; revertido con la evidencia real).
- Hardcodear el segmento del PRM en `local.prm_url` como hace el pionero: se prefiere la variable derivada de la API compartida.
- Que #832 dependa de #831: el ADR documenta una decision ya aplicada en el consumidor; el orden no importa tecnicamente.

## Preguntas abiertas
- Si algun cliente MCP real construye la URL del PRM por convencion well-known sin leer el `WWW-Authenticate`: hasta ahora Claude lo toma del header (evidencia CA-7 de #575 pendiente del operador).
- #575 del pionero se cerro al mergear el PR, no al aplicar (14 minutos con dev sin PRM): sintoma de proceso del consumidor (MEF-ADR-0022), no del harness; queda anotado por si se repite.

## Referencias
Issues refinados: #827 (segunda pasada, `estado:listo`)
Issues creados: #831 (`estado:listo`, `bloqueado` por #827), #832 (draft ADR), #833 (draft, `bloqueado` por #831)
Orden de batch sugerido: #827 -> #831 -> #833 (tras refinar); #832 independiente
