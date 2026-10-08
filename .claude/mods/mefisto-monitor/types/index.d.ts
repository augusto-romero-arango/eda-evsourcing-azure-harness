export type MonitorAgent = { duration: number | null; result: string }

export type MonitorRun = {
  issue: string
  title: string
  stage: string
  state: 'running' | 'completed' | 'failed'
  startedMs: number
  finishedMs: number | null
  agents: Record<string, MonitorAgent>
  pr: string | null
  lastError: string | null
  eventsFile: string | null
}

export type LogKind = 'start' | 'tool' | 'text' | 'fail' | 'done'

export type LogLine = { ts: string; kind: LogKind; text: string }

declare module 'claude-code' {
  interface PluginState {
    'mefisto-monitor': {
      run: MonitorRun | null
      lines: LogLine[]
      now: number
    }
  }
}
