import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardList } from '../types'
import {
  PACT_COMMAND,
  PAGE_ROWS,
  PLANNER_AGENT,
  agentFlagOf,
  agentSettingOf,
  clip,
  footerOf,
  isMefistoManifest,
  nextOrderPath,
  pageOf,
  parseNextOrder,
  rowText,
  transcriptPathOf,
} from './logic'

const POLL_MS = 60_000
const SCRIPT_TIMEOUT_MS = 180_000

const activeAtom = atom({ plugin: 'mefisto', key: 'pactIsActive' } as const, false)
const listAtom = atom({ plugin: 'mefisto', key: 'pactList' } as const, null)
const pageAtom = atom({ plugin: 'mefisto', key: 'pactPage' } as const, 0)

// La intencion on/off y la elegibilidad viven aqui: /clear no dispara session.start y reinicia los atoms.
let isEligible = false
let isWanted = true
let isRefreshing = false
let timer: { cancel: () => void } | null = null

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

async function refresh($: EngineInterface) {
  if (isRefreshing || !isEligible || !isWanted) return
  isRefreshing = true
  try {
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
  void refresh($)
}

async function deactivate($: EngineInterface) {
  isWanted = false
  timer?.cancel()
  timer = null
  await update($, activeAtom, () => false)
}

async function isMefistoRepo($: EngineInterface): Promise<boolean> {
  const top = await $.process.run(['git', 'rev-parse', '--show-toplevel']).catch(() => ({ exitCode: 1, stdout: '' }))
  if (top.exitCode !== 0) return false
  const raw = await $.fs.read(`${top.stdout.trim()}/.claude-plugin/plugin.json`).catch(() => '')
  return typeof raw === 'string' && isMefistoManifest(raw)
}

// Agente principal de la sesion: primero la linea de comando de Claude Code, luego el transcript si ya existe.
async function isPlannerSession($: EngineInterface): Promise<boolean> {
  const ps = await $.process.run(['sh', '-c', 'ps -o args= -p "$PPID"']).catch(() => ({ exitCode: 1, stdout: '' }))
  const cmdline = ps.exitCode === 0 ? ps.stdout.trim() : ''
  if (/\bclaude\b/.test(cmdline)) return agentFlagOf(cmdline) === PLANNER_AGENT
  const home = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`
  const path = transcriptPathOf(home, await $.session.cwd(), await $.session.id())
  const { stdout } = await $.process.run(['head', '-c', '200000', path]).catch(() => ({ stdout: '' }))
  return agentSettingOf(stdout) === PLANNER_AGENT
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isEligible = false
    if (!e.isInteractive || (await isMefistoRepo($)) || (await isPlannerSession($))) {
      await deactivate($)
      isWanted = true
      return next(e)
    }
    isEligible = true
    await $.command.register({
      name: PACT_COMMAND,
      description: 'Consola de Fausto: refresh | on | off',
      argumentHint: '[refresh|on|off]',
      immediate: true,
    })
    if (isWanted) await activate($)
    return next(e)
  })

  on('command.run', { command: PACT_COMMAND }, async ($, e) => {
    const arg = e.args.trim()
    if (!isEligible) return { text: 'La consola no aplica en esta sesión.' }
    if (arg === 'off') {
      await deactivate($)
      return { text: 'Consola de Fausto apagada.' }
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
    const list = await read($, listAtom)
    if (!list) void refresh($)
    const { Box, Text, Button } = $.ui.resolve(e)
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
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
