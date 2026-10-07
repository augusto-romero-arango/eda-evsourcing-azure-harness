---
fecha: 2026-10-07
hora: 13:39
sesion: mefisto-planner
tema: Triage de la nightly roja del 2026-10-07
---

## Contexto
La nightly (run 37642637968) reporto 2 FAIL de 220: test-tdd-agents.sh y test-tmux-parallel.sh.

## Descubrimientos
- test-tdd-agents.sh cablea un conteo literal (35) de `${{` en domain-scaffolder; #2037 lo subio a 38 legitimamente. Los PR no corren tests, asi que la nightly es el primer detector.
- `printf "$haystack" | grep -q` bajo pipefail da falsos FAIL intermitentes por SIGPIPE con fuentes grandes; el helper esta en 6 tests de tmux/herdr.
- En zsh, `git show $c:ruta` aplica el modificador `:s`; usar `${c}:ruta`.

## Decisiones
- Un issue por causa raiz, ambos `estado:listo`, `bug`, con Refs #1908 (tracker automatico).
- #2053 acotado a test-tmux-parallel.sh: es el unico que pasa un fuente grande (~50 KB > buffer de pipe macOS 16 KB) a grep -q; los otros 5 usan haystacks de pocos KB. Reproducido 10/30 en local. Se reemplazan las aserciones sobre texto del fuente ([pre]) por aserciones de comportamiento sobre el stub de tmux y el FS del escenario [C].
- #2052 refinado (opcion A): el conteo fijo es el unico oraculo independiente del traductor (el diff vecino usa el mismo translate del generador), pero solo cubria domain-scaffolder/Claude. Se reemplaza por invariante fuente=espejo para todo agents/commands publicado en ambos runtimes, en test-generate-published-adapters.sh.

## Descartado
- Actualizar el literal a 38.
- Solo borrar la asercion (opcion B).
- Parchear el helper en los 6 tests tmux/herdr: alcance inflado.

## Preguntas abiertas
- Ninguna: el barrido no encontro otros tests con fuente grande en pipe a grep -q.

## Referencias
Issues creados: #2052, #2053
