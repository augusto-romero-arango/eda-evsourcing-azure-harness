---
fecha: 2026-08-05
hora: 09:41
sesion: mefisto-planner
tema: Cierre completo del ciclo de bitacora (historiador multi-dia + skills orquestadores con merge automatico, ambos lados)
---

## Contexto

El usuario pidio que "el skill de crear la bitacora" cubra el ciclo completo en ambos lados (consumidor y Mefisto): revisar todas las field notes no integradas, redactar la bitacora, mover a `procesadas/` las que apliquen, abrir el PR con entradas + movimientos, y mergearlo con el skill de merge correspondiente (`/merge` publicado, `/mefisto-merge` interno).

## Descubrimientos

- **Hoy solo existe UN historiador y ningun skill de bitacora.** `agents/historiador.md` (publicado) es un agente sin slash command que lo invoque; del lado interno no existe `mefisto-historiador`. Las bitacoras del propio Mefisto se han creado invocando el agente publicado a mano (que ni siquiera se carga al abrir este repo: Claude Code solo carga `.claude/agents/`).
- **El historiador actual es mono-dia** (`FECHA=${1:-$(date +%Y-%m-%d)}`): ignora el backlog. Dolor real medido: 15 field notes sin procesar del 2026-07-27 al 2026-08-04, con ultima bitacora del 2026-07-26.
- **Restriccion de diseno clave**: un subagente no puede invocar slash commands; el encadenamiento del merge debe vivir en el hilo principal. El patron ya existe en `/install-auth` (skill -> agente -> skill).
- **Scope MEF-ADR-0019**: `commands/*`, `.claude/commands/*` y `.claude/agents/*` estan cubiertos por patron en ambos gates; los archivos nuevos NO requieren PR de registro previo.

## Decisiones

1. **Una entrada de bitacora por cada dia con field notes pendientes** (no una entrada consolidada del periodo); git log, issues y metricas acotados al dia de cada entrada.
2. **Un solo PR por sesion** de historiador (rama `docs/bitacora-hasta-YYYY-MM-DD`), no un PR por dia.
3. **Merge automatico sin gate adicional**: el gate humano es la aprobacion del borrador dentro del historiador; el PR es solo el vehiculo.
4. **Movimiento selectivo a `procesadas/`**: solo las notas efectivamente integradas; las excluidas por el usuario permanecen.
5. **Contrato agente->skill**: el historiador reporta el numero de PR en su mensaje final; el skill orquestador lo toma y encadena el merge.
6. Desglose en 4 issues, uno por componente: evolucion del agente publicado, skill publicado `/bitacora`, agente interno `mefisto-historiador`, skill interno `/mefisto-bitacora`.

## Descartado

- **Un PR por dia con notas**: 6 ciclos de push/PR/merge por sesion, friccion sin valor.
- **Gate de confirmacion antes del merge**: redundante con la aprobacion conversacional del borrador.
- **Que el propio agente mergee con `gh pr merge`**: el usuario pidio explicitamente usar los skills de merge; ademas centraliza la logica de merge en un solo lugar por lado.

## Preguntas abiertas

- Drift futuro entre `historiador` y `mefisto-historiador`: la doctrina se duplica adaptada (deuda conocida y aceptada en #529); si diverge sin razon, considerar un Agent Skill compartido... que MEF-ADR-0019 hoy no permite compartir entre lados.
- El movimiento selectivo depende de que el usuario excluya notas en conversacion; no hay marca persistente de "excluida para siempre" (una nota excluida reaparecera como pendiente en la proxima sesion).

## Referencias

Issues creados:
- #527 Evolucionar historiador para procesar todas las field notes pendientes en entradas por dia (`estado:listo`)
- #528 Crear skill /bitacora que orquesta al historiador y mergea el PR automaticamente (`estado:listo`, `bloqueado` por #527)
- #529 Crear agente interno mefisto-historiador para la bitacora del propio Mefisto (`estado:listo`, `bloqueado` por #527)
- #530 Crear skill interno /mefisto-bitacora con merge automatico via /mefisto-merge (`estado:listo`, `bloqueado` por #529)

Orden de batch sugerido: `527 528 529 530` (o `527 529 528 530`).
