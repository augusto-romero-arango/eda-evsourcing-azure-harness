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
  /** Numeros de los `tipo:infra` lanzables, en el orden de items. */
  infra: number[]
  /** Lote de `/mefisto:parallel` calculado por next-order. */
  parallel: { issues: number[]; launch: string | null } | null
  error: string | null
}

export type PipelineKind = 'tdd' | 'tooling' | 'infra'

/** Un `pipeline-status-*.json` ya parseado; lo que la consola muestra de una corrida. */
export type PipelineRun = {
  issue: number
  pipeline: PipelineKind
  variant: string | null
  started: string
  updated: string
  stage: string
  state: string
  nextProbe: string | null
}

/** Una corrida terminada pendiente de descartar: `✗ <stage>` o `✓ PR #X`. */
export type PipelineResult = { key: string; issue: number; pipeline: PipelineKind; text: string; ok: boolean }

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
      pactRuns: PipelineRun[]
      pactResults: PipelineResult[]
      pactLastEvent: { kind: 'tool' | 'text'; tool: string } | null
      pactTick: number
    }
  }
}
