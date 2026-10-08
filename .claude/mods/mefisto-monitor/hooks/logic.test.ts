import { expect, test } from 'claude-code/testing'

import { agentFlagOf, batchFromStatus, batchIssuesOf, batchPr, batchSummary, issueMark, newlyMerged, readyRows, titlesOf, toolingOf, waitingFace, cropGrid, pageOf, parseNextOrder, sequentialOf, finishedFromHistory, mascotPose, parseEvent, usedColumns, relative, pickEventsFile, steps, stampToMs, toolingIssueOf, withModUi } from './logic'

test('detecta el lanzamiento de /mefisto-tooling', async () => {
  expect(toolingIssueOf('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 2059')).toBe('2059')
  expect(toolingIssueOf('./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 2059 --models opus')).toBe('2059')
  expect(toolingIssueOf('./.claude/scripts/mefisto-tmux-pipeline.sh --batch 1 2')).toBe(null)
  expect(toolingIssueOf('git status')).toBe(null)
})

test('elige el events.jsonl mas reciente del issue', async () => {
  const since = stampToMs('20261007-225000')
  const entries = [
    { name: 'mefisto-tooling-stage-1-writer-20261007-225622-issue-2059.events.jsonl', mtimeMs: 10 },
    { name: 'mefisto-tooling-stage-2-reviewer-20261007-225622-issue-2059.events.jsonl', mtimeMs: 20 },
    { name: 'mefisto-tooling-stage-2-reviewer-20261007-225622-issue-2058.events.jsonl', mtimeMs: 30 },
    { name: 'mefisto-tooling-stage-1-writer-20261001-100000-issue-2059.events.jsonl', mtimeMs: 40 },
    { name: 'mefisto-tooling-stage-2-reviewer-20261007-225622-issue-2059.stream.jsonl', mtimeMs: 50 },
  ]
  expect(pickEventsFile(entries, '2059', since)).toBe(
    'mefisto-tooling-stage-2-reviewer-20261007-225622-issue-2059.events.jsonl',
  )
  expect(pickEventsFile(entries, '9999', since)).toBe(null)
})

test('porta el filtro del visor', async () => {
  expect(parseEvent('{"v":1,"type":"tool.started","ts":"2026-10-08T03:58:47.000Z","tool":"Bash","input_summary":"git diff"}')?.text).toBe('Bash git diff')
  expect(parseEvent('{"v":1,"type":"tool.completed","tool":"Bash","ok":true}')).toBe(null)
  expect(parseEvent('{"v":1,"type":"tool.completed","tool":"Bash","ok":false}')?.kind).toBe('fail')
  expect(parseEvent('{"v":1,"type":"message","role":"assistant","text":"Corro\\nlos checks."}')?.text).toBe('Corro los checks.')
  expect(parseEvent('{"v":1,"type":"run.completed","status":"success","turns":7,"estimated_cost_usd":0.315}')?.text).toBe('success · 7 turnos · $0.32')
  expect(parseEvent('no es json')).toBe(null)
})

test('lee el cierre de la corrida desde el historial', async () => {
  const tail = [
    '{"issue":"2059","pipeline":"mefisto-tooling","started":"20261001-100000","state":"failed"}',
    '{"issue":"2059","pipeline":"mefisto-tooling","started":"20261007-225622","state":"completed","pr":"https://github.com/o/r/pull/2071"}',
  ].join('\n')
  expect(finishedFromHistory(tail, '2059', stampToMs('20261007-225000'))?.pr).toBe('https://github.com/o/r/pull/2071')
  expect(finishedFromHistory(tail, '2059', stampToMs('20261008-000000'))).toBe(null)
})

test('marca los stages', async () => {
  const run = {
    issue: '1', title: '', stage: '2-reviewer', state: 'running' as const, startedMs: 0, finishedMs: null,
    agents: {}, pr: null, lastError: null, eventsFile: null,
  }
  expect(steps(run).map(s => s.mark)).toEqual(['done', 'done', 'current', 'pending'])
  expect(steps({ ...run, state: 'failed' }).map(s => s.mark)).toEqual(['done', 'done', 'failed', 'pending'])
})

test('acorta las rutas del worktree', async () => {
  expect(relative('/Users/x/Cosmos/worktree-mefisto-issue-1982-enmendar/docs/adr/a.md')).toBe('docs/adr/a.md')
  expect(relative('git diff')).toBe('git diff')
})

test('antepone MEFISTO_UI=mod sin pisar uno explicito', async () => {
  expect(withModUi('MEFISTO_RUNTIME=claude ./x.sh --tooling 1')).toBe('MEFISTO_UI=mod MEFISTO_RUNTIME=claude ./x.sh --tooling 1')
  expect(withModUi('MEFISTO_UI=tmux ./x.sh --tooling 1')).toBe('MEFISTO_UI=tmux ./x.sh --tooling 1')
})

test('la mascota toma el rol del stage y la pose del ultimo evento', async () => {
  const run = { issue: '1', title: '', stage: '1-writer', state: 'running', startedMs: 0, finishedMs: null, agents: {}, pr: null, lastError: null, eventsFile: null } as const
  const tool = (text: string) => ({ ts: '', kind: 'tool', text }) as const
  expect(mascotPose(run, undefined)).toEqual({ role: 'desarrollador', state: 'pensando' })
  expect(mascotPose(run, tool('Bash ls'))).toEqual({ role: 'desarrollador', state: 'trabajando' })
  expect(mascotPose(run, { ts: '', kind: 'text', text: 'hola' })).toEqual({ role: 'desarrollador', state: 'pensando' })
  const reviewer = { ...run, stage: '2-reviewer' }
  expect(mascotPose(reviewer, tool('Read a.md'))).toEqual({ role: 'revisor', state: 'trabajando' })
  expect(mascotPose(reviewer, tool('Edit a.md'))).toEqual({ role: 'revisor', state: 'corrigiendo' })
  expect(mascotPose({ ...run, state: 'completed' }, undefined)).toEqual({ role: 'revisor', state: 'aprobado' })
  expect(mascotPose({ ...run, state: 'failed' }, tool('Bash x'))).toEqual({ role: 'desarrollador', state: 'error' })
})

test('recorta las columnas vacias comunes a todos los cuadros', async () => {
  const cols = usedColumns([['..a.', '....'], ['.b..', '    ']])
  expect(cols).toEqual({ from: 1, to: 2 })
  expect(cropGrid(['..a.', '....'], cols)).toEqual(['.a', '..'])
})

test('lee los listos de next-order, vacio y con fallo', async () => {
  const json = JSON.stringify({ items: [{ number: 7, title: 'Uno', after: [5] }], blocked: [{ number: 9, by: 3 }, { number: 9, by: 4 }], cycles: [], launch: '/mefisto-sequential 7' })
  expect(parseNextOrder(0, json, '')).toEqual({
    items: [{ number: 7, title: 'Uno', after: [5] }], blocked: [{ number: 9, title: '', by: [3, 4] }], cycleCount: 0, launch: '/mefisto-sequential 7', error: null,
  })
  expect(parseNextOrder(1, '{"items":[],"launch":null}', '').items).toEqual([])
  expect(parseNextOrder(2, '', 'gh: no auth\n').error).toBe('gh: no auth')
})

test('un listo suelto sale por /mefisto-sequential o, sin merge, por /mefisto-tooling', async () => {
  expect(sequentialOf(1746)).toBe('/mefisto-sequential 1746')
  expect(toolingOf(1746)).toBe('/mefisto-tooling 1746')
})

test('reconoce la sesion del planner por su --agent', async () => {
  expect(agentFlagOf('claude --agent mefisto-planner')).toBe('mefisto-planner')
  expect(agentFlagOf('claude --agent=mefisto-planner --model opus')).toBe('mefisto-planner')
  expect(agentFlagOf('claude')).toBe(null)
})

test('pagina los listos y vuelve a la primera si la lista se achica', async () => {
  expect(pageOf(1, 7, 5)).toEqual({ page: 1, pages: 2 })
  expect(pageOf(2, 7, 5)).toEqual({ page: 0, pages: 2 })
})

test('en espera: reloj de arena y ojos que miran de un lado al otro mientras trabaja', async () => {
  const base = Array(12).fill('.'.repeat(18))
  expect(waitingFace(base, null)[6]).toBe('YYYY.rrEErrEErr.tt')
  expect(waitingFace(base, null)[7]).toBe('gyyg.rrEErrEErr..t')
  expect(waitingFace(base, null)[9]).toBe('g..g..rrrrMMMr..t.')
  expect(waitingFace(base, 0)[6]).toBe('YYYY.rEErrEErrr.tt')
  expect(waitingFace(base, 1)[7]).toBe('g..g.rrrEErrEEr..t')
  expect(waitingFace(base, 1)[10]).toBe('gyyg..............')
})

test('la lista muestra los lanzables con tecla y al final los bloqueados sin tecla', async () => {
  const json = JSON.stringify({ items: [{ number: 1746, title: 'Proteger main', after: [] }], blocked: [{ number: 2082, by: 2080 }, { number: 2082, by: 2081 }] })
  const list = parseNextOrder(0, json, '', titlesOf('[{"number":2082,"title":"Crear el tablero"}]'))
  expect(readyRows(list)).toEqual([
    { number: 1746, title: 'Proteger main', reason: '', isLaunchable: true },
    { number: 2082, title: 'Crear el tablero', reason: '', isLaunchable: false },
  ])
  expect(titlesOf('no json')).toEqual({})
})

test('detecta el lanzamiento del batch y sus issues en orden', async () => {
  expect(batchIssuesOf('MEFISTO_UI=mod ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 1746 2079 2080')).toEqual(['1746', '2079', '2080'])
  expect(batchIssuesOf('./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 2059')).toBe(null)
})

test('lee el estado del batch e ignora el de un batch anterior', async () => {
  const prev = { issues: [], state: 'running', current: null, stopRequested: false, holdSeconds: 0, startedMs: 0, finishedMs: null } as const
  const raw = JSON.stringify({
    started: '20261008-190000', state: 'running', current: '2079', stop_requested: false, hold_seconds: 120,
    issues: [{ issue: '1746', status: 'completado (PR #2093 mergeado)', pr: '2093' }, { issue: '2079', status: 'en curso', pr: null }],
  })
  const batch = batchFromStatus(raw, prev, stampToMs('20261008-185959'))
  expect(batch.current).toBe('2079')
  expect(batch.issues.map(i => issueMark(i.status))).toEqual(['done', 'current'])
  expect(batchPr(batch)).toBe('2093')
  expect(batchFromStatus(raw, prev, stampToMs('20261008-200000'))).toBe(prev)
  expect(batchSummary({ ...batch, issues: [...batch.issues, { issue: '3', status: 'ERROR: x', pr: null }, { issue: '4', status: 'aplazado (parada)', pr: null }] }))
    .toBe('✓ 1 mergeados · ✗ 1 fallidos · ⏸ 1 aplazados · espera 2m')
})

test('avisa una sola vez por issue mergeado', async () => {
  const before = [{ issue: '1', status: 'en curso', pr: '9' }]
  const after = [{ issue: '1', status: 'completado (PR #9 mergeado)', pr: '9' }]
  expect(newlyMerged(before, after).map(i => i.issue)).toEqual(['1'])
  expect(newlyMerged(after, after)).toEqual([])
})
