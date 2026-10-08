import type { BoardItem, BoardList } from '../types'

export const NEXT_ORDER = './.claude/scripts/mefisto-next-order.sh'
export const PLANNER = 'mefisto-planner'
/** Filas fijas de la lista: la banda no cambia de alto con la cantidad de issues. */
export const LIST_ROWS = 5

/** El hilo principal de una sesion `claude --agent mefisto-planner`: un subagente trae agent_id. */
export function isPlannerMainThread(e: { agent_type?: string; agent_id?: string }): boolean {
  return e.agent_type === PLANNER && !e.agent_id
}

type NextOrderJson = {
  items?: { number: number; title: string; after?: number[]; hasDepsSection?: boolean }[]
  blocked?: unknown[]
  cycles?: unknown[]
  launch?: string | null
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 es un fallo de gh o de argumentos. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): BoardList {
  if (exitCode !== 0 && exitCode !== 1) {
    return { items: [], blockedCount: 0, cycleCount: 0, launch: null, error: firstLine(stderr) || `exit ${exitCode}` }
  }
  let json: NextOrderJson
  try {
    json = JSON.parse(stdout)
  } catch {
    return { items: [], blockedCount: 0, cycleCount: 0, launch: null, error: 'salida de next-order no es JSON' }
  }
  const items: BoardItem[] = (json.items ?? []).map(i => ({
    number: i.number,
    title: i.title,
    after: i.after ?? [],
    hasDepsSection: i.hasDepsSection !== false,
  }))
  return {
    items,
    blockedCount: (json.blocked ?? []).length,
    cycleCount: (json.cycles ?? []).length,
    launch: json.launch ?? null,
    error: null,
  }
}

type OpenIssue = { number: number; title?: string; updatedAt?: string; labels?: { name: string }[] }

export function parseOpenIssues(stdout: string): OpenIssue[] | null {
  try {
    const list = JSON.parse(stdout)
    return Array.isArray(list) ? list : null
  } catch {
    return null
  }
}

/** Cambia cuando entra, sale o se edita un issue abierto (labels o body actualizan updatedAt). */
export function signatureOf(issues: OpenIssue[]): string {
  return issues
    .map(i => `${i.number}:${i.updatedAt ?? ''}:${(i.labels ?? []).map(l => l.name).sort().join(',')}`)
    .sort()
    .join('|')
}

export type Arrival = { number: number; title: string; kind: 'borrador' | 'listo' }

/** Issues abiertos nuevos con estado borrador o listo. Sin conocidos previos (primer refresco) no hay avisos. */
export function arrivals(issues: OpenIssue[], known: number[]): Arrival[] {
  if (known.length === 0) return []
  const seen = new Set(known)
  const out: Arrival[] = []
  for (const i of issues) {
    if (seen.has(i.number)) continue
    const names = (i.labels ?? []).map(l => l.name)
    const kind = names.includes('estado:borrador') ? 'borrador' : names.includes('estado:listo') ? 'listo' : null
    if (kind) out.push({ number: i.number, title: i.title ?? '', kind })
  }
  return out
}

/** Solo lo que aporta: de que depende, o el aviso de que falta la seccion. "Sin dependencias" no se escribe. */
export function reasonOf(item: BoardItem): { text: string; isWarning: boolean } {
  if (!item.hasDepsSection) return { text: 'sin ## Dependencias', isWarning: true }
  if (item.after.length > 0) return { text: `tras ${item.after.map(n => `#${n}`).join(' ')}`, isWarning: false }
  return { text: '', isWarning: false }
}

/** Ancho comun de la columna de numeros (#801 y #1981 alineados). */
export function numberWidth(items: BoardItem[]): number {
  return Math.max(4, ...items.map(i => String(i.number).length + 1))
}

export function padEnd(text: string, width: number): string {
  return text.length >= width ? text : text + ' '.repeat(width - text.length)
}

export function clip(text: string, max: number): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > max ? `${one.slice(0, Math.max(1, max - 1))}…` : one
}

export function clockOf(ms: number): string {
  if (ms === 0) return ''
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}`
}

function firstLine(text: string): string {
  return text.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
}

const REFINE = /\brefin\w*\s+(?:el\s+)?(?:borrador\s+)?#(\d+)/i

/** `refina #801`, `Refina el borrador #801`, `refinemos #801`: el issue a refinar, o null. */
export function refineTargetOf(prompt: string): number | null {
  const m = REFINE.exec(prompt)
  return m ? Number(m[1]) : null
}

/** El tema de una exploracion: la primera linea con contenido del mensaje, recortada. */
export function topicOf(prompt: string): string {
  const line = prompt.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return clip(line.replace(/^quiero explorar:\s*/i, ''), 70)
}

export function isIssueCreate(command: string): boolean {
  return /\bgh\s+issue\s+create\b/.test(command)
}

/** `gh issue edit 801 ... --add-label estado:listo`: el issue que pasa a listo, o null. */
export function issueMarkedListo(command: string): number | null {
  const m = /\bgh\s+issue\s+edit\s+#?(\d+)\b/.exec(command)
  if (!m || !/--add-label[=\s]+["']?[^"'\s]*estado:listo/.test(command)) return null
  return Number(m[1])
}

export function isPlannerClosing(command: string): boolean {
  return /mefisto-field-note\.sh/.test(command)
}

/** Numero del issue que `gh issue create` imprime como URL. */
export function createdIssueOf(output: string): number | null {
  const m = /\/issues\/(\d+)/.exec(output)
  return m ? Number(m[1]) : null
}

export function createdText(created: number[]): string {
  return created.length > 0 ? `creó ${created.map(n => `#${n}`).join(' ')}` : ''
}

/** Issues por pagina: en listos la ultima fila es la del batch (/mefisto-sequential). */
export function pageSizeOf(tab: 'borrador' | 'listo'): number {
  return tab === 'listo' ? LIST_ROWS - 1 : LIST_ROWS
}

/** Pagina valida (0-based) para una lista de `total` items; vuelve a 0 si la lista se achico. */
export function pageOf(page: number, total: number, size: number): { page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(total / size))
  return { page: page >= 0 && page < pages ? page : 0, pages }
}

type HerdrPane = { pane_id: string; tab_id?: string; label?: string; agent?: string }

/**
 * El pane de ejecucion hermano del planner en herdr: misma pestaña, etiqueta que empieza por
 * "ejecucion" y, si hay varias, la del mismo runtime que el planner (`ejecucion [claude]`).
 */
export function executionPaneOf(listJson: string, currentPaneId: string): string | null {
  let panes: HerdrPane[]
  try {
    panes = JSON.parse(listJson)?.result?.panes ?? []
  } catch {
    return null
  }
  const current = panes.find(p => p.pane_id === currentPaneId)
  if (!current) return null
  const candidates = panes.filter(
    p => p.pane_id !== currentPaneId && p.tab_id === current.tab_id && /^ejecuci[oó]n\b/i.test(p.label ?? ''),
  )
  const sameRuntime = candidates.find(p => current.agent && p.agent === current.agent)
  return (sameRuntime ?? candidates[0])?.pane_id ?? null
}
