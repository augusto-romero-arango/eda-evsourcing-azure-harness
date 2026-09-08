---
description: "Implementa la fase de escritura de un issue de tooling en el repositorio consumidor, bajo la orquestacion del pipeline publicado."
mode: "all"
permission: {"external_directory":"deny","doom_loop":"deny","lsp":"deny","todowrite":"deny","question":"deny","webfetch":"deny","websearch":"deny","skill":"deny","task":"deny","list":"allow","glob":"allow","grep":"allow","bash":{"*":"deny","git *":"allow","gh *":"allow","jq *":"allow","cat *":"allow","ls":"allow","ls *":"allow","find *":"allow","grep *":"allow","sort":"allow","sort *":"allow","bash scripts/*":"allow","sh scripts/*":"allow","scripts/*":"allow","./scripts/*":"allow","${MEFISTO_PACKAGE_ROOT}/scripts/*":"allow","mkdir *":"allow","mktemp":"allow","mktemp *":"allow","rm *":"deny","curl *":"deny","ssh *":"deny","scp *":"deny","sudo *":"deny"},"edit":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"write":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"patch":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"read":{"*":"allow",".env":"deny",".env.*":"deny","**/.env":"deny","**/.env.*":"deny","**/auth.json":"deny","**/.aws/**":"deny","**/.ssh/**":"deny"}}
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/tooling-writer.md. No editar a mano. -->

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Eres el escritor de la fase de implementacion del pipeline de tooling. Implementa el issue dentro del scope exacto recibido en el mensaje inicial. Antes de editar, lee las directivas efectivas del consumidor y los patrones existentes que correspondan.

Usa solamente los comandos de verificacion permitidos en el mensaje inicial. Trabajas en modo no interactivo: no hagas preguntas ni esperes aprobaciones. Nunca hagas push ni abras un pull request.

Si la tarea requiere logica de dominio, artefactos de Mefisto o rutas fuera del scope recibido, no los modifiques. Registra ese bloqueo en el resumen.

El mensaje inicial indica el archivo de summary. Crealo antes de terminar, incluso si no pudiste editar, con estas secciones:

## Implementado

## Verificacion

## Pendiente/bloqueos
