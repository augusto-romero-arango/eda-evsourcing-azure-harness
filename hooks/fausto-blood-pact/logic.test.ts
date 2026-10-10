import { expect, test } from 'claude-code/testing'

import {
  batchIssueLine,
  batchTitleOf,
  bandViewOf,
  resultsFooterText,
  mergeArgsOf,
  mergeOptions,
  mergeToast,
  openPrArgsOf,
  openPrOptions,
  parseOpenPrs,
  parsePrArgs,
  prOfResult,
  resultPrs,
  viewPrOf,
  activeRunOf,
  agentFlagOf,
  eventsFileOf,
  eventsLogBase,
  lastEventOf,
  poseOfResults,
  poseOfRun,
  roleOfAgent,
  agentOf,
  clockOf,
  minutesSince,
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
  rowParts,
  rowText,
  answerText,
  footerRestOf,
  launchKeysText,
  parseLaunchArg,
  planIssue,
  planLaunch,
  transcriptPathOf,
  batchCounts,
  batchDismissKey,
  batchHeader,
  batchPrOf,
  batchQueueText,
  batchRunOf,
  batchStopPath,
  batchSummaryText,
  canStopBatch,
  newlyMerged,
  otherRunsText,
  parseBatchStatus,
  runsOutsideBatch,
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
  expect(footerOf(list)).toBe('1 sequential · 5-9 uno · 2 bloqueados · 1 en ciclo')
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

test('rowText y rowParts: sin tecla, posicion ni [tipo]; letra de typeBadge y tras #M', () => {
  const item = { number: 7, title: 'Hacer algo', tipo: 'tooling', after: [3], hasDepsSection: true }
  expect(rowText(item, 4, 40)).toBe('#7   Hacer algo')
  expect(rowParts(item, 4, 40)).toEqual({ letter: 'T', color: 'magenta', label: '#7   Hacer algo', after: 'tras #3' })
  expect(rowParts({ ...item, tipo: null, after: [] }, 4, 40)).toEqual({ letter: '?', color: 'gray', label: '#7   Hacer algo', after: '' })
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

test('started compacto de los pipelines y next_probe en UTC', () => {
  expect(minutesSince('20261009-100000', NOW)).toBe(12)
  const probe = '2026-10-09T15:45:00Z'
  const d = new Date(Date.parse(probe))
  expect(clockOf(probe)).toBe(`${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`)
  expect(clockOf('nada')).toBe('nada')
})

const board = (over: Record<string, unknown> = {}) =>
  parseNextOrder(
    0,
    JSON.stringify({
      items: [
        { number: 7, title: 'A', tipo: 'tooling' },
        { number: 8, title: 'B', tipo: 'feature' },
        { number: 9, title: 'C', tipo: 'infra' },
        { number: 10, title: 'D', tipo: null },
      ],
      blocked: [{ number: 1 }],
      launch: '/mefisto:sequential 7 8',
      infra: [],
      parallel: { issues: [7, 8], launch: '/mefisto:parallel 7 8' },
      ...over,
    }),
    '',
  )

test('parseNextOrder lee infra y parallel', () => {
  const l = board({ infra: [9] })
  expect(l.infra).toEqual([9])
  expect(l.parallel?.launch).toBe('/mefisto:parallel 7 8')
})

test('1 y 2 escriben la linea de next-order sin infra', () => {
  expect(planLaunch(board(), 'sequential')).toEqual({ kind: 'fill', text: '/mefisto:sequential 7 8' })
  expect(planLaunch(board(), 'parallel')).toEqual({ kind: 'fill', text: '/mefisto:parallel 7 8' })
})

test('linea null: no actua ni se muestra', () => {
  const l = board({ launch: null, parallel: { issues: [], launch: null } })
  expect(planLaunch(l, 'sequential').kind).toBe('none')
  expect(planLaunch(l, 'parallel').kind).toBe('none')
  expect(launchKeysText(l)).toBe('')
})

test('con infra, 1 y 2 abren el dialogo previo con tres opciones', () => {
  const plan = planLaunch(board({ infra: [9, 11] }), 'parallel')
  if (plan.kind !== 'ask') throw new Error('se esperaba dialogo')
  expect(plan.options.map(o => o.label)).toEqual(['Infra primero', 'Seguir sin infra', 'Cancelar'])
  expect(answerText(plan.options, 'Infra primero')).toBe('/mefisto:infra 9')
  expect(answerText(plan.options, 'Seguir sin infra')).toBe('/mefisto:parallel 7 8')
  expect(answerText(plan.options, 'Cancelar')).toBe(null)
})

test('cerrar el dialogo o texto libre no escriben nada', () => {
  const plan = planLaunch(board({ infra: [9] }), 'sequential')
  if (plan.kind !== 'ask') throw new Error('se esperaba dialogo')
  expect(answerText(plan.options, null)).toBe(null)
  expect(answerText(plan.options, 'infra primero')).toBe(null)
  expect(answerText(plan.options, 'lo que sea')).toBe(null)
})

test('tipo -> opciones de un solo issue', () => {
  const item = (tipo: string | null) => ({ number: 5, title: 't', tipo, after: [], hasDepsSection: true })
  const texts = (tipo: string | null) => {
    const p = planIssue(item(tipo))
    return p.kind === 'ask' ? p.options.map(o => `${o.label}=${o.text}`) : p
  }
  for (const t of ['feature', 'refactor', 'projection']) {
    expect(texts(t)).toEqual(['Con merge=/mefisto:sequential 5', 'Solo PR=/mefisto:implement 5', 'Cancelar=null'])
  }
  expect(texts('tooling')).toEqual(['Con merge=/mefisto:sequential 5', 'Solo PR=/mefisto:tooling 5', 'Cancelar=null'])
  expect(texts('infra')).toEqual(['Solo PR=/mefisto:infra 5', 'Cancelar=null'])
  expect(planIssue(item(null)).kind).toBe('none')
  expect(planIssue(item('docs')).kind).toBe('none')
})

test('pie: teclas, infra y excluidos; fila sin prefijo', () => {
  const l = board({ infra: [9] })
  expect(footerOf(l)).toBe('1 sequential · 2 parallel 2 · 5-9 uno · infra: #9 · 1 bloqueados')
  expect(footerRestOf(l, true)).toBe(' · 5-9 uno · infra: #9 · 1 bloqueados')
  expect(rowText(l.items[0]!, 4, 20)).toBe('#7   A')
})

test('lanzar: sin argumento es 1, un numero fuera de los lanzables lo dice', () => {
  const l = board()
  expect(parseLaunchArg('', l)).toEqual({ kind: 'launch', launch: 'sequential' })
  expect(parseLaunchArg(' parallel', l)).toEqual({ kind: 'launch', launch: 'parallel' })
  expect(parseLaunchArg('8', l)).toEqual({ kind: 'issue', issue: 8 })
  expect(parseLaunchArg('99', l).kind).toBe('invalid')
  expect(parseLaunchArg('x', l).kind).toBe('invalid')
})

test('roleOfAgent mapea el agente del stage al rol', () => {
  for (const a of ['test-writer', 'smoke-test-writer', 'coverage-gate']) expect(roleOfAgent(a)).toBe('tester')
  for (const a of ['implementer', 'writer', 'setup', 'scaffold']) expect(roleOfAgent(a)).toBe('desarrollador')
  for (const a of ['reviewer', 'infra-reviewer']) expect(roleOfAgent(a)).toBe('revisor')
  expect(roleOfAgent('infra-writer')).toBe('infraestructura')
})

const runOf = (over: Record<string, unknown> = {}) =>
  parseStatus('pipeline-status-tdd-7.json', status({ updated: '2026-10-09T10:05:00', ...over }))!

test('activeRunOf elige la activa con updated mas reciente', () => {
  const a = runOf({ updated: '2026-10-09T10:05:00' })
  const b = parseStatus('pipeline-status-tooling-8.json', status({ pipeline: 'tooling', issue: 8, updated: '2026-10-09T10:09:00' }))!
  const done = parseStatus('pipeline-status-tdd-9.json', status({ issue: 9, state: 'failed', updated: '2026-10-09T10:11:00' }))!
  expect(activeRunOf([a, b, done])?.issue).toBe(8)
  expect(activeRunOf([done])).toBe(null)
})

test('ruta del events.jsonl por pipeline y el intento mas alto', () => {
  expect(eventsLogBase(runOf())).toBe('stage-3-implementer-2026-10-09T10:00:00-issue-7')
  const tooling = parseStatus('pipeline-status-tooling-8-b.json', status({ pipeline: 'tooling', issue: 8, variant: 'b', stage: '1-writer' }))!
  expect(eventsLogBase(tooling)).toBe('tooling-stage-1-writer-2026-10-09T10:00:00-issue-8-b')
  const infra = parseStatus('pipeline-status-infra-9.json', status({ pipeline: 'infra', issue: 9, stage: '1-infra-writer' }))!
  expect(eventsLogBase(infra)).toBe('iac-stage-1-infra-writer-2026-10-09T10:00:00-issue-9')
  const base = eventsLogBase(runOf())
  const names = [`${base}-attempt-1.events.jsonl`, `${base}-attempt-10.events.jsonl`, `${base}-attempt-2.events.jsonl`, `${base}-attempt-3.log`, 'otro.events.jsonl']
  expect(eventsFileOf(runOf(), names)).toBe(`${base}-attempt-10.events.jsonl`)
  expect(eventsFileOf(runOf(), ['otro'])).toBe(null)
})

test('lastEventOf toma el ultimo evento relevante', () => {
  const tool = '{"type":"tool.started","tool":"Edit"}'
  const text = '{"type":"message","role":"assistant","text":"hola"}'
  expect(lastEventOf(`${text}\n${tool}\n{"type":"tool.completed","ok":true}\nbasura\n`)).toEqual({ kind: 'tool', tool: 'Edit' })
  expect(lastEventOf(`${tool}\n${text}\n`)).toEqual({ kind: 'text', tool: '' })
  expect(lastEventOf('{"type":"message","role":"user","text":"x"}\n')).toBe(null)
  expect(lastEventOf('')).toBe(null)
})

test('poseOfRun sigue el ultimo evento, tambien en hold', () => {
  const tool = { kind: 'tool', tool: 'Bash' } as const
  const edit = { kind: 'tool', tool: 'Write' } as const
  const text = { kind: 'text', tool: '' } as const
  expect(poseOfRun(runOf(), tool)).toEqual({ role: 'desarrollador', state: 'trabajando' })
  expect(poseOfRun(runOf(), text)).toEqual({ role: 'desarrollador', state: 'pensando' })
  expect(poseOfRun(runOf(), null)).toEqual({ role: 'desarrollador', state: 'pensando' })
  expect(poseOfRun(runOf({ stage: '2-reviewer' }), edit)).toEqual({ role: 'revisor', state: 'corrigiendo' })
  expect(poseOfRun(runOf({ stage: '2-reviewer' }), tool)).toEqual({ role: 'revisor', state: 'trabajando' })
  expect(poseOfRun(runOf({ stage: '1-test-writer' }), edit)).toEqual({ role: 'tester', state: 'trabajando' })
  expect(poseOfRun(runOf({ stage: '1-infra-writer' }), text)).toEqual({ role: 'infraestructura', state: 'desplegando' })
  expect(poseOfRun(runOf({ state: 'hold' }), tool)).toEqual({ role: 'desarrollador', state: 'trabajando' })
})

test('poseOfResults: aprobado/error y variantes de infra', () => {
  const r = (pipeline: 'tdd' | 'infra', ok: boolean) => ({ key: 'k', issue: 1, pipeline, ok, text: '' })
  expect(poseOfResults([])).toBe(null)
  expect(poseOfResults([r('tdd', true)])).toEqual({ role: 'revisor', state: 'aprobado' })
  expect(poseOfResults([r('tdd', false)])).toEqual({ role: 'desarrollador', state: 'error' })
  expect(poseOfResults([r('infra', true)])).toEqual({ role: 'infraestructura', state: 'arriba' })
  expect(poseOfResults([r('infra', false)])).toEqual({ role: 'infraestructura', state: 'caido' })
})

const res = (issue: number, pr: number | null, pipeline: 'tdd' | 'infra' = 'tdd', ok = true) => ({
  key: `k${issue}`,
  issue,
  pipeline,
  ok,
  text: ok ? (pr ? `✓ PR #${pr}` : '✓ completado') : '✗ 1-writer',
})

test('resultPrs: solo ✓ con PR, sin repetir, del mas reciente al mas antiguo', () => {
  expect(prOfResult(res(1, 7))).toBe('7')
  expect(prOfResult(res(1, null))).toBe(null)
  expect(prOfResult(res(1, null, 'tdd', false))).toBe(null)
  const prs = resultPrs([res(1, 7), res(2, 9), res(3, null), res(4, 5, 'tdd', false), res(5, 7)])
  expect(prs.map(p => p.pr)).toEqual(['9', '7'])
})

test('mergeArgsOf: un PR, varios, "Todos" y texto libre; nunca --all', () => {
  const one = resultPrs([res(1, 7)])
  expect(mergeOptions(one)).toEqual(['Mergear #7', 'Cancelar'])
  expect(mergeArgsOf('Mergear #7', mergeOptions(one), one)).toBe('7')
  expect(mergeArgsOf('Cancelar', mergeOptions(one), one)).toBe(null)

  const many = resultPrs([res(1, 5), res(2, 6), res(3, 7), res(4, 8), res(5, 9)])
  const options = mergeOptions(many)
  expect(options).toHaveLength(4)
  expect(options[0]).toBe('Todos')
  expect(mergeArgsOf('Todos', options, many)).toBe('9 8 7 6 5')
  expect(mergeArgsOf(`${options[1]}, ${options[3]}`, options, many)).toBe('9 7')
  expect(mergeArgsOf('5, 99', options, many)).toBe('5')
  expect(mergeArgsOf(`${options[2]}, 5`, options, many)).toBe('8 5')
  expect(mergeArgsOf('99', options, many)).toBe(null)
  expect(mergeArgsOf('', options, many)).toBe(null)
  expect(mergeArgsOf(null, options, many)).toBe(null)
  expect(mergeArgsOf('Todos', options, many)).not.toContain('--all')
})

test('viewPrOf y parsePrArgs: solo numeros de ✓ conocidos', () => {
  const prs = resultPrs([res(1, 7), res(2, 9)])
  expect(viewPrOf('#9 · #2 tdd', prs)).toBe('9')
  expect(viewPrOf('7', prs)).toBe('7')
  expect(viewPrOf('55', prs)).toBe(null)
  expect(viewPrOf(null, prs)).toBe(null)
  expect(parsePrArgs('7 #9 55 7', prs)).toEqual({ prs: ['7', '9'], invalid: ['55'] })
})

test('mergeToast: en infra avisa que el issue lo cierra el apply de CI', () => {
  const prs = resultPrs([res(1, 7), res(2, 9, 'infra')])
  expect(mergeToast('7', prs)).toBe('/mefisto:merge 7 en cola')
  expect(mergeToast('7 9', prs)).toContain('apply de CI')
})

test('parseOpenPrs: borradores y field notes fuera; el mas reciente primero', () => {
  const raw = JSON.stringify([
    { number: 5, title: 'A', isDraft: false, headRefName: 'worktree-issue-5-a' },
    { number: 9, title: 'B', isDraft: false, headRefName: 'docs/bitacora-hasta-2026-10-08' },
    { number: 8, title: 'Borrador', isDraft: true, headRefName: 'x' },
    { number: 7, title: 'Nota', isDraft: false, headRefName: 'docs/planner-field-notes-abc' },
  ])
  expect(parseOpenPrs(raw)).toEqual([{ number: '9', title: 'B' }, { number: '5', title: 'A' }])
  expect(parseOpenPrs('no json')).toEqual([])
  expect(parseOpenPrs('{}')).toEqual([])
})

test('openPrArgsOf: uno, varios, "Todos" y texto libre; nunca --all', () => {
  const one = [{ number: '7', title: 'X' }]
  expect(openPrOptions(one)).toEqual(['#7 X', 'Cancelar'])
  expect(openPrArgsOf('#7 X', openPrOptions(one), one)).toBe('7')
  expect(openPrArgsOf('Cancelar', openPrOptions(one), one)).toBe(null)

  const many = [9, 8, 7, 6, 5].map(n => ({ number: String(n), title: `T${n}` }))
  const options = openPrOptions(many)
  expect(options).toEqual(['Todos', '#9 T9', '#8 T8', '#7 T7'])
  expect(openPrArgsOf('Todos', options, many)).toBe('9 8 7 6 5')
  expect(openPrArgsOf('Todos', options, many)).not.toContain('--all')
  expect(openPrArgsOf('#9 T9, #7 T7', options, many)).toBe('9 7')
  expect(openPrArgsOf('#8 T8, 5, 99', options, many)).toBe('8 5')
  expect(openPrArgsOf('99', options, many)).toBe(null)
  expect(openPrArgsOf(null, options, many)).toBe(null)
})

// ---- Incremento 7: lote ----
const batchRaw = (over: Record<string, unknown> = {}) =>
  JSON.stringify({
    pipeline: 'sequential',
    started: '2026-10-09T10:00:00',
    state: 'running',
    current: 13,
    stop_requested: false,
    hold_seconds: 0,
    log: 'x.log',
    issues: [
      { issue: 12, status: 'mergeado', pr: '#101', detail: '' },
      { issue: 13, status: 'en-curso', pr: null, detail: '' },
      { issue: 14, status: 'pendiente', pr: null, detail: '' },
    ],
    ...over,
  })
const batchNow = Date.parse('2026-10-09T10:07:30')

test('parseBatchStatus lee un lote running y calcula cabecera, cola y avance', () => {
  const b = parseBatchStatus(batchRaw())!
  expect(b.state).toBe('running')
  expect(b.current).toBe(13)
  expect(b.issues[0]?.pr).toBe('101')
  expect(batchHeader(b, batchNow)).toBe('sequential 1/3 · 7m')
  expect(batchQueueText(b)).toBe('✓ #12 · ● #13 · · #14')
  expect(canStopBatch(b)).toBe(true)
})

test('parseBatchStatus con stop_requested dice deteniendo y no ofrece 1', () => {
  const b = parseBatchStatus(batchRaw({ stop_requested: true }))!
  expect(batchHeader(b, batchNow)).toContain('deteniendo')
  expect(canStopBatch(b)).toBe(false)
})

test('parseBatchStatus completed con fallidos y saltados: conteos y resumen', () => {
  const b = parseBatchStatus(
    batchRaw({
      state: 'completed',
      current: null,
      hold_seconds: 600,
      issues: [
        { issue: 1, status: 'mergeado', pr: 5 },
        { issue: 2, status: 'fallido', pr: null, detail: 'review' },
        { issue: 3, status: 'saltado', pr: null, detail: 'infra' },
        { issue: 4, status: 'aplazado', pr: null },
      ],
    }),
  )!
  expect(batchCounts(b)).toEqual({ merged: 1, failed: 1, deferred: 1, skipped: 1, total: 4 })
  expect(batchSummaryText(b)).toBe('1 mergeados · 1 fallidos · 1 aplazados · 1 saltados · espera 10m por rate limit')
  expect(canStopBatch(b)).toBe(false)
})

test('parseBatchStatus stopped y entradas invalidas', () => {
  expect(parseBatchStatus(batchRaw({ state: 'stopped' }))?.state).toBe('stopped')
  expect(parseBatchStatus('no json')).toBe(null)
  expect(parseBatchStatus(batchRaw({ state: 'raro' }))).toBe(null)
  expect(parseBatchStatus('[]')).toBe(null)
})

test('batchPrOf: PR del eslabon en curso o del ultimo mergeado; sin PR, null', () => {
  expect(batchPrOf(parseBatchStatus(batchRaw())!)).toBe('101')
  const own = parseBatchStatus(
    batchRaw({ issues: [{ issue: 12, status: 'mergeado', pr: 101 }, { issue: 13, status: 'en-curso', pr: 102 }] }),
  )!
  expect(batchPrOf(own)).toBe('102')
  expect(batchPrOf(parseBatchStatus(batchRaw({ issues: [{ issue: 13, status: 'en-curso' }] }))!)).toBe(null)
})

test('newlyMerged solo anuncia las transiciones a mergeado', () => {
  const a = parseBatchStatus(batchRaw())!
  const b = parseBatchStatus(
    batchRaw({ issues: [{ issue: 12, status: 'mergeado' }, { issue: 13, status: 'mergeado', pr: 7 }, { issue: 14, status: 'en-curso' }] }),
  )!
  expect(newlyMerged(a.issues, b.issues).map(i => i.issue)).toEqual([13])
  expect(newlyMerged(null, b.issues)).toEqual([])
})

test('el eslabon en curso no se repite como corrida suelta y las demas se cuentan', () => {
  const b = parseBatchStatus(batchRaw())!
  const mk = (issue: number): ReturnType<typeof parseStatus> =>
    parseStatus(`pipeline-status-tdd-${issue}.json`, JSON.stringify({ issue, started: '20261009-100000', updated: '20261009-100100', stage: '2-implementer', state: 'running' }))
  const runs = [mk(13)!, mk(40)!]
  expect(batchRunOf(b, runs)?.issue).toBe(13)
  expect(runsOutsideBatch(b, runs).map(r => r.issue)).toEqual([40])
  expect(otherRunsText(1)).toBe('+1 corrida')
  expect(otherRunsText(2)).toBe('+2 corridas')
  expect(otherRunsText(0)).toBe('')
})

test('senal de parada en la raiz del checkout principal y clave de descarte por repo + started', () => {
  expect(batchStopPath('/r/')).toBe('/r/pipeline-state/batch-stop')
  expect(batchDismissKey('/r', parseBatchStatus(batchRaw())!)).toBe('/r|batch|2026-10-09T10:00:00')
})

test('bandViewOf: las corridas toman la banda solo con una activa', () => {
  const active = parseStatus('pipeline-status-tdd-7.json', status())!
  const failed = parseStatus('pipeline-status-tdd-8.json', status({ state: 'failed', stage: '2-infra-reviewer' }))!
  const res = [{ key: 'k', issue: 8, pipeline: 'tdd', ok: false, text: '✗ setup' }]
  expect(bandViewOf([active], [])).toBe('runs')
  expect(bandViewOf([active], res)).toBe('runs')
  expect(bandViewOf([], res)).toBe('ready-with-results')
  expect(bandViewOf([failed], [])).toBe('ready')
  expect(bandViewOf([], [])).toBe('ready')
})

test('resultsFooterText: formato, recorte al ancho y +N', () => {
  const res = [
    { key: 'a', issue: 7, pipeline: 'tdd', ok: true, text: '✓ PR #55' },
    { key: 'b', issue: 413, pipeline: 'infra', ok: false, text: '✗ 2-infra-reviewer' },
    { key: 'c', issue: 99, pipeline: 'tooling', ok: false, text: '✗ setup' },
  ]
  expect(resultsFooterText(res, 200)).toBe('resultados: ✓#7 PR #55 · ✗#413 2-infra-reviewer · ✗#99 setup')
  expect(resultsFooterText(res, 45)).toBe('resultados: ✓#7 PR #55 +2')
  expect(resultsFooterText(res, 45).length).toBeLessThanOrEqual(45)
})

const hist = (issue: string, started: string, title?: string) => ({ issue, pipeline: 'tdd', variant: null, started, pr: null, title })

test('batchTitleOf toma la entrada mas reciente dentro de la ventana del lote', () => {
  const entries = [hist('7', '20260101-000000', 'viejo'), hist('7', '20260102-100000', 'a'), hist('7', '20260102-110000', 'b')]
  expect(batchTitleOf(entries, 7, '20260102-090000')).toBe('b')
})

test('batchTitleOf ignora entradas anteriores al lote y issues ausentes', () => {
  const entries = [hist('7', '20260101-000000', 'viejo')]
  expect(batchTitleOf(entries, 7, '20260102-090000')).toBeNull()
  expect(batchTitleOf(entries, 8, '20260101-000000')).toBeNull()
})

test('batchIssueLine muestra el titulo y lo recorta para dejar PR y detalle', () => {
  const i = { issue: 12, status: 'mergeado' as const, pr: '30', detail: 'ok' }
  const full = batchIssueLine(i, 'Mostrar el titulo del issue')
  expect(full).toContain('#12  Mostrar el titulo del issue  · PR #30 · ok')
  const short = batchIssueLine(i, 'Mostrar el titulo del issue', 30)
  expect(short).toContain('…')
  expect(short.endsWith('· PR #30 · ok')).toBe(true)
  expect(short.length).toBeLessThanOrEqual(30)
  expect(batchIssueLine(i)).toBe(batchIssueLine(i, ''))
})
