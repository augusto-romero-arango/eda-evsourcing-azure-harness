import { expect, test } from 'claude-code/testing'

import { agentFlagOf, historianFrom, isAgentActive, isReleasePrompt, isReleaseRun, holdOf, holdText, bitacoraPrompt, changelogOf, fieldNotesIn, releaseArgsOf, releaseOptions, mergeArgsOf, mergeOptions, parseOpenPrs, withoutHeredocs, fmtCost, issueStatsFromHistory, statsTotal, batchFromStatus, batchIssuesOf, batchPr, batchSummary, issueMark, newlyMerged, readyRows, titlesOf, toolingOf, waitingFace, cropGrid, pageOf, parseNextOrder, sequentialOf, finishedFromHistory, mascotPose, parseEvent, usedColumns, relative, pickEventsFile, steps, stampToMs, toolingIssueOf, withModUi } from './logic'

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
  expect(withModUi('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 1')).toBe('MEFISTO_RUNTIME=claude MEFISTO_UI=mod ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 1')
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
  const prev = { issues: [], state: 'running', current: null, stopRequested: false, holdSeconds: 0, startedMs: 0, finishedMs: null, stats: {} } as const
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

test('MEFISTO_UI=mod llega al wrapper aunque vaya dentro de un comando compuesto', async () => {
  expect(withModUi('./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7')).toBe('MEFISTO_UI=mod ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7')
  expect(withModUi('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-validate-batch-deps.sh 2080; rc=$?; [ "$rc" -eq 0 ] && MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 2080'))
    .toBe('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-validate-batch-deps.sh 2080; rc=$?; [ "$rc" -eq 0 ] && MEFISTO_RUNTIME=claude MEFISTO_UI=mod ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 2080')
  expect(withModUi('MEFISTO_UI=tmux ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7')).toBe('MEFISTO_UI=tmux ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7')
})

test('duracion y costo de cada issue terminado desde el historial', async () => {
  const entry = (issue: string, started: string, finished: string, costs: (number | null)[]) =>
    JSON.stringify({
      issue, pipeline: 'mefisto-tooling', started, finished,
      agents: Object.fromEntries(costs.map((c, i) => [`a${i}`, { metrics: { estimated_cost_usd: c } }])),
    })
  const tail = [
    entry('2080', '20261008-100000', '2026-10-08T10:05:00', [0.1, 0.25]),
    entry('2081', '20261008-090000', '2026-10-08T09:01:00', [1]),
    entry('2081', '20261008-101000', '2026-10-08T10:12:30', [null]),
    'no json',
  ].join('\n')
  const stats = issueStatsFromHistory(tail, ['2080', '2081'], stampToMs('20261008-095959'))
  expect(stats['2080']).toEqual({ durationMs: 300_000, costUsd: 0.35 })
  expect(stats['2081']).toEqual({ durationMs: 150_000, costUsd: null })
  expect(fmtCost(0.35)).toBe('$0.35')
  expect(fmtCost(null)).toBe('$?')
  expect(statsTotal(Object.values(stats))).toEqual({ durationMs: 450_000, costUsd: 0.35 })
})

test('solo cuenta el wrapper que se ejecuta, no el que aparece como texto', async () => {
  const heredoc = "python3 - <<'EOF'\nx = './.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7'\n./.claude/scripts/mefisto-tmux-pipeline.sh --batch 8 9\nEOF\necho listo"
  expect(withoutHeredocs(heredoc)).toBe("python3 - <<heredoc\necho listo")
  expect(toolingIssueOf(heredoc)).toBe(null)
  expect(batchIssuesOf(heredoc)).toBe(null)
  expect(toolingIssueOf('grep -n "mefisto-tmux-pipeline.sh --tooling 7" a.md')).toBe(null)
  expect(toolingIssueOf("echo 'mefisto-tmux-pipeline.sh --tooling 7'")).toBe(null)
  expect(toolingIssueOf('cd /repo && MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 7')).toBe('7')
  expect(batchIssuesOf('a; rc=$?; [ "$rc" -eq 0 ] && X=1 ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 8 9')).toEqual(['8', '9'])
  expect(withModUi('echo "mefisto-tmux-pipeline.sh"; ./s/mefisto-tmux-pipeline.sh --tooling 7'))
    .toBe('echo "mefisto-tmux-pipeline.sh"; MEFISTO_UI=mod ./s/mefisto-tmux-pipeline.sh --tooling 7')
})

test('el merge desde la banda ofrece todos o los PRs mas recientes y arma los argumentos de /mefisto-merge', async () => {
  const prs = parseOpenPrs(JSON.stringify([
    { number: 2089, title: 'B', isDraft: false }, { number: 2097, title: 'A', isDraft: false },
    { number: 2090, title: 'Borrador', isDraft: true }, { number: 2085, title: 'C' }, { number: 1994, title: 'D' },
    { number: 2084, title: 'docs(bitacora): field note', headRefName: 'docs/mefisto-planner-field-note-abc' },
  ]))
  expect(prs?.map(p => p.number)).toEqual([2097, 2089, 2085, 2084, 1994])
  expect(prs?.filter(p => p.isFieldNote).map(p => p.number)).toEqual([2084])
  expect(mergeOptions((prs ?? []).filter(p => !p.isFieldNote))).toEqual(['Todos (--all)', '#2097 A', '#2089 B', '#2085 C'])
  expect(mergeOptions([{ number: 7, title: 'X', isFieldNote: false }])).toEqual(['#7 X', 'Cancelar'])
  const options = ['Todos (--all)', '#2097 field note 2026-10-08-1848', '#2089 B']
  expect(mergeArgsOf('Todos (--all), #2097 field note 2026-10-08-1848', options)).toBe('--all')
  expect(mergeArgsOf('#2097 field note 2026-10-08-1848, #2089 B', options)).toBe('2097 2089')
  expect(mergeArgsOf('#2089 B, 1994 2063', options)).toBe('2089 1994 2063')
  expect(mergeArgsOf('Cancelar', ['#7 X', 'Cancelar'])).toBe(null)
  expect(parseOpenPrs('no json')).toBe(null)
})

test('bitacora y release: contadores, opciones e instruccion', async () => {
  expect(fieldNotesIn(['2026-10-01-1548-mefisto-planner.md', 'procesadas', 'x.txt'])).toBe(1)
  const summary = changelogOf(['README.md', '2090.changed.md', '2090.fixed.md', '2093.added.md', '2094.fixed.md'])
  expect(summary).toEqual({ issues: 3, added: 1, changed: 1, fixed: 2, removed: 0 })
  expect(releaseOptions(summary)).toEqual(['minor (recomendado)', 'patch', 'Solo preparar el PR (minor --prepare-only)'])
  expect(releaseOptions({ ...summary, added: 0 })[0]).toBe('patch (recomendado)')
  expect(releaseArgsOf('minor (recomendado)')).toBe('minor')
  expect(releaseArgsOf('Solo preparar el PR (minor --prepare-only)')).toBe('minor --prepare-only')
  expect(releaseArgsOf('otra cosa')).toBe(null)
  expect(bitacoraPrompt([])).toBe(
    'Integra la bitacora: pon el checkout en main al dia (git switch main && git pull --ff-only) y luego corre /mefisto-bitacora.',
  )
  expect(bitacoraPrompt([2097, 2089])).toBe(
    'Integra la bitacora: mergea los PRs de field notes #2097 #2089 con /mefisto-merge, pon el checkout en main al dia (git switch main && git pull --ff-only) y luego corre /mefisto-bitacora.',
  )
})

test('la espera por rate limit se lee de la ultima linea de events.log', async () => {
  const hold = '[18:51:24][hold] RATE_LIMIT: esperando, proxima sonda 20:51:00 (techo 00:51)'
  expect(holdOf(`[18:50:00][tool] mefisto-writer Bash ok\n${hold}\n`)).toEqual({ family: 'RATE_LIMIT', nextProbe: '20:51', deadline: '00:51' })
  expect(holdOf(`${hold}\n[18:51:24][hold][resume] writer: reanudando sesion x`)).toBe(null)
  expect(holdOf(`${hold}\n[20:52:00][tool] mefisto-writer Bash ok`)).toBe(null)
  expect(holdText({ family: 'RATE_LIMIT', nextProbe: '20:51', deadline: '00:51' })).toBe('en espera por RATE_LIMIT · próxima sonda 20:51 · techo 00:51')
})

test('reconoce el release que se lanza y su script en ejecucion', async () => {
  expect(isReleasePrompt('/mefisto-release minor')).toBe(true)
  expect(isReleasePrompt('/mefisto-release')).toBe(true)
  expect(isReleasePrompt('/mefisto-releases')).toBe(false)
  expect(isReleaseRun('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-release.sh minor')).toBe(true)
  expect(isReleaseRun('grep -n release src/internal/scripts/mefisto-release.sh')).toBe(false)
})

test('sigue al historiador por su estado, aunque corra en segundo plano', async () => {
  expect(isAgentActive('running')).toBe(true)
  expect(isAgentActive('waiting')).toBe(true)
  expect(isAgentActive('completed')).toBe(false)
  expect(historianFrom(null, false, 5)).toBe(null)
  const writing = historianFrom(null, true, 10)
  expect(writing).toEqual({ startedMs: 10, finishedMs: null })
  expect(historianFrom(writing, true, 20)).toBe(writing)
  const done = historianFrom(writing, false, 30)
  expect(done).toEqual({ startedMs: 10, finishedMs: 30 })
  expect(historianFrom(done, false, 40)).toBe(done)
  expect(historianFrom(done, true, 50)).toEqual({ startedMs: 50, finishedMs: null })
})
