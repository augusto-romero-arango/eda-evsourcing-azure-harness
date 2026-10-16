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
  /** Pasos de `status.agents` en su orden (#2320). */
  agents?: RunStep[]
  /** Ruta del log del pipeline (`status.log`). */
  log?: string | null
  /** Titulo del issue (`status.title`). */
  title?: string
  /** Ultimo error del status (`last_error`) de una corrida fallida. */
  lastError?: string
}

/** Una linea del pane de log: evento del agente o linea del log del pipeline (`log`, atenuada). */
export type PaneLine = { kind: 'start' | 'tool' | 'fail' | 'done' | 'log'; text: string }

/** Un agente del status: `pending` cubre todo `result` vacio o desconocido. */
export type RunStep = { name: string; result: 'passed' | 'running' | 'failed' | 'pending'; /** Segundos del paso (`agents.<x>.duration`). */ duration?: number }

/** Una corrida terminada pendiente de descartar: `✗ <stage>` o `✓ PR #X`. */
export type PipelineResult = { key: string; issue: number; pipeline: PipelineKind; text: string; ok: boolean }

/** Una fila de la cinta de merge de la consola. */
export type PactMergePr = { num: string; title: string; estado: 'pendiente' | 'mergeado' | 'fallido' }

/** La cinta de merge en curso de la consola; `finishedMs` null mientras corre. */
export type PactMerge = { prs: PactMergePr[]; startedMs: number; finishedMs: number | null }

/** Una field note que integra el historiador: pendiente hasta que aparece en `procesadas/`. */
export type BitacoraNote = { name: string; estado: 'pendiente' | 'procesada' }

/** El PR de bitacora que dejo el historiador, abierto a la espera de mergearlo o cerrarlo. */
export type BitacoraPr = { number: number; title: string }

/** El subagente historiador escribiendo la bitacora en esta sesion (lo lanza /mefisto:bitacora). */
export type Historian = { startedMs: number; finishedMs: number | null; notes: BitacoraNote[]; pr: BitacoraPr | null }

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
      pactBandLines: string[]
      pactOpenPrs: { number: string; title: string; isFieldNote: boolean }[]
      pactFieldNotes: number | null
      pactHistorian: Historian | null
      pactBatch: {
        pipeline: string
        started: string
        state: 'running' | 'completed' | 'failed' | 'stopped'
        current: number | null
        stopRequested: boolean
        holdSeconds: number
        issues: { issue: number; status: 'pendiente' | 'en-curso' | 'mergeado' | 'fallido' | 'aplazado' | 'saltado'; pr: string | null; detail: string }[]
      } | null
      pactBatchStats: {
        stats: Record<string, { durationMs: number; costUsd: number | null; title: string | null; finishedMs: number }>
        endedMs: number | null
      }
      /** Fila `●` del sequential en curso: su corrida y, si espera el merge, el instante en que se congela su tiempo (#2361). */
      pactBatchCurrent: { run: PipelineRun; endMs: number | null } | null
      /** Lote parallel en curso (#2449), leido de `pipeline-status-parallel.json`; null si no corre. */
      pactParallel: {
        started: string
        state: 'running' | 'completed' | 'failed' | 'stopped'
        stopRequested: boolean
        log?: string
        issues: {
          issue: number
          pipeline: string | null
          status: 'pendiente' | 'en-curso' | 'terminado' | 'fallido' | 'aplazado' | 'saltado'
          pr: string | null
          startedMs: number
          finishedMs: number
          detail: string
        }[]
      } | null
      pactParallelStats: Record<string, { durationMs: number; costUsd: number | null; title: string | null; finishedMs: number }>
      /** Banda de cada issue en curso del parallel: su corrida, sus ultimas lineas y su ultimo evento (para la pose). */
      pactParallelBands: Record<string, { run: PipelineRun | null; lines: string[]; last: { kind: 'tool' | 'text'; tool: string } | null }>
      pactParallelPage: number
      pactMerge: PactMerge | null
      pactLogLines: PaneLine[]
      pactPaneRun: PipelineRun | null
      pactTick: number
      pactVersion: string | null
    }
  }
}
