---
fecha: 2026-10-09
hora: 11:08
sesion: mefisto-planner
tema: Diferencial del tablero publicado, dependencias negadas y upgrade por scope
---

## Contexto
Refinar #2115, explorar las dependencias negadas que rompen sequential/next-order y diagnosticar por que el tablero no cargo en Bitakora.ControlAsistencia.

## Descubrimientos
- El tablero publicado (#2098) tenia todo lo del interno salvo los arreglos de #2113; mascota roja vs blanco perla y letra de tipo son diferencias intencionales.
- Los cuatro parsers de dependencias (`mefisto-deps.sh`, `scripts/next-order.sh`, `scripts/pr-sync.sh`) usan `grep -ioE '(Depende de|Bloqueado por)...'`: "No depende de #N" cuenta como dependencia. #1915 ya lo habia reportado y se cerro con un workaround doctrinal que nunca llego a los planners.
- Sobre 400 issues: 298 lineas con marcador al inicio del item y 4 fuera del inicio, todas negaciones. Anclar al inicio no pierde dependencias reales.
- `/upgrade` actualiza solo `--scope user`; Bitakora tiene una instalacion `project` en 0.42.1 que la sesion sigue cargando, por eso el mod de 0.43.0 no aparece.

## Decisiones
- #2115 -> listo (port de #2113 al tablero publicado, con tests de la invocacion real de `field-note.sh`).
- Dependencias: una dependencia que no aplica se borra, nunca se niega; parser anclado al inicio del item en ambos lados. Borradores #2126-#2129.
- #2130 (borrador, bug): `/upgrade` debe actualizar el scope efectivo del consumidor y verificar la version cargada.

## Preguntas abiertas
- Precedencia de scopes user/project/local en Claude Code (verificar en documentacion oficial al refinar #2130).

## Referencias
Refinado: #2115. Creados: #2126, #2127, #2128, #2129, #2130.
