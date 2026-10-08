import type { LogLine, MonitorAgent, MonitorRun, ReadyItem, ReadyList } from '../types'

export const STATE_DIR = '.mefisto/pipeline'
export const LOG_DIR = `${STATE_DIR}/logs`
export const HISTORY = `${STATE_DIR}/pipeline-history.jsonl`

export const statusPath = (issue: string) =>
  `${STATE_DIR}/pipeline-status-mefisto-tooling-${issue}.json`

const LAUNCH = /mefisto-tmux-pipeline\.sh\s+--tooling\s+#?(\d+)/

export function toolingIssueOf(command: string): string | null {
  return LAUNCH.exec(command)?.[1] ?? null
}

/** Antepone MEFISTO_UI=mod: el wrapper corre el pipeline sin pane y este mod es el visor (MEF-ADR-0055). */
export function withModUi(command: string): string {
  return /(^|\s)MEFISTO_UI=/.test(command) ? command : `MEFISTO_UI=mod ${command}`
}

export function stampToMs(stamp: string): number {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/.exec(stamp)
  if (!m) return 0
  const [y = 0, mo = 1, d = 1, h = 0, mi = 0, s = 0] = m.slice(1).map(Number)
  return new Date(y, mo - 1, d, h, mi, s).getTime()
}

type StatusFile = {
  issue: string
  title?: string
  stage?: string
  state?: string
  started?: string
  agents?: Record<string, MonitorAgent>
  pr?: string | null
  last_error?: string | null
}

export function runFromStatus(raw: string, prev: MonitorRun | null): MonitorRun | null {
  let s: StatusFile
  try {
    s = JSON.parse(raw)
  } catch {
    return prev
  }
  const state = s.state === 'failed' ? 'failed' : s.state === 'completed' ? 'completed' : 'running'
  return {
    issue: String(s.issue),
    title: s.title ?? prev?.title ?? '',
    stage: s.stage ?? 'setup',
    state,
    startedMs: s.started ? stampToMs(s.started) : (prev?.startedMs ?? 0),
    finishedMs: state === 'running' ? null : (prev?.finishedMs ?? Date.now()),
    agents: s.agents ?? {},
    pr: s.pr ?? null,
    lastError: s.last_error ?? null,
    eventsFile: prev?.eventsFile ?? null,
  }
}

type HistoryEntry = {
  issue: string
  title?: string
  pipeline?: string
  started?: string
  finished?: string
  state?: string
  stage?: string | null
  pr?: string | null
  error?: string | null
}

/** La ultima linea del historial de esta corrida: mismo issue, arrancada en o despues de `sinceMs`. */
export function finishedFromHistory(tail: string, issue: string, sinceMs: number): HistoryEntry | null {
  const lines = tail.split('\n').filter(Boolean).reverse()
  for (const line of lines) {
    let h: HistoryEntry
    try {
      h = JSON.parse(line)
    } catch {
      continue
    }
    if (h.pipeline !== 'mefisto-tooling' || String(h.issue) !== issue) continue
    if (h.started && stampToMs(h.started) + 1000 < sinceMs) return null
    return h
  }
  return null
}

const EVENTS = /^mefisto-tooling-stage-(\d+|merge)-([a-z-]+?)-(\d{8}-\d{6})-issue-(\d+)(?:-[^.]+)?(?:\.attempt-\d+)?\.events\.jsonl$/

export type Entry = { name: string; mtimeMs: number }

export function pickEventsFile(entries: Entry[], issue: string, sinceMs: number): string | null {
  let best: Entry | null = null
  for (const entry of entries) {
    const m = EVENTS.exec(entry.name)
    if (!m || m[4] !== issue) continue
    if (stampToMs(m[3] ?? '') + 1000 < sinceMs) continue
    if (!best || entry.mtimeMs > best.mtimeMs) best = entry
  }
  return best?.name ?? null
}

export function agentOfEventsFile(name: string): string {
  return EVENTS.exec(name)?.[2] ?? ''
}

export const clip = (text: string, max: number) => {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > max ? `${one.slice(0, max - 1)}…` : one
}

const WORKTREE = /\S*\/worktree-[^/\s]+\//g

export const relative = (text: string) => text.replace(WORKTREE, '')

const clock = (ts: unknown) => {
  if (typeof ts !== 'string') return ''
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return ''
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

/** Filtro del visor (mefisto-stream-watch.sh) portado: una linea por evento relevante del contrato run-events v1. */
export function parseEvent(raw: string): LogLine | null {
  let ev: Record<string, any>
  try {
    ev = JSON.parse(raw)
  } catch {
    return null
  }
  const ts = clock(ev.ts)
  switch (ev.type) {
    case 'run.started':
      return { ts, kind: 'start', text: `${ev.agent ?? 'agente'} · ${ev.model ?? ''}`.trim() }
    case 'message':
      if (ev.role !== 'assistant' || typeof ev.text !== 'string' || ev.text.trim() === '') return null
      return { ts, kind: 'text', text: clip(ev.text, 400) }
    case 'tool.started':
      return { ts, kind: 'tool', text: clip(`${ev.tool ?? '?'} ${relative(String(ev.input_summary ?? ''))}`, 400) }
    case 'tool.completed':
      return ev.ok === false ? { ts, kind: 'fail', text: `${ev.tool ?? '?'} falló` } : null
    case 'run.completed': {
      const cost = typeof ev.estimated_cost_usd === 'number' ? ` · $${ev.estimated_cost_usd.toFixed(2)}` : ''
      const turns = typeof ev.turns === 'number' ? ` · ${ev.turns} turnos` : ''
      return { ts, kind: ev.status === 'success' ? 'done' : 'fail', text: `${ev.status ?? 'fin'}${turns}${cost}` }
    }
    case 'run.failed':
      return { ts, kind: 'fail', text: clip(String(ev.error ?? 'fallo'), 400) }
    default:
      return null
  }
}

export type Step = { name: string; mark: 'done' | 'current' | 'failed' | 'pending' }

const STAGES = [
  { id: 'setup', name: 'setup' },
  { id: '1-writer', name: 'writer' },
  { id: '2-reviewer', name: 'reviewer' },
  { id: 'done', name: 'done' },
]

export function steps(run: MonitorRun): Step[] {
  const stage = run.stage === 'merge-writer' ? '2-reviewer' : run.stage
  const at = Math.max(0, STAGES.findIndex(s => s.id === stage))
  return STAGES.map((s, i) => {
    if (run.state === 'completed') return { name: s.name, mark: 'done' }
    if (i < at) return { name: s.name, mark: 'done' }
    if (i === at) return { name: s.name, mark: run.state === 'failed' ? 'failed' : 'current' }
    return { name: s.name, mark: 'pending' }
  })
}

export function elapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const p = (n: number) => String(n).padStart(2, '0')
  return h > 0 ? `${h}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`
}

export function prNumber(pr: string | null): string | null {
  return pr ? (/(\d+)\/?$/.exec(pr)?.[1] ?? null) : null
}

export type MascotPose = { role: 'desarrollador' | 'revisor'; state: string }

const EDITS = /^(Edit|Write|MultiEdit|NotebookEdit)\b/

/** El rol sale del stage y la pose del ultimo evento: herramienta trabaja, texto piensa, edicion del reviewer corrige. */
export function mascotPose(run: MonitorRun, last: LogLine | undefined): MascotPose {
  if (run.state === 'completed') return { role: 'revisor', state: 'aprobado' }
  if (run.state === 'failed') return { role: 'desarrollador', state: 'error' }
  const role = run.stage === '2-reviewer' ? 'revisor' : 'desarrollador'
  if (!last || last.kind !== 'tool') return { role, state: 'pensando' }
  if (role === 'revisor' && EDITS.test(last.text)) return { role, state: 'corrigiendo' }
  return { role, state: 'trabajando' }
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

export const NEXT_ORDER = './.claude/scripts/mefisto-next-order.sh'
export const PLANNER_AGENT = 'mefisto-planner'
/** Filas fijas de la lista de listos: la banda no cambia de alto con la cantidad de issues. */
export const READY_ROWS = 5

type NextOrderJson = {
  items?: { number: number; title: string; after?: number[] }[]
  blocked?: unknown[]
  cycles?: unknown[]
  launch?: string | null
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 es un fallo de gh o de argumentos. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): ReadyList {
  const empty = { items: [], blockedCount: 0, cycleCount: 0, launch: null }
  if (exitCode !== 0 && exitCode !== 1) {
    return { ...empty, error: stderr.split('\n').find(l => l.trim() !== '')?.trim() || `exit ${exitCode}` }
  }
  let json: NextOrderJson
  try {
    json = JSON.parse(stdout)
  } catch {
    return { ...empty, error: 'salida de next-order no es JSON' }
  }
  return {
    items: (json.items ?? []).map(i => ({ number: i.number, title: i.title, after: i.after ?? [] })),
    blockedCount: (json.blocked ?? []).length,
    cycleCount: (json.cycles ?? []).length,
    launch: json.launch ?? null,
    error: null,
  }
}

/** Todo se lanza por /mefisto-sequential, aunque sea un solo issue: la cadena mergea y sincroniza main. */
export const sequentialOf = (issue: number) => `/mefisto-sequential ${issue}`

export function reasonOf(item: ReadyItem): string {
  return item.after.length > 0 ? `tras ${item.after.map(n => `#${n}`).join(' ')}` : ''
}

export function padEnd(text: string, width: number): string {
  return text.length >= width ? text : text + ' '.repeat(width - text.length)
}

/** Pagina valida (0-based) para una lista de `total` items; vuelve a 0 si la lista se achico. */
export function pageOf(page: number, total: number, size: number): { page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(total / size))
  return { page: page >= 0 && page < pages ? page : 0, pages }
}

/** El `--agent` de una linea de comando de Claude Code (`--agent x` o `--agent=x`), o null. */
export function agentFlagOf(cmdline: string): string | null {
  const m = /(?:^|\s)--agent(?:=|\s+)(\S+)/.exec(cmdline)
  return m ? (m[1] ?? null) : null
}

/**
 * Mefisto en espera, sobre la cara 'normal': boca plana corrida a un lado y un reloj de arena a la izquierda.
 * Mientras Claude trabaja en la sesion, en cada tick los ojos miran de un lado al otro y la arena cambia de
 * mitad; en reposo mira al frente con la arena arriba.
 */
const HOURGLASS = [
  ['YYYY', 'gyyg', '.yg.', 'g..g', 'g..g', 'YYYY'],
  ['YYYY', 'g..g', '.gg.', 'g..g', 'gyyg', 'YYYY'],
] as const

export function waitingFace(base: Grid, tick: number | null): Grid {
  const eyes =
    tick === null ? ['.....rrEErrEErr.tt', '.....rrEErrEErr..t']
    : tick % 2 === 0 ? ['.....rEErrEErrr.tt', '.....rEErrEErrr..t']
    : ['.....rrrEErrEEr.tt', '.....rrrEErrEEr..t']
  const glass = HOURGLASS[tick !== null && tick % 2 === 1 ? 1 : 0]
  return base.map((row, y) => {
    let out = row
    if (y === 6 || y === 7) out = eyes[y - 6] ?? out
    if (y === 9) out = '......rrrrMMMr..t.'
    const g = y >= 6 ? glass[y - 6] : undefined
    if (g) out = [...out].map((c, x) => (x < g.length && g[x] !== '.' ? g[x] : c)).join('')
    return out
  })
}
