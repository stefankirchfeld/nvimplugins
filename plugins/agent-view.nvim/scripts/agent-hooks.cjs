'use strict'
const path = require('node:path')
function quote(value) { return "'" + value.replace(/'/g, "'\\''") + "'" }
function command(status) {
  return 'if [ -n "${NVIM_AGENT_ID:-${MESA_AGENT_ID:-}}" ]; then ' + quote(process.execPath) + ' '
    + quote(path.join(__dirname, 'agent-status.cjs')) + ' ' + status + '; fi'
}
function group(status, matcher) {
  const entry = { hooks: [{ type: 'command', command: command(status) }] }
  if (matcher) entry.matcher = matcher
  return entry
}
function config(agent) {
  const hooks = {
    SessionStart: [group('idle', agent === 'claude' ? 'startup|resume|clear|fork' : 'startup|resume|clear')],
    UserPromptSubmit: [group('working')],
    PreToolUse: [group('working')],
    PostToolUse: [group('working')],
    Stop: [group('done')],
  }
  if (agent === 'claude') {
    hooks.Notification = [group('waiting', 'permission_prompt|elicitation_dialog')]
  } else if (agent === 'codex') {
    hooks.PermissionRequest = [group('waiting')]
    hooks.SubagentStart = [group('working')]
    hooks.SubagentStop = [group('working')]
  } else throw new Error('No JSON hook adapter for ' + agent)
  return { hooks }
}
module.exports = { config }
