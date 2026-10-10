import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { RASTER_ROWS, ROLES, face, sprite, toRasterCells, waitingFace } from '../sprites'
import type { Role } from '../sprites'
import { cropGrid, usedColumns } from '../logic'
import type { BoardList, PipelineResult, PipelineRun } from '../types'
import type { BatchStatus, LastEvent, LaunchKind, LaunchPlan, MascotPose, OpenPr } from './logic'
import {
  LOGS_DIR,
  activeRunOf,
  eventsFileOf,
  lastEventOf,
  poseOfResults,
  poseOfRun,
  DISMISSED_STORE_KEY,
  HISTORY_FILE,
  PAGE_ROWS,
  PLANNER_AGENT,
  agentFlagOf,
  agentSettingOf,
  NEXT_ORDER_ARGS,
  ROW_KEYS,
  answerText,
  parseLaunchArg,
  planIssue,
  planLaunch,
  clip,
  footerRestOf,
  isMefistoManifest,
  nextOrderPath,
  RUNS_POLL_MS,
  dismissKey,
  parseHistory,
  parseStatus,
  pruneDismissed,
  reconcile,
  repoRootOf,
  resultLine,
  runLine,
  stateDirOf,
  pageOf,
  parseNextOrder,
  rowText,
  transcriptPathOf,
  PR_CHECK_MS,
  mergeArgsOf,
  mergeOptions,
  mergeToast,
  OPEN_PRS_ARGS,
  openPrArgsOf,
  openPrOptions,
  parseOpenPrs,
  parsePrArgs,
  resultPrs,
  viewOptions,
  viewPrOf,
  BATCH_KEEP_ANSWER,
  BATCH_STOP_ANSWER,
  batchCounts,
  batchCurrentOf,
  batchDismissKey,
  batchHeader,
  batchMark,
  batchIssueLine,
  batchPrOf,
  batchRunOf,
  batchStatusPath,
  batchStopPath,
  batchSummaryText,
  canStopBatch,
  isBatchRunning,
  newlyMerged,
  otherRunsText,
  parseBatchStatus,
  runsOutsideBatch,
  stopQuestion,
} from './logic'
import type { ResultPr } from './logic'

const POLL_MS = 60_000
const SCRIPT_TIMEOUT_MS = 180_000

const activeAtom = atom({ plugin: 'mefisto', key: 'pactIsActive' } as const, false)
const listAtom = atom({ plugin: 'mefisto', key: 'pactList' } as const, null)
const pageAtom = atom({ plugin: 'mefisto', key: 'pactPage' } as const, 0)
const runsAtom = atom({ plugin: 'mefisto', key: 'pactRuns' } as const, [] as PipelineRun[])
const resultsAtom = atom({ plugin: 'mefisto', key: 'pactResults' } as const, [] as PipelineResult[])
const lastEventAtom = atom({ plugin: 'mefisto', key: 'pactLastEvent' } as const, null as LastEvent | null)
const openPrsAtom = atom({ plugin: 'mefisto', key: 'pactOpenPrs' } as const, [] as OpenPr[])
const batchAtom = atom({ plugin: 'mefisto', key: 'pactBatch' } as const, null as BatchStatus | null)
const tickAtom = atom({ plugin: 'mefisto', key: 'pactTick' } as const, 0)

// Columnas comunes a todos los cuadros de la mascota: el recorte no cambia al alternar poses.
const MASCOT_GRIDS = [
  ...(Object.keys(ROLES) as Role[])
    .filter(role => role !== 'planner')
    .flatMap(role => Object.keys(ROLES[role]).flatMap(state => [sprite(role, state, 0), sprite(role, state, 1)])),
  ...[null, 0, 1].map(tick => waitingFace(face('normal'), tick)),
]
const MASCOT_COLS = usedColumns(MASCOT_GRIDS)
const MASCOT_WIDTH = MASCOT_COLS.to - MASCOT_COLS.from + 1

const mascotGrid = (pose: MascotPose, frame: 0 | 1) => cropGrid(sprite(pose.role, pose.state, frame), MASCOT_COLS)
let isAnimating = false

// La intencion on/off y la elegibilidad viven aqui: /clear no dispara session.start y reinicia los atoms.
let isEligible = false
let isWanted = true
let isRefreshing = false
let timer: { cancel: () => void } | null = null
let runsTimer: { cancel: () => void } | null = null
let tickTimer: { cancel: () => void } | null = null
let prTimer: { cancel: () => void } | null = null
let isCheckingPrs = false
let isRefreshingOpenPrs = false
let isRefreshingRuns = false
// Corridas que esta sesion vio activas y resultados `✓` ya derivados; viven aqui porque /clear reinicia los atoms.
let seenRuns: Record<string, PipelineRun> = {}
let carriedResults: PipelineResult[] = []
let runsRepo = ''
// Ultimo estado del lote leido: base para anunciar con un toast cada issue que pasa a `mergeado`.
let lastBatchIssues: BatchStatus['issues'] | null = null
// Si al arrancar no se pudo saber el agente (sin linea de comando y sin transcript aun), se reintenta en cada refresh.
let agentChecksLeft = 0
const AGENT_CHECKS = 20

async function pluginRoot($: EngineInterface): Promise<string | null> {
  const own = $.plugin.root
  if (own) return own
  const top = await $.process.run(['git', 'rev-parse', '--show-toplevel']).catch(() => ({ exitCode: 1, stdout: '' }))
  const base = top.exitCode === 0 ? top.stdout.trim() : await $.session.cwd()
  const root = await $.fs.read(`${base}/.mefisto/pipeline/.plugin-root`).catch(() => '')
  return typeof root === 'string' && root.trim() !== '' ? root.trim() : null
}

async function runNextOrder($: EngineInterface): Promise<BoardList> {
  const root = await pluginRoot($)
  if (!root) return parseNextOrder(2, '', 'raiz del plugin desconocida')
  const { exitCode, stdout, stderr } = await $.process
    .run([nextOrderPath(root), ...NEXT_ORDER_ARGS], { timeoutMs: SCRIPT_TIMEOUT_MS })
    .catch(err => ({ exitCode: 2, stdout: '', stderr: String(err) }))
  return parseNextOrder(exitCode, stdout, stderr)
}

async function readDismissed($: EngineInterface): Promise<string[]> {
  const raw = await $.store.get(DISMISSED_STORE_KEY).catch(() => null)
  return Array.isArray(raw) ? raw.filter((k): k is string => typeof k === 'string') : []
}

async function saveDismissed($: EngineInterface, keys: string[]) {
  await $.store.set(DISMISSED_STORE_KEY, keys).catch(() => undefined)
}

// Lector puro: solo lee `.mefisto/pipeline/` del checkout principal (con `.claude/pipeline/` de respaldo).
async function readRuns($: EngineInterface): Promise<PipelineRun[]> {
  const cwd = await $.session.cwd()
  const common = await $.process.run(['git', 'rev-parse', '--git-common-dir']).catch(() => ({ exitCode: 1, stdout: '' }))
  const dir = stateDirOf(common.exitCode === 0 ? common.stdout.trim() : '.git', cwd)
  runsRepo = repoRootOf(dir)
  const found = new Map<string, PipelineRun>()
  for (const base of [dir, `${runsRepo}/.claude/pipeline`]) {
    const ls = await $.process.run(['ls', base]).catch(() => ({ exitCode: 1, stdout: '' }))
    if (ls.exitCode !== 0) continue
    for (const name of ls.stdout.split('\n')) {
      const file = name.trim()
      if (!file.startsWith('pipeline-status-')) continue
      const raw = await $.fs.read(`${base}/${file}`).catch(() => '')
      const run = typeof raw === 'string' ? parseStatus(file, raw) : null
      if (run && !found.has(file)) found.set(file, run)
    }
  }
  return [...found.values()]
}

// Ultimo evento del ultimo intento del agente activo; lector puro de `<estado>/logs/*.events.jsonl`.
async function readLastEvent($: EngineInterface, run: PipelineRun | null): Promise<LastEvent | null> {
  if (!run) return null
  for (const base of [`${runsRepo}/.mefisto/pipeline`, `${runsRepo}/.claude/pipeline`]) {
    const dir = `${base}/${LOGS_DIR}`
    const ls = await $.process.run(['ls', dir]).catch(() => ({ exitCode: 1, stdout: '' }))
    if (ls.exitCode !== 0) continue
    const file = eventsFileOf(run, ls.stdout.split('\n'))
    if (!file) continue
    const tail = await $.process.run(['tail', '-c', '65536', `${dir}/${file}`]).catch(() => ({ exitCode: 1, stdout: '' }))
    return tail.exitCode === 0 ? lastEventOf(tail.stdout) : null
  }
  return null
}

// `.mefisto/pipeline/` primero; `.claude/pipeline/` solo como respaldo de lectura (MEF-ADR-0053).
async function readHistory($: EngineInterface): Promise<string> {
  for (const base of ['.mefisto/pipeline', '.claude/pipeline']) {
    const raw = await $.fs.read(`${runsRepo}/${base}/${HISTORY_FILE}`).catch(() => '')
    if (typeof raw === 'string' && raw !== '') return raw
  }
  return ''
}

// Lector puro del status del lote (#2202); un lote terminado y cerrado (clave repo + `started` en el store) no se muestra.
async function readBatch($: EngineInterface): Promise<BatchStatus | null> {
  for (const base of ['.mefisto/pipeline', '.claude/pipeline']) {
    const raw = await $.fs.read(batchStatusPath(`${runsRepo}/${base}`)).catch(() => '')
    const batch = typeof raw === 'string' && raw !== '' ? parseBatchStatus(raw) : null
    if (batch) return batch
  }
  return null
}

async function refreshBatch($: EngineInterface) {
  const batch = await readBatch($)
  if (!batch) {
    lastBatchIssues = null
    await update($, batchAtom, () => null)
    return
  }
  for (const i of newlyMerged(lastBatchIssues, batch.issues)) $.ui.toast(`#${i.issue} mergeado${i.pr ? ` · PR #${i.pr}` : ''}`)
  lastBatchIssues = batch.issues
  const closed = !isBatchRunning(batch) && (await readDismissed($)).includes(batchDismissKey(runsRepo, batch))
  await update($, batchAtom, () => (closed ? null : batch))
}

// Parada suave (MEF-ADR-0017): la misma senal vacia que /mefisto:batch-stop, en la raiz del checkout principal.
async function requestStop($: EngineInterface): Promise<string> {
  const batch = await read($, batchAtom)
  if (!batch || !canStopBatch(batch)) return 'No hay un sequential en curso que detener.'
  await $.fs.write(batchStopPath(runsRepo), '')
  await update($, batchAtom, b => (b ? { ...b, stopRequested: true } : b))
  $.ui.toast('parada pedida: termina el issue en curso y no arranca los siguientes')
  return 'Parada pedida: termina el issue en curso y no arranca los siguientes.'
}

async function confirmStop($: EngineInterface): Promise<string> {
  const batch = await read($, batchAtom)
  if (batch && isBatchRunning(batch) && batch.stopRequested) return 'La parada ya esta pedida: termina el issue en curso.'
  if (!batch || !canStopBatch(batch)) return 'No hay un sequential en curso que detener.'
  const answer = await $.ui
    .ask(stopQuestion(batch), { header: 'Detener', options: [BATCH_STOP_ANSWER, BATCH_KEEP_ANSWER] })
    .catch(() => null)
  return answer === BATCH_STOP_ANSWER ? requestStop($) : 'Sin cambios.'
}

async function viewBatchPr($: EngineInterface): Promise<string> {
  const batch = await read($, batchAtom)
  const pr = batch ? batchPrOf(batch) : null
  if (!pr) return 'El lote no tiene PR que abrir.'
  await $.process.run(['gh', 'pr', 'view', pr, '--web']).catch(() => undefined)
  return `PR #${pr} abierto en GitHub.`
}

async function closeBatch($: EngineInterface) {
  const batch = await read($, batchAtom)
  if (!batch || isBatchRunning(batch)) return
  const keys = new Set(await readDismissed($))
  keys.add(batchDismissKey(runsRepo, batch))
  await saveDismissed($, [...keys])
  await update($, batchAtom, () => null)
}

async function refreshRuns($: EngineInterface) {
  if (isRefreshingRuns || !isEligible || !isWanted) return
  isRefreshingRuns = true
  try {
    const statuses = await readRuns($)
    const dismissed = await readDismissed($)
    const wasSeen = seenRuns
    const historyRaw = await readHistory($)
    const view = reconcile(
      runsRepo,
      statuses,
      wasSeen,
      parseHistory(typeof historyRaw === 'string' ? historyRaw : ''),
      new Set(dismissed),
      carriedResults,
    )
    seenRuns = view.seen
    carriedResults = view.results.filter(r => r.ok)
    const live = new Set(statuses.map(s => dismissKey(runsRepo, s)))
    const pruned = pruneDismissed(dismissed, runsRepo, live, Date.now())
    if (pruned.length !== dismissed.length) await saveDismissed($, pruned)
    const last = await readLastEvent($, activeRunOf(view.runs))
    await update($, lastEventAtom, () => last)
    await update($, runsAtom, () => view.runs)
    await refreshBatch($)
    await update($, resultsAtom, () => view.results)
  } finally {
    isRefreshingRuns = false
  }
}

async function dismissResults($: EngineInterface): Promise<number> {
  const results = await read($, resultsAtom)
  if (results.length === 0) return 0
  const keys = new Set(await readDismissed($))
  for (const r of results) keys.add(r.key)
  await saveDismissed($, [...keys])
  carriedResults = []
  await update($, resultsAtom, () => [])
  await update($, pageAtom, () => 0)
  return results.length
}

// Un PR `MERGED` quita su linea sola: se guarda en `$.store` (nunca en archivos de estado) para que no reaparezca.
async function closeMergedPrs($: EngineInterface) {
  if (isCheckingPrs || !isEligible || !isWanted) return
  isCheckingPrs = true
  try {
    const results = await read($, resultsAtom)
    const merged: ResultPr[] = []
    for (const p of resultPrs(results)) {
      const { exitCode, stdout } = await $.process
        .run(['gh', 'pr', 'view', p.pr, '--json', 'state', '-q', '.state'])
        .catch(() => ({ exitCode: 1, stdout: '' }))
      if (exitCode === 0 && stdout.trim() === 'MERGED') merged.push(p)
    }
    if (merged.length === 0) return
    const keys = new Set(await readDismissed($))
    for (const p of merged) keys.add(p.key)
    await saveDismissed($, [...keys])
    const gone = new Set(merged.map(p => p.key))
    carriedResults = carriedResults.filter(r => !gone.has(r.key))
    await update($, resultsAtom, rs => rs.filter(r => !gone.has(r.key)))
    await update($, pageAtom, () => 0)
    void refreshOpenPrs($)
    for (const p of merged) {
      $.ui.toast(`PR #${p.pr} mergeado${p.pipeline === 'infra' ? ' · el issue se cierra cuando termine el apply de CI' : ''}`)
    }
  } finally {
    isCheckingPrs = false
  }
}

// Mergear: la confirmacion del dialogo es la unica; /mefisto:merge no pide otra. Nunca `--all`.
async function mergePrs($: EngineInterface, preset: string[] | null = null): Promise<string> {
  const prs = resultPrs(await read($, resultsAtom))
  if (prs.length === 0) return 'No hay PRs de corridas terminadas.'
  const scope = preset ? prs.filter(p => preset.includes(p.pr)) : prs
  const options = mergeOptions(scope)
  const answer = await $.ui
    .ask(
      scope.length === 1 ? `¿Mergear el PR #${scope[0]!.pr}?` : `¿Qué mergear? ${scope.length} PRs${scope.length > 3 ? ' (otros números: escríbelos en la opción de texto)' : ''}`,
      scope.length === 1 ? options : { header: 'Merge', options, multiSelect: true as const },
    )
    .catch(() => null)
  const args = mergeArgsOf(answer, options, scope)
  if (!args) return 'Merge cancelado.'
  $.ui.toast(mergeToast(args, prs))
  await $.command.run({ command: 'mefisto:merge', args })
  void refreshOpenPrs($)
  return `/mefisto:merge ${args} en cola.`
}

async function refreshOpenPrs($: EngineInterface) {
  if (isRefreshingOpenPrs || !isEligible || !isWanted) return
  isRefreshingOpenPrs = true
  try {
    const { exitCode, stdout } = await $.process.run(['gh', ...OPEN_PRS_ARGS]).catch(() => ({ exitCode: 1, stdout: '' }))
    if (exitCode === 0) await update($, openPrsAtom, () => parseOpenPrs(stdout))
  } finally {
    isRefreshingOpenPrs = false
  }
}

// Reposo: la lista es de PRs abiertos de trabajo; "Todos" pasa sus numeros, nunca `--all`.
async function mergeOpenPrs($: EngineInterface): Promise<string> {
  await refreshOpenPrs($)
  const prs = await read($, openPrsAtom)
  if (prs.length === 0) return 'No hay PRs abiertos de trabajo.'
  const options = openPrOptions(prs)
  const answer = await $.ui
    .ask(
      prs.length === 1 ? `¿Mergear el PR #${prs[0]!.number}?` : `¿Qué mergear? ${prs.length} PRs${prs.length > 3 ? ' (otros números: escríbelos en la opción de texto)' : ''}`,
      prs.length === 1 ? options : { header: 'Merge', options, multiSelect: true as const },
    )
    .catch(() => null)
  const args = openPrArgsOf(typeof answer === 'string' ? answer : null, options, prs)
  if (!args) return 'Merge cancelado.'
  $.ui.toast(`/mefisto:merge ${args} en cola`)
  await $.command.run({ command: 'mefisto:merge', args })
  void refreshOpenPrs($)
  return `/mefisto:merge ${args} en cola.`
}

async function viewPr($: EngineInterface, preset: string | null = null): Promise<string> {
  const prs = resultPrs(await read($, resultsAtom))
  if (prs.length === 0) return 'No hay PRs de corridas terminadas.'
  let pr = preset
  if (!pr) {
    if (prs.length === 1) pr = prs[0]!.pr
    else {
      const options = viewOptions(prs)
      const answer = await $.ui.ask('¿Cuál PR ver?', { header: 'PR', options }).catch(() => null)
      pr = viewPrOf(answer, prs)
    }
  }
  if (!pr) return 'Sin PR elegido.'
  await $.process.run(['gh', 'pr', 'view', pr, '--web']).catch(() => undefined)
  return `PR #${pr} abierto en GitHub.`
}

async function refresh($: EngineInterface) {
  if (isRefreshing || !isEligible || !isWanted) return
  isRefreshing = true
  try {
    if (agentChecksLeft > 0) {
      agentChecksLeft -= 1
      const agent = await plannerSession($)
      if (agent !== null) agentChecksLeft = 0
      if (agent === true) {
        isEligible = false
        await deactivate($)
        isWanted = true
        return
      }
    }
    await refreshRuns($)
    await refreshOpenPrs($)
    const list = await runNextOrder($)
    await update($, listAtom, () => list)
  } finally {
    isRefreshing = false
  }
}

// El comando queda escrito sin Enter: la persona lo revisa y lo envia (MEF-ADR-0055 decision 2).
async function applyPlan($: EngineInterface, plan: LaunchPlan): Promise<boolean> {
  if (plan.kind === 'none') {
    $.ui.toast(plan.message)
    return false
  }
  const text = plan.kind === 'fill'
    ? plan.text
    : answerText(plan.options, await $.ui.ask(plan.question, plan.options.map(o => o.label)).catch(() => null))
  if (text === null) return false
  await $.prompt.fill({ text, mode: 'replace' })
  return true
}

async function launchKey($: EngineInterface, kind: LaunchKind) {
  const list = await read($, listAtom)
  if (list && !list.error) await applyPlan($, planLaunch(list, kind))
}

async function launchRow($: EngineInterface, issue: number) {
  const item = (await read($, listAtom))?.items.find(i => i.number === issue)
  if (item) await applyPlan($, planIssue(item))
}

async function activate($: EngineInterface) {
  isWanted = true
  await update($, activeAtom, () => true)
  timer?.cancel()
  timer = $.clock.every(POLL_MS, () => void refresh($))
  runsTimer?.cancel()
  // Ritmo rapido solo con corridas activas; sin ellas, `refresh` las relee al ritmo de los listos (CA-5).
  runsTimer = $.clock.every(RUNS_POLL_MS, () => {
    if (Object.keys(seenRuns).length > 0 || lastBatchIssues !== null) void refreshRuns($)
  })
  prTimer?.cancel()
  prTimer = $.clock.every(PR_CHECK_MS, () => void closeMergedPrs($))
  tickTimer?.cancel()
  // La mascota anima solo con corrida activa o con Claude trabajando; en reposo no hay re-render por segundo.
  tickTimer = $.clock.every(1000, () => {
    if (isAnimating) void update($, tickAtom, () => Math.floor(Date.now() / 1000))
  })
  void refresh($)
}

async function deactivate($: EngineInterface) {
  isWanted = false
  timer?.cancel()
  timer = null
  runsTimer?.cancel()
  runsTimer = null
  tickTimer?.cancel()
  tickTimer = null
  prTimer?.cancel()
  prTimer = null
  await update($, activeAtom, () => false)
}

async function isMefistoRepo($: EngineInterface): Promise<boolean> {
  const top = await $.process.run(['git', 'rev-parse', '--show-toplevel']).catch(() => ({ exitCode: 1, stdout: '' }))
  if (top.exitCode !== 0) return false
  const raw = await $.fs.read(`${top.stdout.trim()}/.claude-plugin/plugin.json`).catch(() => '')
  return typeof raw === 'string' && isMefistoManifest(raw)
}

// Agente principal de la sesion: primero la linea de comando de Claude Code, luego el transcript si ya existe.
async function plannerSession($: EngineInterface): Promise<boolean | null> {
  const ps = await $.process.run(['sh', '-c', 'ps -o args= -p "$PPID"']).catch(() => ({ exitCode: 1, stdout: '' }))
  const cmdline = ps.exitCode === 0 ? ps.stdout.trim() : ''
  if (/\bclaude\b/.test(cmdline)) return agentFlagOf(cmdline) === PLANNER_AGENT
  const home = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`
  const path = transcriptPathOf(home, await $.session.cwd(), await $.session.id())
  const { stdout } = await $.process.run(['head', '-c', '200000', path]).catch(() => ({ stdout: '' }))
  const agent = agentSettingOf(stdout)
  return agent === null ? null : agent === PLANNER_AGENT
}

export const register: Register = on => {
  // Con matcher: el engine admite un solo session.start sin matcher por plugin (el del tablero), y asi `-p` ni lo dispara.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    isEligible = false
    const agent = (await isMefistoRepo($)) ? true : await plannerSession($)
    if (agent === true) {
      await deactivate($)
      isWanted = true
      return next(e)
    }
    isEligible = true
    agentChecksLeft = agent === null ? AGENT_CHECKS : 0
    await $.command.register({
      name: 'fausto-blood-pact',
      description: 'Consola de Fausto: refresh | on | off | descartar | detener | lanzar | merge | prs | pr',
      argumentHint: '[refresh|on|off|descartar|detener|lanzar [sequential|parallel|<n>]|merge [<pr>...]|prs|pr [<pr>]]',
      immediate: true,
    })
    if (isWanted) await activate($)
    return next(e)
  })

  on('command.run', { command: 'fausto-blood-pact' }, async ($, e) => {
    const arg = e.args.trim()
    if (!isEligible) return { text: 'La consola no aplica en esta sesión.' }
    if (arg === 'off') {
      await deactivate($)
      return { text: 'Consola de Fausto apagada.' }
    }
    if (arg === 'descartar') {
      const n = await dismissResults($)
      return { text: n > 0 ? `Resultados descartados: ${n}.` : 'No hay resultados que descartar.' }
    }
    if (arg === 'detener') {
      const batch = await read($, batchAtom)
      if (!batch || !isBatchRunning(batch)) return { text: 'No hay un sequential en curso.' }
      return { text: await confirmStop($) }
    }
    if (arg === 'merge' || arg.startsWith('merge ')) {
      const given = arg.slice('merge'.length).trim()
      if (given === '') return { text: await mergePrs($) }
      const { prs, invalid } = parsePrArgs(given, resultPrs(await read($, resultsAtom)))
      if (prs.length === 0) return { text: `Sin ✓ con PR para: ${invalid.join(' ')}.` }
      return { text: await mergePrs($, prs) }
    }
    if (arg === 'prs') return { text: await mergeOpenPrs($) }
    if (arg === 'pr' || arg.startsWith('pr ')) {
      const given = arg.slice('pr'.length).trim()
      if (given === '') return { text: await viewPr($) }
      const { prs, invalid } = parsePrArgs(given, resultPrs(await read($, resultsAtom)))
      return { text: prs[0] ? await viewPr($, prs[0]) : `Sin ✓ con PR para: ${invalid.join(' ')}.` }
    }
    if (arg === 'lanzar' || arg.startsWith('lanzar ')) {
      const list = await read($, listAtom)
      if (!list || list.error) return { text: 'No hay lista de lanzables.' }
      const target = parseLaunchArg(arg.slice('lanzar'.length), list)
      if (target.kind === 'invalid') return { text: target.message }
      const plan = target.kind === 'launch' ? planLaunch(list, target.launch) : planIssue(list.items.find(i => i.number === target.issue)!)
      if (plan.kind === 'none') return { text: plan.message }
      return { text: (await applyPlan($, plan)) ? 'Comando escrito en el prompt.' : 'Sin cambios en el prompt.' }
    }
    if (arg === 'on' || !isWanted) {
      await activate($)
      return { text: 'Consola de Fausto activa.' }
    }
    await refresh($)
    return { text: 'Consola actualizada.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!isEligible || !isWanted || e.props.hasSurvey) return next(e)
    if (!(await read($, activeAtom))) await activate($)
    const elements = $.ui.resolve(e)
    const { Box, Text, Button } = elements
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
    const body = Math.max(30, inner - MASCOT_WIDTH - 2)
    const runs = await read($, runsAtom)
    const results = await read($, resultsAtom)
    const batch = await read($, batchAtom)
    const openPrs = await read($, openPrsAtom)
    await read($, tickAtom)
    const isWorking = Boolean(e.props.isWorking)
    const sec = Math.floor(Date.now() / 1000)
    const batchRun = batch ? batchRunOf(batch, runs) : null
    const active = batch ? batchRun : activeRunOf(runs)
    isAnimating = isWorking || active !== null || (batch !== null && isBatchRunning(batch))
    const pose: MascotPose | null = active
      ? poseOfRun(active, await read($, lastEventAtom))
      : batch
        ? { role: 'desarrollador', state: batch.state === 'failed' ? 'error' : isBatchRunning(batch) ? 'pensando' : batch.state === 'completed' ? 'aprobado' : 'pensando' }
        : poseOfResults(results)
    const grid = pose
      ? mascotGrid(pose, active ? (sec % 2 === 0 ? 0 : 1) : 0)
      : cropGrid(waitingFace(face('normal'), isWorking ? sec : null), MASCOT_COLS)
    const mascot =
      'Raster' in elements ? (
        <elements.Raster key="mefisto-mascota" columns={MASCOT_WIDTH} rows={RASTER_ROWS} cells={toRasterCells(grid, MASCOT_WIDTH)} />
      ) : (
        <Box width={MASCOT_WIDTH} />
      )
    if (batch) {
      const running = isBatchRunning(batch)
      const c = batchCounts(batch)
      const pr = batchPrOf(batch)
      const current = batchCurrentOf(batch)
      const others = otherRunsText(runsOutsideBatch(batch, runs).length)
      const queue = batch.issues.map(i => ({ key: `b-${i.issue}`, text: batchIssueLine(i), dim: i.status === 'saltado' || i.status === 'pendiente' }))
      const { page, pages } = pageOf(await read($, pageAtom), queue.length, PAGE_ROWS)
      const visible = running ? [] : queue.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS)
      const headColor = batch.state === 'failed' ? 'error' : batch.state === 'stopped' || batch.stopRequested ? 'warning' : 'claude'
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box gap={2} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body}>
              <Text bold color={headColor} wrap="truncate-end">
                {clip(`${batchHeader(batch, Date.now())}${running ? '' : ` · ${batch.state === 'completed' ? 'terminado' : batch.state === 'stopped' ? 'detenido' : 'con fallos'}`}`, body)}
              </Text>
              {running ? (
                <>
                  <Text wrap="truncate-end">
                    {batch.issues.map((i, n) => (
                      <Text key={`q-${i.issue}`} dimColor={i.status === 'saltado' || i.status === 'pendiente'}>
                        {`${n > 0 ? ' · ' : ''}${batchMark(i.status)} #${i.issue}`}
                      </Text>
                    ))}
                  </Text>
                  <Text color="claude" wrap="truncate-end">
                    {clip(batchRun ? runLine(batchRun, Date.now()) : `#${current?.issue ?? batch.current ?? '…'} en curso`, body)}
                  </Text>
                  {batch.holdSeconds > 0 && <Text dimColor>{clip(batchSummaryText(batch), body)}</Text>}
                </>
              ) : (
                <>
                  {visible.map(l => (
                    <Text key={l.key} dimColor={l.dim} wrap="truncate-end">{clip(l.text, body)}</Text>
                  ))}
                  <Text wrap="truncate-end">{clip(batchSummaryText(batch), body)}</Text>
                </>
              )}
              {Array.from({ length: Math.max(0, PAGE_ROWS - (running ? 3 : visible.length + 1)) }, (_, i) => (
                <Text key={`blank-${i}`}> </Text>
              ))}
              <Box justifyContent="space-between">
                <Box>
                  {canStopBatch(batch) && (
                    <Button key="batch-stop" hotkey="1" plain dimColor label="1 detener" onPress={() => void confirmStop($)} />
                  )}
                  {pr && (
                    <Button key="batch-pr" hotkey="2" plain dimColor label={`${canStopBatch(batch) ? ' · ' : ''}2 ver PR #${pr}`}
                      onPress={() => void viewBatchPr($)} />
                  )}
                  {!running && (
                    <Button key="batch-close" hotkey="4" plain dimColor label={`${pr ? ' · ' : ''}4 cerrar`} onPress={() => void closeBatch($)} />
                  )}
                  <Text dimColor>{others ? ` · ${others}` : ''}{c.failed > 0 && running ? ` · ${c.failed} ✗` : ''}</Text>
                </Box>
                {pages > 1 && !running && (
                  <Button key="pact-next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
                    onPress={() => void update($, pageAtom, () => (page + 1) % pages)} />
                )}
              </Box>
            </Box>
          </Box>
        </Box>
      )
    }
    const hasPrs = resultPrs(results).length > 0
    const lines = [
      ...runs.map(r => ({ key: `run-${r.pipeline}-${r.issue}-${r.variant ?? ''}`, text: runLine(r, Date.now()), color: undefined as string | undefined })),
      ...results.map(r => ({ key: `res-${r.key}`, text: resultLine(r), color: r.ok ? 'success' : 'error' })),
    ]
    if (lines.length > 0) {
      const { page, pages } = pageOf(await read($, pageAtom), lines.length, PAGE_ROWS)
      const visible = lines.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS)
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box gap={2} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body}>
              <Text bold color="claude">Corridas{` · ${runs.length} activas`}</Text>
              {visible.map(l => (
                <Text key={l.key} color={l.color} wrap="truncate-end">{clip(l.text, body)}</Text>
              ))}
              {Array.from({ length: Math.max(0, PAGE_ROWS - visible.length) }, (_, i) => (
                <Text key={`blank-${i}`}> </Text>
              ))}
              <Box justifyContent="space-between">
                {results.length > 0 ? (
                  <Box>
                    {hasPrs && (
                      <Button key="pact-merge" hotkey="1" plain dimColor label="1 mergear"
                        onPress={() => void mergePrs($)} />
                    )}
                    {hasPrs && (
                      <Button key="pact-view-pr" hotkey="2" plain dimColor label=" · 2 ver PR"
                        onPress={() => void viewPr($)} />
                    )}
                    <Button key="pact-dismiss" hotkey="4" plain dimColor label={`${hasPrs ? ' · ' : ''}4 descartar`}
                      onPress={() => void dismissResults($)} />
                  </Box>
                ) : (
                  <Text dimColor> </Text>
                )}
                {pages > 1 && (
                  <Button key="pact-next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
                    onPress={() => void update($, pageAtom, () => (page + 1) % pages)} />
                )}
              </Box>
            </Box>
          </Box>
        </Box>
      )
    }
    const list = await read($, listAtom)
    if (!list) void refresh($)
    const { page, pages } = pageOf(await read($, pageAtom), list?.items.length ?? 0, PAGE_ROWS)
    const visible = list?.items.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS) ?? []
    const numWidth = String(list?.items.length ?? 0).length + 2
    const footerRest = list ? footerRestOf(list, Boolean(list.launch || list.parallel?.launch) || openPrs.length > 0) : ''
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
        <Box gap={2} alignItems="flex-start">
          {mascot}
          <Box flexDirection="column" width={body}>
            <Text bold color="claude">Lanzables{list && !list.error ? ` · ${list.items.length}` : ''}</Text>
            {!list && <Text dimColor>cargando…</Text>}
            {list?.error && <Text color="error">next-order falló: {clip(list.error, body - 20)}</Text>}
            {list && !list.error && visible.length === 0 && <Text dimColor>Sin issues lanzables</Text>}
            {visible.map((item, i) => (
              <Button key={`row-${item.number}`} hotkey={ROW_KEYS[i] as string} plain dimColor={page > 0 || i > 0}
                label={rowText(item, page * PAGE_ROWS + i + 1, numWidth, Math.max(12, body - numWidth - 24), Number(ROW_KEYS[i]))}
                onPress={() => void launchRow($, item.number)} />
            ))}
            {Array.from({ length: Math.max(0, PAGE_ROWS - Math.max(visible.length, 1)) }, (_, i) => (
              <Text key={`blank-${i}`}> </Text>
            ))}
            <Box justifyContent="space-between">
              <Box>
                {list?.launch && (
                  <Button key="pact-sequential" hotkey="1" plain dimColor label="1 sequential"
                    onPress={() => void launchKey($, 'sequential')} />
                )}
                {list?.parallel?.launch && (
                  <Button key="pact-parallel" hotkey="2" plain dimColor label={`${list.launch ? ' · ' : ''}2 parallel ${list.parallel.issues.length}`}
                    onPress={() => void launchKey($, 'parallel')} />
                )}
                {openPrs.length > 0 && (
                  <Button key="pact-open-prs" hotkey="3" plain dimColor
                    label={`${list?.launch || list?.parallel?.launch ? ' · ' : ''}3 PRs ${openPrs.length}`}
                    onPress={() => void mergeOpenPrs($)} />
                )}
                <Text dimColor>{footerRest}</Text>
              </Box>
              {pages > 1 && (
                <Button key="pact-next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
                  onPress={() => void update($, pageAtom, () => (page + 1) % pages)} />
              )}
            </Box>
          </Box>
        </Box>
      </Box>
    )
  })
}
