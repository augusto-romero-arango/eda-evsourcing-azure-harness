import { expect, test } from 'claude-code/testing'

import {
  agentFlagOf,
  agentOf,
  agentSettingOf,
  dismissKey,
  parseHistory,
  parseStatus,
  pruneDismissed,
  reconcile,
  resultLine,
  runLine,
  stateDirOf,
  footerOf,
  isMefistoManifest,
  nextOrderPath,
  pageOf,
  parseNextOrder,
  rowText,
  transcriptPathOf,
} from './logic'

const json = JSON.stringify({
  items: [{ position: 1, number: 7, title: 'Hacer algo', tipo: 'tooling', after: [], hasDepsSection: true }],
  blocked: [{ number: 9 }, { number: 10 }],
  cycles: [[3, 4]],
  launch: '/mefisto:sequential 7',
})

test('parseNextOrder lee items, bloqueados y ciclos', () => {
  const list = parseNextOrder(0, json, '')
  expect(list.error).toBe(null)
  expect(list.items[0]?.number).toBe(7)
  expect(list.blockedCount).toBe(2)
  expect(list.cycleCount).toBe(1)
  expect(footerOf(list)).toBe('2 bloqueados · 1 en ciclo')
})

test('parseNextOrder con exit 1 y sin items no es error', () => {
  const list = parseNextOrder(1, '{"items":[],"blocked":[],"cycles":[],"launch":null}', '')
  expect(list.error).toBe(null)
  expect(list.items.length).toBe(0)
})

test('parseNextOrder con exit 2 informa el error', () => {
  expect(parseNextOrder(2, '', '\nfallo gh\n').error).toBe('fallo gh')
  expect(parseNextOrder(2, '', '').error).toBe('exit 2')
  expect(parseNextOrder(0, 'no json', '').error).toBe('salida de next-order no es JSON')
})

test('rowText muestra orden, numero, tipo y titulo', () => {
  const item = { number: 7, title: 'Hacer algo', tipo: 'tooling', after: [], hasDepsSection: true }
  expect(rowText(item, 1, 3, 40)).toBe('1.  #7 [tooling] Hacer algo')
  expect(rowText({ ...item, tipo: null }, 1, 3, 40)).toBe('1.  #7 [?] Hacer algo')
})

test('pageOf acota la pagina', () => {
  expect(pageOf(0, 0, 5)).toEqual({ page: 0, pages: 1 })
  expect(pageOf(9, 11, 5)).toEqual({ page: 2, pages: 3 })
})

test('deteccion del planner y del repo de Mefisto', () => {
  expect(agentFlagOf('claude --agent mefisto:planner')).toBe('mefisto:planner')
  expect(agentFlagOf('claude --agent=otro -p')).toBe('otro')
  expect(agentFlagOf('claude')).toBe(null)
  expect(agentSettingOf('{"type":"agent-setting","agentSetting":"mefisto:planner"}\n')).toBe('mefisto:planner')
  expect(agentSettingOf('{"type":"user"}\n')).toBe(null)
  expect(isMefistoManifest('{"name":"mefisto"}')).toBe(true)
  expect(isMefistoManifest('{"name":"otro"}')).toBe(false)
  expect(isMefistoManifest('x')).toBe(false)
})

test('rutas', () => {
  expect(nextOrderPath('/p/')).toBe('/p/scripts/next-order.sh')
  expect(transcriptPathOf('/h/.c', '/a/b', 's1')).toBe('/h/.c/projects/-a-b/s1.jsonl')
})

const status = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ issue: '7', pipeline: 'tdd', variant: null, started: '2026-10-09T10:00:00', stage: '3-implementer', state: 'running', ...over })
const NOW = Date.parse('2026-10-09T10:12:30')

test('parseStatus: running, hold, fallo y variante', () => {
  const run = parseStatus('pipeline-status-tdd-7.json', status())!
  expect(agentOf(run.stage)).toBe('implementer')
  expect(runLine(run, NOW)).toBe('#7 tdd implementer 12m')
  const hold = parseStatus('pipeline-status-tooling-8.json', status({ pipeline: 'tooling', issue: 8, state: 'hold', hold: { next_probe: '2026-10-09T10:45:00' } }))!
  expect(runLine(hold, NOW)).toBe('#8 tooling rate limit · sonda 10:45 12m')
  expect(runLine(parseStatus('pipeline-status-infra-9.json', status({ pipeline: 'infra', issue: 9, stage: 'setup' }))!, NOW)).toBe('#9 infra setup 12m')
  const variant = parseStatus('pipeline-status-tdd-7-b.json', status({ variant: 'b' }))!
  expect(variant.variant).toBe('b')
  expect(parseStatus('otro.json', status())).toBe(null)
  expect(parseStatus('pipeline-status-tdd-7.json', 'no json')).toBe(null)
})

test('parseHistory ignora lineas rotas y conserva el PR', () => {
  const h = parseHistory(`{"issue":"7","pipeline":"tdd","variant":null,"started":"2026-10-09T10:00:00","pr":"https://x/pull/55"}\nbasura\n`)
  expect(h.length).toBe(1)
  expect(h[0]!.pr).toBe('https://x/pull/55')
})

test('reconcile: de activa a ✓ PR, fallo con ✗ y descarte persistente', () => {
  const repo = '/r'
  const run = parseStatus('pipeline-status-tdd-7.json', status())!
  const history = parseHistory('{"issue":"7","pipeline":"tdd","variant":null,"started":"2026-10-09T10:00:00","pr":"https://x/pull/55"}')
  const first = reconcile(repo, [run], {}, history, new Set())
  expect(first.runs.length).toBe(1)
  const done = reconcile(repo, [], first.seen, history, new Set())
  expect(done.results.map(resultLine)).toEqual(['#7 tdd ✓ PR #55'])
  const failed = parseStatus('pipeline-status-tdd-7.json', status({ state: 'blocked', stage: '4-reviewer' }))!
  expect(reconcile(repo, [failed], {}, [], new Set()).results[0]!.text).toBe('✗ 4-reviewer')
  expect(reconcile(repo, [failed], {}, [], new Set([dismissKey(repo, failed)])).results.length).toBe(0)
})

test('dismissKey incluye repo, pipeline, issue, variante y started', () => {
  const run = parseStatus('pipeline-status-tdd-7-b.json', status({ variant: 'b' }))!
  expect(dismissKey('/r', run)).toBe('/r|tdd|7|b|2026-10-09T10:00:00')
})

test('pruneDismissed poda solo claves viejas del repo sin status vivo', () => {
  const old = '/r|tdd|1||2026-10-01T10:00:00'
  const fresh = '/r|tdd|2||2026-10-09T10:00:00'
  const other = '/o|tdd|1||2026-10-01T10:00:00'
  expect(pruneDismissed([old, fresh, other], '/r', new Set(), NOW)).toEqual([fresh, other])
  expect(pruneDismissed([old], '/r', new Set([old]), NOW)).toEqual([old])
})

test('stateDirOf resuelve el checkout principal aunque sea un worktree', () => {
  expect(stateDirOf('/repo/.git', '/repo/.mefisto/worktrees/x')).toBe('/repo/.mefisto/pipeline')
  expect(stateDirOf('.git', '/repo/')).toBe('/repo/.mefisto/pipeline')
})
