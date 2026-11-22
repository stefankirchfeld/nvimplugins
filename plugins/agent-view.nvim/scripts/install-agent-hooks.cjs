'use strict'
// Codex stores command hooks in CODEX_HOME/hooks.json. Claude and Pi load
// theirs per launch; this installer only adds guarded Mesa entries to Codex.
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { isDeepStrictEqual } = require('node:util')
const { config } = require('./agent-hooks.cjs')
const home = process.env.CODEX_HOME || process.env.CODEX_CONFIG_DIR || path.join(os.homedir(), '.codex')
const file = path.join(home, 'hooks.json')
const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {}
let added = 0
const migrateIndex = process.argv.indexOf('--migrate-from')
const legacy = migrateIndex >= 0 ? path.resolve(process.argv[migrateIndex + 1], 'agent-status.cjs') : null
if (legacy) {
  for (const [event, groups] of Object.entries(data.hooks || {})) {
    for (const group of groups) {
      group.hooks = (group.hooks || []).filter(hook => {
        const owned = typeof hook.command === 'string' && hook.command.includes('MESA_AGENT_ID') && hook.command.includes(legacy)
        if (owned) added++
        return !owned
      })
    }
    data.hooks[event] = groups.filter(group => group.hooks.length)
  }
}

const removing = process.argv.includes('--remove')
if (removing) {
  for (const [event, groups] of Object.entries(data.hooks || {})) {
    for (const group of groups) {
      group.hooks = (group.hooks || []).filter(hook => {
        const owned = typeof hook.command === 'string' && hook.command.includes('NVIM_AGENT_ID')
          && hook.command.includes(path.join(__dirname, 'agent-status.cjs'))
        if (owned) added++
        return !owned
      })
    }
    data.hooks[event] = groups.filter(group => group.hooks.length)
  }
}
for (const [event, groups] of Object.entries(removing ? {} : config('codex').hooks)) {
  const current = (data.hooks ||= {})[event] ||= []
  for (const group of groups) {
    if (!current.some(existing => isDeepStrictEqual(existing, group))) {
      current.push(group)
      added++
    }
  }
}
if (added) {
  fs.mkdirSync(home, { recursive: true })
  if (fs.existsSync(file)) {
    const backup = file + '.pre-agent-view-' + Date.now()
    fs.copyFileSync(file, backup)
    console.log('Backup: ' + backup)
  }
  const tmp = file + '.agent-view-tmp'
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 })
  fs.renameSync(tmp, file)
}
if (!removing) fs.mkdirSync(require('./agent-status.cjs').directory(), { recursive: true, mode: 0o700 })
console.log('Agent view Codex hooks ' + (removing ? 'removed' : 'added') + ': ' + added)
console.log('Hooks: ' + file)
