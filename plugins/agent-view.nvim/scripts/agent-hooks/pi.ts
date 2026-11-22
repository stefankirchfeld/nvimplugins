import type { ExtensionAPI } from '@mariozechner/pi-coding-agent'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'

// Event choices follow workmux's public Pi integration; the writer is local.
export default function (pi: ExtensionAPI) {
  const writer = fileURLToPath(new URL('../agent-status.cjs', import.meta.url))
  let writes = Promise.resolve()
  const report = (status: string, payload = {}) => {
    writes = writes.then(async () => {
      if (!process.env.NVIM_AGENT_ID) return
      await new Promise<void>(resolve => {
        const child = spawn(process.execPath, [writer, status], { stdio: ['pipe', 'ignore', 'ignore'] })
        child.on('error', () => resolve())
        child.on('close', () => resolve())
        child.stdin.end(JSON.stringify(payload))
      })
    }).catch(() => {})
    return writes
  }
  const session = (ctx: { sessionManager: { getSessionId(): string }; cwd: string }) => ({
    session_id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd,
  })
  pi.on('session_start', (_event, ctx) => report('idle', session(ctx)))
  pi.on('session_switch', (_event, ctx) => report('idle', session(ctx)))
  pi.on('agent_start', (_event, ctx) => report('working', session(ctx)))
  pi.on('tool_execution_end', (event, ctx) => report('working', event.isError ? {} : {
    ...session(ctx), tool_name: event.toolName, tool_input: { path: event.args?.path },
  }))
  pi.on('agent_end', (_event, ctx) => report('done', session(ctx)))
  pi.on('agent_settled', (_event, ctx) => report('done', session(ctx)))
}
