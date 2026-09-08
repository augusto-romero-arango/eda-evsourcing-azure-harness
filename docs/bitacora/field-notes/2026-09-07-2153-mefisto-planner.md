---
fecha: 2026-09-07
hora: 21:53
sesion: mefisto-planner
tema: Refinamiento y desglose del generador publicado #1048
---

## Contexto

Se solicito refinar el issue #1048, que ya estaba marcado `estado:listo` y agrupaba el generador publicado, los renderizadores Claude Code/OpenCode y sus pruebas de paridad.

## Descubrimientos

- El precedente interno `generate-internal-adapters.sh` concentra orquestacion y adaptadores, pero el alcance publicado agrega namespace, permisos de consumidor y `dist/{claude,opencode}`.
- El CA original sobre resolucion de raiz, configuracion y estado mezclaba traduccion de directivas con los resolutores operativos de #1054, #1049 y #1050.
- Las dependencias downstream que nombraban #1048 directamente eran #1052, #1055, #1060 y #1061.

## Decisiones

- Por confirmacion del usuario, el alcance se partio en tres issues sin crear epic: #1048 conserva solo el motor; #1076 renderiza Claude Code; #1075 renderiza OpenCode.
- El core no conoce frontmatter, namespace, permisos ni directivas concretas de runtime. Los adaptadores implementan esa traduccion mediante una interfaz documentada.
- Los resolutores de raiz/config/estado permanecen fuera de los adaptadores: estos prueban la expansion de las directivas; #1054/#1049/#1050 entregan su comportamiento operativo.
- Se actualizaron #1052 y #1055 para depender de #1075, y #1060/#1061 para depender de #1075 y #1076.
- Los tres issues quedan `estado:listo`, `tipo:tooling`; #1048 permanece bloqueado por #1047 y #1075/#1076 permanecen bloqueados por #1048.

## Descartado

- Mantener generador y ambos formatos en #1048: no superaba la revision de complejidad simplificada.
- Duplicar o sourcear los adaptadores internos: contradice la divergencia deliberada entre lado publicado e interno de MEF-ADR-0019.
- Probar discovery o instalacion real dentro de los adaptadores: pertenece al empaquetado, instalacion y certificacion posteriores.

## Preguntas abiertas

- #1047 debe fijar antes de implementar los valores exactos de sus tablas campo/capacidad/directiva por runtime; #1075 y #1076 dependen de ese contrato de forma transitiva.

## Referencias

Issues creados: #1075 "Renderizar artefactos publicados para OpenCode"; #1076 "Renderizar artefactos publicados para Claude Code".

Issue refinado: #1048 "Implementar el generador de adaptadores publicados".
