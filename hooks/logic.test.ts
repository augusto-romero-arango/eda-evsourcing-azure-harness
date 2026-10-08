import { expect, test } from 'claude-code/testing'

import {
  arrivals,
  isIssueChange,
  createdIssueOf,
  isIssueCreate,
  cropGrid,
  mascotPose,
  usedColumns,
  isPlannerClosing,
  issueMarkedListo,
  agentFlagOf,
  agentSettingOf,
  transcriptPathOf,
  pageOf,
  parseNextOrder,
  reasonOf,
  refineTargetOf,
  signatureOf,
  topicOf,
  typeBadge,
  nextOrderPath,
} from './logic'

test('lee el JSON de next-order, vacio y con fallo', async () => {
  const ok = parseNextOrder(
    0,
    '{"mode":"refinement","items":[{"number":801,"title":"A","tipo":"tooling","after":[],"hasDepsSection":false}],"blocked":[{"number":2,"by":3,"reason":"external"}],"cycles":[],"launch":null}',
    '',
  )
  expect(ok.items[0]?.number).toBe(801)
  expect(ok.items[0]?.tipo).toBe('tooling')
  expect(ok.items[0]?.hasDepsSection).toBe(false)
  expect(ok.blockedCount).toBe(1)
  expect(parseNextOrder(1, '{"items":[],"blocked":[],"cycles":[],"launch":null}', '').error).toBe(null)
  expect(parseNextOrder(2, '', "ERROR: fallo 'gh issue list'\n").error).toBe("ERROR: fallo 'gh issue list'")
})

test('la firma cambia con labels y updatedAt, no con el orden de la lista', async () => {
  const a = [{ number: 1, updatedAt: 't1', labels: [{ name: 'estado:borrador' }] }, { number: 2, updatedAt: 't2' }]
  expect(signatureOf(a)).toBe(signatureOf([...a].reverse()))
  expect(signatureOf(a)).not.toBe(signatureOf([{ ...a[0]!, labels: [{ name: 'estado:listo' }] }, a[1]!]))
})

test('avisa solo de borradores y listos nuevos, nunca en el primer refresco', async () => {
  const issues = [
    { number: 1, title: 'viejo', labels: [{ name: 'estado:listo' }] },
    { number: 2, title: 'nuevo borrador', labels: [{ name: 'estado:borrador' }] },
    { number: 3, title: 'sin estado', labels: [] },
  ]
  expect(arrivals(issues, [])).toEqual([])
  expect(arrivals(issues, [1])).toEqual([{ number: 2, title: 'nuevo borrador', kind: 'borrador' }])
})

test('la razon solo dice de que depende', async () => {
  const item = { number: 5, title: 't', tipo: null, after: [3, 4], hasDepsSection: true }
  expect(reasonOf(item)).toBe('tras #3 #4')
  expect(reasonOf({ ...item, after: [], hasDepsSection: false })).toBe('')
})

test('el mensaje marca el foco: refinar #N o explorar con tema', async () => {
  expect(refineTargetOf('Refina el borrador #801')).toBe(801)
  expect(refineTargetOf('refinemos #1800 por favor')).toBe(1800)
  expect(refineTargetOf('mira el #801 antes')).toBe(null)
  expect(topicOf('Quiero explorar: tablero del planner con foco\nmas detalle')).toBe('tablero del planner con foco')
})

test('reconoce las senales de cierre y de borradores creados', async () => {
  expect(issueMarkedListo('gh issue edit 801 --remove-label "estado:borrador" --add-label "estado:listo" --add-label "tipo:tooling"')).toBe(801)
  expect(issueMarkedListo('gh issue edit 801 --add-label bloqueado')).toBe(null)
  expect(isPlannerClosing('MEFISTO_RUNTIME=claude ./.claude/scripts/field-note.sh --agent mefisto:planner')).toBe(true)
  expect(isIssueCreate('gh issue create --title "X" --label "estado:borrador"')).toBe(true)
  expect(createdIssueOf('https://github.com/o/r/issues/2085\n')).toBe(2085)
})

test('pagina con su tamaño y vuelve a la primera si la lista se achica', async () => {
  expect(pageOf(0, 12, 5)).toEqual({ page: 0, pages: 3 })
  expect(pageOf(2, 12, 5)).toEqual({ page: 2, pages: 3 })
  expect(pageOf(2, 4, 4)).toEqual({ page: 0, pages: 1 })
  expect(pageOf(0, 0, 5)).toEqual({ page: 0, pages: 1 })
})

test('reconoce la sesion del planner por su transcript', async () => {
  const planner = '{"type":"user"}\n{"type":"agent-setting","agentSetting":"mefisto:planner","sessionId":"s"}\n'
  expect(agentSettingOf(planner)).toBe('mefisto:planner')
  expect(agentSettingOf('{"type":"user"}\n')).toBe(null)
  expect(agentSettingOf('roto\n{"type":"agent-setting","agentSetting":"otro"}')).toBe('otro')
  expect(transcriptPathOf('/h/.claude', '/Users/a/Cosmos/eda-evsourcing-azure-harness', 'id1')).toBe(
    '/h/.claude/projects/-Users-a-Cosmos-eda-evsourcing-azure-harness/id1.jsonl',
  )
})

test('lee el --agent de la linea de comando del proceso', async () => {
  expect(agentFlagOf('claude --agent mefisto:planner --plugin-dir /x')).toBe('mefisto:planner')
  expect(agentFlagOf('/usr/local/bin/claude --agent=mefisto:planner')).toBe('mefisto:planner')
  expect(agentFlagOf('claude --plugin-dir /x')).toBe(null)
})

test('la mascota es siempre la del planner', async () => {
  expect(mascotPose(true, 2, false)).toBe('planeando')
  expect(mascotPose(true, 0, false)).toBe('pensando')
  expect(mascotPose(false, 3, true)).toBe('listo')
  expect(mascotPose(false, 0, false)).toBe('planeando')
})

test('recorta las columnas vacias comunes a todos los cuadros', async () => {
  const a = ['..x...', '...x..']
  const b = ['....x.', '..x...']
  expect(usedColumns([a, b])).toEqual({ from: 2, to: 4 })
  expect(cropGrid(a, { from: 2, to: 4 })).toEqual(['x..', '.x.'])
})


test('reconoce los cambios de issues que obligan a refrescar las listas', async () => {
  expect(isIssueChange('gh issue edit 2080 --add-label estado:listo')).toBe(true)
  expect(isIssueChange('gh issue create --title x')).toBe(true)
  expect(isIssueChange('gh issue close 12')).toBe(true)
  expect(isIssueChange('gh issue view 12')).toBe(false)
})

test('traduce el tipo a su letra y color, y ? gris si falta', async () => {
  expect(typeBadge('feature')).toEqual({ letter: 'F', color: 'success' })
  expect(typeBadge('refactor').letter).toBe('R')
  expect(typeBadge('projection')).toEqual({ letter: 'P', color: 'cyan' })
  expect(typeBadge('tooling')).toEqual({ letter: 'T', color: 'magenta' })
  expect(typeBadge('infra')).toEqual({ letter: 'I', color: 'blue' })
  expect(typeBadge(null)).toEqual({ letter: '?', color: 'gray' })
  expect(typeBadge('otro').letter).toBe('?')
})

test('el cierre es field-note.sh y la ruta de next-order cuelga de la raiz del plugin', async () => {
  expect(isPlannerClosing('"$root/scripts/field-note.sh" --agent mefisto:planner')).toBe(true)
  expect(isPlannerClosing('gh issue view 3')).toBe(false)
  expect(nextOrderPath('/p/mefisto/')).toBe('/p/mefisto/scripts/next-order.sh')
})
