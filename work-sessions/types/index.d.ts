export type Step = { name: string; startsOn?: string }

export type Progress = { title: string; steps: Step[]; current: number }

declare module 'claude-code' {
  interface PluginState {
    'work-sessions': { progress: Progress | null; isHidden: boolean; sessionId: string | null }
  }
}
