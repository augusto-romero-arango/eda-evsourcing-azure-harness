export type BoardItem = {
  number: number
  title: string
  after: number[]
  hasDepsSection: boolean
}

export type BoardList = {
  items: BoardItem[]
  blockedCount: number
  cycleCount: number
  launch: string | null
  error: string | null
}

export type BoardTab = 'borrador' | 'listo'

/** Lo que el planner esta haciendo: refinar un borrador o explorar una idea. */
export type BoardFocus = {
  kind: 'refinar' | 'explorar'
  issue: number | null
  topic: string
  created: number[]
  startedMs: number
}

/** Ficha de un issue: lo que la conversacion no muestra (labels, de que depende y a quien bloquea). */
export type IssueCard = {
  number: number
  title: string
  labels: string[]
  deps: number[]
  hasDepsSection: boolean
}

/** Issue abierto, para saber si una dependencia sigue abierta y en que estado. */
export type OpenIssueBrief = { number: number; title: string; labels: string[] }

/** Resumen breve que la banda muestra al cerrar un foco. */
export type BoardFlash = { text: string; untilMs: number }

declare module 'claude-code' {
  interface PluginState {
    'mefisto-planner-board': {
      isActive: boolean
      isPlannerSession: boolean
      isExpanded: boolean
      tab: BoardTab
      page: number
      frame: 0 | 1
      stepsInTurn: number
      isWorking: boolean
      focus: BoardFocus | null
      card: IssueCard | null
      open: OpenIssueBrief[]
      flash: BoardFlash | null
      refine: BoardList | null
      develop: BoardList | null
      updatedMs: number
      signature: string
      pendingCount: number
      known: number[]
    }
  }
}
