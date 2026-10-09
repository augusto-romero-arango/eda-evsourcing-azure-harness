---
fecha: 2026-10-09
hora: 12:41
sesion: mefisto-planner
tema: Refinar #2127 y #2128 (dependencias negadas: parsers publicados y doctrina del planner interno)
---

## Contexto
Refinamiento de los borradores #2127 (parsers publicados) y #2128 (doctrina de mefisto-planner), hermanos de #2126 (parser interno, ya listo) y #2129 (planner publicado, en borrador).

## Decisiones
- #2127: alcance solo `scripts/next-order.sh` y `scripts/pr-sync.sh`, mismo patron anclado que #2126; sin libreria publicada. Sin dependencia declarada hacia #2126: son hermanos, no prerequisito.
- #2127: en `pr-sync.sh`, una negacion como unica referencia al issue cerrado cae en la guardia existente (warn, no desbloquea); correcto, sin cambio extra.
- #2128: vocabulario admitido en `## Dependencias`: Depende de / Bloqueado por / Bloquea / Relacionado: / Ninguna; una relacion por linea, marcador al inicio; nunca negaciones (se borra la linea y se explica en comentario).
- #2128: la regla vive en la doctrina del planner, sin enmendar MEF-ADR-0011 (solo exige la existencia de la seccion).

## Preguntas abiertas
- #2129 (planner publicado) sigue en borrador.

## Referencias
Issues refinados: #2127 -> estado:listo, #2128 -> estado:listo
