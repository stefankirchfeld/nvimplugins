#!/usr/bin/env node
'use strict'

// One launch path for both the main assistant and assistants beside Vim.
const fs = require('fs')
const path = require('path')
const { spawn } = require('child_process')
const agentStatus = require('./agent-status.cjs')
const agentHooks = require('./agent-hooks.cjs')

const harness = process.argv[2] || 'claude'
if (!['claude', 'codex', 'pi'].includes(harness)) {
  console.error(`Unknown assistant: ${harness}`)
  process.exit(1)
}

const separator = process.argv.indexOf('--', 3)
const options = process.argv.slice(3, separator === -1 ? undefined : separator)
const args = separator === -1 ? [] : process.argv.slice(separator + 1)
let workingDir = process.cwd()
const cwdIndex = options.indexOf('--cwd')
if (cwdIndex !== -1) {
  if (!options[cwdIndex + 1]) throw new Error('--cwd requires a folder')
  workingDir = path.resolve(options[cwdIndex + 1])
}
let registration
const launchEnv = { ...process.env }
delete launchEnv.NVIM_AGENT_ID
delete launchEnv.MESA_AGENT_ID // A nested or failed launch must never update its parent.
try { registration = agentStatus.start({ agent: harness, folder: workingDir, env: launchEnv }) } catch (error) {
  console.error('Agent overview unavailable: ' + error.message)
}
if (harness === 'claude') args.unshift('--settings', JSON.stringify(agentHooks.config('claude')))
if (harness === 'codex') args.unshift('--no-daemon', '--enable', 'hooks')
if (harness === 'pi') args.unshift('-e', path.join(__dirname, 'agent-hooks/pi.ts'))
const cleanup = () => {
  const current = registration
  registration = null
  if (current) {
    try { agentStatus.remove(current) } catch (error) { console.error('Agent metadata cleanup: ' + error.message) }
  }
}
process.on('exit', cleanup)
const child = spawn(harness, args, { cwd: workingDir, stdio: 'inherit', env: registration?.env || launchEnv })
let refreshWarning = false
const timer = registration ? setInterval(() => {
  if (!registration) return
  try {
    agentStatus.refresh(registration.env)
    refreshWarning = false
  } catch (error) {
    if (!refreshWarning) console.error('Agent title refresh: ' + error.message)
    refreshWarning = true
  }
}, 2000) : null
timer?.unref()
child.on('error', error => {
  console.error('Could not start ' + harness + ': ' + error.message)
  if (timer) clearInterval(timer)
  cleanup()
  process.exitCode = 1
})
child.on('exit', (code, signal) => {
  if (timer) clearInterval(timer)
  cleanup()
  process.exitCode = code ?? (128 + (require('node:os').constants.signals[signal] || 1))
})
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => child.kill(signal))
}
