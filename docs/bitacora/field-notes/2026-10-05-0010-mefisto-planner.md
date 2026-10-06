---
fecha: 2026-10-05
hora: 00:10
sesion: mefisto-planner
tema: cerrar_sesion refutado, plan para la nightly roja, identidad de release OpenCode y autonomia por defecto
---

## Contexto
La sesion empezo refinando #1800 (`cerrar_sesion` en servidores MCP) y se extendio a tres frentes: la nightly de CI roja (#1908), un borrador desde el consumidor sobre el preflight de autonomia en OpenCode (#1989), y como activar la autonomia de un consumidor.

## Descubrimientos
- El diseno B de `cerrar_sesion` (URL de logout de AuthKit) no funciona: la verificacion manual en Bitakora.ControlAsistencia mostro una pagina vacia y la sesion seguia viva despues de mas de 10 min. Hipotesis principal: el refresh token del conector MCP renueva la sesion sin pasar por el navegador.
- La nightly del 2026-10-05 se cancelo por el timeout de 60 min: 31 tests publicados no corrieron y hubo 17 FAIL. La mayoria son aserciones viejas tras #1890/#1920/#1945; hay posibles regresiones reales en bug-investigator, herdr, hold-visibility y la cobertura NuGet. Causa de fondo: desde #1772 la suite no corre en los PR.
- La release OpenCode no incluye `src/published/release-identity.json` (su identidad va en `mefisto-manifest.json`). `autonomy-preflight.sh`, `run-published-agent.sh` y `execution-context.sh` leen ese archivo, asi que en OpenCode no puede lanzarse ninguna etapa publicada. En Claude no se nota porque el marketplace instala desde la raiz del repo.
- `/onboard` no diagnostica la autonomia.

## Decisiones
- #1800 vuelve a `estado:borrador` con el diseno B refutado. `cerrar_sesion` se genera solo con `multi-tenant-header`.
- Plan para la nightly: un issue por grupo de causa, todos con `Refs #1908`. El timeout (#1973) va primero.
- #1989: leer la identidad de la release desde `mefisto-manifest.json` (opcion A), con un test que corra los scripts contra una release staged.
- Autonomia: maxima por defecto con opt-out, sin quitar el consentimiento explicito (opciones 2+3). El perfil maximo es todo el catalogo en `commands` y nada en `administration`. Se implementa con el comando `/autonomy` y una seccion en onboard.

## Descartado
- Revocar la sesion del lado del servidor y empaquetar una copia de `release-identity.json` (opcion B de #1989).
- Autonomia implicita sin consentimiento (opcion 4): exigiria enmendar MEF-ADR-0055 §1 y cualquier clon nuevo correria desatendido sin que nadie lo decidiera.

## Preguntas abiertas
- #1800: la prueba del `sid` en el consumidor (si es el mismo antes y despues del logout) y que mecanismo de cierre reemplaza al diseno B.
- #1973: subir el timeout de la nightly o particionar el carril publicado.
- Reabrir Bitakora.ControlAsistencia #736 (lo hace el usuario).

## Referencias
Issues refinados: #1800 (sigue en borrador), #1989 (listo).
Issues creados: #1973-#1981 (nightly), #1990-#1992 (autonomia).
