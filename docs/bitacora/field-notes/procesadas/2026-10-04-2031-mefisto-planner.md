---
fecha: 2026-10-04
hora: 20:31
sesion: mefisto-planner
tema: Refinar #1944 (contrato de plantillas shell por comando OpenCode)
---

## Contexto
Draft #1944 nacido de la revisión de #1836: el resolver de entrada OpenCode no tiene contrato `command-shell-templates.json` en la release.

## Descubrimientos
- Los 27 comandos de `command-entry.json` declaran `shell`: hoy ninguna fila de la proyección real llega a `ready`, no solo los 5 citados en el draft.
- La suite de #1836 usa un contrato inventado (`git status*`, `gh issue list*`), así que CA-5 de #1836 nunca se verificó con plantillas reales.
- Varios comandos ejecutan bash crudo fuera de `{{mefisto:run}}` (batch-stop, draft, bitacora, install-auth, infra-base).

## Decisiones
- Contrato generado por el adaptador OpenCode (no curado a mano), con `--check`.
- Bash crudo declarado en la matriz neutral vía campo `shellExtra` por fila; gate de cobertura sobre los bloques ```bash de cada comando.
- Partir: #1944 (generador + contrato + gate) y #1955 (pruebas CA-5 con el contrato real, bloqueado por #1944).

## Descartado
- Extracción automática total desde los bloques bash (patrones amplios, no distingue instrucciones para el humano).

## Preguntas abiertas
- Ninguna.

## Referencias
Issues refinados: #1944. Issues creados: #1955.
