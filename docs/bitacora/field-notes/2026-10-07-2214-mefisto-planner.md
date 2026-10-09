---
fecha: 2026-10-07
hora: 22:14
sesion: mefisto-planner
tema: Refinar #2057 (tests rojos que no son defecto de produccion)
---

## Contexto
Refinar el draft #2057, nacido de 4 abortos en Gate 2 en Bitakora.ControlAsistencia (Mefisto 0.42.0: #889, #894, #883, #884).

## Descubrimientos
- La senal que falto ya existia y la borro la purga a v0.40.2 (#2022): #1802 (camino corto del test defectuoso en implementer/reviewer, commit 4cf4de2b) y #1937 (aviso de tests preexistentes en rojo en Gate 1b, commit 24c0b420). Ambos aplican limpio sobre main aba2df28, con tests verdes (simulado en un worktree aislado).
- Las guardas de inventario estan en verde en la fase roja: el aviso del Gate 1b no las ve y la deteccion debe repetirse en el Gate 2.

## Decisiones
- Partir en 4 issues: #2060 (restaurar #1802), #2061 (restaurar #1937), #2057 (doctrina del reviewer: guardas de inventario), #2062 (mecanica del pipeline).
- Gate 2 determinista: si todos los rojos son preexistentes no modificados, continua al reviewer sin depender del agente.
- El issue de revision para el humano lo crea tdd-pipeline.sh al abrir el PR (no post-merge en pr-sync.sh).
- PR sin label `bloqueado` cuando el Gate 3 queda en verde.

## Descartado
- Crear el issue post-merge en pr-sync.sh (no cubre el merge manual y acopla scripts).
- Confiar solo en el camino corto del implementer.

## Preguntas abiertas
- Si conviene que #2058 (prevencion en el test-writer) se refine en el mismo frente.

## Referencias
Issues creados: #2060, #2061, #2062. Refinado: #2057.

## Segunda parte: refinar #2058
- #1933 (pines de catalogo en el test-writer) tambien se perdio en la purga; el usuario pidio replanear desde cero, sin restaurarlo.
- Decision del usuario: las guardas de lista exacta/conteo de tipos no aportan valor. Se eliminan si hay una guarda derivada por reflexion y se reemplazan por la derivada si no la hay. La tabla evento->topic se mantiene (enrutamiento real). Los tests de dominio Given/When/Then quedan fuera.
- #2058 pasa a ser solo del planner: la regla 2 del test-writer ya ejecuta lo listado en "Impacto / Modifica".
- #2057 ya estaba mergeado; su ajuste va en #2067 (el reviewer elimina o reemplaza las listas exactas en vez de actualizarlas).
- A #2062 se le quito el label `bloqueado` (dependencias cerradas).
Issues: #2058 refinado, #2067 creado.

## Tercera parte: refinar #2059
- Se registra la regla en un ADR (opcion elegida por el usuario): enmienda de MEF-ADR-0036 seccion 4. La lista exacta de tipos persistidos no forma parte de los guardrails: se elimina si existe el guardrail 1 y se reemplaza por el si no existe.
- La proteccion frente a borrado o renombre la da el guardrail 2 (alias congelado). Se descarta el snapshot de alias que solo crece (duplicaria el guardrail 2).
- Quedan fuera de la regla la tabla evento->topic y los tests de dominio.
Issues: #2059 refinado (no bloquea #2058 ni #2067).

## Cuarta parte: refinar #1982 (doctrina de consultas, origen CA-ADR-0039 de Bitakora)
- Se parte en dos enmiendas de ADR: #1982 (MEF-ADR-0042, backend) y #2074 (MEF-ADR-0047 decision 4, tools MCP; depende de #1982). La propagacion (skill projections, mcp-scaffolder, planner) se define cuando cierren.
- Backend: Take opcional (sin Take devuelve todo), sobre {elementos, siguienteCursor} con cursor opaco y Take+1, sin total, regimen de migracion de MEF-ADR-0043 seccion 7 (solo endpoints nuevos).
- Se elimina la excepcion de offset. Argumento del usuario: sin total no hay "pagina N de M".
- Tools: tope recomendado de 50 en todas las modalidades (el consumidor usaba 20 en desambiguacion); la desambiguacion no pagina; el tope lo fija el servidor, nunca el modelo.
- Pendiente: la plantilla del mcp-scaffolder (EjemploListarTool) hoy devuelve Total y contradice la doctrina nueva.
Issues: #1982 refinado, #2074 creado.
