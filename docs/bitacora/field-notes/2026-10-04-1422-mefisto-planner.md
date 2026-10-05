---
fecha: 2026-10-04
hora: 14:22
sesion: mefisto-planner
tema: Refinamiento del backlog de borradores (MCP, workflows, pipeline TDD)
---

## Contexto
Revision de los borradores pendientes para decidir que refinar. Casi todos venian del consumidor Bitakora.ControlAsistencia, que ya habia resuelto en produccion varios de los problemas (PRs 739, 740, 777, 778, 809-820, 564/583).

## Descubrimientos
- MEF-ADR-0047 decision 7 es inexacta: el `Authorization` no llega por `HttpContext`, pero si esta en el transporte MCP (`ToolInvocationContext.TryGetHttpTransport().Headers`, extension 1.6.0). MEF-ADR-0032 seccion 9 y la plantilla del `mcp-scaffolder` repiten la premisa falsa.
- La plantilla MCP sigue con el tenant interino; el consumidor deriva la identidad del token desde 2026-09-02 y el marco no se puso al dia.
- El catalogo de tools es estatico por app (registro en el host, MEF-ADR-0048 seccion 1): no se puede filtrar `tools/list` por claims.
- El `infra-cd.yml` del marco corre tambien en `pull_request`, asi que `workflow_run` dispara con corridas de PR: la exposicion de `untrusted-checkout` es mayor que en el consumidor.
- El `test-writer` no lee "Impacto en archivos"; la compuerta roja acepta cualquier rojo; el `implementer` solo escala tras 5 intentos.
- Regresion en el consumidor (#807): se perdio la escritura de `SesionUsuario` en el contexto y los tests no la detectaron porque sembraban el contexto a mano. El consumidor ya la esta corrigiendo.
- Solo 3 plantillas de deploy carecen de piso de `permissions`; las de smoke ya estaban corregidas.

## Decisiones
- Un proyecto empieza con un solo servidor MCP, `<RootNamespace>.Mcp.General` (ruta `/mcp-general`): nombre generico estable que mantiene uniforme la mecanica `Mcp.{Proposito}`; separar solo por necesidad demostrada y con autorizacion efectiva; receta de separacion documentada en el ADR, sin modo guiado (#1848, #1924, #1925).
- Identidad derivada del token: primero la enmienda del ADR (#1927), luego la plantilla solo en `/scaffold-mcp` siguiendo el precedente de los componentes OAuth (#1934), con publicacion de la sesion y `obtener_sesion` en el mismo issue; `cerrar_sesion` con URL de logout (diseno B del consumidor) en #1800.
- `untrusted-checkout`: replicar la opcion A del consumidor (guardas de origen), `workflow_call` fuera (#1828). Permisos minimos como piso a nivel de workflow + test guardian (#1923).
- Pipeline TDD: camino corto de `blockage-report.md` en el implementer + tercera excepcion acotada del reviewer (#1802); prevencion en el test-writer (#1933); compuerta roja que advierte, no aborta (#1937).

## Descartado
- #1801 y #1915 cerrados como not planned por decision del mantenedor.
- #1824 (worker aislado) aparcado hasta lanzar el frente de autonomia local.
- Que el flip a->b de `/install-apim` migre el codigo de servidores MCP existentes.
- Revocacion server-side de sesiones WorkOS (exige custodiar la API key del entorno).

## Preguntas abiertas
- Verificacion manual post-despliegue de `cerrar_sesion` en el consumidor (selector de organizacion tras > 300 s) antes de marcar #1800 listo.
- Al mergear #1848, alinear el CA-ADR-0037 del consumidor.
- #801 (multi-entorno) y la nightly roja #1908 quedan sin tratar.

## Referencias
Issues refinados a listo: #1802, #1828, #1848, #1923, #1927, #1933, #1934, #1937
Issues creados listo: #1924, #1925
Issues actualizados en borrador: #1800, #1824
Issues cerrados: #1801, #1915
