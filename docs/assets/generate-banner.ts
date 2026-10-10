// Genera docs/assets/mefisto-banner.svg: Fausto, la palabra MEFISTO y Mefisto ejecutando.
// Uso: node --experimental-strip-types docs/assets/generate-banner.ts [--check]
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sprite, PALETTE, WIDTH, HEIGHT } from '../../hooks/sprites.ts'

const SCALE = 8
const MARGIN = 2
const GAP = 4
const TEXT = 'MEFISTO'
const FILL = 'r'
const SHADOW = 'h'

const FONT: Record<string, readonly string[]> = {
  M: ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'],
  E: ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
  F: ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
  I: ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '#####'],
  S: ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'],
  T: ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
  O: ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
}
const GLYPH_W = 5
const GLYPH_H = 7
const LETTER_GAP = 1

const hex = (ch: string): string => {
  const c = PALETTE[ch]
  if (c === undefined) throw new Error(`Letra sin color en PALETTE: '${ch}'`)
  return '#' + c.toString(16).padStart(6, '0')
}

// Une pixeles consecutivos iguales de una fila en un solo rect.
function rowRects(row: string, ox: number, y: number, out: string[]): void {
  let x = 0
  while (x < row.length) {
    const ch = row[x]
    if (ch === '.' || ch === ' ') { x++; continue }
    let end = x
    while (end < row.length && row[end] === ch) end++
    out.push(`<rect x="${(ox + x) * SCALE}" y="${y * SCALE}" width="${(end - x) * SCALE}" height="${SCALE}" fill="${hex(ch)}"/>`)
    x = end
  }
}

function build(): string {
  const textW = TEXT.length * GLYPH_W + (TEXT.length - 1) * LETTER_GAP
  const textH = GLYPH_H
  const faustoX = MARGIN
  const textX = faustoX + WIDTH + GAP
  const mefistoX = textX + textW + 1 + GAP
  const cols = mefistoX + WIDTH + MARGIN
  const rows = HEIGHT + MARGIN * 2
  const textY = MARGIN + Math.floor((HEIGHT - textH) / 2)

  const rects: string[] = []
  sprite('planner', 'listo').forEach((row, y) => rowRects(row, faustoX, MARGIN + y, rects))

  const lines: string[] = []
  const shadow: string[] = []
  for (let y = 0; y < GLYPH_H; y++) {
    let line = ''
    for (let i = 0; i < TEXT.length; i++) {
      line += FONT[TEXT[i]][y].replace(/#/g, FILL)
      if (i < TEXT.length - 1) line += '.'.repeat(LETTER_GAP)
    }
    lines.push(line)
    shadow.push(line.replace(new RegExp(FILL, 'g'), SHADOW))
  }
  shadow.forEach((row, y) => rowRects(row, textX + 1, textY + y + 1, rects))
  lines.forEach((row, y) => rowRects(row, textX, textY + y, rects))

  sprite('desarrollador', 'trabajando').forEach((row, y) => rowRects(row, mefistoX, MARGIN + y, rects))

  const w = cols * SCALE
  const h = rows * SCALE
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" shape-rendering="crispEdges"><title>Mefisto: Fausto decide, Mefisto ejecuta</title>${rects.join('')}</svg>\n`
}

const target = join(dirname(fileURLToPath(import.meta.url)), 'mefisto-banner.svg')
const svg = build()
if (process.argv.includes('--check')) {
  let current = ''
  try { current = readFileSync(target, 'utf8') } catch { /* ausente */ }
  if (current !== svg) {
    console.error('docs/assets/mefisto-banner.svg difiere de lo generado; regenerar con: node --experimental-strip-types docs/assets/generate-banner.ts')
    process.exit(1)
  }
  console.log('mefisto-banner.svg al dia')
} else {
  writeFileSync(target, svg)
  console.log(`Escrito ${target}`)
}
