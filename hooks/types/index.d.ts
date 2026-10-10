export type BoardItem = {
  number: number
  title: string
  tipo: string | null
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

/** Resumen breve que la banda muestra al cerrar un foco. */
export type BoardFlash = { text: string; untilMs: number }

declare module 'claude-code' {
  interface PluginState {
    mefisto: {
      isActive: boolean
      isPlannerSession: boolean
      isExpanded: boolean
      tab: BoardTab
      page: number
      frame: 0 | 1
      stepsInTurn: number
      isWorking: boolean
      focus: BoardFocus | null
      isConfirmingClose: boolean
      flash: BoardFlash | null
      refine: BoardList | null
      develop: BoardList | null
      updatedMs: number
      signature: string
      known: number[]
      pactIsActive: boolean
      pactList: BoardList | null
      pactPage: number
    }
  }
}
