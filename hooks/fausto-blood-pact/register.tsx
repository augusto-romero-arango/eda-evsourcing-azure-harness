import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardList, PipelineResult, PipelineRun } from '../types'
import {
  DISMISSED_STORE_KEY,
  HISTORY_FILE,
  PAGE_ROWS,
  PLANNER_AGENT,
  agentFlagOf,
  agentSettingOf,
  clip,
  footerOf,
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
} from './logic'

const POLL_MS = 60_000
const STORE_ERROR = 'store no disponible'
const SCRIPT_TIMEOUT_MS = 180_000

const activeAtom = atom({ plugin: 'mefisto', key: 'pactIsActive' } as const, false)
const listAtom = atom({ plugin: 'mefisto', key: 'pactList' } as const, null)
const pageAtom = atom({ plugin: 'mefisto', key: 'pactPage' } as const, 0)
const runsAtom = atom({ plugin: 'mefisto', key: 'pactRuns' } as const, [] as PipelineRun[])
const resultsAtom = atom({ plugin: 'mefisto', key: 'pactResults' } as const, [] as PipelineResult[])

// La intencion on/off y la elegibilidad viven aqui: /clear no dispara session.start y reinicia los atoms.
let isEligible = false
let isWanted = true
let isRefreshing = false
let timer: { cancel: () => void } | null = null
let runsTimer: { cancel: () => void } | null = null
let isRefreshingRuns = false
// Corridas que esta sesion vio activas y resultados `✓` ya derivados; viven aqui porque /clear reinicia los atoms.
let seenRuns: Record<string, PipelineRun> = {}
let carriedResults: PipelineResult[] = []
let runsRepo = ''
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
    .run([nextOrderPath(root), '--json'], { timeoutMs: SCRIPT_TIMEOUT_MS })
    .catch(err => ({ exitCode: 2, stdout: '', stderr: String(err) }))
  return parseNextOrder(exitCode, stdout, stderr)
}

type Store = { get: (k: string) => Promise<unknown>; set: (k: string, v: unknown) => Promise<unknown> }
const storeOf = ($: EngineInterface) => ($ as unknown as { store?: Store }).store

async function readDismissed($: EngineInterface): Promise<string[]> {
  const raw = await storeOf($)?.get(DISMISSED_STORE_KEY).catch(() => null)
  return Array.isArray(raw) ? raw.filter((k): k is string => typeof k === 'string') : []
}

async function saveDismissed($: EngineInterface, keys: string[]) {
  await storeOf($)?.set(DISMISSED_STORE_KEY, keys).catch(() => STORE_ERROR)
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

async function refreshRuns($: EngineInterface) {
  if (isRefreshingRuns || !isEligible || !isWanted) return
  isRefreshingRuns = true
  try {
    const statuses = await readRuns($)
    const dismissed = await readDismissed($)
    const wasSeen = seenRuns
    const historyRaw = await $.fs.read(`${runsRepo}/.mefisto/pipeline/${HISTORY_FILE}`).catch(() => '')
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
    await update($, runsAtom, () => view.runs)
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
    const list = await runNextOrder($)
    await update($, listAtom, () => list)
  } finally {
    isRefreshing = false
  }
}

async function activate($: EngineInterface) {
  isWanted = true
  await update($, activeAtom, () => true)
  timer?.cancel()
  timer = $.clock.every(POLL_MS, () => void refresh($))
  runsTimer?.cancel()
  runsTimer = $.clock.every(RUNS_POLL_MS, () => void refreshRuns($))
  void refresh($)
}

async function deactivate($: EngineInterface) {
  isWanted = false
  timer?.cancel()
  timer = null
  runsTimer?.cancel()
  runsTimer = null
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
      description: 'Consola de Fausto: refresh | on | off | descartar',
      argumentHint: '[refresh|on|off|descartar]',
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
    const { Box, Text, Button } = $.ui.resolve(e)
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
    const runs = await read($, runsAtom)
    const results = await read($, resultsAtom)
    const lines = [
      ...runs.map(r => ({ key: `run-${r.pipeline}-${r.issue}-${r.variant ?? ''}`, text: runLine(r, Date.now()), color: undefined as string | undefined })),
      ...results.map(r => ({ key: `res-${r.key}`, text: resultLine(r), color: r.ok ? 'success' : 'error' })),
    ]
    if (lines.length > 0) {
      const { page, pages } = pageOf(await read($, pageAtom), lines.length, PAGE_ROWS)
      const visible = lines.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS)
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          <Text bold color="claude">Corridas{` · ${runs.length} activas`}</Text>
          {visible.map(l => (
            <Text key={l.key} color={l.color} wrap="truncate-end">{clip(l.text, inner)}</Text>
          ))}
          {Array.from({ length: Math.max(0, PAGE_ROWS - visible.length) }, (_, i) => (
            <Text key={`blank-${i}`}> </Text>
          ))}
          <Box justifyContent="space-between">
            {results.length > 0 ? (
              <Button key="pact-dismiss" hotkey="4" plain dimColor label="descartar resultados"
                onPress={() => void dismissResults($)} />
            ) : (
              <Text dimColor> </Text>
            )}
            {pages > 1 && (
              <Button key="pact-next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
                onPress={() => void update($, pageAtom, () => (page + 1) % pages)} />
            )}
          </Box>
        </Box>
      )
    }
    const list = await read($, listAtom)
    if (!list) void refresh($)
    const { page, pages } = pageOf(await read($, pageAtom), list?.items.length ?? 0, PAGE_ROWS)
    const visible = list?.items.slice(page * PAGE_ROWS, (page + 1) * PAGE_ROWS) ?? []
    const numWidth = String(list?.items.length ?? 0).length + 2
    const footer = list ? footerOf(list) : ''
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
        <Text bold color="claude">Lanzables{list && !list.error ? ` · ${list.items.length}` : ''}</Text>
        {!list && <Text dimColor>cargando…</Text>}
        {list?.error && <Text color="error">next-order falló: {clip(list.error, inner - 20)}</Text>}
        {list && !list.error && visible.length === 0 && <Text dimColor>Sin issues lanzables</Text>}
        {visible.map((item, i) => (
          <Text key={`row-${item.number}`} dimColor={page > 0 || i > 0} wrap="truncate-end">
            {rowText(item, page * PAGE_ROWS + i + 1, numWidth, Math.max(12, inner - numWidth - 20))}
          </Text>
        ))}
        {Array.from({ length: Math.max(0, PAGE_ROWS - Math.max(visible.length, 1)) }, (_, i) => (
          <Text key={`blank-${i}`}> </Text>
        ))}
        <Box justifyContent="space-between">
          <Text dimColor>{footer}</Text>
          {pages > 1 && (
            <Button key="pact-next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`}
              onPress={() => void update($, pageAtom, () => (page + 1) % pages)} />
          )}
        </Box>
      </Box>
    )
  })
}
