---
description: "Calcula el orden topologico de lanzamiento de los issues 'estado:listo' abiertos del repo de Mefisto a partir de sus dependencias declaradas (ciclos y bloqueos al tope), y deja lista la linea de lanzamiento de /mefisto-sequential."
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde src/internal/commands/mefisto-next-order.md. No editar a mano. -->

Calcula el orden topologico de lanzamiento de los issues `estado:listo` abiertos del repo de Mefisto, a partir de sus dependencias declaradas. Solo opera dentro del repo de Mefisto. Comunicate en **espanol**.

## Paso 0: Verificar que estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    exit 1
}
```

## Paso 1: Ejecutar el calculo

Este comando no acepta argumentos: siempre analiza TODO el universo `estado:listo` abierto. Si `$ARGUMENTS` trae texto, ignoralo por completo -- no se lo pases al script.

```bash
MEFISTO_RUNTIME=opencode ./.claude/scripts/mefisto-next-order.sh
```

Reproduce la salida tal cual, sin reordenarla, resumirla ni completarla con informacion propia: el reporte de ciclos/bloqueos (si los hay) y la lista numerada de issues lanzables, terminando siempre con la linea `/mefisto-sequential ...`.

## Reglas

- No dupliques a mano el calculo del orden ni la deteccion de ciclos: el script es la unica fuente de verdad.
- Este comando es de solo lectura: nunca muta labels ni bodies de issues.
