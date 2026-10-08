import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardFocus, BoardList, BoardTab } from '../types'
import {
  NEXT_ORDER,
  arrivals,
  clip,
  clockOf,
  createdIssueOf,
  createdText,
  isIssueCreate,
  isPlannerClosing,
  isPlannerMainThread,
  issueMarkedListo,
  numberWidth,
  executionPaneOf,
  padEnd,
  pageOf,
  pageSizeOf,
  parseNextOrder,
  parseOpenIssues,
  reasonOf,
  refineTargetOf,
  signatureOf,
  topicOf,
} from './logic'

const POLL_MS = 60_000
const SCRIPT_TIMEOUT_MS = 180_000
const FLASH_MS = 8_000

const activeAtom = atom({ plugin: 'mefisto-planner-board', key: 'isActive' } as const, false)
const plannerAtom = atom({ plugin: 'mefisto-planner-board', key: 'isPlannerSession' } as const, false)
const expandedAtom = atom({ plugin: 'mefisto-planner-board', key: 'isExpanded' } as const, false)
const pageAtom = atom({ plugin: 'mefisto-planner-board', key: 'page' } as const, 0)
const tabAtom = atom({ plugin: 'mefisto-planner-board', key: 'tab' } as const, 'borrador')
const focusAtom = atom({ plugin: 'mefisto-planner-board', key: 'focus' } as const, null)
const flashAtom = atom({ plugin: 'mefisto-planner-board', key: 'flash' } as const, null)
const refineAtom = atom({ plugin: 'mefisto-planner-board', key: 'refine' } as const, null)
const developAtom = atom({ plugin: 'mefisto-planner-board', key: 'develop' } as const, null)
const updatedAtom = atom({ plugin: 'mefisto-planner-board', key: 'updatedMs' } as const, 0)
const signatureAtom = atom({ plugin: 'mefisto-planner-board', key: 'signature' } as const, '')
const knownAtom = atom({ plugin: 'mefisto-planner-board', key: 'known' } as const, [])

let isInteractive = false
let isRefreshing = false
let timer: { cancel: () => void } | null = null

async function runNextOrder($: EngineInterface, args: string[]): Promise<BoardList> {
  const { exitCode, stdout, stderr } = await $.process
    .run([NEXT_ORDER, ...args], { timeoutMs: SCRIPT_TIMEOUT_MS })
    .catch(err => ({ exitCode: 2, stdout: '', stderr: String(err) }))
  return parseNextOrder(exitCode, stdout, stderr)
}

async function refresh($: EngineInterface, isForced: boolean) {
  if (isRefreshing || !(await read($, activeAtom))) return
  isRefreshing = true
  try {
    const { exitCode, stdout } = await $.process
      .run(['gh', 'issue', 'list', '--state', 'open', '--limit', '300', '--json', 'number,title,labels,updatedAt'])
      .catch(() => ({ exitCode: 1, stdout: '' }))
    const issues = exitCode === 0 ? parseOpenIssues(stdout) : null
    if (!issues) return

    const signature = signatureOf(issues)
    if (!isForced && signature === (await read($, signatureAtom))) return

    const focus = await read($, focusAtom)
    for (const a of arrivals(issues, await read($, knownAtom))) {
      if (!focus?.created.includes(a.number)) $.ui.toast(`Nuevo ${a.kind} #${a.number}: ${clip(a.title, 60)}`)
    }
    const [refine, develop] = await Promise.all([runNextOrder($, ['--refinement', '--json']), runNextOrder($, ['--json'])])
    await update($, refineAtom, () => refine)
    await update($, developAtom, () => develop)
    await update($, signatureAtom, () => signature)
    await update($, knownAtom, () => issues.map(i => i.number))
    await update($, updatedAtom, () => Date.now())
  } finally {
    isRefreshing = false
  }
}

async function activate($: EngineInterface) {
  await update($, activeAtom, () => true)
  timer?.cancel()
  timer = $.clock.every(POLL_MS, () => void refresh($, false))
  void refresh($, true)
}

async function deactivate($: EngineInterface) {
  timer?.cancel()
  timer = null
  await update($, activeAtom, () => false)
}

async function startFocus($: EngineInterface, focus: BoardFocus) {
  await update($, flashAtom, () => null)
  await update($, focusAtom, () => focus)
}

async function closeFocus($: EngineInterface, summary: string) {
  await update($, focusAtom, () => null)
  await update($, flashAtom, () => ({ text: summary, untilMs: Date.now() + FLASH_MS }))
  $.clock.after(FLASH_MS, () => void update($, flashAtom, () => null))
  void refresh($, true)
}

function summaryOf(focus: BoardFocus, isListo: boolean): string {
  const created = createdText(focus.created)
  const head =
    focus.kind === 'refinar'
      ? `✓ #${focus.issue}${isListo ? ' → listo' : ' · refinamiento cerrado'}`
      : `✓ exploración «${clip(focus.topic, 40)}»`
  return [head, created].filter(Boolean).join(' · ')
}

async function onPrompt($: EngineInterface, text: string) {
  const focus = await read($, focusAtom)
  const target = refineTargetOf(text)
  if (target !== null && !(focus?.kind === 'refinar' && focus.issue === target)) {
    const known = (await read($, refineAtom))?.items.find(i => i.number === target)
    await startFocus($, { kind: 'refinar', issue: target, topic: known?.title ?? '', created: [] })
    return
  }
  if (!focus && target === null && text.trim() !== '' && !text.trim().startsWith('/')) {
    await startFocus($, { kind: 'explorar', issue: null, topic: topicOf(text), created: [] })
  }
}

async function onBash($: EngineInterface, command: string, output: string) {
  const focus = await read($, focusAtom)
  if (!focus) return
  if (isIssueCreate(command)) {
    const created = createdIssueOf(output)
    if (created !== null && !focus.created.includes(created)) {
      await update($, focusAtom, f => (f ? { ...f, created: [...f.created, created] } : f))
    }
    return
  }
  const listo = issueMarkedListo(command)
  if (focus.kind === 'refinar' && listo !== null && listo === focus.issue) {
    await closeFocus($, summaryOf(focus, true))
    return
  }
  if (isPlannerClosing(command)) await closeFocus($, summaryOf(focus, false))
}

// La misma tecla abre su lista o, si ya estaba abierta, la cierra.
async function toggleList($: EngineInterface, tab: BoardTab) {
  const isOpen = (await read($, expandedAtom)) && (await read($, tabAtom)) === tab
  await update($, tabAtom, () => tab)
  await update($, pageAtom, () => 0)
  await update($, expandedAtom, () => !isOpen)
}

// Avanza de pagina y da la vuelta al final.
async function nextPage($: EngineInterface) {
  const list = (await read($, tabAtom)) === 'borrador' ? await read($, refineAtom) : await read($, developAtom)
  const tab = await read($, tabAtom)
  const { page, pages } = pageOf(await read($, pageAtom), list?.items.length ?? 0, pageSizeOf(tab))
  await update($, pageAtom, () => (page + 1) % pages)
}

async function fill($: EngineInterface, text: string) {
  await $.prompt.fill({ text, mode: 'replace' })
}

// El planner no ejecuta: el comando queda escrito, sin Enter, en el pane de ejecucion de herdr para
// editarlo antes de lanzarlo. Fuera de herdr, o sin ese pane, va al portapapeles.
async function sendToExecution($: EngineInterface, text: string, surface: 'terminal' | 'desktop' | 'vscode' | 'mobile') {
  const current = await $.env.get('HERDR_PANE_ID')
  if (current) {
    const { exitCode, stdout } = await $.process.run(['herdr', 'pane', 'list']).catch(() => ({ exitCode: 1, stdout: '' }))
    const target = exitCode === 0 ? executionPaneOf(stdout, current) : null
    if (target) {
      const sent = await $.process.run(['herdr', 'pane', 'send-text', target, text]).catch(() => ({ exitCode: 1 }))
      if (sent.exitCode === 0) {
        $.ui.toast(`En el pane de ejecución, sin Enter: ${text}`)
        return
      }
    }
  }
  await copyText($, text, surface)
}

async function copyText($: EngineInterface, text: string, surface: 'terminal' | 'desktop' | 'vscode' | 'mobile') {
  const copied = await $.ui.copy({ text, surface })
  $.ui.toast(copied.isCopied ? `Copiado: ${text}` : `No se pudo copiar: ${text}`)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    await $.command.register({
      name: 'mefisto-board',
      description: 'Tablero del planner: refresh | borradores | listos | batch | cerrar | on | off',
      argumentHint: '[refresh|borradores|listos|batch|cerrar|on|off]',
      immediate: true,
    })
    const isWanted = (await read($, activeAtom)) || (await read($, plannerAtom))
    if (isInteractive && isWanted) await activate($)
    return next(e)
  })

  // SessionStart (classic) puede llegar antes o despues de session.start: se recuerda que es el planner
  // y activa quien llegue segundo, ya con isInteractive conocido.
  on('classic.SessionStart', async ($, e, next) => {
    if (isPlannerMainThread(e)) {
      await update($, plannerAtom, () => true)
      if (isInteractive && !(await read($, activeAtom))) await activate($)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' && (await read($, activeAtom))) await onPrompt($, e.text)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (await read($, activeAtom)) {
      const output = ran.text ?? JSON.stringify(ran.result ?? '')
      await onBash($, e.command, output).catch(() => undefined)
    }
    return ran
  })

  on('command.run', { command: 'mefisto-board' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'off') {
      await deactivate($)
      return { text: 'Tablero del planner apagado en esta sesión.' }
    }
    if (arg === 'on' || !(await read($, activeAtom))) {
      await activate($)
      return { text: 'Tablero del planner activo en esta sesión.' }
    }
    if (arg === 'borradores' || arg === 'listos') {
      await toggleList($, arg === 'borradores' ? 'borrador' : 'listo')
      return { text: `Lista de ${arg} alternada.` }
    }
    if (arg === 'batch') {
      const launch = (await read($, developAtom))?.launch
      if (!launch) return { text: 'No hay batch lanzable.' }
      const copied = await $.ui.copy({ text: launch })
      return { text: copied.isCopied ? `Copiado: ${launch}` : launch }
    }
    if (arg === 'cerrar') {
      const focus = await read($, focusAtom)
      if (focus) await closeFocus($, summaryOf(focus, false))
      return { text: focus ? 'Foco cerrado.' : 'No había foco abierto.' }
    }
    await refresh($, true)
    return { text: 'Tablero actualizado.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!(await read($, activeAtom)) || e.props.hasSurvey) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const focus = await read($, focusAtom)
    const flash = await read($, flashAtom)
    const isExpanded = await read($, expandedAtom)
    const refine = await read($, refineAtom)
    const develop = await read($, developAtom)
    const inner = Math.max(40, (e.props.bodyColumns ?? 80) - 4)
    const count = (l: BoardList | null) => (l ? String(l.items.length) : '…')
    const tab = await read($, tabAtom)
    const suggested = refine?.items[0]?.number ?? null
    const listButtons = (
      <Box gap={2}>
        <Button key="list-borrador" hotkey="3" plain variant={isExpanded && tab === 'borrador' ? 'primary' : undefined}
          dimColor={!(isExpanded && tab === 'borrador')} label={`borradores ${count(refine)}`}
          onPress={() => void toggleList($, 'borrador')} />
        <Button key="list-listo" hotkey="4" plain variant={isExpanded && tab === 'listo' ? 'primary' : undefined}
          dimColor={!(isExpanded && tab === 'listo')} label={`listos ${count(develop)}`}
          onPress={() => void toggleList($, 'listo')} />
      </Box>
    )

    let head
    if (focus) {
      const label =
        focus.kind === 'refinar'
          ? `refinar #${focus.issue}${focus.topic ? ` · ${focus.topic}` : ''}`
          : `explorar · ${focus.topic}`
      const created = createdText(focus.created)
      head = (
        <Box justifyContent="space-between">
          <Box gap={2}>
            <Text color="claude">●</Text>
            <Text bold wrap="truncate-end">{clip(label, Math.max(20, inner - created.length - 46))}</Text>
            {created !== '' && <Text color="success">{created}</Text>}
          </Box>
          {listButtons}
        </Box>
      )
    } else if (flash && flash.untilMs > Date.now()) {
      head = (
        <Box justifyContent="space-between">
          <Text color="success">{clip(flash.text, inner - 34)}</Text>
          {listButtons}
        </Box>
      )
    } else {
      head = (
        <Box justifyContent="space-between">
          <Box gap={3}>
            <Text dimColor>planner ·</Text>
            <Button key="mode-explorar" hotkey="1" plain label="explorar" onPress={() => void fill($, 'Quiero explorar: ')} />
            {suggested !== null && (
              <Button key="mode-refinar" hotkey="2" plain label={`refinar #${suggested}`}
                onPress={() => void fill($, `Refina el borrador #${suggested}`)} />
            )}
          </Box>
          {listButtons}
        </Box>
      )
    }

    if (!isExpanded) {
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
          {head}
        </Box>
      )
    }

    const updatedMs = await read($, updatedAtom)
    const list = tab === 'borrador' ? refine : develop
    const size = pageSizeOf(tab)
    const { page, pages } = pageOf(await read($, pageAtom), list?.items.length ?? 0, size)
    const visible = list?.items.slice(page * size, (page + 1) * size) ?? []
    const blankRows = Math.max(0, size - Math.max(visible.length, 1))
    const numWidth = numberWidth(visible)
    const reasonWidth = Math.min(24, Math.max(0, ...visible.map(i => reasonOf(i).text.length)))
    const titleWidth = Math.max(16, inner - numWidth - reasonWidth - 9)
    const surface = e.surface
    const more = list
      ? [
          list.blockedCount > 0 ? `${list.blockedCount} bloqueados` : '',
          list.cycleCount > 0 ? `${list.cycleCount} en ciclo` : '',
        ].filter(Boolean).join(' · ')
      : ''
    const hint = tab === 'borrador' ? '5-9 lo escribe en el prompt' : '5-8 /mefisto-tooling · 9 batch · al pane de ejecución, sin Enter'

    return (
      <Box flexDirection="column" borderStyle="round" borderColor="claude" borderDimColor paddingX={1}>
        {head}
        {list?.error && <Text color="error">next-order falló: {clip(list.error, inner - 20)}</Text>}
        {list && !list.error && visible.length === 0 && (
          <Text dimColor>{tab === 'borrador' ? 'Sin borradores refinables.' : 'Sin issues lanzables.'}</Text>
        )}
        {visible.map((item, i) => {
          const reason = reasonOf(item)
          return (
            <Box>
              <Button
                key={`item-${item.number}`}
                hotkey={String(i + 5)}
                plain
                dimColor={page > 0 || i > 0}
                label={`${padEnd(`#${item.number}`, numWidth)}  ${padEnd(clip(item.title, titleWidth), titleWidth)}`}
                onPress={() =>
                  void (tab === 'borrador'
                    ? fill($, `Refina el borrador #${item.number}`)
                    : sendToExecution($, `/mefisto-tooling ${item.number}`, surface))
                }
              />
              <Text color={reason.isWarning ? 'warning' : undefined} dimColor={!reason.isWarning}>
                {'  '}{clip(reason.text, reasonWidth)}
              </Text>
            </Box>
          )
        })}
        {Array.from({ length: blankRows }, (_, i) => (
          <Text key={`blank-${i}`}> </Text>
        ))}
        {tab === 'listo' &&
          (develop?.launch ? (
            <Button key="send-batch" hotkey="9" plain label={clip(develop.launch, inner - 4)}
              onPress={() => void sendToExecution($, develop.launch ?? '', surface)} />
          ) : (
            <Text dimColor>sin batch lanzable</Text>
          ))}
        <Box justifyContent="space-between">
          <Text dimColor>{hint}{updatedMs ? ` · ${clockOf(updatedMs)}` : ' · cargando…'}</Text>
          <Box gap={2}>
            {more !== '' && <Text dimColor>{more}</Text>}
            {pages > 1 && (
              <Button key="next-page" hotkey="0" plain dimColor label={`página ${page + 1}/${pages} ▸`} onPress={() => void nextPage($)} />
            )}
          </Box>
        </Box>
      </Box>
    )
  })
}
