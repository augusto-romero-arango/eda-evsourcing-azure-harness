import type { BoardItem, BoardList, PipelineKind, PipelineResult, PipelineRun } from '../types'

export const NEXT_ORDER_FILE = 'scripts/next-order.sh'
export const PLANNER_AGENT = 'mefisto:planner'
export const PAGE_ROWS = 5

export function nextOrderPath(root: string): string {
  return `${root.replace(/\/+$/, '')}/${NEXT_ORDER_FILE}`
}

type NextOrderJson = {
  items?: { number: number; title: string; tipo?: string | null; after?: number[]; hasDepsSection?: boolean }[]
  blocked?: unknown[]
  cycles?: unknown[]
  launch?: string | null
}

function firstLine(text: string): string {
  return text.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 u otro es un fallo. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): BoardList {
  const failed = (error: string): BoardList => ({ items: [], blockedCount: 0, cycleCount: 0, launch: null, error })
  if (exitCode !== 0 && exitCode !== 1) return failed(firstLine(stderr) || `exit ${exitCode}`)
  let json: NextOrderJson
  try {
    json = JSON.parse(stdout)
  } catch {
    return failed('salida de next-order no es JSON')
  }
  const items: BoardItem[] = (json.items ?? []).map(i => ({
    number: i.number,
    title: i.title,
    tipo: i.tipo ?? null,
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

export function clip(text: string, max: number): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > max ? `${one.slice(0, Math.max(1, max - 1))}…` : one
}

/** Pagina vigente (acotada) y total de paginas; siempre al menos una. */
export function pageOf(page: number, total: number, size: number): { page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(total / size))
  return { page: Math.min(Math.max(0, page), pages - 1), pages }
}

/** Linea de una fila: numero de orden, `#issue`, tipo y titulo. */
export function rowText(item: BoardItem, position: number, numWidth: number, titleMax: number): string {
  const n = `${position}.`.padEnd(numWidth)
  return `${n} #${item.number} [${item.tipo ?? '?'}] ${clip(item.title, titleMax)}`
}

/** Pie con los issues que no entran al orden; vacio si no hay ninguno. */
export function footerOf(list: BoardList): string {
  return [
    list.blockedCount > 0 ? `${list.blockedCount} bloqueados` : '',
    list.cycleCount > 0 ? `${list.cycleCount} en ciclo` : '',
  ]
    .filter(Boolean)
    .join(' · ')
}

export function isMefistoManifest(raw: string): boolean {
  try {
    return (JSON.parse(raw) as { name?: unknown }).name === 'mefisto'
  } catch {
    return false
  }
}

export function transcriptPathOf(configDir: string, cwd: string, sessionId: string): string {
  return `${configDir}/projects/${cwd.replace(/[^A-Za-z0-9]/g, '-')}/${sessionId}.jsonl`
}

/** La ultima fila `agent-setting` del transcript de la sesion, o null. */
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

// ---- Incremento 2: seguimiento de corridas (MEF-ADR-0055 decision 1: lector puro) ----

export const RUNS_POLL_MS = 5_000
export const STATUS_FILE_RE = /^pipeline-status-(tdd|tooling|infra)-(\d+)(?:-(.+))?\.json$/
export const HISTORY_FILE = 'pipeline-history.jsonl'
export const DISMISSED_STORE_KEY = 'fausto-blood-pact.dismissed'
const PRUNE_GRACE_MS = 24 * 60 * 60 * 1000

/** Directorio de estado del checkout principal: el padre de `--git-common-dir`, nunca el worktree. */
export function stateDirOf(gitCommonDir: string, cwd: string): string {
  const abs = gitCommonDir.startsWith('/') ? gitCommonDir : `${cwd.replace(/\/+$/, '')}/${gitCommonDir}`
  const common = abs.replace(/\/+$/, '').replace(/\/\.git$/, '')
  return `${common}/.mefisto/pipeline`
}

/** Raiz del repo (checkout principal) a partir del directorio de estado. */
export function repoRootOf(stateDir: string): string {
  return stateDir.replace(/\/\.mefisto\/pipeline$/, '')
}

type StatusJson = {
  issue?: string | number | null
  pipeline?: string
  variant?: string | null
  started?: string
  stage?: string
  state?: string
  hold?: { next_probe?: string | null } | null
}

/** Parseo de un status; null si no es de un pipeline conocido o no es JSON valido. */
export function parseStatus(fileName: string, raw: string): PipelineRun | null {
  const m = STATUS_FILE_RE.exec(fileName)
  if (!m) return null
  let json: StatusJson
  try {
    json = JSON.parse(raw) as StatusJson
  } catch {
    return null
  }
  const issue = Number(json.issue ?? m[2])
  if (!Number.isFinite(issue)) return null
  return {
    issue,
    pipeline: m[1] as PipelineKind,
    variant: json.variant ?? m[3] ?? null,
    started: json.started ?? '',
    stage: json.stage ?? '',
    state: json.state ?? '',
    nextProbe: json.hold?.next_probe ?? null,
  }
}

export const isActive = (r: PipelineRun) => r.state === 'running' || r.state === 'hold'
export const isFailure = (r: PipelineRun) => r.state === 'failed' || r.state === 'blocked' || r.state === 'gaps'

/** Agente en curso: `<n>-<agente>` -> agente; `setup`/`scaffold` y cualquier otro stage, tal cual. */
export function agentOf(stage: string): string {
  const m = /^\d+-(.+)$/.exec(stage)
  return m ? (m[1] as string) : stage
}

/** Hora local HH:MM de un timestamp ISO (`next_probe` viaja en UTC con `Z`); el texto original si no se puede leer. */
export function clockOf(iso: string): string {
  const ms = Date.parse(iso)
  if (Number.isNaN(ms)) return iso
  const d = new Date(ms)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** Minutos enteros desde `started` (`YYYYMMDD-HHMMSS` de los pipelines o ISO, hora local) hasta `nowMs`; null si no parsea. */
export function minutesSince(started: string, nowMs: number): number | null {
  const ms = Date.parse(/^\d{8}-\d{6}$/.test(started)
    ? `${started.slice(0, 4)}-${started.slice(4, 6)}-${started.slice(6, 8)}T${started.slice(9, 11)}:${started.slice(11, 13)}:${started.slice(13, 15)}`
    : started)
  return Number.isNaN(ms) ? null : Math.max(0, Math.floor((nowMs - ms) / 60_000))
}

/** `#N pipeline agente Mm`; en `hold`, `rate limit · sonda HH:MM` en lugar del agente. */
export function runLine(run: PipelineRun, nowMs: number): string {
  const what = run.state === 'hold' ? `rate limit · sonda ${run.nextProbe ? clockOf(run.nextProbe) : '?'}` : agentOf(run.stage)
  const mins = minutesSince(run.started, nowMs)
  return `#${run.issue} ${run.pipeline}${run.variant ? `/${run.variant}` : ''} ${what}${mins === null ? '' : ` ${mins}m`}`
}

export function runKey(repo: string, run: PipelineRun): string {
  return [repo, run.pipeline, run.issue, run.variant ?? '', run.started].join('|')
}

/** Clave de descarte (repo + pipeline + issue + variante + started). */
export const dismissKey = runKey

export type HistoryEntry = { issue: string; pipeline: string; variant: string | null; started: string; pr: string | null }

export function parseHistory(raw: string): HistoryEntry[] {
  const out: HistoryEntry[] = []
  for (const line of raw.split('\n')) {
    if (line.trim() === '') continue
    try {
      const j = JSON.parse(line) as Record<string, unknown>
      out.push({
        issue: String(j.issue ?? ''),
        pipeline: String(j.pipeline ?? ''),
        variant: typeof j.variant === 'string' ? j.variant : null,
        started: String(j.started ?? ''),
        pr: typeof j.pr === 'string' || typeof j.pr === 'number' ? String(j.pr) : null,
      })
    } catch {
      continue
    }
  }
  return out
}

/** Numero de PR de la ultima entrada del historial para ese issue, pipeline y `started`; null si no hay. */
export function prOf(entries: HistoryEntry[], run: PipelineRun): string | null {
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const e = entries[i] as HistoryEntry
    if (e.issue === String(run.issue) && e.pipeline === run.pipeline && e.started === run.started) {
      const m = e.pr ? /(\d+)\s*$/.exec(e.pr) : null
      return m ? (m[1] as string) : null
    }
  }
  return null
}

export type RunsView = { runs: PipelineRun[]; results: PipelineResult[]; seen: Record<string, PipelineRun> }

/**
 * Une el status actual con lo que la sesion vio activo: un status de fallo es `✗ <stage>`;
 * una corrida vista activa cuyo status desaparecio es `✓ PR #X` (el exito se reconoce por la desaparicion).
 */
export function reconcile(
  repo: string,
  statuses: PipelineRun[],
  seen: Record<string, PipelineRun>,
  history: HistoryEntry[],
  dismissed: ReadonlySet<string>,
  carried: PipelineResult[] = [],
): RunsView {
  const present = new Set(statuses.map(r => runKey(repo, r)))
  const results: PipelineResult[] = carried.filter(r => !present.has(r.key))
  const nextSeen: Record<string, PipelineRun> = {}
  for (const [key, run] of Object.entries(seen)) {
    if (present.has(key)) continue
    const pr = prOf(history, run)
    results.push({ key, issue: run.issue, pipeline: run.pipeline, ok: true, text: pr ? `✓ PR #${pr}` : '✓ completado' })
  }
  const runs: PipelineRun[] = []
  for (const run of statuses) {
    const key = runKey(repo, run)
    if (isActive(run)) {
      runs.push(run)
      nextSeen[key] = run
    } else if (isFailure(run)) {
      results.push({ key, issue: run.issue, pipeline: run.pipeline, ok: false, text: `✗ ${run.stage}` })
    }
  }
  runs.sort((a, b) => a.started.localeCompare(b.started) || a.issue - b.issue)
  return { runs, results: results.filter(r => !dismissed.has(r.key)), seen: nextSeen }
}

/** Linea de un resultado: `#N pipeline ✗ stage` o `#N pipeline ✓ PR #X`. */
export function resultLine(r: PipelineResult): string {
  return `#${r.issue} ${r.pipeline} ${r.text}`
}

/** Descarta de `dismissed` las claves del repo sin status vivo y con mas de un dia (gracia para otros panes). */
export function pruneDismissed(dismissed: string[], repo: string, liveKeys: ReadonlySet<string>, nowMs: number): string[] {
  return dismissed.filter(key => {
    if (!key.startsWith(`${repo}|`) || liveKeys.has(key)) return true
    const mins = minutesSince(key.split('|')[4] ?? '', nowMs)
    return mins === null || mins * 60_000 < PRUNE_GRACE_MS
  })
}
