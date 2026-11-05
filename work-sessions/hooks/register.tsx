import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Progress, Step } from '../types'

const progress = atom({ plugin: 'work-sessions', key: 'progress' } as const, null)
const isHidden = atom({ plugin: 'work-sessions', key: 'isHidden' } as const, false)
const sessionId = atom({ plugin: 'work-sessions', key: 'sessionId' } as const, null)

const PROGRESS_TOOL = 'mcp__work-sessions__progress'

const PROGRESS_DESCRIPTION = [
  'Shows a multi-step workflow in a row above the prompt: its title, every step, and the current one.',
  'Call it once when the workflow starts, with every step, and again with `current` each time a step starts.',
  'A step may carry `startsOn`, a regular expression; a later Bash command matching it moves the row to that step by itself.',
  'Call it with `clear: true` when the workflow ends.',
].join(' ')

const PROGRESS_SCHEMA = {
  type: 'object',
  properties: {
    title: { type: 'string', description: 'What the workflow works on, e.g. the issue key.' },
    steps: {
      type: 'array',
      description: 'Every step in order; send it on the first call, and again only when the steps change.',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          startsOn: { type: 'string', description: 'Regular expression on a Bash command that means this step has started.' },
        },
        required: ['name'],
      },
    },
    current: { type: 'integer', minimum: 1, description: 'The step that is starting now, counted from 1.' },
    clear: { type: 'boolean', description: 'Removes the row: the workflow has ended.' },
  },
}

const shortId = (id: string) => id.replace(/-/g, '').slice(0, 8)

const shellQuote = (text: string) => `'${text.replace(/'/g, `'\\''`)}'`

async function sessionEnvFile($: EngineInterface): Promise<string | null> {
  try {
    const id = await read($, sessionId)
    const home = await $.env.get('HOME')
    if (id === null || home === undefined) return null
    const file = `${home}/.cc/sessions/${id}/env`
    return (await $.fs.exists(file)) ? file : null
  } catch {
    return null
  }
}

function commandParts(command: string): string[] {
  return [command, ...command.split(/&&|\|\||;|\n/).map(part => part.trim())]
}

function stepMatching(steps: readonly Step[], after: number, command: string): number | null {
  for (let i = steps.length; i > after; i--) {
    const pattern = steps[i - 1]?.startsOn
    if (pattern === undefined) continue
    try {
      const matcher = new RegExp(pattern)
      if (commandParts(command).some(part => matcher.test(part))) return i
    } catch {
      continue
    }
  }
  return null
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({ name: 'progress', description: PROGRESS_DESCRIPTION, inputSchema: PROGRESS_SCHEMA, isDeferred: false })
    await $.command.register({ name: 'progress', description: 'Show or hide the workflow progress row' })

    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    try {
      await update($, sessionId, was => (e.source === 'startup' || was === null ? shortId(e.session_id) : was))
      const ran = await $.process.run(['bash', `${$.plugin.root}/kit/lifecycle.sh`, 'start'], { stdin: JSON.stringify(e), timeoutMs: 10000 })
      const notice = ran.stdout.trim()
      if (notice !== '') $.ui.toast(notice)
    } catch {
      $.ui.toast('work-sessions: could not check for earlier sessions.')
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.SessionEnd', async ($, e, next) => {
    try {
      await $.process.run(['bash', `${$.plugin.root}/kit/lifecycle.sh`, 'end'], { stdin: JSON.stringify(e), timeoutMs: 5000 })
    } catch {
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const envFile = await sessionEnvFile($)
    const ran = await next(envFile === null ? e : { ...e, command: `. ${shellQuote(envFile)} && ${e.command}` })

    try {
      const shown = await read($, progress)
      if (shown !== null && ran.deny === undefined && ran.isError !== true) {
        const step = stepMatching(shown.steps, shown.current, e.command)
        if (step !== null) await update($, progress, p => (p === null ? p : { ...p, current: step }))
      }
    } catch {
    }

    return ran
  }).catch(($, e, next) => (next.called ? { deny: 'work-sessions failed after the command ran; its result is above.' } : next(e)))

  on('tool.call', { tool: PROGRESS_TOOL }, async ($, e) => {
    if (e.clear === true) {
      await update($, progress, () => null)
      return { result: 'Progress row removed.' }
    }
    const before = await read($, progress)
    const steps: Step[] = Array.isArray(e.steps) ? e.steps : before?.steps ?? []
    if (steps.length === 0) return { result: 'No steps yet: send `steps` on the first call.', isError: true }
    const current = Math.min(Math.max(1, Number(e.current ?? before?.current ?? 1)), steps.length)
    const title = typeof e.title === 'string' ? e.title : before?.title ?? ''
    await update($, progress, () => ({ title, steps, current }))
    await update($, isHidden, () => false)

    return { result: `Showing ${title} step ${current}/${steps.length}: ${steps[current - 1]?.name ?? ''}.` }
  }).catch(() => ({ result: 'The progress row could not be updated.', isError: true }))

  on('command.run', { command: 'progress' }, async $ => {
    const hidden = await update($, isHidden, was => !was)

    return { text: hidden ? 'Progress row hidden. /progress shows it again.' : 'Progress row shown.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const shown = await read($, progress)
    if (e.props.hasSurvey || shown === null || (await read($, isHidden))) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const { title, steps, current } = shown
    const following = steps[current]

    return (
      <Box>
        {title !== '' && <Text bold>{title} </Text>}
        <Text color="green">{'●'.repeat(current - 1)}</Text>
        <Text bold color="yellow">◉</Text>
        <Text dimColor>{'○'.repeat(steps.length - current)} </Text>
        <Text bold color="yellow">
          {current}/{steps.length} {steps[current - 1]?.name ?? ''}
        </Text>
        <Text dimColor>{following ? `   next ${following.name}  ` : '   last step  '}</Text>
        <Button key="hide" label="Hide" onPress={() => update($, isHidden, () => true)} />
      </Box>
    )
  })
}
