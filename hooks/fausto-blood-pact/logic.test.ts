import { expect, test } from 'claude-code/testing'

import {
  agentFlagOf,
  agentSettingOf,
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
