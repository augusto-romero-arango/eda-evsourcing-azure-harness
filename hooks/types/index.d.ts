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

/** Una fila de la cinta de merge de la consola. */
export type PactMergePr = { num: string; title: string; estado: 'pendiente' | 'mergeado' | 'fallido' }

/** La cinta de merge en curso de la consola; `finishedMs` null mientras corre. */
export type PactMerge = { prs: PactMergePr[]; startedMs: number; finishedMs: number | null }

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
      pendingCount: number
      version: string | null
      pactIsActive: boolean
      pactList: BoardList | null
      pactPage: number
      pactRuns: PipelineRun[]
      pactResults: PipelineResult[]
      pactLastEvent: { kind: 'tool' | 'text'; tool: string } | null
      pactOpenPrs: { number: string; title: string }[]
      pactBatch: {
        pipeline: string
        started: string
        state: 'running' | 'completed' | 'failed' | 'stopped'
        current: number | null
        stopRequested: boolean
        holdSeconds: number
        issues: { issue: number; status: 'pendiente' | 'en-curso' | 'mergeado' | 'fallido' | 'aplazado' | 'saltado'; pr: string | null; detail: string }[]
      } | null
      pactMerge: PactMerge | null
      pactTick: number
      pactVersion: string | null
    }
  }
}
