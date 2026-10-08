import type { LogLine, MonitorAgent, MonitorRun } from '../types'

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

const clip = (text: string, max: number) => {
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
