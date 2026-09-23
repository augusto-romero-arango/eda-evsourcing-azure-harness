---
fecha: 2026-09-16
hora: 00:22
sesion: mefisto-planner
tema: refinamiento y desglose del draft 1413
---

## Contexto
Se refino el draft #1413, creado tras una corrida completa de las suites del repo con dos falsos rojos independientes.

## Descubrimientos
El desfase de dos archivos de `test-tooling-agents.sh` proviene de la incorporacion de `tdd-pipeline.sh` en #1390, no de `mefisto-process.sh`, que ya pertenecia a la clausura. El test de colapso de panes conserva `HERDR_ENV` del proceso padre y por eso su escenario fuera de Herdr no queda aislado.

## Decisiones
Dividir por componente: #1413 queda dedicado a derivar expectativas desde `TOOLING_CLOSURE_ASSETS`; #1414 cubre exclusivamente el aislamiento ambiental de la fixture Herdr. Ambos cumplen Definition of Ready y quedaron `estado:listo` con label `bug`.

## Descartado
No mantener ambos defectos en un solo issue. No corregir #1413 incrementando otros numeros magicos que volverian a divergir con la siguiente ampliacion de la clausura.

## Preguntas abiertas
Ninguna para iniciar implementacion.

## Referencias
Issues refinados/creados: #1413, #1414.
