---
fecha: 2026-09-17
hora: 22:42
sesion: mefisto-planner
tema: Refinar #1469 (remedio por regla del gate de neutralidad) y separar el reintento del writer
---

## Contexto
Continuacion de la sesion de #1468: el mensaje de `abort` de `run_neutrality_gate` y de `mefisto-release.sh` ofrece como unico remedio la allowlist (dos PRs), la ruta mas cara y casi siempre equivocada.

## Descubrimientos
- El gate ya expone la regla por violacion como sufijo fijo `: <regla>` (incluida la linea generica de adapters-check): el consumidor ramifica con `${line##*: }`, sin reparsear.
- `mefisto-tooling-pipeline.sh` y `mefisto-release.sh` sourcean la misma lib: una funcion `mefisto_neutrality_remedy` evita duplicar el texto y deja a cada script su marco (retoma `--from-stage` vs fuga en origin/main).
- La lib tambien esta bajo R1/R3: los remedios se redactan por categoria, igual que el bloque de prompts de #1468.

## Decisiones
- #1469 queda como cambio puro de mensajeria: funcion compartida + remedio por regla en orden fijo + test unitario nuevo + asserts en el escenario [F].
- El reintento del agente antes del `abort` cambia el control de flujo del stage: sale a #1473 (draft, bloqueado por #1469).

## Descartado
- Mantener textos separados en pipeline y release.
- Meter el reintento en el mismo issue.

## Preguntas abiertas
- #1473: numero de intentos, presupuesto de tiempo, registro en el JSONL/metricas, y como el CLI falso del escenario [F] simula "no corregir".

## Referencias
Issues refinados: #1469 (estado:borrador -> estado:listo)
Issues creados: #1473 (estado:borrador, bloqueado)
