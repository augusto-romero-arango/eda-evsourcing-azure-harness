import type { BatchIssue, BatchRun, IssueStats, BlockedItem, LogLine, MonitorAgent, MonitorRun, ReadyItem, ReadyList } from '../types'

export const STATE_DIR = '.mefisto/pipeline'
export const LOG_DIR = `${STATE_DIR}/logs`
export const HISTORY = `${STATE_DIR}/pipeline-history.jsonl`

export const BATCH_STATUS = `${STATE_DIR}/pipeline-status-mefisto-batch.json`
/** Senal de parada suave del batch (la misma que escribe /mefisto-batch-stop). */
export const BATCH_STOP = `${STATE_DIR}/batch-stop`

export const statusPath = (issue: string) =>
  `${STATE_DIR}/pipeline-status-mefisto-tooling-${issue}.json`

// El wrapper cuenta solo donde se ejecuta: al inicio de un comando (tras ; && || | ( then do o un salto de
// linea), con asignaciones de entorno delante. Un texto que lo nombra (un heredoc, un grep, un echo) no lanza nada.
const AT_COMMAND = String.raw`(?:^|[;&|(\n]|\bthen\b|\bdo\b)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*`
const WRAPPER = String.raw`\S*mefisto-tmux-pipeline\.sh`
const LAUNCH = new RegExp(`${AT_COMMAND}${WRAPPER}\\s+--tooling\\s+#?(\\d+)`)

/** El comando sin el cuerpo de sus heredocs, que es texto y no se ejecuta. */
export function withoutHeredocs(command: string): string {
  return command.replace(/<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2[ \t]*(?=\n|$)/g, '<<heredoc')
}

export function toolingIssueOf(command: string): string | null {
  return LAUNCH.exec(withoutHeredocs(command))?.[1] ?? null
}

const BATCH_LAUNCH = new RegExp(`${AT_COMMAND}${WRAPPER}\\s+--batch((?:\\s+#?\\d+)+)`)

/** Los issues de un `mefisto-tmux-pipeline.sh --batch N M ...` (lo que corre /mefisto-sequential), en orden. */
export function batchIssuesOf(command: string): string[] | null {
  const m = BATCH_LAUNCH.exec(withoutHeredocs(command))
  return m?.[1] ? (m[1].match(/\d+/g) ?? []) : null
}

/**
 * Pone MEFISTO_UI=mod justo delante de cada invocacion del wrapper: corre el pipeline sin pane y este mod es el
 * visor (MEF-ADR-0055). Al inicio del comando no basta: /mefisto-sequential lanza un comando compuesto
 * (`validador ...; ... && MEFISTO_RUNTIME=claude ./mefisto-tmux-pipeline.sh --batch ...`) y la asignacion solo
 * llegaria al primer comando.
 */
export function withModUi(command: string): string {
  if (/(^|\s)MEFISTO_UI=/.test(command)) return command
  return command.replace(new RegExp(`(${AT_COMMAND})(${WRAPPER})`, 'g'), '$1MEFISTO_UI=mod $2')
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
  blocked?: { number?: number; by?: number }[]
  cycles?: unknown[]
  launch?: string | null
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 es un fallo de gh o de argumentos. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string, titles: Record<number, string> = {}): ReadyList {
  const empty = { items: [], blocked: [], cycleCount: 0, launch: null }
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
    blocked: blockedOf(json.blocked ?? [], titles),
    cycleCount: (json.cycles ?? []).length,
    launch: json.launch ?? null,
    error: null,
  }
}

/** next-order da una fila por par issue-dependencia: se agrupan por issue para contar issues, no pares. */
function blockedOf(rows: { number?: number; by?: number }[], titles: Record<number, string>): BlockedItem[] {
  const out: BlockedItem[] = []
  for (const r of rows) {
    if (typeof r.number !== 'number') continue
    const item = out.find(b => b.number === r.number) ?? out[out.push({ number: r.number, title: titles[r.number] ?? '', by: [] }) - 1]
    if (item && typeof r.by === 'number' && !item.by.includes(r.by)) item.by.push(r.by)
  }
  return out
}

export type ReadyRow = { number: number; title: string; reason: string; isLaunchable: boolean }

/**
 * Todos los estado:listo de la banda: primero los lanzables en el orden de next-order y al final los bloqueados,
 * visibles para armar un sequential a mano pero atenuados y sin tecla.
 */
export function readyRows(list: ReadyList): ReadyRow[] {
  return [
    ...list.items.map(i => ({ number: i.number, title: i.title, reason: reasonOf(i), isLaunchable: true })),
    ...list.blocked.map(b => ({ number: b.number, title: b.title, reason: '', isLaunchable: false })),
  ]
}

/** Titulos de los estado:listo abiertos (`gh issue list --json number,title`): next-order no los da para los bloqueados. */
export function titlesOf(stdout: string): Record<number, string> {
  try {
    const rows = JSON.parse(stdout) as { number: number; title: string }[]
    return Object.fromEntries(rows.map(r => [r.number, r.title]))
  } catch {
    return {}
  }
}

/** Todo se lanza por /mefisto-sequential, aunque sea un solo issue: la cadena mergea y sincroniza main. */
export const sequentialOf = (issue: number) => `/mefisto-sequential ${issue}`

/** Un solo issue sin merge automatico: /mefisto-tooling deja el PR abierto para revisarlo. */
export const toolingOf = (issue: number) => `/mefisto-tooling ${issue}`

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

type BatchStatusFile = {
  started?: string
  state?: string
  current?: string | null
  stop_requested?: boolean
  hold_seconds?: number
  issues?: { issue: string; status: string; pr: string | null }[]
}

/** El estado publicado del batch; un archivo de un batch anterior (arrancado antes de `sinceMs`) se ignora. */
export function batchFromStatus(raw: string, prev: BatchRun, sinceMs: number): BatchRun {
  let s: BatchStatusFile
  try {
    s = JSON.parse(raw)
  } catch {
    return prev
  }
  const startedMs = s.started ? stampToMs(s.started) : 0
  if (startedMs + 1000 < sinceMs) return prev
  const state = s.state === 'completed' || s.state === 'failed' || s.state === 'stopped' ? s.state : 'running'
  return {
    issues: (s.issues ?? []).map(i => ({ issue: String(i.issue), status: i.status ?? '', pr: i.pr ?? null })),
    state,
    current: s.current ? String(s.current) : null,
    stopRequested: s.stop_requested === true || prev.stopRequested,
    holdSeconds: s.hold_seconds ?? 0,
    startedMs: startedMs || prev.startedMs,
    finishedMs: state === 'running' ? null : (prev.finishedMs ?? Date.now()),
    stats: prev.stats ?? {},
  }
}

export type IssueMark = 'done' | 'current' | 'failed' | 'deferred' | 'pending'

export function issueMark(status: string): IssueMark {
  if (status.startsWith('completado')) return 'done'
  if (status.startsWith('ERROR')) return 'failed'
  if (status.startsWith('aplazado')) return 'deferred'
  if (status.startsWith('en curso')) return 'current'
  return 'pending'
}

export function batchCounts(issues: BatchIssue[]) {
  const marks = issues.map(i => issueMark(i.status))
  return {
    total: issues.length,
    done: marks.filter(m => m === 'done').length,
    failed: marks.filter(m => m === 'failed').length,
    deferred: marks.filter(m => m === 'deferred').length,
  }
}

/** Los issues que pasaron a mergeados entre dos lecturas: un toast por cada uno. */
export function newlyMerged(prev: BatchIssue[], next: BatchIssue[]): BatchIssue[] {
  return next.filter(i => issueMark(i.status) === 'done' && issueMark(prev.find(p => p.issue === i.issue)?.status ?? '') !== 'done')
}

/** El PR para abrir: el del issue en curso si ya lo tiene, o el del ultimo mergeado. */
export function batchPr(batch: BatchRun): string | null {
  const current = batch.issues.find(i => i.issue === batch.current)
  if (current?.pr) return current.pr
  return [...batch.issues].reverse().find(i => i.pr)?.pr ?? null
}

/** Resumen del cierre: mergeados, fallidos, aplazados y la espera por rate limit si la hubo. */
export function batchSummary(batch: BatchRun): string {
  const c = batchCounts(batch.issues)
  const hold = batch.holdSeconds > 0 ? `espera ${Math.round(batch.holdSeconds / 60)}m` : ''
  return [
    `✓ ${c.done} mergeados`,
    c.failed > 0 ? `✗ ${c.failed} fallidos` : '',
    c.deferred > 0 ? `⏸ ${c.deferred} aplazados` : '',
    hold,
  ].filter(Boolean).join(' · ')
}

type StatsEntry = {
  issue?: string
  pipeline?: string
  started?: string
  finished?: string
  agents?: Record<string, { metrics?: { estimated_cost_usd?: number | null } }>
}

/**
 * Duracion y costo de las corridas de tooling de estos issues, desde el final del historial: la ultima de cada
 * issue arrancada en o despues de `sinceMs`. El costo suma el estimado de cada agente (null si ninguno lo da).
 */
export function issueStatsFromHistory(tail: string, issues: string[], sinceMs: number): Record<string, IssueStats> {
  const out: Record<string, IssueStats> = {}
  for (const line of tail.split('\n')) {
    let h: StatsEntry
    try {
      h = JSON.parse(line)
    } catch {
      continue
    }
    const issue = String(h.issue ?? '')
    if (h.pipeline !== 'mefisto-tooling' || !issues.includes(issue) || !h.started || !h.finished) continue
    const startedMs = stampToMs(h.started)
    const finishedMs = new Date(h.finished).getTime()
    if (startedMs + 1000 < sinceMs || Number.isNaN(finishedMs)) continue
    const costs = Object.values(h.agents ?? {})
      .map(a => a.metrics?.estimated_cost_usd)
      .filter((c): c is number => typeof c === 'number')
    out[issue] = { durationMs: Math.max(0, finishedMs - startedMs), costUsd: costs.length > 0 ? costs.reduce((a, b) => a + b, 0) : null }
  }
  return out
}

export const fmtCost = (usd: number | null) => (usd === null ? '$?' : `$${usd.toFixed(2)}`)

/** Total de lo terminado: duracion sumada y costo sumado (sin contar los que no lo informan). */
export function statsTotal(stats: IssueStats[]): IssueStats {
  const costs = stats.map(s => s.costUsd).filter((c): c is number => c !== null)
  return {
    durationMs: stats.reduce((a, s) => a + s.durationMs, 0),
    costUsd: costs.length > 0 ? costs.reduce((a, b) => a + b, 0) : null,
  }
}
