import { expect, test } from 'claude-code/testing'

import {
  arrivals,
  createdIssueOf,
  isIssueCreate,
  isPlannerClosing,
  isPlannerMainThread,
  issueMarkedListo,
  executionPaneOf,
  pageOf,
  parseNextOrder,
  reasonOf,
  refineTargetOf,
  signatureOf,
  topicOf,
} from './logic'

test('solo el hilo principal de --agent mefisto-planner activa el tablero', async () => {
  expect(isPlannerMainThread({ agent_type: 'mefisto-planner' })).toBe(true)
  expect(isPlannerMainThread({ agent_type: 'mefisto-planner', agent_id: 'a1' })).toBe(false)
  expect(isPlannerMainThread({ agent_type: 'general-purpose' })).toBe(false)
  expect(isPlannerMainThread({})).toBe(false)
})

test('lee el JSON de next-order, vacio y con fallo', async () => {
  const ok = parseNextOrder(
    0,
    '{"mode":"refinement","items":[{"number":801,"title":"A","after":[],"hasDepsSection":false}],"blocked":[{"number":2,"by":3,"reason":"external"}],"cycles":[],"launch":null}',
    '',
  )
  expect(ok.items[0]?.number).toBe(801)
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

test('la razon solo dice lo que aporta', async () => {
  const item = { number: 5, title: 't', after: [3, 4], hasDepsSection: true }
  expect(reasonOf(item)).toEqual({ text: 'tras #3 #4', isWarning: false })
  expect(reasonOf({ ...item, after: [] })).toEqual({ text: '', isWarning: false })
  expect(reasonOf({ ...item, hasDepsSection: false })).toEqual({ text: 'sin ## Dependencias', isWarning: true })
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
  expect(isPlannerClosing('MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-field-note.sh --agent mefisto-planner')).toBe(true)
  expect(isIssueCreate('gh issue create --title "X" --label "estado:borrador"')).toBe(true)
  expect(createdIssueOf('https://github.com/o/r/issues/2085\n')).toBe(2085)
})

test('pagina con su tamaño y vuelve a la primera si la lista se achica', async () => {
  expect(pageOf(0, 12, 5)).toEqual({ page: 0, pages: 3 })
  expect(pageOf(2, 12, 5)).toEqual({ page: 2, pages: 3 })
  expect(pageOf(2, 4, 4)).toEqual({ page: 0, pages: 1 })
  expect(pageOf(0, 0, 5)).toEqual({ page: 0, pages: 1 })
})

test('encuentra el pane de ejecucion hermano del planner', async () => {
  const list = JSON.stringify({
    result: {
      panes: [
        { pane_id: 'w9:p1', tab_id: 'w9:t1', label: 'planner [claude]', agent: 'claude' },
        { pane_id: 'w9:p3', tab_id: 'w9:t1', label: 'ejecucion [claude]', agent: 'claude' },
        { pane_id: 'w9:p5', tab_id: 'w9:t1', label: 'ejecucion [opencode]', agent: 'opencode' },
        { pane_id: 'w8:p2', tab_id: 'w8:t1', label: 'ejecucion [claude]', agent: 'claude' },
      ],
    },
  })
  expect(executionPaneOf(list, 'w9:p1')).toBe('w9:p3')
  expect(executionPaneOf(list, 'w0:p1')).toBe(null)
  expect(executionPaneOf('no json', 'w9:p1')).toBe(null)
})
