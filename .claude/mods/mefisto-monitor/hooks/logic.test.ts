import { expect, test } from 'claude-code/testing'

import { finishedFromHistory, parseEvent, relative, pickEventsFile, steps, stampToMs, toolingIssueOf, withModUi } from './logic'

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
