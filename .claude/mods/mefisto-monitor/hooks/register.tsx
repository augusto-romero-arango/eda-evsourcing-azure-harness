import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BatchRun, LogLine, MonitorRun, ReadyList } from '../types'
import {
  BATCH_STATUS,
  BATCH_STOP,
  HISTORY,
  LOG_DIR,
  NEXT_ORDER,
  PLANNER_AGENT,
  READY_ROWS,
  agentFlagOf,
  agentOfEventsFile,
  batchCounts,
  batchFromStatus,
  batchIssuesOf,
  batchPr,
  batchSummary,
  clip,
  elapsed,
  cropGrid,
  finishedFromHistory,
  fmtCost,
  issueStatsFromHistory,
  statsTotal,
  issueMark,
  mascotPose,
  mergeArgsOf,
  mergeOptions,
  newlyMerged,
  padEnd,
  pageOf,
  parseNextOrder,
  parseOpenPrs,
  readyRows,
  sequentialOf,
  titlesOf,
  toolingOf,
  waitingFace,
  parseEvent,
  pickEventsFile,
  prNumber,
  runFromStatus,
  statusPath,
  steps,
  toolingIssueOf,
  usedColumns,
  withModUi,
} from './logic'
import { DEFAULT_COLOR, HEIGHT, PALETTE, RASTER_ROWS, face, sprite } from './sprites'

const PANE = 'mefisto-monitor'
const MAX_LINES = 200
const STATUS_GRACE_MS = 30_000
// Un seguimiento que tras este tiempo sigue en setup sin status ni historial no corresponde a ninguna corrida.
const ORPHAN_MS = 120_000
const PANE_ROWS = 16
const FIXED_ROWS = 7
const PR_CHECK_MS = 15_000
const READY_POLL_MS = 60_000
const BAND_LOG_ROWS = 3
const STATS_EVERY_MS = 5_000
const SCRIPT_TIMEOUT_MS = 180_000

// Recorte comun a todos los cuadros que usa el monitor, calculado una vez: sin margen y sin saltos al alternar.
const MASCOT_POSES = [
  ['desarrollador', 'trabajando'],
  ['desarrollador', 'pensando'],
  ['desarrollador', 'error'],
  ['revisor', 'trabajando'],
  ['revisor', 'pensando'],
  ['revisor', 'corrigiendo'],
  ['revisor', 'aprobado'],
] as const
const MASCOT_COLS = usedColumns([
  ...MASCOT_POSES.flatMap(([role, state]) => [sprite(role, state, 0), sprite(role, state, 1)]),
  face('normal'),
])
const MASCOT_WIDTH = MASCOT_COLS.to - MASCOT_COLS.from + 1

/** Celdas del Raster (dos pixeles por celda con ▀/▄), como toRasterCells de sprites.ts pero con el ancho recortado. */
function mascotCells(grid: readonly string[]): string {
  const color = (ch: string | undefined) => (!ch || ch === '.' || ch === ' ' ? null : (PALETTE[ch] ?? null))
  const words: number[] = []
  for (let y = 0; y < HEIGHT; y += 2) {
    for (let x = 0; x < MASCOT_WIDTH; x++) {
      const top = color(grid[y]?.[x])
      const bottom = color(grid[y + 1]?.[x])
      if (top !== null) words.push(0x2580, top, bottom ?? DEFAULT_COLOR)
      else if (bottom !== null) words.push(0x2584, bottom, DEFAULT_COLOR)
      else words.push(0x20, DEFAULT_COLOR, DEFAULT_COLOR)
    }
  }
  let bin = ''
  for (const b of new Uint8Array(Uint32Array.from(words).buffer)) bin += String.fromCharCode(b)
  return btoa(bin)
}

const runAtom = atom({ plugin: 'mefisto-monitor', key: 'run' } as const, null)
const linesAtom = atom({ plugin: 'mefisto-monitor', key: 'lines' } as const, [])
const nowAtom = atom({ plugin: 'mefisto-monitor', key: 'now' } as const, 0)
const executionAtom = atom({ plugin: 'mefisto-monitor', key: 'isExecutionSession' } as const, false)
const readyAtom = atom({ plugin: 'mefisto-monitor', key: 'ready' } as const, null)
const readyPageAtom = atom({ plugin: 'mefisto-monitor', key: 'readyPage' } as const, 0)
const batchAtom = atom({ plugin: 'mefisto-monitor', key: 'batch' } as const, null)
const openPrsAtom = atom({ plugin: 'mefisto-monitor', key: 'openPrs' } as const, null)

type Tail = { path: string; stream: AsyncGenerator<unknown, unknown> }

let tail: Tail | null = null
let watchSinceMs = 0
let batchSinceMs = 0
let lastStatsReadMs = 0
let isPolling = false
// Una sesion no interactiva (los agentes de los pipelines) no tiene a nadie mirando: el mod no reescribe ni sigue nada.
let isInteractive = false
let lastPrCheckMs = 0
let isLogOpen = false
let isRefreshingReady = false
let readyTimer: { cancel: () => void } | null = null

async function stopTail() {
  const current = tail
  tail = null
  if (current) await current.stream.return(undefined).catch(() => undefined)
}

async function pushLines($: EngineInterface, added: LogLine[]) {
  if (added.length === 0) return
  await update($, linesAtom, list => [...(list ?? []), ...added].slice(-MAX_LINES))
}

async function followTail($: EngineInterface, stream: AsyncGenerator<unknown, unknown>, path: string) {
  let pending = ''
  try {
    for await (const chunk of stream) {
      if (tail?.stream !== stream) break
      const { stream: kind, text } = chunk as { stream: string; text: string }
      if (kind !== 'stdout') continue
      pending += text
      const rows = pending.split('\n')
      pending = rows.pop() ?? ''
      await pushLines($, rows.map(parseEvent).filter((l): l is LogLine => l !== null))
    }
  } catch (err) {
    $.ui.log(`tail ${path}: ${String(err)}`, { to: 'debug' })
  }
}

async function startTail($: EngineInterface, name: string) {
  await stopTail()
  const path = `${LOG_DIR}/${name}`
  const stream = $.process.spawn({ argv: ['tail', '-n', '40', '-F', path] })
  tail = { path, stream }
  await pushLines($, [{ ts: '', kind: 'start', text: `── ${agentOfEventsFile(name)} ──` }])
  void followTail($, stream, path)
}

// En un batch cada eslabon se sigue igual que un /mefisto-tooling suelto, pero el log acumula todos los issues.
async function watch($: EngineInterface, issue: string, sinceMs: number, keepLines = false) {
  await stopTail()
  watchSinceMs = sinceMs
  const run: MonitorRun = {
    issue,
    title: '',
    stage: 'setup',
    state: 'running',
    startedMs: Date.now(),
    finishedMs: null,
    agents: {},
    pr: null,
    lastError: null,
    eventsFile: null,
  }
  await update($, runAtom, () => run)
  if (keepLines) await pushLines($, [{ ts: '', kind: 'start', text: `══ #${issue} ══` }])
  else await update($, linesAtom, () => [])
  await poll($)
}

async function watchBatch($: EngineInterface, issues: string[], sinceMs: number) {
  await stopTail()
  batchSinceMs = sinceMs
  const batch: BatchRun = {
    issues: issues.map(issue => ({ issue, status: 'pendiente', pr: null })),
    state: 'running',
    current: null,
    stopRequested: false,
    holdSeconds: 0,
    startedMs: Date.now(),
    finishedMs: null,
    stats: {},
  }
  await update($, runAtom, () => null)
  await update($, linesAtom, () => [])
  await update($, batchAtom, () => batch)
}

// Duracion y costo de cada terminado: se leen del historial cuando aparece uno que todavia no los tiene, a lo
// sumo cada STATS_EVERY_MS (un fallido antes de escribir su historial no los tendra nunca).
async function withStats($: EngineInterface, batch: BatchRun): Promise<BatchRun> {
  const stats = batch.stats ?? {}
  const missing = batch.issues.filter(i => ['done', 'failed'].includes(issueMark(i.status)) && !stats[i.issue])
  if (missing.length === 0 || Date.now() - lastStatsReadMs < STATS_EVERY_MS) return batch
  lastStatsReadMs = Date.now()
  const { stdout } = await $.process.run(['tail', '-n', '200', HISTORY]).catch(() => ({ stdout: '' }))
  return { ...batch, stats: { ...stats, ...issueStatsFromHistory(stdout, missing.map(i => i.issue), batch.startedMs) } }
}

async function pollBatch($: EngineInterface) {
  const batch = await read($, batchAtom)
  if (!batch) return
  if (batch.state !== 'running') {
    const filled = await withStats($, batch)
    if (filled !== batch) await update($, batchAtom, () => filled)
    return
  }
  let next = batch
  if (await $.fs.exists(BATCH_STATUS)) next = batchFromStatus(await $.fs.read(BATCH_STATUS).catch(() => ''), batch, batchSinceMs)
  next = { ...next, stopRequested: next.stopRequested || (await $.fs.exists(BATCH_STOP)) }
  for (const i of newlyMerged(batch.issues, next.issues)) $.ui.toast(`#${i.issue} mergeado${i.pr ? ` · PR #${i.pr}` : ''}`)
  next = await withStats($, next)
  const settled = next
  await update($, batchAtom, () => settled)
  const run = await read($, runAtom)
  if (settled.current && settled.current !== run?.issue) await watch($, settled.current, settled.startedMs, true)
  const c = batchCounts(settled.issues)
  if (settled.state === 'running') {
    $.ui.status(`mefisto · sequential ${c.done + c.failed}/${c.total}${settled.current ? ` · #${settled.current}` : ''}`)
    return
  }
  await stopTail()
  $.ui.toast(`sequential terminado: ${batchSummary(settled)}`)
  $.ui.status(settled.state === 'failed' ? `mefisto · sequential con fallos` : undefined)
}

// Parada suave: la misma senal que /mefisto-batch-stop. Termina el eslabon en curso (con su merge) y no sigue.
async function requestStop($: EngineInterface) {
  await $.fs.write(BATCH_STOP, '')
  await update($, batchAtom, b => (b ? { ...b, stopRequested: true } : b))
  $.ui.toast('parada pedida: termina el issue en curso y no arranca los siguientes')
}

async function finish($: EngineInterface, run: MonitorRun) {
  await stopTail()
  if (run.state === 'completed') {
    const pr = prNumber(run.pr)
    $.ui.toast(pr ? `#${run.issue} terminó · PR #${pr} listo` : `#${run.issue} terminó`)
    $.ui.status(undefined)
  } else {
    $.ui.toast(`#${run.issue} falló en ${stageName(run.stage)}`)
    $.ui.status(`mefisto · #${run.issue} falló`)
  }
}

async function fromHistory($: EngineInterface, prev: MonitorRun): Promise<MonitorRun> {
  const { stdout } = await $.process.run(['tail', '-n', '50', HISTORY]).catch(() => ({ stdout: '' }))
  const done = finishedFromHistory(stdout, prev.issue, Math.min(prev.startedMs, watchSinceMs))
  if (!done) return prev
  const isFailed = done.state === 'failed'
  return {
    ...prev,
    title: done.title ?? prev.title,
    state: isFailed ? 'failed' : 'completed',
    stage: isFailed ? (done.stage ?? prev.stage) : 'done',
    pr: done.pr ?? null,
    lastError: done.error ?? null,
    finishedMs: Date.now(),
  }
}

async function poll($: EngineInterface) {
  if (isPolling) return
  isPolling = true
  try {
    await update($, nowAtom, () => Date.now())
    await pollBatch($)
    const inBatch = (await read($, batchAtom)) !== null
    const prev = await read($, runAtom)
    if (prev?.state === 'completed' && !inBatch) await closeIfMerged($, prev)
    if (!prev || prev.state !== 'running') return

    let next: MonitorRun = prev
    const status = statusPath(prev.issue)
    if (await $.fs.exists(status)) {
      const raw = await $.fs.read(status).catch(() => '')
      const parsed = runFromStatus(raw, prev)
      if (parsed && !(parsed.state !== 'running' && parsed.startedMs + 1000 < watchSinceMs)) next = parsed
    } else if (watchSinceMs === 0 || Date.now() - watchSinceMs > STATUS_GRACE_MS || prev.stage !== 'setup') {
      next = await fromHistory($, prev)
      if (!inBatch && next === prev && prev.stage === 'setup' && Date.now() - prev.startedMs > ORPHAN_MS) {
        $.ui.log(`mefisto-monitor: #${prev.issue} sin status ni historial tras ${ORPHAN_MS / 60_000} min; se deja de seguir`, { to: 'debug' })
        await closeRun($)
        return
      }
    }

    if (next.state === 'running') {
      const entries = await $.fs.list(LOG_DIR).catch(() => [])
      const name = pickEventsFile(entries, next.issue, Math.min(next.startedMs, watchSinceMs))
      if (name && name !== next.eventsFile) {
        next = { ...next, eventsFile: name }
        await startTail($, name)
      }
      if (!inBatch) $.ui.status(`mefisto · #${next.issue} ${stageName(next.stage)} ${elapsed(Date.now() - next.startedMs)}`)
    }

    const settled = next
    await update($, runAtom, () => settled)
    if (settled.state !== 'running') {
      if (inBatch) await stopTail()
      else await finish($, settled)
    }
  } finally {
    isPolling = false
  }
}

// El PR mergeado da la corrida por terminada: venga del boton, de /mefisto-merge tecleado o de GitHub.
async function closeIfMerged($: EngineInterface, run: MonitorRun) {
  const pr = prNumber(run.pr)
  if (!pr || Date.now() - lastPrCheckMs < PR_CHECK_MS) return
  lastPrCheckMs = Date.now()
  const { exitCode, stdout } = await $.process
    .run(['gh', 'pr', 'view', pr, '--json', 'state', '-q', '.state'])
    .catch(() => ({ exitCode: 1, stdout: '' }))
  if (exitCode !== 0 || stdout.trim() !== 'MERGED') return
  await closeRun($)
  $.ui.toast(`PR #${pr} mergeado · monitor de #${run.issue} cerrado`)
}

async function openPane($: EngineInterface, isFocused = false) {
  isLogOpen = true
  return $.ui.open({ id: PANE, title: 'mefisto', rows: PANE_ROWS, ...(isFocused ? { focus: true as const } : {}) })
}

async function closeLog($: EngineInterface) {
  isLogOpen = false
  await $.ui.close({ id: PANE })
}

// La tecla 3 de la banda abre el log o, si ya estaba abierto, lo cierra.
async function toggleLog($: EngineInterface) {
  if (isLogOpen) await closeLog($)
  else await openPane($, true)
}

async function closeRun($: EngineInterface) {
  await stopTail()
  await update($, batchAtom, () => null)
  await update($, runAtom, () => null)
  await update($, linesAtom, () => [])
  $.ui.status(undefined)
  await $.ui.close({ id: PANE })
  void refreshReady($)
}

async function openPr($: EngineInterface) {
  const run = await read($, runAtom)
  const batch = await read($, batchAtom)
  const pr = batch ? batchPr(batch) : prNumber(run?.pr ?? null)
  if (pr) await $.process.run(['gh', 'pr', 'view', pr, '--web']).catch(() => undefined)
}

async function merge($: EngineInterface) {
  const run = await read($, runAtom)
  const pr = prNumber(run?.pr ?? null)
  if (!pr) return
  const answer = await $.ui
    .ask(`¿Mergear el PR #${pr} con /mefisto-merge?`, ['Mergear', 'Cancelar'])
    .catch(() => 'Cancelar')
  if (answer !== 'Mergear') return
  $.ui.toast(`/mefisto-merge ${pr} en cola: el monitor se cierra cuando el PR quede mergeado`)
  lastPrCheckMs = 0
  await $.command.run({ command: 'mefisto-merge', args: pr })
}

// La sesion de ejecucion es cualquier sesion interactiva que no sea la del planner: el planner no lanza
// trabajo (su tablero deja los listos en solo lectura). Se lee el --agent de la linea de comando del
// proceso de Claude Code, padre del `sh` que corre aqui; si no se puede leer, la sesion cuenta como de ejecucion.
async function detectExecution($: EngineInterface) {
  const ps = await $.process.run(['sh', '-c', 'ps -o args= -p "$PPID"']).catch(() => ({ exitCode: 1, stdout: '' }))
  const cmdline = ps.exitCode === 0 ? ps.stdout.trim() : ''
  if (agentFlagOf(cmdline) === PLANNER_AGENT) return
  await update($, executionAtom, () => true)
  readyTimer?.cancel()
  readyTimer = $.clock.every(READY_POLL_MS, () => void refreshReady($))
  void refreshReady($)
}

async function refreshReady($: EngineInterface) {
  if (isRefreshingReady || !(await read($, executionAtom))) return
  isRefreshingReady = true
  try {
    const [order, listos, prs] = await Promise.all([
      $.process
        .run([NEXT_ORDER, '--json'], { timeoutMs: SCRIPT_TIMEOUT_MS })
        .catch(err => ({ exitCode: 2, stdout: '', stderr: String(err) })),
      $.process
        .run(['gh', 'issue', 'list', '--state', 'open', '--label', 'estado:listo', '--limit', '200', '--json', 'number,title'])
        .catch(() => ({ exitCode: 1, stdout: '' })),
      $.process
        .run(['gh', 'pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,isDraft'])
        .catch(() => ({ exitCode: 1, stdout: '' })),
    ])
    const openPrs = prs.exitCode === 0 ? parseOpenPrs(prs.stdout) : null
    await update($, openPrsAtom, () => openPrs)
    const ready: ReadyList = parseNextOrder(order.exitCode, order.stdout, order.stderr, titlesOf(listos.stdout))
    await update($, readyAtom, () => ready)
  } finally {
    isRefreshingReady = false
  }
}

// La banda escribe el comando sin Enter: se lanza a mano, con la opcion de ajustarlo antes.
async function fill($: EngineInterface, text: string) {
  await $.prompt.fill({ text, mode: 'replace' })
}

// Las confirmaciones van en el dialogo nativo, abajo junto al prompt; la banda queda para informar. Esc cancela.
const WITH_MERGE = 'Con merge (sequential)'
const ONLY_PR = 'Solo PR (tooling)'

async function choose($: EngineInterface, issue: number) {
  const answer = await $.ui
    .ask(`¿Cómo desarrollar #${issue}?`, { header: 'Lanzar', options: [WITH_MERGE, ONLY_PR] })
    .catch(() => null)
  if (answer === WITH_MERGE) await fill($, sequentialOf(issue))
  else if (answer === ONLY_PR) await fill($, toolingOf(issue))
}

// Mergear desde la espera: todos o los PRs elegidos; en la opcion de texto se escriben otros numeros. Elegir en el
// dialogo ya es la aprobacion, asi que /mefisto-merge se ejecuta de una vez.
async function chooseMerge($: EngineInterface) {
  const prs = (await read($, openPrsAtom)) ?? []
  if (prs.length === 0) return
  const options = mergeOptions(prs)
  const answer = await $.ui
    .ask(`¿Qué mergear? ${prs.length} PRs abiertos${prs.length > 3 ? ' (otros números: escríbelos en la opción de texto)' : ''}`, {
      header: 'Merge',
      options,
      ...(prs.length > 1 ? { multiSelect: true as const } : {}),
    })
    .catch(() => null)
  const args = answer === null ? null : mergeArgsOf(answer, options)
  if (!args) return
  $.ui.toast(`/mefisto-merge ${args} en cola`)
  await $.command.run({ command: 'mefisto-merge', args })
}

async function confirmStop($: EngineInterface) {
  const current = (await read($, batchAtom))?.current
  const answer = await $.ui
    .ask(`¿Detener el sequential tras ${current ? `#${current}` : 'el issue en curso'}?`, {
      header: 'Detener',
      options: ['Detener tras el actual', 'Seguir'],
    })
    .catch(() => null)
  if (answer === 'Detener tras el actual') await requestStop($)
}

async function nextReadyPage($: EngineInterface) {
  const ready = await read($, readyAtom)
  const total = ready ? readyRows(ready).length : 0
  await update($, readyPageAtom, p => pageOf((p ?? 0) + 1, total, READY_ROWS).page)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    await $.command.register({
      name: 'mefisto-monitor',
      description: 'Abre el monitor de /mefisto-tooling (con <issue> sigue esa corrida; batch <issues> sigue un sequential; merge | close | refresh)',
      argumentHint: '[issue|batch <issues>|merge|close|refresh]',
      immediate: true,
    })
    // Tras un hot-reload el tail del modulo anterior murio: se fuerza a reabrirlo.
    await update($, runAtom, run => (run && run.state === 'running' ? { ...run, eventsFile: null } : run))
    $.clock.every(1000, () => void poll($))
    if (isInteractive) void detectExecution($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const batchIssues = isInteractive ? batchIssuesOf(e.command) : null
    if (batchIssues && batchIssues.length > 0) {
      const ran = await next({ ...e, command: withModUi(e.command) })
      if (ran.deny === undefined && ran.isError !== true) await watchBatch($, batchIssues, Date.now() - 5_000)
      return ran
    }
    const issue = isInteractive ? toolingIssueOf(e.command) : null
    if (!issue) return next(e)
    const ran = await next({ ...e, command: withModUi(e.command) })
    if (ran.deny === undefined && ran.isError !== true) {
      await watch($, issue, Date.now() - 5_000)
    }
    return ran
  })

  on('command.run', { command: 'mefisto-monitor' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'close') {
      await closeRun($)
      return { text: 'Monitor cerrado.' }
    }
    if (arg === 'refresh') {
      await refreshReady($)
      return { text: 'Listos actualizados.' }
    }
    if (arg === 'merge') {
      await merge($)
      return { text: 'Merge solicitado.' }
    }
    // Reengancha un sequential ya lanzado (tras reiniciar la sesion): `/mefisto-monitor batch 12 13`.
    const batchArgs = /^batch((?:\s+#?\d+)+)$/.exec(arg)
    if (batchArgs?.[1]) {
      const issues = batchArgs[1].match(/\d+/g) ?? []
      await watchBatch($, issues, 0)
      return { text: `Siguiendo el sequential ${issues.map(n => `#${n}`).join(' ')} en la banda.` }
    }
    // La banda sigue la corrida; el pane es solo el log completo y se abre a pedido.
    if (/^#?\d+$/.test(arg)) {
      await watch($, arg.replace('#', ''), 0)
      return { text: `Siguiendo #${arg.replace('#', '')} en la banda.` }
    }
    await openPane($, true)
    return { text: 'Monitor abierto.' }
  })

  // Cerrar el log solo cierra el pane: la banda conserva la corrida (y su PR) hasta que se cierre con 4.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    isLogOpen = false
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const run = await read($, runAtom)
    const batch = await read($, batchAtom)
    if (e.props.hasSurvey) return next(e)
    if (!run && !batch && !(await read($, executionAtom))) return next(e)
    const now = await read($, nowAtom)
    const { Box, Text, Button } = $.ui.resolve(e)
    if (batch) {
      // El sequential: avance y cola arriba, el eslabon en curso abajo con su mascota, pasos y ultimas lineas.
      const lines = await read($, linesAtom)
      const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
      const body = Math.max(30, inner - MASCOT_WIDTH - 2)
      const c = batchCounts(batch.issues)
      const end = batch.finishedMs ?? (now || Date.now())
      const isRunning = batch.state === 'running'
      const pr = batchPr(batch)
      const pose =
        isRunning && run ? mascotPose(run, lines[lines.length - 1])
        : batch.state === 'failed' ? { role: 'desarrollador' as const, state: 'error' }
        : isRunning ? { role: 'desarrollador' as const, state: 'pensando' }
        : { role: 'revisor' as const, state: 'aprobado' }
      const frame = isRunning ? (Math.floor((now || Date.now()) / 1000) % 2 === 0 ? 0 : 1) : 0
      const grid = cropGrid(sprite(pose.role, pose.state, frame), MASCOT_COLS)
      const elements = $.ui.resolve(e)
      const mascot =
        'Raster' in elements ? (
          <elements.Raster key="mefisto-mascota" columns={MASCOT_WIDTH} rows={RASTER_ROWS} cells={mascotCells(grid)} />
        ) : (
          <Box width={MASCOT_WIDTH} />
        )
      const recent = lines.filter(l => l.ts !== '').slice(-3)
      const markText = (m: ReturnType<typeof issueMark>) =>
        m === 'done' ? '✓' : m === 'failed' ? '✗' : m === 'deferred' ? '⏸' : m === 'current' ? '●' : '○'
      const markColor = (m: ReturnType<typeof issueMark>) =>
        m === 'done' ? ('success' as const) : m === 'failed' ? ('error' as const) : m === 'current' ? ('warning' as const) : undefined
      const failedIssue = batch.issues.find(i => issueMark(i.status) === 'failed')
      const doneRows = batch.issues.filter(i => ['done', 'failed'].includes(issueMark(i.status)))
      const stats = batch.stats ?? {}
      const total = statsTotal(doneRows.map(i => stats[i.issue]).filter(st => st !== undefined))
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box justifyContent="space-between">
            <Text wrap="truncate-end">
              <Text color="claude">mefisto</Text>
              <Text> · sequential {c.done + c.failed}/{c.total}</Text>
              {isRunning && batch.stopRequested && <Text color="warning"> · se detiene tras #{batch.current ?? '…'}</Text>}
              {batch.state === 'completed' && <Text color="success"> · terminado</Text>}
              {batch.state === 'stopped' && <Text color="warning"> · detenido</Text>}
              {batch.state === 'failed' && <Text color="error"> · con fallos</Text>}
              <Text dimColor> {elapsed(end - batch.startedMs)}</Text>
            </Text>
            <Box gap={2}>
              {isRunning && !batch.stopRequested && (
                <Button key="batch-stop" hotkey="1" plain label="detener" onPress={() => void confirmStop($)} />
              )}
              {pr && <Button key="batch-pr" hotkey="2" plain label={`ver PR #${pr}`} onPress={() => void openPr($)} />}
              <Button key="batch-log" hotkey="3" plain dimColor={isRunning} label="log" onPress={() => void toggleLog($)} />
              {!isRunning && <Button key="batch-close" hotkey="4" plain label="cerrar" onPress={() => void closeRun($)} />}
            </Box>
          </Box>
          <Box gap={2} height={RASTER_ROWS + 1} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body} marginTop={1}>
              <Text wrap="truncate-end">
                {batch.issues.map((i, k) => {
                  const m = issueMark(i.status)
                  return (
                    <Text color={markColor(m)} dimColor={m === 'pending' || m === 'deferred'}>
                      {k > 0 ? ' ─ ' : ''}
                      {markText(m)} #{i.issue}
                      {m === 'current' && run && run.issue === i.issue ? ` ${stageName(run.stage)}` : ''}
                    </Text>
                  )
                })}
              </Text>
              {isRunning && run && run.title !== '' && <Text dimColor wrap="truncate-end">#{run.issue} {run.title}</Text>}
              {isRunning && run && <Text> </Text>}
              {isRunning && !run && <Text dimColor>preparando el primer issue…</Text>}
              {isRunning &&
                recent.map(line => (
                  <Text wrap="truncate-end" color={lineColor(line)} dimColor={line.kind === 'text'}>
                    {`${line.ts} ${line.kind === 'text' ? '» ' : ''}${line.text}`}
                  </Text>
                ))}
              {!isRunning && <Text wrap="truncate-end">{batchSummary(batch)}</Text>}
              {!isRunning && failedIssue && (
                <Text color="error" wrap="truncate-end">#{failedIssue.issue} {failedIssue.status.replace(/^ERROR:\s*/, '')}</Text>
              )}
            </Box>
          </Box>
          {doneRows.length > 0 && (
            <Box flexDirection="column">
              {doneRows.map(i => {
                const st = stats[i.issue]
                const m = issueMark(i.status)
                return (
                  <Text wrap="truncate-end" color={markColor(m)}>
                    {`${markText(m)} ${padEnd(`#${i.issue}`, 7)} ${padEnd(i.pr ? `PR #${i.pr}` : 'sin PR', 10)} `}
                    <Text dimColor>{st ? `${padEnd(elapsed(st.durationMs), 8)} ${fmtCost(st.costUsd)}` : '…'}</Text>
                  </Text>
                )
              })}
              {doneRows.length > 1 && (
                <Text dimColor wrap="truncate-end">
                  {`  total ${padEnd(String(doneRows.length), 15)} ${padEnd(elapsed(total.durationMs), 8)} ${fmtCost(total.costUsd)}`}
                </Text>
              )}
            </Box>
          )}
        </Box>
      )
    }
    if (!run) {
      const ready = await read($, readyAtom)
      const openPrs = await read($, openPrsAtom)
      const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
      const body = Math.max(30, inner - MASCOT_WIDTH - 2)
      const { page, pages } = pageOf(await read($, readyPageAtom), ready ? readyRows(ready).length : 0, READY_ROWS)
      const rows = ready ? readyRows(ready) : []
      const visible = rows.slice(page * READY_ROWS, (page + 1) * READY_ROWS)
      const numWidth = Math.max(4, ...visible.map(i => String(i.number).length + 1))
      const afterWidth = Math.min(24, Math.max(0, ...visible.map(i => i.reason.length)))
      // El prefijo '5: ' de la tecla, el numero, un espacio y, si alguno depende de otro, la columna 'tras #N'.
      const titleWidth = Math.max(12, body - 3 - numWidth - 1 - (afterWidth > 0 ? afterWidth + 2 : 0))
      const more = ready
        ? [
            ready.cycleCount > 0 ? `${ready.cycleCount} en ciclo` : '',
          ].filter(Boolean).join(' · ')
        : ''
      // En espera de que se lance algo; mientras Claude trabaja en la sesion, mira de lado a lado y corre la arena.
      const tick = e.props.isWorking ? Math.floor((now || Date.now()) / 1000) : null
      const grid = cropGrid(waitingFace(face('normal'), tick), MASCOT_COLS)
      const elements = $.ui.resolve(e)
      const mascot =
        'Raster' in elements ? (
          <elements.Raster key="mefisto-mascota" columns={MASCOT_WIDTH} rows={RASTER_ROWS} cells={mascotCells(grid)} />
        ) : (
          <Box width={MASCOT_WIDTH} />
        )
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Box justifyContent="space-between">
            <Text>
              <Text color="claude">mefisto</Text>
              <Text dimColor> · listos {ready ? readyRows(ready).length : '…'}</Text>
            </Text>
            <Box gap={2}>
              {openPrs && openPrs.length > 0 && (
                <Button key="merge-prs" hotkey="2" plain label={`PRs ${openPrs.length}`} onPress={() => void chooseMerge($)} />
              )}
              {ready?.launch ? (
                <Button key="ready-all" hotkey="1" plain label={clip(ready.launch, inner - 24)} onPress={() => void fill($, ready.launch ?? '')} />
              ) : (
                <Text dimColor>sin batch lanzable</Text>
              )}
            </Box>
          </Box>
          <Box gap={2} height={RASTER_ROWS + 1} alignItems="flex-start">
            {mascot}
            <Box flexDirection="column" width={body} marginTop={1}>
              {!ready && <Text dimColor>cargando…</Text>}
              {ready?.error && <Text color="error">next-order falló: {clip(ready.error, body - 20)}</Text>}
              {ready && !ready.error && visible.length === 0 && <Text dimColor>Sin issues en estado:listo.</Text>}
              {visible.map((item, i) => {
                const label = `${padEnd(`#${item.number}`, numWidth)} ${padEnd(clip(item.title, titleWidth), titleWidth)}`
                return (
                  <Box>
                    {item.isLaunchable ? (
                      <Button
                        key={`ready-${item.number}`}
                        hotkey={String(i + 5)}
                        plain
                        dimColor={page > 0 || i > 0}
                        label={label}
                        onPress={() => void choose($, item.number)}
                      />
                    ) : (
                      <Text dimColor>{`   ${label}`}</Text>
                    )}
                    <Text dimColor>{item.reason ? `  ${clip(item.reason, afterWidth)}` : ''}</Text>
                  </Box>
                )
              })}
              {Array.from({ length: Math.max(0, READY_ROWS - Math.max(visible.length, 1)) }, (_, i) => (
                <Text key={`ready-blank-${i}`}> </Text>
              ))}
              <Box justifyContent="space-between">
                <Text> </Text>
                <Box gap={2}>
                  {more !== '' && <Text dimColor>{more}</Text>}
                  {pages > 1 && (
                    <Button key="ready-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
                      onPress={() => void nextReadyPage($)} />
                  )}
                </Box>
              </Box>
            </Box>
          </Box>
        </Box>
      )
    }
    // La corrida ocupa la misma banda que la espera: la mascota del agente activo, los pasos y lo ultimo que hizo.
    const lines = await read($, linesAtom)
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
    const body = Math.max(30, inner - MASCOT_WIDTH - 2)
    const end = run.finishedMs ?? (now || Date.now())
    const pr = prNumber(run.pr)
    const pose = mascotPose(run, lines[lines.length - 1])
    const frame = run.state === 'running' ? (Math.floor((now || Date.now()) / 1000) % 2 === 0 ? 0 : 1) : 0
    const grid = cropGrid(sprite(pose.role, pose.state, frame), MASCOT_COLS)
    const elements = $.ui.resolve(e)
    const mascot =
      'Raster' in elements ? (
        <elements.Raster key="mefisto-mascota" columns={MASCOT_WIDTH} rows={RASTER_ROWS} cells={mascotCells(grid)} />
      ) : (
        <Box width={MASCOT_WIDTH} />
      )
    const recent = lines.filter(l => l.ts !== '').slice(-BAND_LOG_ROWS)
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
        <Box justifyContent="space-between">
          <Text wrap="truncate-end">
            <Text color="claude">mefisto</Text>
            {run.state === 'running' && <Text> · #{run.issue} {stageName(run.stage)}</Text>}
            {run.state === 'completed' && <Text color="success"> · #{run.issue} ✓ {pr ? `PR #${pr}` : 'terminado'}</Text>}
            {run.state === 'failed' && <Text color="error"> · #{run.issue} ✗ {stageName(run.stage)}</Text>}
            <Text dimColor> {elapsed(end - run.startedMs)}</Text>
          </Text>
          <Box gap={2}>
            {run.state === 'completed' && pr && (
              <Button key="band-merge" hotkey="1" plain variant="primary" label="mergear" onPress={() => void merge($)} />
            )}
            {run.state === 'completed' && pr && <Button key="band-web" hotkey="2" plain label="ver PR" onPress={() => void openPr($)} />}
            <Button key="band-open" hotkey="3" plain dimColor={run.state === 'running'} label="log" onPress={() => void toggleLog($)} />
            {run.state !== 'running' && <Button key="band-close" hotkey="4" plain label="cerrar" onPress={() => void closeRun($)} />}
          </Box>
        </Box>
        <Box gap={2} height={RASTER_ROWS + 1} alignItems="flex-start">
          {mascot}
          <Box flexDirection="column" width={body} marginTop={1}>
            <Text wrap="truncate-end">
              {steps(run).map((st, i) => (
                <Text
                  color={st.mark === 'done' ? 'success' : st.mark === 'failed' ? 'error' : st.mark === 'current' ? 'warning' : undefined}
                  dimColor={st.mark === 'pending'}
                >
                  {i > 0 ? ' ─ ' : ''}
                  {st.mark === 'done' ? '✓' : st.mark === 'failed' ? '✗' : st.mark === 'current' ? '●' : '○'} {st.name}
                </Text>
              ))}
            </Text>
            {run.title !== '' && <Text dimColor wrap="truncate-end">{run.title}</Text>}
            {run.state === 'failed' && run.lastError && <Text color="error" wrap="truncate-end">{run.lastError}</Text>}
            {run.state === 'running' && recent.length === 0 && <Text dimColor>esperando eventos del agente…</Text>}
            {run.state === 'running' &&
              recent.map(line => (
                <Text wrap="truncate-end" color={lineColor(line)} dimColor={line.kind === 'text'}>
                  {`${line.ts} ${line.kind === 'text' ? '» ' : ''}${line.text}`}
                </Text>
              ))}
          </Box>
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const run = await read($, runAtom)
    if (!run) {
      return (
        <Box flexDirection="column">
          <Text dimColor>Sin corrida. Lanza /mefisto-tooling &lt;issue&gt; o /mefisto-monitor &lt;issue&gt;.</Text>
        </Box>
      )
    }
    const lines = await read($, linesAtom)
    const now = await read($, nowAtom)
    const width = Math.max(20, e.props.bodyColumns ?? 60)
    const rows = Math.max(3, (e.props.scroll?.bodyRows ?? PANE_ROWS) - FIXED_ROWS)
    const end = run.finishedMs ?? (now || Date.now())
    const pr = prNumber(run.pr)

    return (
      <Box flexDirection="column" width={width}>
        <Box justifyContent="space-between">
          <Text bold color="claude">mefisto-tooling #{run.issue}</Text>
          <Text dimColor>{elapsed(end - run.startedMs)}</Text>
        </Box>
        {run.title !== '' && <Text wrap="truncate-end">{run.title}</Text>}
        <Box>
          {steps(run).map((s, i) => (
            <Text
              color={s.mark === 'done' ? 'success' : s.mark === 'failed' ? 'error' : s.mark === 'current' ? 'warning' : undefined}
              dimColor={s.mark === 'pending'}
            >
              {i > 0 ? ' ─ ' : ''}
              {s.mark === 'done' ? '✓' : s.mark === 'failed' ? '✗' : s.mark === 'current' ? '●' : '○'} {s.name}
              {agentDuration(run, s.name)}
            </Text>
          ))}
        </Box>
        {run.state === 'completed' && (
          <Box flexDirection="column">
            <Box gap={3}>
              <Text color="success" bold>✓ {pr ? `PR #${pr} creado` : 'terminado'}</Text>
              {pr && <Button key="merge" hotkey="m" plain variant="primary" label={`Mergear #${pr}`} onPress={() => void merge($)} />}
              {pr && <Button key="web" hotkey="v" plain label="Ver en GitHub" onPress={() => void openPr($)} />}
              <Button key="close" hotkey="c" plain label="Cerrar log" role="dismiss" onPress={() => void closeLog($)} />
            </Box>
            <Text dimColor wrap="truncate-end">
              {pr ? `m: /mefisto-merge ${pr} (squash + borra rama) · ` : ''}c: cierra el log, la banda sigue · ctrl+x tab enfoca · esc vuelve al prompt
            </Text>
          </Box>
        )}
        {run.state === 'failed' && (
          <Box flexDirection="column">
            <Text color="error" wrap="wrap">✗ falló en {stageName(run.stage)}{run.lastError ? `: ${run.lastError}` : ''}</Text>
            <Box gap={2}>
              <Button key="close" hotkey="c" plain label="Cerrar log" role="dismiss" onPress={() => void closeLog($)} />
            </Box>
          </Box>
        )}
        {run.state === 'running' && (
          <Box gap={2}>
            <Button key="close" hotkey="c" plain label="Cerrar log" role="dismiss" onPress={() => void closeLog($)} />
            <Text dimColor>3 en la banda también lo cierra · ctrl+x tab enfoca · esc vuelve al prompt</Text>
          </Box>
        )}
        <Text dimColor>{'─'.repeat(Math.min(width, 80))}</Text>
        <Box flexDirection="column">
          {lines.length === 0 && <Text dimColor>esperando eventos del agente…</Text>}
          {lines.slice(-rows).map(line => (
            <Text wrap="truncate-end" color={lineColor(line)} dimColor={line.kind === 'text'}>
              {line.ts !== '' ? `${line.ts} ` : ''}
              {line.kind === 'text' ? '» ' : ''}
              {line.text}
            </Text>
          ))}
        </Box>
      </Box>
    )
  })
}

function stageName(stage: string): string {
  return stage.replace(/^\d+-/, '')
}

function agentDuration(run: MonitorRun, step: string): string {
  const d = run.agents[step]?.duration
  return typeof d === 'number' && d > 0 ? ` ${Math.round(d / 60)}m` : ''
}

function lineColor(line: LogLine) {
  if (line.kind === 'fail') return 'error' as const
  if (line.kind === 'done') return 'success' as const
  if (line.kind === 'start') return 'claude' as const
  return undefined
}
