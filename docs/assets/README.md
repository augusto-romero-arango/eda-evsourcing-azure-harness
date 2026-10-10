# docs/assets

`mefisto-banner.svg` es el banner pixel art del README: Fausto (planner), la palabra MEFISTO y Mefisto ejecutando ("Fausto decide, Mefisto ejecuta", MEF-ADR-0055).

Los sprites y colores salen de `hooks/sprites.ts` (`sprite`, `PALETTE`); el generador no dibuja personajes nuevos. El SVG es autocontenido, con fondo transparente.

```bash
node --experimental-strip-types docs/assets/generate-banner.ts          # regenera
node --experimental-strip-types docs/assets/generate-banner.ts --check  # falla si el SVG versionado difiere
```
