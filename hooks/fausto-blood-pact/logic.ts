import type { BoardItem, BoardList } from '../types'

export const NEXT_ORDER_FILE = 'scripts/next-order.sh'
export const PLANNER_AGENT = 'mefisto:planner'
export const PAGE_ROWS = 5

export function nextOrderPath(root: string): string {
  return `${root.replace(/\/+$/, '')}/${NEXT_ORDER_FILE}`
}

type NextOrderJson = {
  items?: { number: number; title: string; tipo?: string | null; after?: number[]; hasDepsSection?: boolean }[]
  blocked?: unknown[]
  cycles?: unknown[]
  launch?: string | null
}

function firstLine(text: string): string {
  return text.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
}

/** Exit 0 (hay orden) y 1 (vacio) traen JSON valido; 2 u otro es un fallo. */
export function parseNextOrder(exitCode: number, stdout: string, stderr: string): BoardList {
  const failed = (error: string): BoardList => ({ items: [], blockedCount: 0, cycleCount: 0, launch: null, error })
  if (exitCode !== 0 && exitCode !== 1) return failed(firstLine(stderr) || `exit ${exitCode}`)
  let json: NextOrderJson
  try {
    json = JSON.parse(stdout)
  } catch {
    return failed('salida de next-order no es JSON')
  }
  const items: BoardItem[] = (json.items ?? []).map(i => ({
    number: i.number,
    title: i.title,
    tipo: i.tipo ?? null,
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

export function clip(text: string, max: number): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > max ? `${one.slice(0, Math.max(1, max - 1))}…` : one
}

/** Pagina vigente (acotada) y total de paginas; siempre al menos una. */
export function pageOf(page: number, total: number, size: number): { page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(total / size))
  return { page: Math.min(Math.max(0, page), pages - 1), pages }
}

/** Linea de una fila: numero de orden, `#issue`, tipo y titulo. */
export function rowText(item: BoardItem, position: number, numWidth: number, titleMax: number): string {
  const n = `${position}.`.padEnd(numWidth)
  return `${n} #${item.number} [${item.tipo ?? '?'}] ${clip(item.title, titleMax)}`
}

/** Pie con los issues que no entran al orden; vacio si no hay ninguno. */
export function footerOf(list: BoardList): string {
  return [
    list.blockedCount > 0 ? `${list.blockedCount} bloqueados` : '',
    list.cycleCount > 0 ? `${list.cycleCount} en ciclo` : '',
  ]
    .filter(Boolean)
    .join(' · ')
}

export function isMefistoManifest(raw: string): boolean {
  try {
    return (JSON.parse(raw) as { name?: unknown }).name === 'mefisto'
  } catch {
    return false
  }
}

export function transcriptPathOf(configDir: string, cwd: string, sessionId: string): string {
  return `${configDir}/projects/${cwd.replace(/[^A-Za-z0-9]/g, '-')}/${sessionId}.jsonl`
}

/** La ultima fila `agent-setting` del transcript de la sesion, o null. */
export function agentSettingOf(transcript: string): string | null {
  let found: string | null = null
  for (const line of transcript.split('\n')) {
    if (!line.includes('"agent-setting"')) continue
    try {
      const row = JSON.parse(line)
      if (row.type === 'agent-setting' && typeof row.agentSetting === 'string') found = row.agentSetting
    } catch {
      continue
    }
  }
  return found
}

/** El `--agent` de una linea de comando de Claude Code (`--agent x` o `--agent=x`), o null. */
export function agentFlagOf(cmdline: string): string | null {
  const m = /(?:^|\s)--agent(?:=|\s+)(\S+)/.exec(cmdline)
  return m ? (m[1] ?? null) : null
}
