import type { BoardItem, BoardList } from '../types'

export const NEXT_ORDER = './.claude/scripts/mefisto-next-order.sh'
/** Filas fijas de la lista: la banda no cambia de alto con la cantidad de issues. */
export const LIST_ROWS = 5

type NextOrderJson = {
  items?: { number: number; title: string; after?: number[]; hasDepsSection?: boolean }[]
  blocked?: unknown[]
  cycles?: unknown[]
  launch?: string | null
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 es un fallo de gh o de argumentos. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): BoardList {
  if (exitCode !== 0 && exitCode !== 1) {
    return { items: [], blockedCount: 0, cycleCount: 0, launch: null, error: firstLine(stderr) || `exit ${exitCode}` }
  }
  let json: NextOrderJson
  try {
    json = JSON.parse(stdout)
  } catch {
    return { items: [], blockedCount: 0, cycleCount: 0, launch: null, error: 'salida de next-order no es JSON' }
  }
  const items: BoardItem[] = (json.items ?? []).map(i => ({
    number: i.number,
    title: i.title,
    after: i.after ?? [],
    hasDepsSection: i.hasDepsSection !== false,
  }))
  return {
    items,
    blockedCount: (json.blocked ?? []).length,
    cycleCount: (json.cycles ?? []).length,
    launch: json.launch ?? null,
    error: null,
  }
}

type OpenIssue = { number: number; title?: string; updatedAt?: string; labels?: { name: string }[] }

export function parseOpenIssues(stdout: string): OpenIssue[] | null {
  try {
    const list = JSON.parse(stdout)
    return Array.isArray(list) ? list : null
  } catch {
    return null
  }
}

/** Cambia cuando entra, sale o se edita un issue abierto (labels o body actualizan updatedAt). */
export function signatureOf(issues: OpenIssue[]): string {
  return issues
    .map(i => `${i.number}:${i.updatedAt ?? ''}:${(i.labels ?? []).map(l => l.name).sort().join(',')}`)
    .sort()
    .join('|')
}

export type Arrival = { number: number; title: string; kind: 'borrador' | 'listo' }

/** Issues abiertos nuevos con estado borrador o listo. Sin conocidos previos (primer refresco) no hay avisos. */
export function arrivals(issues: OpenIssue[], known: number[]): Arrival[] {
  if (known.length === 0) return []
  const seen = new Set(known)
  const out: Arrival[] = []
  for (const i of issues) {
    if (seen.has(i.number)) continue
    const names = (i.labels ?? []).map(l => l.name)
    const kind = names.includes('estado:borrador') ? 'borrador' : names.includes('estado:listo') ? 'listo' : null
    if (kind) out.push({ number: i.number, title: i.title ?? '', kind })
  }
  return out
}

/** De que depende el issue (`tras #A #B`), o vacio si no depende de nada abierto. */
export function reasonOf(item: BoardItem): string {
  return item.after.length > 0 ? `tras ${item.after.map(n => `#${n}`).join(' ')}` : ''
}

/** Ancho comun de la columna de numeros (#801 y #1981 alineados). */
export function numberWidth(items: BoardItem[]): number {
  return Math.max(4, ...items.map(i => String(i.number).length + 1))
}

export function padEnd(text: string, width: number): string {
  return text.length >= width ? text : text + ' '.repeat(width - text.length)
}

export function clip(text: string, max: number): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > max ? `${one.slice(0, Math.max(1, max - 1))}…` : one
}

export function clockOf(ms: number): string {
  if (ms === 0) return ''
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}`
}

function firstLine(text: string): string {
  return text.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
}

const REFINE = /\brefin\w*\s+(?:el\s+)?(?:borrador\s+)?#(\d+)/i

/** `refina #801`, `Refina el borrador #801`, `refinemos #801`: el issue a refinar, o null. */
export function refineTargetOf(prompt: string): number | null {
  const m = REFINE.exec(prompt)
  return m ? Number(m[1]) : null
}

/** El tema de una exploracion: la primera linea con contenido del mensaje, recortada. */
export function topicOf(prompt: string): string {
  const line = prompt.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return clip(line.replace(/^quiero explorar:\s*/i, ''), 70)
}

export function isIssueCreate(command: string): boolean {
  return /\bgh\s+issue\s+create\b/.test(command)
}

/** `gh issue edit 801 ... --add-label estado:listo`: el issue que pasa a listo, o null. */
export function issueMarkedListo(command: string): number | null {
  const m = /\bgh\s+issue\s+edit\s+#?(\d+)\b/.exec(command)
  if (!m || !/--add-label[=\s]+["']?[^"'\s]*estado:listo/.test(command)) return null
  return Number(m[1])
}

export function isPlannerClosing(command: string): boolean {
  return /mefisto-field-note\.sh/.test(command)
}

/** Numero del issue que `gh issue create` imprime como URL. */
export function createdIssueOf(output: string): number | null {
  const m = /\/issues\/(\d+)/.exec(output)
  return m ? Number(m[1]) : null
}

export function createdText(created: number[]): string {
  return created.length > 0 ? `creó ${created.map(n => `#${n}`).join(' ')}` : ''
}

/** Issues por pagina, igual en las dos listas. */
export function pageSizeOf(_tab: 'borrador' | 'listo'): number {
  return LIST_ROWS
}

/** Pagina valida (0-based) para una lista de `total` items; vuelve a 0 si la lista se achico. */
export function pageOf(page: number, total: number, size: number): { page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(total / size))
  return { page: page >= 0 && page < pages ? page : 0, pages }
}

/** Ruta del transcript de una sesion: ~/.claude/projects/<cwd con lo no alfanumerico como '-'>/<id>.jsonl. */
export function transcriptPathOf(configDir: string, cwd: string, sessionId: string): string {
  return `${configDir}/projects/${cwd.replace(/[^A-Za-z0-9]/g, '-')}/${sessionId}.jsonl`
}

/**
 * `claude --agent mefisto-planner` deja en el transcript de la sesion filas
 * `{"type":"agent-setting","agentSetting":"mefisto-planner"}`; manda la ultima. Un planner lanzado como
 * subagente escribe en el transcript del subagente, nunca en el de la sesion que lo lanzo.
 */
export function agentSettingOf(transcript: string): string | null {
  let found: string | null = null
  for (const line of transcript.split('\n')) {
    if (!line.includes('"agent-setting"')) continue
    try {
      const row = JSON.parse(line)
      if (row.type === 'agent-setting' && typeof row.agentSetting === 'string') found = row.agentSetting
    } catch {
      continue
    }
  }
  return found
}

/** El `--agent` de una linea de comando de Claude Code (`--agent x` o `--agent=x`), o null. */
export function agentFlagOf(cmdline: string): string | null {
  const m = /(?:^|\s)--agent(?:=|\s+)(\S+)/.exec(cmdline)
  return m ? (m[1] ?? null) : null
}

export type MascotState = 'planeando' | 'pensando' | 'listo'

/** Siempre la mascota del planner: trabajando con herramientas planea, sin ellas piensa y al cerrar un foco queda lista. */
export function mascotPose(isWorking: boolean, stepsInTurn: number, hasFlash: boolean): MascotState {
  if (isWorking) return stepsInTurn > 0 ? 'planeando' : 'pensando'
  if (hasFlash) return 'listo'
  return 'planeando'
}

type Grid = readonly string[]

/** Columnas con algun pixel visible en cualquiera de los cuadros: recorta el margen sin que la mascota salte. */
export function usedColumns(grids: readonly Grid[]): { from: number; to: number } {
  let from = Infinity
  let to = -1
  for (const g of grids) {
    for (const row of g) {
      for (let x = 0; x < row.length; x++) {
        const c = row[x]
        if (c !== '.' && c !== ' ') {
          from = Math.min(from, x)
          to = Math.max(to, x)
        }
      }
    }
  }
  return to < 0 ? { from: 0, to: 0 } : { from, to }
}

export function cropGrid(grid: Grid, cols: { from: number; to: number }): Grid {
  return grid.map(row => row.slice(cols.from, cols.to + 1).padEnd(cols.to - cols.from + 1, '.'))
}
