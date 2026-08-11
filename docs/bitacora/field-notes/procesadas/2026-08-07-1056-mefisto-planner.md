---
fecha: 2026-08-07
hora: 10:56
sesion: mefisto-planner
tema: refinamiento del issue 582 - eliminar los gates humanos del historiador
---

## Contexto

El draft #582 capturaba que los dos gates humanos del historiador de bitacora (aprobar
borrador, confirmar cierre atomico) no son exigibles: el agente corre como subagente via
`claude --agent` desde bash, sin canal con el humano. En la corrida del 2026-08-06 (PR #580)
el orquestador improviso el relevo del gate 1 con AskUserQuestion y salto el gate 2, llegando
hasta el merge en main sobre su propio criterio.

## Descubrimientos

- Causa raiz verificada en los 4 archivos: los skills prohiben al orquestador responder los
  gates pero no definen mecanismo de relevo; la doctrina "conversacional en primer plano" era
  inejecutable desde el arranque (proceso bash sin TTY).
- La simetria publicado/interno es textual: `commands/bitacora.md` + `agents/historiador.md`
  espejan a `.claude/commands/mefisto-bitacora.md` + `.claude/agents/mefisto-historiador.md`.

## Decisiones

- **Se eliminan los gates en vez de sostenerlos**: el usuario no quiere ninguna revision
  humana en el ciclo de bitacora. Autorizacion = invocar el skill. El merge encadenado
  automatico se conserva (la verificacion del PR — OPEN y solo `docs/bitacora/` — acota el riesgo).
- Dos reglas autonomas reemplazan las decisiones que tomaba el humano en los gates:
  (1) si la entrada del dia ya existe, **siempre se extiende** (nunca duplicar ni pisar);
  (2) **nunca se excluyen field notes** — todo el glob se integra y se mueve a `procesadas/`.
- **Un solo issue para los dos pares** (a diferencia del precedente #527/#529): cambio
  homogeneo en espejo; partirlo abriria una ventana entre merges con un lado gated y el otro
  autonomo, con la premisa del auto-merge divergiendo.
- Retitulado: de "Definir quien sostiene los gates" a "Eliminar los gates humanos del
  historiador y volver autonomo el ciclo completo de bitacora". Promovido a `estado:listo`.

## Descartado

- Opcion A (relevos explicitos con AskUserQuestion por gate) y B (un solo gate relevado):
  descartadas porque el usuario no quiere revision humana alguna, no por inviabilidad tecnica.
- Opcion C (ejecutar el historiador inline en el hilo principal): innecesaria al desaparecer
  la conversacionalidad; se mantiene el subagente con pin de modelo sonnet.

## Preguntas abiertas

- Auditar si otros agentes conversacionales invocados desde skills (`mefisto-planner` via
  algun orquestador, `mefisto-investigator`, `/install-auth`) tienen el mismo hueco de gates
  inejecutables. Quedo fuera de alcance del #582; ameritaria draft propio si se observa.

## Referencias

Issues creados: ninguno (refinado: #582)
