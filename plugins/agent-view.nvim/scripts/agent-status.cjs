'use strict'

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const crypto = require('node:crypto')
const { execFileSync } = require('node:child_process')

const STATUSES = new Set(['idle', 'working', 'waiting', 'done', 'error'])
function directory(env = process.env) {
  return env.NVIM_AGENTS_DIR || env.MESA_AGENTS_DIR || path.join(env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'mesa', 'agents')
}
function filename(id, dir) {
  if (!/^[a-zA-Z0-9_-]+$/.test(id || '')) throw new Error('Invalid agent ID')
  return path.join(dir, id + '.json')
}
function atomicWrite(file, record) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const temporary = file + '.' + crypto.randomUUID() + '.tmp'
  try {
    fs.writeFileSync(temporary, JSON.stringify(record) + '\n', { mode: 0o600 })
    fs.renameSync(temporary, file)
  } finally {
    try { fs.unlinkSync(temporary) } catch (error) { if (error.code !== 'ENOENT') throw error }
  }
}
function coordinates(env) {
  if (!env.TMUX_PANE) return {}
  try {
    const fields = execFileSync('tmux', ['display-message', '-p', '-t', env.TMUX_PANE,
      '#{socket_path}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}'],
    { env, encoding: 'utf8', timeout: 1500, stdio: ['ignore', 'pipe', 'ignore'] }).trim().split('\t')
    if (fields.length !== 5) return {}
    const [tmux_socket, session_id, session, window_id, pane_id] = fields
    return { tmux_socket, session_id, session, window_id, pane_id }
  } catch { return {} }
}
function start({ agent, folder, env = process.env, pid = process.pid, tmux = coordinates(env) }) {
  const dir = directory(env)
  const id = pid + '-' + crypto.randomBytes(6).toString('hex')
  const now = Math.floor(Date.now() / 1000)
  const record = { version: 1, id, agent, folder: path.resolve(folder), status: 'idle', pid,
    created_at: now, updated_at: now, ...tmux }
  const file = filename(id, dir)
  atomicWrite(file, record)
  return { id, dir, file, record, env: { ...env, NVIM_AGENT_ID: id, NVIM_AGENTS_DIR: dir } }
}
function alive(pid) {
  try { process.kill(pid, 0); return true } catch (error) { return error.code === 'EPERM' }
}
function withLock(file, callback) {
  const lock = file + '.lock'
  let descriptor
  const deadline = Date.now() + 1500
  while (descriptor === undefined) {
    try {
      descriptor = fs.openSync(lock, 'wx', 0o600)
      fs.writeFileSync(descriptor, String(process.pid))
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
      try {
        const owner = Number(fs.readFileSync(lock, 'utf8'))
        if ((owner > 0 && !alive(owner)) || (!owner && Date.now() - fs.statSync(lock).mtimeMs > 2000)) {
          fs.unlinkSync(lock)
          continue
        }
      } catch (readError) { if (readError.code === 'ENOENT') continue; throw readError }
      if (Date.now() >= deadline) throw new Error('Agent metadata is busy')
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5)
    }
  }
  try { return callback() } finally {
    fs.closeSync(descriptor)
    try { fs.unlinkSync(lock) } catch (error) { if (error.code !== 'ENOENT') throw error }
  }
}
function read(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}
function conversationFile(agent, id, dir) {
  const key = crypto.createHash('sha256').update(agent + '\0' + id).digest('hex')
  return path.join(dir, 'conversations', key + '.json')
}
function conversationDetails(record) {
  const details = {}
  for (const key of ['title', 'last_file', 'last_project', 'last_edit_at']) {
    if (record[key] !== undefined) details[key] = record[key]
  }
  return details
}
function completion(record, payload, dir) {
  const eventId = crypto.randomUUID()
  const event = { ...record, event_id: eventId, type: 'done', completed_at: Date.now(),
    turn_id: payload.turn_id }
  atomicWrite(path.join(dir, 'notifications', eventId + '.json'), event)
  // Keep a week of events; readers maintain their own cursor and never consume files.
  for (const name of fs.readdirSync(path.join(dir, 'notifications'))) {
    if (!name.endsWith('.json')) continue
    const file = path.join(dir, 'notifications', name)
    try {
      if (fs.statSync(file).mtimeMs < Date.now() - 7 * 86400000) fs.unlinkSync(file)
    } catch (error) { if (error.code !== 'ENOENT') throw error }
  }
}
function nativeTitle(record) {
  if (!record.tmux_socket || !record.pane_id) return ''
  try {
    let title = execFileSync('tmux', ['-S', record.tmux_socket, 'display-message', '-p', '-t', record.pane_id, '#{pane_title}'],
      { encoding: 'utf8', timeout: 1000, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    title = title.replace(/^[\u2800-\u28ff✳✻✽⏺⏵●○✓✔]\s*/u, '').replace(/[\r\n]/g, ' ')
    const suffix = ' | ' + path.basename(record.folder)
    if (title.endsWith(suffix)) title = title.slice(0, -suffix.length)
    if ([os.hostname(), os.hostname().split('.')[0], record.agent, 'node', 'bash', 'zsh'].includes(title)) return ''
    return title.slice(0, 240)
  } catch { return '' }
}
function projectRoot(file) {
  let dir = path.dirname(file)
  while (true) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir
    const parent = path.dirname(dir)
    if (parent === dir) return path.dirname(file)
    dir = parent
  }
}
function editPaths(payload) {
  payload = payload && typeof payload === 'object' ? payload : {}
  const tool = String(payload.tool_name || payload.toolName || '').split(/\.|__/).pop().toLowerCase()
  let input = payload.tool_input ?? payload.toolInput ?? payload.input ?? {}
  if (typeof input === 'string') { try { input = JSON.parse(input) } catch {} }
  if (input === null) input = {}
  const paths = []
  if (['write', 'edit', 'multiedit', 'write_file', 'edit_file', 'replace_in_file'].includes(tool)) {
    const candidate = input.file_path || input.filePath || input.path
    if (typeof candidate === 'string') paths.push(candidate)
  }
  if (['apply_patch', 'applypatch'].includes(tool)) {
    const patch = typeof input === 'string' ? input : input.patch || input.input || input.content || ''
    for (const match of String(patch).matchAll(/^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+)$/gm)) paths.push(match[1].trim())
  }
  const result = payload.tool_response ?? payload.tool_output ?? payload.tool_result
  // MCP tools may wrap their file list in structured text blocks.
  const resultText = value => {
    if (typeof value === 'string') return value
    if (Array.isArray(value)) return value.map(resultText).join('\n')
    if (!value || typeof value !== 'object') return ''
    return [value.text, value.output, value.content, value.result].map(resultText).filter(Boolean).join('\n')
  }
  const output = resultText(result)
  if (output.includes('Success. Updated the following files:')) {
    for (const match of output.replace(/\\n/g, '\n').matchAll(/^[AMD] (.+)$/gm)) paths.push(match[1].trim())
  }
  return paths
}
function update(status, env = process.env, payload = {}) {
  env = { ...env, NVIM_AGENT_ID: env.NVIM_AGENT_ID || env.MESA_AGENT_ID }
  payload = payload && typeof payload === 'object' ? payload : {}
  if (!STATUSES.has(status)) throw new Error('Unknown agent status: ' + status)
  if (!env.NVIM_AGENT_ID) return false // Hooks outside a registered launch do nothing.
  const file = filename(env.NVIM_AGENT_ID, directory(env))
  const record = read(file)
  if (!record) return false
  if (record.id !== env.NVIM_AGENT_ID || !alive(record.pid)) return false
  const title = nativeTitle(record)
  const files = editPaths(payload)
  const cwd = typeof payload.cwd === 'string' ? payload.cwd : record.folder
  const last = files.length ? path.resolve(cwd, files[files.length - 1]) : null
  return withLock(file, () => {
    const current = read(file)
    if (!current || !alive(current.pid)) return false
    const now = Math.floor(Date.now() / 1000)
    const details = title ? { title } : {}
    if (last) Object.assign(details, { last_file: last, last_project: projectRoot(last), last_edit_at: now })
    const suppliedId = payload.session_id || payload.thread_id || payload.conversation_id
    const conversationId = typeof suppliedId === 'string' && suppliedId.length > 0 && suppliedId.length <= 512
      ? suppliedId : current.conversation_id
    let base = { ...current }
    if (current.conversation_id && conversationId !== current.conversation_id) {
      for (const key of ['title', 'last_file', 'last_project', 'last_edit_at']) delete base[key]
    }
    if (conversationId) {
      const archive = conversationFile(current.agent, conversationId, directory(env))
      fs.mkdirSync(path.dirname(archive), { recursive: true, mode: 0o700 })
      withLock(archive, () => {
        const saved = read(archive) || {}
        base = { ...base, ...conversationDetails(saved), ...details, conversation_id: conversationId }
        atomicWrite(archive, { agent: current.agent, conversation_id: conversationId,
          ...conversationDetails(base), updated_at: now })
      })
    }
    const next = { ...base, ...details, status, updated_at: now }
    // A durable event survives a quick next turn or removal of the live record.
    if (status === 'done' && (current.status !== 'done' ||
      (payload.turn_id && payload.turn_id !== current.completed_turn_id))) {
      completion(next, payload, directory(env))
      next.completed_turn_id = payload.turn_id
    }
    atomicWrite(file, next)
    return true
  })
}
function refresh(env = process.env) {
  env = { ...env, NVIM_AGENT_ID: env.NVIM_AGENT_ID || env.MESA_AGENT_ID }
  if (!env.NVIM_AGENT_ID) return false
  const file = filename(env.NVIM_AGENT_ID, directory(env))
  const record = read(file)
  if (!record || !alive(record.pid)) return false
  const title = nativeTitle(record)
  if (!title || title === record.title) return false
  return withLock(file, () => {
    const current = read(file)
    if (!current || !alive(current.pid)) return false
    atomicWrite(file, { ...current, title })
    return true
  })
}
function remove(registration) {
  withLock(registration.file, () => {
    try { fs.unlinkSync(registration.file) } catch (error) { if (error.code !== 'ENOENT') throw error }
  })
}
module.exports = { directory, start, update, refresh, remove, filename, editPaths, projectRoot }
if (require.main === module) {
  try {
    if (process.argv[2] === 'refresh') refresh()
    else {
      let payload = {}
      if (!process.stdin.isTTY) {
        try { const text = fs.readFileSync(0, 'utf8'); if (text.length <= 1024 * 1024) payload = JSON.parse(text || '{}') } catch {}
      }
      update(process.argv[2], process.env, payload)
    }
  } catch (error) {
    console.error('Agent view status: ' + error.message)
    process.exitCode = 1
  }
}
