/**
 * mefisto-sprites.ts
 * Mascota Mefisto para mods de Claude Code. El planner no es un Mefisto: es Fausto, el que decide
 * (birrete de doctor, barba y tunica del mismo color que el Mefisto de su lado).
 *
 * Cada sprite es una cuadrícula de 18×12 píxeles escrita como texto:
 * cada carácter es un píxel y apunta a un color de PALETTE.
 *   '.'  píxel transparente (en EMOTIONS)
 *   ' '  "no tocar" (en las capas de ROLES: deja ver lo de abajo)
 *
 * Un sprite se arma así:  emoción (cara)  +  capa del rol (objeto y detalles)
 * Cada estado tiene dos cuadros, A (0) y B (1), que se alternan con cada instrucción.
 *
 * Salidas:
 *   toRasterCells(grid) -> celdas empacadas para el elemento Raster (terminal), 18 columnas × 6 filas
 *   toSvg(grid)         -> documento SVG para el elemento Svg (app de escritorio)
 *   ONE_LINERS          -> versión de una línea para la status line (elemento Text)
 */

export type Grid = readonly string[]
export type Frame = 0 | 1

export const WIDTH = 18
export const HEIGHT = 12
/** Filas que ocupa el sprite en la terminal (dos píxeles por fila con ▀ / ▄). */
export const RASTER_ROWS = HEIGHT / 2

/** Color por defecto de la terminal (transparente), según la documentación de Raster. */
export const DEFAULT_COLOR = 0x01000000

/**
 * Paleta: letra -> color 0xRRGGBB. Los mods internos (este repo) usan un Mefisto blanco perla con cuernos dorados para no confundirse
 * con los del consumidor, que conservan el rojo de mefisto-sprites.ts (cuernos/cola 0xA32D2D, cuerpo 0xE24B4A,
 * boca 0x501313).
 */
export const PALETTE: Record<string, number> = {
  "h": 0xD9A441, // cuernos (dorados)
  "r": 0xEEEDF5, // cuerpo
  "t": 0xD9A441, // cola (dorada)
  "E": 0x2C2C2A, // ojos / pupilas
  "M": 0x4A4A5E, // boca y cejas
  "W": 0xF1EFE8, // colmillos
  "p": 0xD4537E, // corazones y lengua
  "s": 0xB4B2A9, // humo (enojado)
  "B": 0x85B7EB, // Z y gota de sudor
  "Y": 0xEF9F27, // bombillo, casco, flecha
  "y": 0xFAC775, // destellos
  "w": 0xFFF6D9, // brillo del bombillo
  "G": 0x888780, // casquillo del bombillo
  "o": 0xB4B2A9, // bombillo apagado
  "D": 0x5F5E5A, // marco del portátil
  "U": 0x378ADD, // pantalla
  "u": 0xB5D4F4, // líneas de código
  "q": 0xB4B2A9, // teclado / renglones
  "Q": 0xFFFFFF, // blanco (pantalla, hoja)
  "R": 0xE24B4A, // error / marcas rojas
  "V": 0x639922, // verde de éxito
  "g": 0x888780, // vidrio del matraz
  "L": 0x97C459, // líquido del matraz
  "l": 0xEAF3DE, // reflejo del líquido
  "b": 0xC0DD97, // burbujas
  "P": 0x7F77DD, // marco de la lupa
  "e": 0xEEEDFE, // brillo de la lupa
  "n": 0x854F0B, // mango de la lupa
  "c": 0xB5D4F4, // nube
  "C": 0x888780, // nube caída
  "k": 0xF1C9A5, // piel de Fausto
  "f": 0xD9A07F, // nariz de Fausto
  "i": 0x8A6F5A, // bigote de Fausto
  "K": 0xD9A441, // birrete de Fausto (dorado)
  "z": 0xEEEDF5, // borla del birrete
  "a": 0xB9B5AA, // barba y pelo de Fausto
  "T": 0xEEEDF5, // tunica de Fausto (blanco perla)
  "d": 0xD9A441, // ribete de la tunica
}

export type Emotion =
  | 'normal'
  | 'feliz'
  | 'sonriente'
  | 'enojado'
  | 'dormido'
  | 'asustado'
  | 'pensando'
  | 'preocupado'
  | 'concentrado'

/** Caras base: [cuadro A, cuadro B]. Solo 'pensando' cambia entre cuadros (bombillo encendido / apagado). */
export const EMOTIONS: Record<Emotion, readonly [Grid, Grid]> = (() => {
  const normalA: Grid = [
    '..................',
    '..................',
    '....h..........h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrEErrEErr.tt',
    '.....rrEErrEErr..t',
    '.....rrrrrrrrrr..t',
    '......rrMMMMrr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const felizA: Grid = [
    '......p.p..p.p....',
    '......ppp..ppp....',
    '....h..p....p..h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrEErrEErr.tt',
    '.....rrrrrrrrrr..t',
    '.....rMrrrrrrMr..t',
    '......rMMWWMMr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const sonrienteA: Grid = [
    '..................',
    '..................',
    '....h..........h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrEErrEErr.tt',
    '.....rrrrrrrrrr..t',
    '.....rMrrrrrrMr..t',
    '......rMMWWMMr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const enojadoA: Grid = [
    '.....s.s......s.s.',
    '......s........s..',
    '....h..........h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rMrrrrrrMr..t',
    '.....rrMMrrMMrr.tt',
    '.....rrEErrEErr..t',
    '.....rrrrrrrrrr..t',
    '......rrMMMMrr..t.',
    '.......rMrrMrtt...',
    '.......rr..rr.....',
  ]
  const dormidoA: Grid = [
    '...........BBB....',
    '............B.....',
    '....h......BBB.h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrrrrrrrrr.tt',
    '.....rEErrrrEEr..t',
    '.....rrrrrrrrrr..t',
    '......rrrMMrrr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const asustadoA: Grid = [
    '.......y......y...',
    '........y....y....',
    '....h..........h..',
    '....hh........hh..',
    '.....hrMMrrMMrhB..',
    '.....rrrrrrrrrrB.t',
    '.....rrWWrrWWrr.tt',
    '.....rrWErrWErr..t',
    '.....rrrrMMrrrr..t',
    '......rrrMMrrr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const pensandoA: Grid = [
    '......y..YY..y....',
    '........YwYY......',
    '....h...YYYY...h..',
    '....hh...GG...hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrrEErrEEr.tt',
    '.....rrrrrrrrrr..t',
    '.....rrrrrrrrrr..t',
    '......rrrMMrrr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const pensandoB: Grid = [
    '.........oo.......',
    '........oooo......',
    '....h...oooo...h..',
    '....hh...GG...hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrrEErrEEr.tt',
    '.....rrrrrrrrrr..t',
    '.....rrrrrrrrrr..t',
    '......rrrMMrrr..t.',
    '.......rrrrrrtt...',
    '.......rr..rr.....',
  ]
  const preocupadoA: Grid = [
    '.................R',
    '.................R',
    '....h..........h..',
    '....hh........hh.R',
    '.....hrrrrrrrrh...',
    '....BrrrMrrMrrr..t',
    '....BrrMrrrrMrr.tt',
    '.....rrEErrEErr..t',
    '.....rrrrrrrrrr..t',
    '......rrrMrMrr..t.',
    '.......rMrMrrtt...',
    '.......rr..rr.....',
  ]
  const concentradoA: Grid = [
    '..................',
    '..................',
    '....h..........h..',
    '....hh........hh..',
    '.....hrrrrrrrrh...',
    '.....rrrrrrrrrr..t',
    '.....rrEErrMMrr.tt',
    '.....rrEErrEErr..t',
    '.....rrrrrrrrrr..t',
    '......rrrMMrrr..t.',
    '.......rrrprrtt...',
    '.......rr..rr.....',
  ]
  return {
    normal: [normalA, normalA],
    feliz: [felizA, felizA],
    sonriente: [sonrienteA, sonrienteA],
    enojado: [enojadoA, enojadoA],
    dormido: [dormidoA, dormidoA],
    asustado: [asustadoA, asustadoA],
    pensando: [pensandoA, pensandoB],
    preocupado: [preocupadoA, preocupadoA],
    concentrado: [concentradoA, concentradoA],
  }
})()

export type Role = 'desarrollador' | 'tester' | 'revisor' | 'planner' | 'infraestructura'

export interface RoleState {
  /** Cara que usa este estado. */
  emotion: Emotion
  /** Capas del rol para el cuadro A y el B. ' ' deja ver la cara. */
  layers: readonly [Grid, Grid]
  /** Cara propia del rol en lugar de la de Mefisto (Fausto, el planner). */
  face?: readonly [Grid, Grid]
}

/** Objetos y detalles de cada rol, por estado de trabajo. */
export const ROLES: Record<Role, Record<string, RoleState>> = (() => {
  // Desarrollador · portátil, azul
  const desarrollador_trabajando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DUuUD             ',
    'DuUUD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  const desarrollador_trabajando_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DuUUD             ',
    'DUUuD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  const desarrollador_pensando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DUuUD             ',
    'DuUUD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  const desarrollador_error_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DQRQD             ',
    'DRQRD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  const desarrollador_error_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DRQRD             ',
    'DQRQD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  const desarrollador_resuelto_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    'DDDDD             ',
    'DVVQD             ',
    'DQQVD             ',
    'DDDDD             ',
    'qqqqqqq           ',
  ]
  // Tester · matraz, verde
  const tester_trabajando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    ' b                ',
    '   b              ',
    ' ggg              ',
    '  g               ',
    ' LLL              ',
    'LlLLL             ',
    'LLLLL             ',
  ]
  const tester_trabajando_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '   b              ',
    ' b                ',
    ' ggg              ',
    '  g               ',
    ' LLL              ',
    'LlLLL             ',
    'LLLLL             ',
  ]
  const tester_pensando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    ' b                ',
    '   b              ',
    ' ggg              ',
    '  g               ',
    ' LLL              ',
    'LlLLL             ',
    'LLLLL             ',
  ]
  const tester_feliz_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    ' b                ',
    '   b              ',
    ' ggg              ',
    '  g               ',
    ' LLL              ',
    'LlLLL             ',
    'LLLLL             ',
  ]
  const tester_feliz_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '   b              ',
    ' b                ',
    ' ggg              ',
    '  g               ',
    ' LLL              ',
    'LlLLL             ',
    'LLLLL             ',
  ]
  // Revisor · lupa, morado
  const revisor_trabajando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PeEP        ',
    '      PEEP        ',
    '       PP         ',
    '     n            ',
    '    n             ',
    '   n              ',
  ]
  const revisor_trabajando_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PEEP        ',
    '      PEeP        ',
    '       PP         ',
    '     n            ',
    '    n             ',
    '   n              ',
  ]
  const revisor_pensando_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PeEP        ',
    '      PEEP        ',
    '       PP         ',
    '     n            ',
    '    n             ',
    '   n              ',
  ]
  const revisor_corrigiendo_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PeEP        ',
    'QQQ   PEEP        ',
    'qqR    PP         ',
    'QQQ  n            ',
    'qRq n             ',
    'QQQn              ',
  ]
  const revisor_corrigiendo_B: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PEEP        ',
    'QQQ   PEeP        ',
    'qqR    PP         ',
    'QQQ  n            ',
    'qRq n             ',
    'QQQn              ',
  ]
  const revisor_aprobado_A: Grid = [
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '                  ',
    '       PP         ',
    '      PeEP        ',
    'QQQ   PEEP        ',
    'QQV    PP         ',
    'VQV  n            ',
    'QVQ n             ',
    'QQQn              ',
  ]
  // Planner · Fausto: mira a un lado y a otro mientras planea
  const fausto_planeando_A: Grid = [
    '..................',
    '.....KKKKKKKKKK...',
    '......KKKKKKKK.z..',
    '.......KKKKKK..z..',
    '......akkkkkka....',
    '......akEkkEka....',
    '......akkkkkka....',
    '......akkffkka....',
    '......aaiiiiaa....',
    '.....TdaaaaaadT...',
    '....TTTdaaaadTTT..',
    '....TTTTdaadTTTT..',
  ]
  const fausto_planeando_B: Grid = fausto_planeando_A.map((row, y) => (y === 5 ? '......aEkkEkka....' : row))
  const fausto_pensando_A: Grid = [
    '.yYy..............',
    '.YwY.KKKKKKKKKK...',
    '..G...KKKKKKKK.z..',
    ...fausto_planeando_B.slice(3),
  ]
  const fausto_pensando_B: Grid = ['.ooo..............', '.ooo.KKKKKKKKKK...', ...fausto_pensando_A.slice(2)]
  const fausto_listo_A: Grid = fausto_planeando_A.map((row, y) =>
    y === 8 ? '......aaiaaiaa....' : y === 9 ? '.....TdaaiiaadT...' : row,
  )
  const sin_capa: Grid = Array(HEIGHT).fill(' '.repeat(WIDTH))
  // Infraestructura · nube y casco, amarillo
  const infraestructura_desplegando_A: Grid = [
    '                  ',
    '                  ',
    '        YyYY      ',
    '       YyYYYY     ',
    '      YYYYYYYY    ',
    ' cc               ',
    'cccc              ',
    'ccccc             ',
    'ccccc             ',
    '  Y               ',
    ' YYY              ',
    '  Y               ',
  ]
  const infraestructura_desplegando_B: Grid = [
    '                  ',
    '                  ',
    '        YyYY      ',
    '       YyYYYY     ',
    '      YYYYYYYY    ',
    ' cc               ',
    'cccc              ',
    'ccccc             ',
    'ccYcc             ',
    ' YYY              ',
    '  Y               ',
    '                  ',
  ]
  const infraestructura_caido_A: Grid = [
    '                  ',
    '                  ',
    '        YyYY      ',
    '       YyYYYY     ',
    '      YYYYYYYY    ',
    ' CC               ',
    'CCCC              ',
    'CCCCC             ',
    'CCCCC             ',
    '  RR              ',
    '  R               ',
    ' R                ',
  ]
  const infraestructura_arriba_A: Grid = [
    '                  ',
    '                  ',
    '        YyYY      ',
    '       YyYYYY     ',
    '      YYYYYYYY    ',
    ' cc               ',
    'cccc              ',
    'ccccc             ',
    'ccccc             ',
    '    V             ',
    ' V V              ',
    '  V               ',
  ]
  return {
    desarrollador: {
      trabajando: { emotion: 'normal', layers: [desarrollador_trabajando_A, desarrollador_trabajando_B] },
      pensando: { emotion: 'pensando', layers: [desarrollador_pensando_A, desarrollador_pensando_A] },
      error: { emotion: 'preocupado', layers: [desarrollador_error_A, desarrollador_error_B] },
      resuelto: { emotion: 'sonriente', layers: [desarrollador_resuelto_A, desarrollador_resuelto_A] },
    },
    tester: {
      trabajando: { emotion: 'normal', layers: [tester_trabajando_A, tester_trabajando_B] },
      pensando: { emotion: 'pensando', layers: [tester_pensando_A, tester_pensando_A] },
      feliz: { emotion: 'feliz', layers: [tester_feliz_A, tester_feliz_B] },
    },
    revisor: {
      trabajando: { emotion: 'normal', layers: [revisor_trabajando_A, revisor_trabajando_B] },
      pensando: { emotion: 'pensando', layers: [revisor_pensando_A, revisor_pensando_A] },
      corrigiendo: { emotion: 'concentrado', layers: [revisor_corrigiendo_A, revisor_corrigiendo_B] },
      aprobado: { emotion: 'sonriente', layers: [revisor_aprobado_A, revisor_aprobado_A] },
    },
    planner: {
      planeando: { emotion: 'normal', layers: [sin_capa, sin_capa], face: [fausto_planeando_A, fausto_planeando_B] },
      pensando: { emotion: 'pensando', layers: [sin_capa, sin_capa], face: [fausto_pensando_A, fausto_pensando_B] },
      listo: { emotion: 'sonriente', layers: [sin_capa, sin_capa], face: [fausto_listo_A, fausto_listo_A] },
    },
    infraestructura: {
      desplegando: { emotion: 'normal', layers: [infraestructura_desplegando_A, infraestructura_desplegando_B] },
      caido: { emotion: 'asustado', layers: [infraestructura_caido_A, infraestructura_caido_A] },
      arriba: { emotion: 'sonriente', layers: [infraestructura_arriba_A, infraestructura_arriba_A] },
    },
  }
})()

/** Versión de una línea por emoción, para la status line. */
export const ONE_LINERS: Record<Emotion, string> = {
  normal: "ψ(•‿•)",
  feliz: "ψ(^▽^)♥",
  sonriente: "ψ(^▽^)",
  enojado: "ψ(ಠ益ಠ)",
  dormido: "ψ(-.-)zz",
  asustado: "ψ(°o°)!",
  pensando: "ψ(•_•)💡",
  preocupado: "ψ(°~°);",
  concentrado: "ψ(•ᴗ<)",
}

/** Pone una capa encima de una cuadrícula. En la capa, ' ' significa "no tocar". */
export function overlay(base: Grid, layer: Grid): Grid {
  return base.map((row, y) => {
    const top = layer[y] ?? ''
    let out = ''
    for (let x = 0; x < WIDTH; x++) {
      const c = top[x]
      out += c && c !== ' ' ? c : row[x] ?? '.'
    }
    return out
  })
}

/** Arma el sprite de un rol en un estado y un cuadro. */
export function sprite(role: Role, state: string, frame: Frame = 0): Grid {
  const def = ROLES[role]?.[state]
  if (!def) throw new Error(`Estado desconocido: ${role}.${state}`)
  return overlay((def.face ?? EMOTIONS[def.emotion])[frame], def.layers[frame])
}

/** Sprite solo con la cara, sin objeto de rol. */
export function face(emotion: Emotion, frame: Frame = 0): Grid {
  return EMOTIONS[emotion][frame]
}

function colorOf(ch: string | undefined): number | null {
  if (!ch || ch === '.' || ch === ' ') return null
  const c = PALETTE[ch]
  if (c === undefined) throw new Error(`Letra sin color en PALETTE: '${ch}'`)
  return c
}

const UPPER = '▀'.codePointAt(0)!
const LOWER = '▄'.codePointAt(0)!
const SPACE = ' '.codePointAt(0)!

/**
 * Convierte una cuadrícula en las celdas empacadas que recibe el elemento Raster.
 * Cada celda junta dos píxeles verticales: ▀ con el de arriba como color y el de abajo como fondo.
 * Resultado: columns = WIDTH (18), rows = RASTER_ROWS (6).
 */
export function toRasterCells(grid: Grid): string {
  const numbers: number[] = []
  for (let y = 0; y < HEIGHT; y += 2) {
    for (let x = 0; x < WIDTH; x++) {
      const top = colorOf(grid[y]?.[x])
      const bottom = colorOf(grid[y + 1]?.[x])
      if (top !== null && bottom !== null) numbers.push(UPPER, top, bottom)
      else if (top !== null) numbers.push(UPPER, top, DEFAULT_COLOR)
      else if (bottom !== null) numbers.push(LOWER, bottom, DEFAULT_COLOR)
      else numbers.push(SPACE, DEFAULT_COLOR, DEFAULT_COLOR)
    }
  }
  const bytes = new Uint8Array(Uint32Array.from(numbers).buffer)
  const anyBytes = bytes as Uint8Array & { toBase64?: () => string }
  if (typeof anyBytes.toBase64 === 'function') return anyBytes.toBase64()
  let bin = ''
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}

/** Props listas para Raster({ ...rasterProps(grid, 'mefisto') }). */
export function rasterProps(grid: Grid, key: string) {
  return { key, columns: WIDTH, rows: RASTER_ROWS, cells: toRasterCells(grid) }
}

/** Convierte una cuadrícula en un documento SVG (para la app de escritorio). */
export function toSvg(grid: Grid, scale = 6): string {
  const rects: string[] = []
  grid.forEach((row, y) => {
    let x = 0
    while (x < WIDTH) {
      const ch = row[x]
      const c = colorOf(ch)
      if (c === null) { x++; continue }
      let end = x
      while (end < WIDTH && row[end] === ch) end++
      const hex = '#' + c.toString(16).padStart(6, '0')
      rects.push(`<rect x="${x * scale}" y="${y * scale}" width="${(end - x) * scale}" height="${scale}" fill="${hex}"/>`)
      x = end
    }
  })
  const w = WIDTH * scale
  const h = HEIGHT * scale
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" shape-rendering="crispEdges">${rects.join('')}</svg>`
}
