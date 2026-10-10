import type { Role } from '../sprites'
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
  infra?: number[]
  parallel?: { issues?: number[]; launch?: string | null } | null
}

function firstLine(text: string): string {
  return text.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 u otro es un fallo. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): BoardList {
  const failed = (error: string): BoardList => ({ items: [], blockedCount: 0, cycleCount: 0, launch: null, infra: [], parallel: null, error })
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
    infra: json.infra ?? [],
    parallel: json.parallel ? { issues: json.parallel.issues ?? [], launch: json.parallel.launch ?? null } : null,
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
export function rowText(item: BoardItem, position: number, numWidth: number, titleMax: number, key: number | null = null): string {
  const n = `${position}.`.padEnd(numWidth)
  const k = key === null ? '' : `${key}: `
  return `${k}${n} #${item.number} [${item.tipo ?? '?'}] ${clip(item.title, titleMax)}`
}

/** Pie con los issues que no entran al orden; vacio si no hay ninguno. */
export function footerOf(list: BoardList): string {
  return [launchKeysText(list), footerRestOf(list, false)].filter(Boolean).join(' · ')
}

/** Pie sin las teclas `1`/`2` (la consola las pinta como botones): `5-9 uno`, infra y excluidos. */
export function footerRestOf(list: BoardList, afterButtons: boolean): string {
  const rest = [
    list.items.length > 0 ? '5-9 uno' : '',
    list.infra.length > 0 ? `infra: ${list.infra.map(n => `#${n}`).join(' ')}` : '',
    list.blockedCount > 0 ? `${list.blockedCount} bloqueados` : '',
    list.cycleCount > 0 ? `${list.cycleCount} en ciclo` : '',
  ]
    .filter(Boolean)
    .join(' · ')
  return rest && afterButtons ? ` · ${rest}` : rest
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
  updated?: string
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
    updated: json.updated ?? '',
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

export type HistoryEntry = { issue: string; pipeline: string; variant: string | null; started: string; pr: string | null; title?: string }

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
        title: typeof j.title === 'string' ? j.title : '',
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

export type BandView = 'runs' | 'ready-with-results' | 'ready'

/** Las corridas toman la banda solo con al menos una activa; sin activas se ven los listos (y los resultados al pie). */
export function bandViewOf(runs: readonly PipelineRun[], results: readonly PipelineResult[]): BandView {
  if (runs.some(isActive)) return 'runs'
  return results.length > 0 ? 'ready-with-results' : 'ready'
}

/** Texto de un resultado en el pie: `✓#N PR #X` o `✗#M <stage>`. */
export function resultFooterItem(r: PipelineResult): string {
  const m = /^([✓✗])\s*(.*)$/u.exec(r.text)
  return m ? `${m[1]}#${r.issue}${m[2] ? ` ${m[2]}` : ''}` : `#${r.issue} ${r.text}`
}

/** `resultados: ✓#N PR #X · ✗#M stage` recortado a `max` columnas; lo que no cabe se resume en `+N`. */
export function resultsFooterText(results: readonly PipelineResult[], max: number): string {
  const head = 'resultados: '
  const items = results.map(resultFooterItem)
  for (let shown = items.length; shown >= 1; shown -= 1) {
    const hidden = items.length - shown
    const text = `${head}${items.slice(0, shown).join(' · ')}${hidden > 0 ? ` +${hidden}` : ''}`
    if (text.length <= max) return text
  }
  return clip(`${head}${items[0] ?? ''}${items.length > 1 ? ` +${items.length - 1}` : ''}`, max)
}

/** Descarta de `dismissed` las claves del repo sin status vivo y con mas de un dia (gracia para otros panes). */
export function pruneDismissed(dismissed: string[], repo: string, liveKeys: ReadonlySet<string>, nowMs: number): string[] {
  return dismissed.filter(key => {
    if (!key.startsWith(`${repo}|`) || liveKeys.has(key)) return true
    const mins = minutesSince(key.split('|')[4] ?? '', nowMs)
    return mins === null || mins * 60_000 < PRUNE_GRACE_MS
  })
}

// ---- Incremento 3: lanzar trabajo (el comando se escribe en el prompt, nunca se envia) ----

export const SEQUENTIAL_COMMAND = '/mefisto:sequential'
export const PARALLEL_COMMAND = '/mefisto:parallel'
export const ROW_KEYS = ['5', '6', '7', '8', '9'] as const
export const CANCEL = 'Cancelar'
export const INFRA_FIRST = 'Infra primero'
export const WITHOUT_INFRA = 'Seguir sin infra'
export const WITH_MERGE = 'Con merge'
export const ONLY_PR = 'Solo PR'

export type LaunchKind = 'sequential' | 'parallel'
export type LaunchOption = { label: string; text: string | null }
export type LaunchPlan =
  | { kind: 'fill'; text: string }
  | { kind: 'ask'; question: string; options: LaunchOption[] }
  | { kind: 'none'; message: string }

/** Flags de next-order que fijan las lineas de lanzamiento que la consola escribe. */
export const NEXT_ORDER_ARGS = ['--json', '--launch-command', SEQUENTIAL_COMMAND, '--parallel-command', PARALLEL_COMMAND]

/** La linea de la tecla (`1` sequential, `2` parallel) tal como la entrego next-order; null si no hay. */
export function launchLineOf(list: BoardList, kind: LaunchKind): string | null {
  return kind === 'sequential' ? list.launch : (list.parallel?.launch ?? null)
}

/** Teclas `1`/`2` disponibles: `1 sequential · 2 parallel N`; vacio sin lineas. */
export function launchKeysText(list: BoardList): string {
  return [
    list.launch ? '1 sequential' : '',
    list.parallel?.launch ? `2 parallel ${list.parallel.issues.length}` : '',
  ]
    .filter(Boolean)
    .join(' · ')
}

/** `1`/`2`: escribe la linea; con infra lanzable ofrece desarrollarla antes (sin exigirlo). */
export function planLaunch(list: BoardList, kind: LaunchKind): LaunchPlan {
  const line = launchLineOf(list, kind)
  if (!line) return { kind: 'none', message: `No hay linea de ${kind} para lanzar.` }
  const first = list.infra[0]
  if (first === undefined) return { kind: 'fill', text: line }
  return {
    kind: 'ask',
    question: `Hay ${list.infra.length} issue(s) de infra lanzables (${list.infra.map(n => `#${n}`).join(' ')}). ¿Desarrollarlos antes?`,
    options: [
      { label: INFRA_FIRST, text: `/mefisto:infra ${first}` },
      { label: WITHOUT_INFRA, text: line },
      { label: CANCEL, text: null },
    ],
  }
}

/** `5`-`9` y `lanzar <n>`: opciones segun el `tipo` del issue; sin tipo lanzable no hay dialogo. */
export function planIssue(item: BoardItem): LaunchPlan {
  const n = item.number
  const options = (pr: LaunchOption[]): LaunchPlan => ({
    kind: 'ask',
    question: `¿Cómo desarrollar #${n}?`,
    options: [...pr, { label: CANCEL, text: null }],
  })
  switch (item.tipo) {
    case 'feature':
    case 'refactor':
    case 'projection':
      return options([
        { label: WITH_MERGE, text: `${SEQUENTIAL_COMMAND} ${n}` },
        { label: ONLY_PR, text: `/mefisto:implement ${n}` },
      ])
    case 'tooling':
      return options([
        { label: WITH_MERGE, text: `${SEQUENTIAL_COMMAND} ${n}` },
        { label: ONLY_PR, text: `/mefisto:tooling ${n}` },
      ])
    case 'infra':
      return options([{ label: ONLY_PR, text: `/mefisto:infra ${n}` }])
    default:
      return { kind: 'none', message: `#${n} no tiene un tipo lanzable.` }
  }
}

/** Texto a escribir segun la respuesta del dialogo: comparacion exacta; cierre o texto libre no escriben nada. */
export function answerText(options: LaunchOption[], answer: unknown): string | null {
  if (typeof answer !== 'string') return null
  return options.find(o => o.label === answer)?.text ?? null
}

export type LaunchTarget = { kind: 'launch'; launch: LaunchKind } | { kind: 'issue'; issue: number } | { kind: 'invalid'; message: string }

/** Argumento de `/fausto-blood-pact lanzar`: vacio o `sequential` -> 1, `parallel` -> 2, `<n>` -> ese issue si es lanzable. */
export function parseLaunchArg(arg: string, list: BoardList): LaunchTarget {
  const a = arg.trim()
  if (a === '' || a === 'sequential') return { kind: 'launch', launch: 'sequential' }
  if (a === 'parallel') return { kind: 'launch', launch: 'parallel' }
  if (/^\d+$/.test(a)) {
    const n = Number(a)
    return list.items.some(i => i.number === n)
      ? { kind: 'issue', issue: n }
      : { kind: 'invalid', message: `#${n} no está entre los lanzables.` }
  }
  return { kind: 'invalid', message: 'Uso: /fausto-blood-pact lanzar [sequential|parallel|<n>]' }
}

// ---- Incremento 4: la mascota (MEF-ADR-0055 decision 10/11; lector puro: pose del status y de los events.jsonl) ----

export type MascotPose = { role: Role; state: string }
export type LastEvent = { kind: 'tool' | 'text'; tool: string }

/** Rol de la mascota segun el agente del stage; sin agente conocido, desarrollador. */
export function roleOfAgent(agent: string): Role {
  switch (agent) {
    case 'test-writer':
    case 'smoke-test-writer':
    case 'coverage-gate':
      return 'tester'
    case 'reviewer':
    case 'infra-reviewer':
      return 'revisor'
    case 'infra-writer':
      return 'infraestructura'
    default:
      return 'desarrollador'
  }
}

/** La corrida activa con `updated` mas reciente (a igualdad, la de `started` mas reciente); null sin corridas activas. */
export function activeRunOf(runs: readonly PipelineRun[]): PipelineRun | null {
  let best: PipelineRun | null = null
  for (const r of runs) {
    if (!isActive(r)) continue
    if (!best || r.updated.localeCompare(best.updated) > 0 || (r.updated === best.updated && r.started.localeCompare(best.started) > 0)) best = r
  }
  return best
}

export const LOGS_DIR = 'logs'

/** Prefijo del `log_base` por pipeline: "" en tdd, `tooling-` e `iac-`. */
export function logPrefixOf(pipeline: PipelineKind): string {
  return pipeline === 'tooling' ? 'tooling-' : pipeline === 'infra' ? 'iac-' : ''
}

/** `<prefijo>stage-<stage>-<started>-issue-<n>[-<variante>]`: lo que precede a `-attempt-<k>.events.jsonl`. */
export function eventsLogBase(run: PipelineRun): string {
  return `${logPrefixOf(run.pipeline)}stage-${run.stage}-${run.started}-issue-${run.issue}${run.variant ? `-${run.variant}` : ''}`
}

/** Nombre del `events.jsonl` del intento mas alto de la corrida entre los nombres del directorio de logs; null si no hay. */
export function eventsFileOf(run: PipelineRun, names: readonly string[]): string | null {
  const base = `${eventsLogBase(run)}-attempt-`
  let best: string | null = null
  let bestAttempt = -1
  for (const raw of names) {
    const name = raw.trim()
    if (!name.startsWith(base)) continue
    const m = /^(\d+)\.events\.jsonl$/.exec(name.slice(base.length))
    if (!m) continue
    const attempt = Number(m[1])
    if (attempt > bestAttempt) {
      bestAttempt = attempt
      best = name
    }
  }
  return best
}

/** Ultimo evento relevante del `events.jsonl` (run-events v1): `tool.started` o `message` del assistant con texto; null si no hay. */
export function lastEventOf(raw: string): LastEvent | null {
  const lines = raw.split('\n')
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = (lines[i] ?? '').trim()
    if (line === '') continue
    let ev: Record<string, unknown>
    try {
      ev = JSON.parse(line) as Record<string, unknown>
    } catch {
      continue
    }
    if (ev.type === 'tool.started') return { kind: 'tool', tool: typeof ev.tool === 'string' ? ev.tool : '' }
    if (ev.type === 'message' && ev.role === 'assistant' && typeof ev.text === 'string' && ev.text.trim() !== '') return { kind: 'text', tool: '' }
  }
  return null
}

const EDIT_TOOLS = /^(Edit|Write|MultiEdit|NotebookEdit)$/

/** Pose de la corrida activa: herramienta trabaja (o despliega), texto o sin eventos piensa, edicion del revisor corrige. */
export function poseOfRun(run: PipelineRun, last: LastEvent | null): MascotPose {
  const role = roleOfAgent(agentOf(run.stage))
  if (role === 'infraestructura') return { role, state: 'desplegando' }
  if (last?.kind !== 'tool') return { role, state: 'pensando' }
  if (role === 'revisor' && EDIT_TOOLS.test(last.tool)) return { role, state: 'corrigiendo' }
  return { role, state: 'trabajando' }
}

/** Pose con solo resultados: `✓` revisor aprobado (infra arriba), `✗` desarrollador error (infra caido); null sin resultados. */
export function poseOfResults(results: readonly PipelineResult[]): MascotPose | null {
  const r = results[results.length - 1]
  if (!r) return null
  const isInfra = r.pipeline === 'infra'
  if (r.ok) return isInfra ? { role: 'infraestructura', state: 'arriba' } : { role: 'revisor', state: 'aprobado' }
  return isInfra ? { role: 'infraestructura', state: 'caido' } : { role: 'desarrollador', state: 'error' }
}

// ---- Incremento 5: mergear / ver el PR de una corrida terminada ----
export const PR_CHECK_MS = 15_000
export const MERGE_ALL = 'Todos'
export const MERGE_CANCEL = 'Cancelar'
const MERGE_MAX_OPTIONS = 3

export type ResultPr = { pr: string; issue: number; pipeline: PipelineKind; key: string }

/** Numero de PR de un resultado `✓ PR #X`; null si es `✗` o `✓ completado`. */
export function prOfResult(r: PipelineResult): string | null {
  return r.ok ? (/^✓ PR #(\d+)/.exec(r.text)?.[1] ?? null) : null
}

/** PRs de los `✓` visibles, sin repetir, del mas reciente (numero mayor) al mas antiguo. */
export function resultPrs(results: PipelineResult[]): ResultPr[] {
  const found = new Map<string, ResultPr>()
  for (const r of results) {
    const pr = prOfResult(r)
    if (pr && !found.has(pr)) found.set(pr, { pr, issue: r.issue, pipeline: r.pipeline, key: r.key })
  }
  return [...found.values()].sort((a, b) => Number(b.pr) - Number(a.pr))
}

const prLabel = (p: ResultPr) => `#${p.pr} · #${p.issue} ${p.pipeline}`

/** Opciones del dialogo de merge: con un PR, ese y cancelar; con varios, "Todos" y hasta 3 PRs mas recientes. */
export function mergeOptions(prs: ResultPr[]): string[] {
  if (prs.length === 1 && prs[0]) return [`Mergear #${prs[0].pr}`, MERGE_CANCEL]
  return [MERGE_ALL, ...prs.slice(0, MERGE_MAX_OPTIONS).map(prLabel)]
}

/** Opciones de "cual PR ver": hasta 3 PRs mas recientes; los demas numeros van en la opcion de texto. */
export function viewOptions(prs: ResultPr[]): string[] {
  return prs.slice(0, MERGE_MAX_OPTIONS).map(prLabel)
}

/**
 * Argumentos de /mefisto:merge a partir de la respuesta (opciones marcadas unidas por ", " y/o texto libre):
 * solo numeros de PRs `✓` conocidos, nunca `--all`. Null si no queda ninguno (cancelar o nada elegido).
 */
export function mergeArgsOf(answer: string | null, options: string[], prs: ResultPr[]): string | null {
  return argsOfAnswer(answer, options, prs.map(p => p.pr))
}

/** Comun a ambos dialogos de merge: un solo numero exige su opcion; "Todos" pasa todos los listados; si no, elegidos + texto libre. */
function argsOfAnswer(answer: string | null, options: string[], numbersListed: string[]): string | null {
  if (answer === null) return null
  if (numbersListed.length === 1) return answer === options[0] && numbersListed[0] ? numbersListed[0] : null
  if (answer.includes(MERGE_ALL)) return numbersListed.join(' ')
  const known = new Set(numbersListed)
  let rest = answer
  const numbers: string[] = []
  for (const option of options) {
    if (option === MERGE_ALL || !rest.includes(option)) continue
    rest = rest.replace(option, '')
    const n = /^#(\d+)/.exec(option)?.[1]
    if (n) numbers.push(n)
  }
  numbers.push(...(rest.match(/\d+/g) ?? []))
  const picked = [...new Set(numbers)].filter(n => known.has(n))
  return picked.length > 0 ? picked.join(' ') : null
}

/** El PR que eligio la persona para verlo: un numero de la respuesta que sea de un `✓`. */
export function viewPrOf(answer: string | null, prs: ResultPr[]): string | null {
  if (answer === null) return null
  const known = new Set(prs.map(p => p.pr))
  const n = (/#(\d+)/.exec(answer)?.[1] ?? /\d+/.exec(answer)?.[0]) ?? null
  return n && known.has(n) ? n : null
}

/** Numeros de PR de un argumento de comando (`merge 12 13`, `#12`); invalid = los que no son de un `✓`. */
export function parsePrArgs(arg: string, prs: ResultPr[]): { prs: string[]; invalid: string[] } {
  const known = new Set(prs.map(p => p.pr))
  const given = [...new Set((arg.match(/\d+/g) ?? []))]
  return { prs: given.filter(n => known.has(n)), invalid: given.filter(n => !known.has(n)) }
}

/** Toast del merge: en infra el issue lo cierra el job `apply` de CI tras el merge (MEF-ADR-0022). */
export function mergeToast(args: string, prs: ResultPr[]): string {
  const nums = args.split(' ')
  const hasInfra = prs.some(p => nums.includes(p.pr) && p.pipeline === 'infra')
  return `/mefisto:merge ${args} en cola${hasInfra ? ' · el issue de infra se cierra cuando termine el apply de CI' : ''}`
}

// ---- Incremento 6: mergear PRs abiertos desde el reposo (decision 11: referencia de experiencia) ----
export const FIELD_NOTE_BRANCH_PREFIX = 'docs/planner-field-notes-'
export const OPEN_PRS_ARGS = ['pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,isDraft,headRefName']

export type OpenPr = { number: string; title: string }

/** PRs abiertos de trabajo: sin borradores ni ramas de field notes; el mas reciente (numero mayor) primero. Vacio si no es JSON. */
export function parseOpenPrs(raw: string): OpenPr[] {
  let rows: unknown
  try {
    rows = JSON.parse(raw)
  } catch {
    return []
  }
  if (!Array.isArray(rows)) return []
  const out: OpenPr[] = []
  for (const r of rows as Record<string, unknown>[]) {
    if (!r || typeof r.number !== 'number' || r.isDraft === true) continue
    if (typeof r.headRefName === 'string' && r.headRefName.startsWith(FIELD_NOTE_BRANCH_PREFIX)) continue
    out.push({ number: String(r.number), title: typeof r.title === 'string' ? r.title : '' })
  }
  return out.sort((a, b) => Number(b.number) - Number(a.number))
}

const openPrLabel = (p: OpenPr) => `#${p.number} ${clip(p.title, 60)}`.trim()

/** Opciones del dialogo: con un PR, ese y cancelar; con varios, "Todos" y los 3 mas recientes. */
export function openPrOptions(prs: OpenPr[]): string[] {
  if (prs.length === 1 && prs[0]) return [openPrLabel(prs[0]), MERGE_CANCEL]
  return [MERGE_ALL, ...prs.slice(0, MERGE_MAX_OPTIONS).map(openPrLabel)]
}

/** Argumentos de /mefisto:merge: "Todos" pasa los numeros listados (nunca `--all`); si no, los elegidos y los del texto libre. */
export function openPrArgsOf(answer: string | null, options: string[], prs: OpenPr[]): string | null {
  return argsOfAnswer(answer, options, prs.map(p => p.number))
}

// ---- Incremento 7: seguir un sequential como lote (MEF-ADR-0055 decision 10/11; #2202 escribe el status) ----
export const BATCH_STATUS_FILE = 'pipeline-status-batch.json'
/** Senal de parada suave (MEF-ADR-0017), relativa a la raiz del checkout principal. */
export const BATCH_STOP_FILE = 'pipeline-state/batch-stop'
export const BATCH_STOP_ANSWER = 'Detener tras el actual'
export const BATCH_KEEP_ANSWER = 'Seguir'

export type BatchIssueStatus = 'pendiente' | 'en-curso' | 'mergeado' | 'fallido' | 'aplazado' | 'saltado'
export type BatchState = 'running' | 'completed' | 'failed' | 'stopped'
export type BatchIssue = { issue: number; status: BatchIssueStatus; pr: string | null; detail: string }
export type BatchStatus = {
  pipeline: string
  started: string
  state: BatchState
  current: number | null
  stopRequested: boolean
  holdSeconds: number
  issues: BatchIssue[]
}

const BATCH_ISSUE_STATUSES: readonly string[] = ['pendiente', 'en-curso', 'mergeado', 'fallido', 'aplazado', 'saltado']
const BATCH_STATES: readonly string[] = ['running', 'completed', 'failed', 'stopped']

export function batchStatusPath(stateDir: string): string {
  return `${stateDir.replace(/\/+$/, '')}/${BATCH_STATUS_FILE}`
}

/** Ruta de la senal de parada: la raiz del checkout principal (donde `batch-pipeline.sh` lee su cwd), nunca el worktree. */
export function batchStopPath(repoRoot: string): string {
  return `${repoRoot.replace(/\/+$/, '')}/${BATCH_STOP_FILE}`
}

function prNumberOf(value: unknown): string | null {
  if (typeof value === 'number') return String(value)
  if (typeof value !== 'string') return null
  return /(\d+)\s*$/.exec(value)?.[1] ?? null
}

/** Parseo de `pipeline-status-batch.json`; null si no es JSON valido o no trae un `state` conocido. */
export function parseBatchStatus(raw: string): BatchStatus | null {
  let json: Record<string, unknown>
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
    json = parsed as Record<string, unknown>
  } catch {
    return null
  }
  if (typeof json.state !== 'string' || !BATCH_STATES.includes(json.state)) return null
  const issues: BatchIssue[] = []
  for (const row of Array.isArray(json.issues) ? (json.issues as Record<string, unknown>[]) : []) {
    const issue = Number(row?.issue)
    if (!Number.isFinite(issue)) continue
    const status = typeof row.status === 'string' && BATCH_ISSUE_STATUSES.includes(row.status) ? (row.status as BatchIssueStatus) : 'pendiente'
    issues.push({ issue, status, pr: prNumberOf(row.pr), detail: typeof row.detail === 'string' ? row.detail : '' })
  }
  const current = Number(json.current)
  return {
    pipeline: typeof json.pipeline === 'string' ? json.pipeline : 'sequential',
    started: typeof json.started === 'string' ? json.started : '',
    state: json.state as BatchState,
    current: json.current !== null && json.current !== undefined && json.current !== '' && Number.isFinite(current) ? current : null,
    stopRequested: json.stop_requested === true,
    holdSeconds: typeof json.hold_seconds === 'number' && json.hold_seconds > 0 ? json.hold_seconds : 0,
    issues,
  }
}

export const isBatchRunning = (b: BatchStatus) => b.state === 'running'

export type BatchCounts = { merged: number; failed: number; deferred: number; skipped: number; total: number }

export function batchCounts(b: BatchStatus): BatchCounts {
  const count = (s: BatchIssueStatus) => b.issues.filter(i => i.status === s).length
  return { merged: count('mergeado'), failed: count('fallido'), deferred: count('aplazado'), skipped: count('saltado'), total: b.issues.length }
}

/** Marca de la cola: `✓` mergeado, `●` en curso, `✗` fallido, `⏸` aplazado, `-` saltado, `·` pendiente. */
export function batchMark(status: BatchIssueStatus): string {
  switch (status) {
    case 'mergeado':
      return '✓'
    case 'en-curso':
      return '●'
    case 'fallido':
      return '✗'
    case 'aplazado':
      return '⏸'
    case 'saltado':
      return '-'
    default:
      return '·'
  }
}

/** Cabecera: `sequential N/M · Xm`; con parada pedida, `· deteniendo`. N cuenta los `mergeado`. */
export function batchHeader(b: BatchStatus, nowMs: number): string {
  const mins = minutesSince(b.started, nowMs)
  const stopping = isBatchRunning(b) && b.stopRequested ? ' · deteniendo' : ''
  return `${b.pipeline || 'sequential'} ${batchCounts(b).merged}/${b.issues.length}${mins === null ? '' : ` · ${mins}m`}${stopping}`
}

/** Cola en una linea por tramo: `✓ #12 · ● #13 · ⏸ #14`. */
export function batchQueueText(b: BatchStatus): string {
  return b.issues.map(i => `${batchMark(i.status)} #${i.issue}`).join(' · ')
}

/** El eslabon en curso: `current` del status o, si no, el primero `en-curso`; null si no hay. */
export function batchCurrentOf(b: BatchStatus): BatchIssue | null {
  return b.issues.find(i => i.issue === b.current) ?? b.issues.find(i => i.status === 'en-curso') ?? null
}

/** PR del eslabon en curso o, si aun no tiene, el del ultimo `mergeado` con PR; null sin PR. */
export function batchPrOf(b: BatchStatus): string | null {
  const current = batchCurrentOf(b)
  if (current?.pr) return current.pr
  for (let i = b.issues.length - 1; i >= 0; i -= 1) {
    const row = b.issues[i] as BatchIssue
    if (row.status === 'mergeado' && row.pr) return row.pr
  }
  return null
}

/** Corrida suelta del eslabon en curso (su propio status), para pipeline, agente, tiempo y mascota. */
export function batchRunOf(b: BatchStatus, runs: readonly PipelineRun[]): PipelineRun | null {
  const current = batchCurrentOf(b)
  if (!current) return null
  return runs.filter(r => r.issue === current.issue && isActive(r)).sort((a, c) => c.updated.localeCompare(a.updated))[0] ?? null
}

/** Corridas que no son el eslabon en curso: ese no se repite como corrida suelta. */
export function runsOutsideBatch(b: BatchStatus, runs: readonly PipelineRun[]): PipelineRun[] {
  const mine = batchRunOf(b, runs)
  return runs.filter(r => r !== mine)
}

/** Pie `+N corridas`; vacio sin otras corridas. */
export function otherRunsText(n: number): string {
  return n > 0 ? `+${n} ${n === 1 ? 'corrida' : 'corridas'}` : ''
}

/** Minutos de espera por rate limit acumulados, como `Mm`; vacio sin espera. */
export function holdText(holdSeconds: number): string {
  return holdSeconds > 0 ? `${Math.max(1, Math.round(holdSeconds / 60))}m` : ''
}

/** Resumen de cierre: `N mergeados · N fallidos · N aplazados · N saltados · espera Mm` (omite lo que esta en cero). */
export function batchSummaryText(b: BatchStatus): string {
  const c = batchCounts(b)
  const hold = holdText(b.holdSeconds)
  return [
    `${c.merged} mergeados`,
    c.failed > 0 ? `${c.failed} fallidos` : '',
    c.deferred > 0 ? `${c.deferred} aplazados` : '',
    c.skipped > 0 ? `${c.skipped} saltados` : '',
    hold ? `espera ${hold} por rate limit` : '',
  ]
    .filter(Boolean)
    .join(' · ')
}

/** Titulo de la entrada mas reciente del issue con `started` igual o posterior al del lote (mismo formato `YYYYMMDD-HHMMSS`); null si no hay. */
export function batchTitleOf(entries: readonly HistoryEntry[], issue: number, batchStarted: string): string | null {
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const e = entries[i] as HistoryEntry
    if (e.issue === String(issue) && e.started >= batchStarted && e.title) return e.title
  }
  return null
}

/** Una linea por issue del resumen: marca, issue, titulo (recortado al ancho `max` para dejar PR y detalle visibles), PR y motivo. */
export function batchIssueLine(i: BatchIssue, title?: string | null, max?: number): string {
  const head = `${batchMark(i.status)} #${i.issue}`
  const tail = `${i.pr ? ` · PR #${i.pr}` : ''}${i.detail ? ` · ${i.detail}` : ''}`
  const t = (title ?? '').trim()
  if (t === '') return `${head}${tail}`
  const room = max === undefined ? t.length : max - head.length - tail.length - 4
  if (room < 2) return `${head}${tail}`
  return `${head}  ${clip(t, room)}  ${tail.replace(/^ /, '')}`.trimEnd()
}

/** Issues que pasaron a `mergeado` entre dos lecturas; con `prev` vacio no hay toasts (el primer vistazo no anuncia). */
export function newlyMerged(prev: readonly BatchIssue[] | null, next: readonly BatchIssue[]): BatchIssue[] {
  if (!prev) return []
  const before = new Map(prev.map(i => [i.issue, i.status]))
  return next.filter(i => i.status === 'mergeado' && before.get(i.issue) !== 'mergeado')
}

/** Clave de descarte persistente del lote: repo + `started`. */
export function batchDismissKey(repo: string, b: BatchStatus): string {
  return [repo, 'batch', b.started].join('|')
}

/** Pregunta del dialogo de parada. */
export function stopQuestion(b: BatchStatus): string {
  return `¿Detener el sequential tras ${b.current ? `#${b.current}` : 'el issue en curso'}?`
}

/** `1` se ofrece solo con el lote corriendo y sin parada pedida. */
export const canStopBatch = (b: BatchStatus | null): boolean => b !== null && isBatchRunning(b) && !b.stopRequested
