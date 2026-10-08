import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LogLine, MonitorRun } from '../types'
import {
  HISTORY,
  LOG_DIR,
  agentOfEventsFile,
  elapsed,
  finishedFromHistory,
  parseEvent,
  pickEventsFile,
  prNumber,
  runFromStatus,
  statusPath,
  steps,
  toolingIssueOf,
  withModUi,
} from './logic'

const PANE = 'mefisto-monitor'
const MAX_LINES = 200
const STATUS_GRACE_MS = 30_000
const PANE_ROWS = 16
const FIXED_ROWS = 7
const PR_CHECK_MS = 15_000

const runAtom = atom({ plugin: 'mefisto-monitor', key: 'run' } as const, null)
const linesAtom = atom({ plugin: 'mefisto-monitor', key: 'lines' } as const, [])
const nowAtom = atom({ plugin: 'mefisto-monitor', key: 'now' } as const, 0)

type Tail = { path: string; stream: AsyncGenerator<unknown, unknown> }

let tail: Tail | null = null
let watchSinceMs = 0
let isPolling = false
let lastPrCheckMs = 0

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

async function watch($: EngineInterface, issue: string, sinceMs: number) {
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
  await update($, linesAtom, () => [])
  await poll($)
}

async function finish($: EngineInterface, run: MonitorRun) {
  await stopTail()
  await openPane($, true).catch(() => undefined)
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
    const prev = await read($, runAtom)
    if (prev?.state === 'completed') await closeIfMerged($, prev)
    if (!prev || prev.state !== 'running') return

    let next: MonitorRun = prev
    const status = statusPath(prev.issue)
    if (await $.fs.exists(status)) {
      const raw = await $.fs.read(status).catch(() => '')
      const parsed = runFromStatus(raw, prev)
      if (parsed && !(parsed.state !== 'running' && parsed.startedMs + 1000 < watchSinceMs)) next = parsed
    } else if (watchSinceMs === 0 || Date.now() - watchSinceMs > STATUS_GRACE_MS || prev.stage !== 'setup') {
      next = await fromHistory($, prev)
    }

    if (next.state === 'running') {
      const entries = await $.fs.list(LOG_DIR).catch(() => [])
      const name = pickEventsFile(entries, next.issue, Math.min(next.startedMs, watchSinceMs))
      if (name && name !== next.eventsFile) {
        next = { ...next, eventsFile: name }
        await startTail($, name)
      }
      $.ui.status(`mefisto · #${next.issue} ${stageName(next.stage)} ${elapsed(Date.now() - next.startedMs)}`)
    }

    const settled = next
    await update($, runAtom, () => settled)
    if (settled.state !== 'running') await finish($, settled)
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
  return $.ui.open({ id: PANE, title: 'mefisto', rows: PANE_ROWS, ...(isFocused ? { focus: true as const } : {}) })
}

async function closeRun($: EngineInterface) {
  await stopTail()
  await update($, runAtom, () => null)
  await update($, linesAtom, () => [])
  $.ui.status(undefined)
  await $.ui.close({ id: PANE })
}

async function openPr($: EngineInterface) {
  const run = await read($, runAtom)
  const pr = prNumber(run?.pr ?? null)
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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'mefisto-monitor',
      description: 'Abre el monitor de /mefisto-tooling (con <issue> sigue esa corrida; merge | close)',
      argumentHint: '[issue|merge|close]',
      immediate: true,
    })
    // Tras un hot-reload el tail del modulo anterior murio: se fuerza a reabrirlo.
    await update($, runAtom, run => (run && run.state === 'running' ? { ...run, eventsFile: null } : run))
    $.clock.every(1000, () => void poll($))
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const issue = toolingIssueOf(e.command)
    if (!issue) return next(e)
    const ran = await next({ ...e, command: withModUi(e.command) })
    if (ran.deny === undefined && ran.isError !== true) {
      await watch($, issue, Date.now() - 5_000)
      const opened = await openPane($)
      if (!opened.isPlaced) {
        $.ui.log(`mefisto-monitor: el pane espera sin dibujarse (${opened.reason}). Ábrelo con /mefisto-monitor.`)
        $.ui.toast('mefisto: usa /mefisto-monitor para ver el pane')
      }
    }
    return ran
  })

  on('command.run', { command: 'mefisto-monitor' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'close') {
      await closeRun($)
      return { text: 'Monitor cerrado.' }
    }
    if (arg === 'merge') {
      await merge($)
      return { text: 'Merge solicitado.' }
    }
    if (/^#?\d+$/.test(arg)) await watch($, arg.replace('#', ''), 0)
    await openPane($, true)
    return { text: 'Monitor abierto.' }
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    const run = await read($, runAtom)
    if (run && run.state !== 'running') {
      await stopTail()
      await update($, runAtom, () => null)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const run = await read($, runAtom)
    if (!run || e.props.hasSurvey) return next(e)
    const now = await read($, nowAtom)
    const { Box, Text, Button } = $.ui.resolve(e)
    if (run.state === 'running') {
      return (
        <Box>
          <Text color="claude">mefisto</Text>
          <Text dimColor> · #{run.issue} {stageName(run.stage)} {elapsed((now || Date.now()) - run.startedMs)}</Text>
        </Box>
      )
    }
    const pr = prNumber(run.pr)
    return (
      <Box gap={3}>
        <Text>
          <Text color="claude">mefisto</Text>
          <Text color={run.state === 'completed' ? 'success' : 'error'}>
            {' '}#{run.issue} {run.state === 'completed' ? `✓ ${pr ? `PR #${pr}` : 'terminado'}` : `✗ ${stageName(run.stage)}`}
          </Text>
        </Text>
        {pr && <Button key="band-merge" hotkey="1" plain variant="primary" label={`Mergear #${pr}`} onPress={() => void merge($)} />}
        {pr && <Button key="band-web" hotkey="2" plain label="Ver PR" onPress={() => void openPr($)} />}
        <Button key="band-open" hotkey="3" plain label="Monitor" onPress={() => void openPane($, true)} />
        <Button key="band-close" hotkey="4" plain label="Cerrar" onPress={() => void closeRun($)} />
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
              <Button key="close" hotkey="c" plain label="Cerrar monitor" role="dismiss" onPress={() => void closeRun($)} />
            </Box>
            <Text dimColor wrap="truncate-end">
              {pr ? `m: /mefisto-merge ${pr} (squash + borra rama) · ` : ''}c: oculta el monitor, no toca el PR · ctrl+x tab enfoca · esc vuelve al prompt
            </Text>
          </Box>
        )}
        {run.state === 'failed' && (
          <Box flexDirection="column">
            <Text color="error" wrap="wrap">✗ falló en {stageName(run.stage)}{run.lastError ? `: ${run.lastError}` : ''}</Text>
            <Box gap={2}>
              <Button key="close" hotkey="c" plain label="Cerrar monitor" role="dismiss" onPress={() => void closeRun($)} />
            </Box>
          </Box>
        )}
        {run.state === 'running' && <Text dimColor>ctrl+x tab enfoca · esc vuelve al prompt · /mefisto-monitor reabre</Text>}
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
