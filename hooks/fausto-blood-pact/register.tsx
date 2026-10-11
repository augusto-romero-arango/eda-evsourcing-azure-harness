import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { RASTER_ROWS, ROLES, face, sprite, toRasterCells, waitingFace } from '../sprites'
import type { Role } from '../sprites'
import { cropGrid, numberWidth, padEnd, reasonOf, usedColumns } from '../logic'
import type { BoardList, PactMerge, PipelineResult, PipelineRun } from '../types'
import type { BatchStatus, LastEvent, LaunchKind, LaunchPlan, MascotPose, OpenPr } from './logic'
import {
  LOGS_DIR,
  activeRunOf,
  bandViewOf,
  resultsFooterText,
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
  rowParts,
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
  batchTitleOf,
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
  MERGE_POLL_MS,
  finishMerge,
  mergeRunArgsOf,
  mergePrsOf,
  mergeRibbonHeader,
  mergeRibbonLine,
  mergeRibbonRows,
  mergeRibbonShown,
  mergeSummaryText,
  withMerged,
} from './logic'
import { shouldRearm, versionLabel } from '../logic'
import type { ResultPr } from './logic'

const POLL_MS = 60_000
const STATE_DIR = '.mefisto/pipeline'
const SCRIPT_TIMEOUT_MS = 180_000

const activeAtom = atom({ plugin: 'mefisto', key: 'pactIsActive' } as const, false)
const listAtom = atom({ plugin: 'mefisto', key: 'pactList' } as const, null)
const pageAtom = atom({ plugin: 'mefisto', key: 'pactPage' } as const, 0)
const runsAtom = atom({ plugin: 'mefisto', key: 'pactRuns' } as const, [] as PipelineRun[])
const resultsAtom = atom({ plugin: 'mefisto', key: 'pactResults' } as const, [] as PipelineResult[])
const lastEventAtom = atom({ plugin: 'mefisto', key: 'pactLastEvent' } as const, null as LastEvent | null)
const openPrsAtom = atom({ plugin: 'mefisto', key: 'pactOpenPrs' } as const, [] as OpenPr[])
const batchAtom = atom({ plugin: 'mefisto', key: 'pactBatch' } as const, null as BatchStatus | null)
const mergeAtom = atom({ plugin: 'mefisto', key: 'pactMerge' } as const, null as PactMerge | null)
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
let isHealing = false
let healTimer: { cancel: () => void } | null = null
const HEAL_MS = 1_000
let isRefreshing = false
let timer: { cancel: () => void } | null = null
let runsTimer: { cancel: () => void } | null = null
let tickTimer: { cancel: () => void } | null = null
let prTimer: { cancel: () => void } | null = null
let isCheckingPrs = false
let isRefreshingOpenPrs = false
let isRefreshingRuns = false
let mergeTimer: { cancel: () => void } | null = null
let isPollingMerge = false
// La llamada Bash a pr-sync.sh ya empezo; sin verla, el reloj cierra la cinta arrancada por teclas a los MERGE_STALE_MS.
let isMergeScriptSeen = false
let mergeStartedMs = 0
const MERGE_STALE_MS = 60_000
// Corridas que esta sesion vio activas y resultados `✓` ya derivados; viven aqui porque /clear reinicia los atoms.
let seenRuns: Record<string, PipelineRun> = {}
let carriedResults: PipelineResult[] = []
let runsRepo = ''
// Ultimo estado del lote leido: base para anunciar con un toast cada issue que pasa a `mergeado`.
let lastBatchIssues: BatchStatus['issues'] | null = null
// Titulos del lote en curso (del historial, leido solo cuando aparece un issue terminado sin titulo); se reinician al cambiar el `started` del lote.
let batchTitles: Record<number, string> = {}
let batchTitlesFor = ''
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

const versionAtom = atom({ plugin: 'mefisto', key: 'pactVersion' } as const, null as string | null)

async function loadVersion($: EngineInterface) {
  const root = await pluginRoot($)
  const base = root ? root.replace(/\/+$/, '') : null
  const read1 = async (file: string) => (base ? await $.fs.read(`${base}/${file}`).catch(() => null) : null)
  const label = versionLabel(await read1('mefisto-manifest.json'), await read1('.claude-plugin/plugin.json'))
  await update($, versionAtom, () => label)
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

// Lector puro: solo lee `.mefisto/pipeline/` del checkout principal; la ruta legada se ignora (MEF-ADR-0053).
async function readRuns($: EngineInterface): Promise<PipelineRun[]> {
  const cwd = await $.session.cwd()
  const common = await $.process.run(['git', 'rev-parse', '--git-common-dir']).catch(() => ({ exitCode: 1, stdout: '' }))
  const dir = stateDirOf(common.exitCode === 0 ? common.stdout.trim() : '.git', cwd)
  runsRepo = repoRootOf(dir)
  const ls = await $.process.run(['ls', dir]).catch(() => ({ exitCode: 1, stdout: '' }))
  if (ls.exitCode !== 0) return []
  const runs: PipelineRun[] = []
  for (const name of ls.stdout.split('\n')) {
    const file = name.trim()
    if (!file.startsWith('pipeline-status-')) continue
    const raw = await $.fs.read(`${dir}/${file}`).catch(() => '')
    const run = typeof raw === 'string' ? parseStatus(file, raw) : null
    if (run) runs.push(run)
  }
  return runs
}

// Ultimo evento del ultimo intento del agente activo; lector puro de `<estado>/logs/*.events.jsonl`.
async function readLastEvent($: EngineInterface, run: PipelineRun | null): Promise<LastEvent | null> {
  if (!run) return null
  const dir = `${runsRepo}/${STATE_DIR}/${LOGS_DIR}`
  const ls = await $.process.run(['ls', dir]).catch(() => ({ exitCode: 1, stdout: '' }))
  if (ls.exitCode !== 0) return null
  const file = eventsFileOf(run, ls.stdout.split('\n'))
  if (!file) return null
  const tail = await $.process.run(['tail', '-c', '65536', `${dir}/${file}`]).catch(() => ({ exitCode: 1, stdout: '' }))
  return tail.exitCode === 0 ? lastEventOf(tail.stdout) : null
}

// Solo `.mefisto/pipeline/` (MEF-ADR-0053): la ruta legada ya no la escribe ningun pipeline.
async function readHistory($: EngineInterface): Promise<string> {
  const raw = await $.fs.read(`${runsRepo}/${STATE_DIR}/${HISTORY_FILE}`).catch(() => '')
  return typeof raw === 'string' ? raw : ''
}

// Lector puro del status del lote (#2202); un lote terminado y cerrado (clave repo + `started` en el store) no se muestra.
async function readBatch($: EngineInterface): Promise<BatchStatus | null> {
  const raw = await $.fs.read(batchStatusPath(`${runsRepo}/${STATE_DIR}`)).catch(() => '')
  return typeof raw === 'string' && raw !== '' ? parseBatchStatus(raw) : null
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
  if (batchTitlesFor !== batch.started) {
    batchTitles = {}
    batchTitlesFor = batch.started
  }
  const finished = (i: BatchStatus['issues'][number]) => i.status !== 'pendiente' && i.status !== 'en-curso'
  if (batch.issues.some(i => finished(i) && batchTitles[i.issue] === undefined)) {
    const entries = parseHistory(await readHistory($))
    for (const i of batch.issues) {
      if (!finished(i) || batchTitles[i.issue] !== undefined) continue
      const t = batchTitleOf(entries, i.issue, batch.started)
      batchTitles[i.issue] = t ?? ''
    }
  }
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

// La cinta de merge: arranca con las teclas o al ver la llamada Bash a pr-sync.sh --merge; con --all la lista sale de los PRs abiertos de ese momento.
async function startMerge($: EngineInterface, args: string) {
  const current = await read($, mergeAtom)
  if (current && current.finishedMs === null) return
  let open = await read($, openPrsAtom)
  if (/(^|\s)--all(\s|$)/.test(args)) {
    const listed = await $.process.run(['gh', ...OPEN_PRS_ARGS]).catch(() => ({ exitCode: 1, stdout: '' }))
    if (listed.exitCode === 0) open = parseOpenPrs(listed.stdout)
  }
  const prs = mergePrsOf(args, open)
  if (prs.length === 0) return
  isMergeScriptSeen = false
  mergeStartedMs = Date.now()
  await update($, mergeAtom, () => ({ prs, startedMs: mergeStartedMs, finishedMs: null }))
}

async function pollMerge($: EngineInterface) {
  if (isPollingMerge) return
  isPollingMerge = true
  try {
    const run = await read($, mergeAtom)
    if (!run || run.finishedMs !== null) return
    const pending = run.prs.filter(p => p.estado === 'pendiente').map(p => p.num)
    const states = await Promise.all(
      pending.map(n => $.process.run(['gh', 'pr', 'view', n, '--json', 'state', '-q', '.state']).catch(() => ({ exitCode: 1, stdout: '' }))),
    )
    const merged = pending.filter((_, i) => states[i]?.exitCode === 0 && states[i]?.stdout.trim() === 'MERGED')
    if (merged.length > 0) await update($, mergeAtom, r => (r ? withMerged(r, merged) : r))
  } finally {
    isPollingMerge = false
  }
}

async function endMerge($: EngineInterface) {
  await pollMerge($)
  const run = await read($, mergeAtom)
  if (!run || run.finishedMs !== null) return
  const done = finishMerge(run, Date.now())
  await update($, mergeAtom, () => done)
  $.ui.toast(mergeSummaryText(done))
  void refreshOpenPrs($)
}

async function closeMerge($: EngineInterface) {
  const run = await read($, mergeAtom)
  if (run && run.finishedMs !== null) await update($, mergeAtom, () => null)
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
  await startMerge($, args)
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

// Reposo: la lista es de todo PR abierto que no es borrador (field notes incluidas); "Todos" pasa `--all`.
async function mergeOpenPrs($: EngineInterface): Promise<string> {
  await refreshOpenPrs($)
  const prs = await read($, openPrsAtom)
  if (prs.length === 0) return 'No hay PRs abiertos.'
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
  await startMerge($, args)
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
  void loadVersion($)
  runsTimer?.cancel()
  // Ritmo rapido solo con corridas activas; sin ellas, `refresh` las relee al ritmo de los listos (CA-5).
  runsTimer = $.clock.every(RUNS_POLL_MS, () => {
    if (Object.keys(seenRuns).length > 0 || lastBatchIssues !== null) void refreshRuns($)
  })
  prTimer?.cancel()
  prTimer = $.clock.every(PR_CHECK_MS, () => void closeMergedPrs($))
  mergeTimer?.cancel()
  mergeTimer = $.clock.every(MERGE_POLL_MS, () => void pollMerge($))
  tickTimer?.cancel()
  // La mascota anima solo con corrida activa o con Claude trabajando; en reposo no hay re-render por segundo.
  tickTimer = $.clock.every(1000, () => {
    if (isAnimating) void update($, tickAtom, () => Math.floor(Date.now() / 1000))
    void closeStaleMerge($)
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
  mergeTimer?.cancel()
  mergeTimer = null
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

// El engine no entrega classic.* a un plugin de tier user y session.start no se repite tras /clear, /resume ni /branch:
// cada segundo se compara la intencion del modulo con el atom y se rearma la banda. Corre desde el reloj, donde escribir esta permitido.
async function heal($: EngineInterface) {
  if (isHealing) return
  isHealing = true
  try {
    if (!shouldRearm({ isEligible, isWanted, isActive: await read($, activeAtom) })) return
    await activate($)
    await $.ui.invalidate('ui.render')
  } finally {
    isHealing = false
  }
}

// Cinta vencida: una arrancada por teclas cuyo skill nunca invoco pr-sync.sh (p. ej. descarto todos los PRs).
async function closeStaleMerge($: EngineInterface) {
  if (!isEligible || !isWanted || isMergeScriptSeen) return
  const run = await read($, mergeAtom)
  if (run && run.finishedMs === null && Date.now() - run.startedMs > MERGE_STALE_MS) await endMerge($)
}

export const register: Register = on => {
  // La senal del merge es la llamada Bash a pr-sync.sh: el plugin carga en tier user y el engine no le entrega classic.*.
  // Convive con el tool.call Bash del tablero (mismo matcher, #2302).
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const mergeArgs = isEligible && isWanted ? mergeRunArgsOf(e.command) : null
    if (mergeArgs === null) return next(e)
    await startMerge($, mergeArgs)
    isMergeScriptSeen = true
    try {
      return await next(e)
    } finally {
      await endMerge($)
    }
  }).catch(($, e, next) => next(e))

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
      description: 'Consola de Fausto: refresh | on | off | ocultar | detener | lanzar | merge | prs | pr',
      argumentHint: '[refresh|on|off|ocultar|detener|lanzar [sequential|parallel|<n>]|merge [<pr>...]|prs|pr [<pr>]]',
      immediate: true,
    })
    if (isWanted) await activate($)
    healTimer ??= $.clock.every(HEAL_MS, () => void heal($))
    await $.ui.invalidate('ui.render')
    return next(e)
  })

  on('command.run', { command: 'fausto-blood-pact' }, async ($, e) => {
    const arg = e.args.trim()
    if (!isEligible) return { text: 'La consola no aplica en esta sesión.' }
    if (arg === 'off') {
      await deactivate($)
      return { text: 'Consola de Fausto apagada.' }
    }
    if (arg === 'ocultar' || arg === 'descartar') {
      const n = await dismissResults($)
      return { text: n > 0 ? `Resultados ocultados: ${n}.` : 'No hay resultados que ocultar.' }
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
    await loadVersion($)
    await refresh($)
    return { text: 'Consola actualizada.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const isActive = await read($, activeAtom)
    if (!isEligible || !isWanted || !isActive || e.props.hasSurvey) return next(e)
    const elements = $.ui.resolve(e)
    const { Box, Text, Button } = elements
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
    const body = Math.max(30, inner - MASCOT_WIDTH - 2)
    const runs = await read($, runsAtom)
    const results = await read($, resultsAtom)
    const batch = await read($, batchAtom)
    const openPrs = await read($, openPrsAtom)
    const mergeRun = await read($, mergeAtom)
    await read($, tickAtom)
    const isWorking = Boolean(e.props.isWorking)
    const sec = Math.floor(Date.now() / 1000)
    const batchRun = batch ? batchRunOf(batch, runs) : null
    const active = batch ? batchRun : activeRunOf(runs)
    // El vencimiento se calcula al dibujar: el render nunca escribe estado. La cinta terminada sigue pidiendo
    // re-render por segundo hasta vencer, asi se oculta a los 15 s sin depender de $.clock.after.
    const ribbon = mergeRibbonShown(batch, mergeRun, Date.now())
    isAnimating = isWorking || active !== null || (batch !== null && isBatchRunning(batch)) || ribbon !== null
    const pose: MascotPose | null = active
      ? poseOfRun(active, await read($, lastEventAtom))
      : batch
        ? { role: 'desarrollador', state: batch.state === 'failed' ? 'error' : isBatchRunning(batch) ? 'pensando' : batch.state === 'completed' ? 'aprobado' : 'pensando' }
        : poseOfResults(results)
    const grid = ribbon
      ? cropGrid(sprite('merge', ribbon.finishedMs === null ? 'cosiendo' : 'listo', ribbon.finishedMs === null ? (sec % 2 === 0 ? 0 : 1) : 0), MASCOT_COLS)
      : pose
      ? mascotGrid(pose, active ? (sec % 2 === 0 ? 0 : 1) : 0)
      : cropGrid(waitingFace(face('normal'), isWorking ? sec : null), MASCOT_COLS)
    const version = await read($, versionAtom)
    const list = await read($, listAtom)
    const listosText = list && !list.error ? ` · listos ${list.items.length}` : ''
    const head = (state: string | null, key: string, stateColor?: string) => (
      <Text key={key} wrap="truncate-end">
        <Text color="claude">mefisto</Text>
        <Text dimColor>{clip(listosText, Math.max(8, body - 8))}</Text>
        {state && (
          <Text color={stateColor} dimColor={!stateColor}>
            {clip(` · ${state}`, Math.max(8, body - 8 - listosText.length))}
          </Text>
        )}
      </Text>
    )
    const raster =
      'Raster' in elements ? (
        <elements.Raster key="mefisto-mascota" columns={MASCOT_WIDTH} rows={RASTER_ROWS} cells={toRasterCells(grid, MASCOT_WIDTH)} />
      ) : (
        <Box width={MASCOT_WIDTH} />
      )
    const mascot = version ? (
      <Box key="mefisto-mascota-version" flexDirection="column" width={MASCOT_WIDTH}>
        {raster}
        <Box width={MASCOT_WIDTH} justifyContent="center">
          <Text dimColor wrap="truncate-end">{version}</Text>
        </Box>
      </Box>
    ) : (
      raster
    )
    if (batch) {
      const running = isBatchRunning(batch)
      const c = batchCounts(batch)
      const pr = batchPrOf(batch)
      const current = batchCurrentOf(batch)
      const others = otherRunsText(runsOutsideBatch(batch, runs).length)
      const queue = batch.issues.map(i => ({ key: `b-${i.issue}`, text: batchIssueLine(i, batchTitles[i.issue], body), dim: i.status === 'saltado' || i.status === 'pendiente' }))
      const { page, pages } = pageOf(await read($, pageAtom), queue.length, PAGE_ROWS)
      const visible = running ? [] : queue.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS)
      const headColor = batch.state === 'failed' ? 'error' : batch.state === 'stopped' || batch.stopRequested ? 'warning' : undefined
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box gap={2} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body}>
              {head(`${batchHeader(batch, Date.now())}${running ? '' : ` · ${batch.state === 'completed' ? 'terminado' : batch.state === 'stopped' ? 'detenido' : 'con fallos'}`}`, 'pact-head', headColor)}
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
                  {withSeparators([
                    canStopBatch(batch) && (
                      <Button key="batch-stop" hotkey="1" plain dimColor label="detener" onPress={() => void confirmStop($)} />
                    ),
                    pr && (
                      <Button key="batch-pr" hotkey="2" plain dimColor label={`ver PR #${pr}`}
                        onPress={() => void viewBatchPr($)} />
                    ),
                    !running && (
                      <Button key="batch-close" hotkey="4" plain dimColor label="cerrar" onPress={() => void closeBatch($)} />
                    ),
                  ], Text)}
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
    if (ribbon) {
      const rows = mergeRibbonRows(ribbon)
      const shown = rows.length > PAGE_ROWS ? PAGE_ROWS - 1 : PAGE_ROWS
      const visible = rows.slice(0, shown)
      const hidden = rows.length - visible.length
      const finished = ribbon.finishedMs !== null
      const header = mergeRibbonHeader(ribbon, Date.now())
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box gap={2} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body}>
              {head(header, 'pact-head')}
              {visible.map(p => (
                <Text key={`m-${p.num}`} color={p.estado === 'mergeado' ? 'success' : p.estado === 'fallido' ? 'error' : undefined} dimColor={p.estado === 'pendiente'} wrap="truncate-end">
                  {mergeRibbonLine(p, body)}
                </Text>
              ))}
              {hidden > 0 && <Text dimColor>{`+${hidden} más`}</Text>}
              {Array.from({ length: Math.max(0, PAGE_ROWS - visible.length - (hidden > 0 ? 1 : 0)) }, (_, i) => (
                <Text key={`blank-${i}`}> </Text>
              ))}
              <Box>
                {finished ? (
                  <Button key="merge-close" hotkey="4" plain dimColor label="cerrar" onPress={() => void closeMerge($)} />
                ) : (
                  <Text dimColor> </Text>
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
    if (bandViewOf(runs, results) === 'runs') {
      const { page, pages } = pageOf(await read($, pageAtom), lines.length, PAGE_ROWS)
      const visible = lines.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS)
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box gap={2} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body}>
              {head(`corridas ${runs.length} activas`, 'pact-head')}
              {visible.map(l => (
                <Text key={l.key} color={l.color} wrap="truncate-end">{clip(l.text, body)}</Text>
              ))}
              {Array.from({ length: Math.max(0, PAGE_ROWS - visible.length) }, (_, i) => (
                <Text key={`blank-${i}`}> </Text>
              ))}
              <Box justifyContent="space-between">
                {results.length > 0 ? (
                  <Box>
                    {withSeparators([
                      hasPrs && (
                        <Button key="pact-merge" hotkey="1" plain dimColor label="mergear"
                          onPress={() => void mergePrs($)} />
                      ),
                      hasPrs && (
                        <Button key="pact-view-pr" hotkey="2" plain dimColor label="ver PR"
                          onPress={() => void viewPr($)} />
                      ),
                      <Button key="pact-dismiss" hotkey="4" plain dimColor label="ocultar"
                        onPress={() => void dismissResults($)} />,
                    ], Text)}
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
    if (!list) void refresh($)
    const { page, pages } = pageOf(await read($, pageAtom), list?.items.length ?? 0, PAGE_ROWS)
    const visible = list?.items.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS) ?? []
    const numWidth = numberWidth(visible)
    const afterWidth = Math.min(16, Math.max(0, ...visible.map(i => reasonOf(i).length)))
    const titleWidth = Math.max(12, body - 3 - 2 - numWidth - 1 - (afterWidth > 0 ? afterWidth + 2 : 0))
    const footerRest = list ? footerRestOf(list, Boolean(list.launch || list.parallel?.launch)) : ''
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
        <Box gap={2} alignItems="flex-start">
          {mascot}
          <Box flexDirection="column" width={body}>
            <Box justifyContent="space-between">
              {head(null, 'pact-head')}
              {openPrs.length > 0 && (
                <Box gap={2}>
                  <Button key="pact-open-prs" hotkey="2" plain dimColor label={`PRs ${openPrs.length}`}
                    onPress={() => void mergeOpenPrs($)} />
                </Box>
              )}
            </Box>
            {!list && <Text dimColor>cargando…</Text>}
            {list?.error && <Text color="error">next-order falló: {clip(list.error, body - 20)}</Text>}
            {list && !list.error && visible.length === 0 && <Text dimColor>Sin issues en estado:listo.</Text>}
            {visible.map((item, i) => {
              const row = rowParts(item, numWidth, titleWidth)
              return (
                <Box key={`row-${item.number}`}>
                  <Text color={row.color}>{`${row.letter} `}</Text>
                  <Button hotkey={ROW_KEYS[i] as string} plain dimColor={page > 0 || i > 0}
                    label={afterWidth > 0 ? padEnd(row.label, numWidth + 1 + titleWidth) : row.label}
                    onPress={() => void launchRow($, item.number)} />
                  <Text dimColor>{row.after ? `  ${clip(row.after, afterWidth)}` : ''}</Text>
                </Box>
              )
            })}
            {Array.from({ length: Math.max(0, PAGE_ROWS - Math.max(visible.length, 1)) }, (_, i) => (
              <Text key={`blank-${i}`}> </Text>
            ))}
            {results.length > 0 && (
              <Box>
                <Text dimColor wrap="truncate-end">{resultsFooterText(results, Math.max(12, body - 12))}</Text>
                <Text dimColor> · </Text>
                <Button key="pact-dismiss" hotkey="4" plain dimColor label="ocultar" onPress={() => void dismissResults($)} />
              </Box>
            )}
            <Box justifyContent="space-between">
              <Box>
                {withSeparators([
                  list?.launch && (
                    <Button key="pact-sequential" hotkey="1" plain dimColor label="sequential"
                      onPress={() => void launchKey($, 'sequential')} />
                  ),
                  list?.parallel?.launch && (
                    <Button key="pact-parallel" hotkey="p" plain dimColor label={`parallel ${list.parallel.issues.length}`}
                      onPress={() => void launchKey($, 'parallel')} />
                  ),
                ], Text)}
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

/** Intercala ` · ` (fuera de los botones) solo entre elementos visibles; descarta los falsos. */
function withSeparators(items: unknown[], Text: any): unknown[] {
  const shown = items.filter(Boolean)
  return shown.flatMap((el, i) => (i === 0 ? [el] : [<Text key={`sep-${i}`} dimColor> · </Text>, el]))
}
