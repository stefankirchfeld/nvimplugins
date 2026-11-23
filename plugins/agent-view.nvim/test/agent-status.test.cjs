'use strict'
const { test, after } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync, spawn } = require('node:child_process')
const status = require('../scripts/agent-status.cjs')
const hooks = require('../scripts/agent-hooks.cjs')
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-view-test-'))
after(() => fs.rmSync(root, { recursive: true, force: true }))
const read = registration => JSON.parse(fs.readFileSync(registration.file, 'utf8'))

test('hook installation is idempotent and removal preserves other hook commands', () => {
  const home = path.join(root, 'codex-home'); fs.mkdirSync(home)
  const file = path.join(home, 'hooks.json')
  const existing = { hooks: { Stop: [{ hooks: [{ type: 'command', command: 'echo existing' }] }] }, keep: true }
  fs.writeFileSync(file, JSON.stringify(existing))
  const installer = path.resolve(__dirname, '../scripts/install-agent-hooks.cjs')
  const env = { ...process.env, CODEX_HOME: home, NVIM_AGENTS_DIR: path.join(root, 'installer-registry') }
  assert.equal(spawnSync(process.execPath, [installer], { env }).status, 0)
  const first = fs.readFileSync(file, 'utf8')
  assert.equal(spawnSync(process.execPath, [installer], { env }).status, 0)
  assert.equal(fs.readFileSync(file, 'utf8'), first)
  assert.equal(spawnSync(process.execPath, [installer, '--remove'], { env }).status, 0)
  const removed = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(removed.keep, true)
  assert.deepEqual(removed.hooks.Stop, existing.hooks.Stop)
})

test('independent agents keep atomic files, and late hooks cannot resurrect exited records', () => {
  const env = { ...process.env, NVIM_AGENTS_DIR: path.join(root, 'registry') }
  const a = status.start({ agent: 'codex', folder: '/tmp/a', env, tmux: { pane_id: '%1', tmux_socket: '/tmp/server-a' } })
  const b = status.start({ agent: 'claude', folder: '/tmp/b', env, tmux: { pane_id: '%1', tmux_socket: '/tmp/server-b' } })
  assert.notEqual(a.id, b.id)
  for (const state of ['working', 'waiting', 'done']) {
    assert.equal(status.update(state, a.env), true)
    assert.equal(read(a).status, state)
    assert.equal(read(b).status, 'idle')
  }
  assert.equal(fs.statSync(a.file).mode & 0o777, 0o600)
  assert.equal(fs.readdirSync(a.dir).some(name => name.endsWith('.tmp')), false)
  status.remove(a)
  assert.equal(status.update('working', a.env), false)
  assert.equal(fs.existsSync(a.file), false)
  status.remove(b)
})

test('real hook commands update registered files and ignore unrelated launches', () => {
  const env = { ...process.env, NVIM_AGENTS_DIR: path.join(root, 'hooks') }
  const registration = status.start({ agent: 'codex', folder: '/tmp/hooks', env, tmux: {} })
  const config = hooks.config('codex')
  for (const [event, expected] of [['UserPromptSubmit', 'working'], ['PermissionRequest', 'waiting'], ['PreToolUse', 'working'], ['SubagentStop', 'working'], ['Stop', 'done']]) {
    const command = config.hooks[event][0].hooks[0].command
    const result = spawnSync('/bin/sh', ['-c', command], { env: registration.env, encoding: 'utf8', input: '{}' })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(read(registration).status, expected)
  }
  const before = fs.readFileSync(registration.file, 'utf8')
  const unrelated = { ...env }; delete unrelated.NVIM_AGENT_ID
  const result = spawnSync('/bin/sh', ['-c', config.hooks.UserPromptSubmit[0].hooks[0].command], { env: unrelated })
  assert.equal(result.status, 0)
  assert.equal(fs.readFileSync(registration.file, 'utf8'), before)
  assert.throws(() => status.update('working', { ...env, NVIM_AGENT_ID: '../escape' }), /Invalid agent ID/)
  status.remove(registration)
})

test('Mesa launcher registers before the harness, passes hook context, and cleans up', () => {
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin)
  const fake = path.join(bin, 'codex')
  fs.writeFileSync(fake, [
    '#!' + process.execPath,
    'const fs = require("node:fs"), path = require("node:path");',
    'const writer = require(' + JSON.stringify(path.resolve(__dirname, '../scripts/agent-status.cjs')) + ');',
    'const file = path.join(process.env.NVIM_AGENTS_DIR, process.env.NVIM_AGENT_ID + ".json");',
    'const initial = JSON.parse(fs.readFileSync(file, "utf8"));',
    'writer.update("done");',
    'console.log(JSON.stringify({ initial, args: process.argv.slice(2), final: JSON.parse(fs.readFileSync(file, "utf8")) }));',
  ].join('\n'), { mode: 0o755 })
  const cwd = path.join(root, 'folder with spaces'); fs.mkdirSync(cwd)
  const dir = path.join(root, 'launcher')
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../scripts/run-assistant.cjs'), 'codex', '--empty', '--cwd', cwd], {
    env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, NVIM_AGENTS_DIR: dir, TMUX_PANE: '' },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  const report = JSON.parse(result.stdout)
  assert.equal(report.initial.folder, cwd)
  assert.equal(report.initial.status, 'idle')
  assert.equal(report.final.status, 'done')
  assert.ok(report.args.includes('--no-daemon'))
  assert.ok(report.args.includes('hooks'))
  assert.deepEqual(fs.readdirSync(dir).filter(name => name.endsWith('.json')), [])
  assert.equal(fs.readdirSync(path.join(dir, 'notifications')).length, 1)
})

test('a failed registration does not block the harness or inherit its parent agent ID', () => {
  const bin = path.join(root, 'failure-bin'); fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'claude'), '#!' + process.execPath + '\nconsole.log(JSON.stringify({ registered: !!process.env.NVIM_AGENT_ID }));', { mode: 0o755 })
  const blocked = path.join(root, 'not-a-directory'); fs.writeFileSync(blocked, 'block')
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../scripts/run-assistant.cjs'), 'claude', '--empty', '--cwd', root], {
    env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, NVIM_AGENTS_DIR: blocked, NVIM_AGENT_ID: 'parent', TMUX_PANE: '' },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0)
  assert.equal(JSON.parse(result.stdout).registered, false)
  assert.match(result.stderr, /Agent overview unavailable/)
})

test('direct zsh harness commands register, preserve CLI arguments, and clean up', () => {
  const bin = path.join(root, 'shell-bin'); fs.mkdirSync(bin)
  for (const harness of ['claude', 'codex', 'pi']) {
    fs.writeFileSync(path.join(bin, harness), '#!' + process.execPath + '\n' +
      'const fs=require("node:fs"); console.log(JSON.stringify({cwd:process.cwd(),args:process.argv.slice(2),record:JSON.parse(fs.readFileSync(process.env.NVIM_AGENTS_DIR+"/"+process.env.NVIM_AGENT_ID+".json"))}));', { mode: 0o755 })
  }
  const shell = path.resolve(__dirname, '../scripts/agent-shell.zsh')
  for (const harness of ['claude', 'codex', 'pi']) {
    const dir = path.join(root, 'shell-registry-' + harness)
    const result = spawnSync('/bin/zsh', ['-f', '-c', 'source "$1"; "$2" --resume "prompt with spaces" --cwd agent-option', 'test', shell, harness], {
      cwd: root, env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, NVIM_AGENTS_DIR: dir, TMUX_PANE: '' }, encoding: 'utf8',
    })
    assert.equal(result.status, 0, result.stderr)
    const report = JSON.parse(result.stdout)
    assert.equal(fs.realpathSync(report.cwd), fs.realpathSync(root))
    assert.equal(report.record.agent, harness)
    assert.equal(fs.realpathSync(report.record.folder), fs.realpathSync(root))
    assert.deepEqual(report.args.slice(-4), ['--resume', 'prompt with spaces', '--cwd', 'agent-option'])
    assert.deepEqual(fs.readdirSync(dir), [])
  }
})

test('native titles and edit events preserve start scope and identify the last edited repo', () => {
  const bin = path.join(root, 'title-bin'); fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'tmux'), '#!/bin/sh\nprintf "%s\\n" "⠇ Customize the Starship prompt | das"\n', { mode: 0o755 })
  const scope = path.join(root, 'das'), repo = path.join(scope, 'mesa'), other = path.join(scope, 'other')
  fs.mkdirSync(path.join(repo, 'src'), { recursive: true }); fs.writeFileSync(path.join(repo, '.git'), 'gitdir: example')
  fs.mkdirSync(path.join(other, '.git'), { recursive: true })
  const env = { ...process.env, PATH: bin + path.delimiter + process.env.PATH, NVIM_AGENTS_DIR: path.join(root, 'details') }
  const registration = status.start({ agent: 'codex', folder: scope, env, tmux: { tmux_socket: '/tmp/fake', pane_id: '%1' } })
  fs.writeFileSync(registration.file, JSON.stringify({ ...read(registration), status: 'done', updated_at: 42 }))
  const writer = path.resolve(__dirname, '../scripts/agent-status.cjs')
  assert.equal(spawnSync(process.execPath, [writer, 'refresh'], { env: registration.env }).status, 0)
  assert.equal(read(registration).title, 'Customize the Starship prompt')
  assert.equal(read(registration).status, 'done')
  assert.equal(read(registration).updated_at, 42)
  const invoke = payload => spawnSync(process.execPath, [writer, 'working'], { env: registration.env, input: JSON.stringify(payload) })
  assert.equal(invoke({ cwd: scope, tool_name: 'Edit', tool_input: { file_path: 'mesa/src/a.ts' } }).status, 0)
  assert.equal(read(registration).last_project, repo)
  assert.equal(read(registration).folder, scope)
  assert.equal(invoke({ cwd: scope, tool_name: 'Read', tool_input: { file_path: 'other/file.ts' } }).status, 0)
  assert.equal(read(registration).last_project, repo)
  assert.equal(invoke({ cwd: scope, tool_name: 'functions.apply_patch', tool_input: { input: '*** Begin Patch\n*** Update File: other/b.ts\n*** End Patch' } }).status, 0)
  assert.equal(read(registration).last_project, other)
  status.remove(registration)
})

test('creation and rename paths survive raw patches and structured tool output', () => {
  assert.deepEqual(status.editPaths({ tool_name: 'Write', tool_input: { file_path: 'mesa/new.ts', content: 'hello' } }), ['mesa/new.ts'])
  assert.deepEqual(status.editPaths({ tool_name: 'functions.apply_patch', tool_input:
    '*** Begin Patch\n*** Add File: mesa/new.ts\n+hello\n*** Update File: mesa/old.ts\n*** Move to: jwe/new.ts\n@@\n-old\n+new\n*** End Patch'
  }), ['mesa/new.ts', 'mesa/old.ts', 'jwe/new.ts'])
  assert.deepEqual(status.editPaths({ tool_name: 'functions.exec', tool_response: { content: [
    { type: 'text', text: 'Script completed' },
    { type: 'text', text: 'Success. Updated the following files:\nA mesa/new.ts\nM jwe/renamed.ts\n' },
  ] } }), ['mesa/new.ts', 'jwe/renamed.ts'])
  assert.deepEqual(status.editPaths({ tool_name: 'exec_command', tool_input: { cmd: 'mv mesa/a.ts jwe/a.ts' }, tool_response: { output: '' } }), [])
})

test('conversation metadata survives relaunch without restoring old tmux coordinates or status', () => {
  const env = { ...process.env, NVIM_AGENTS_DIR: path.join(root, 'persistent') }
  const repo = path.join(root, 'persistent-repo')
  fs.mkdirSync(path.join(repo, '.git'), { recursive: true })
  const a = status.start({ agent: 'codex', folder: root, env, tmux: { pane_id: '%1', session_id: '$1' } })
  status.update('working', a.env, { tool_name: 'Write', tool_input: { file_path: path.join(repo, 'new.ts') } })
  status.update('working', a.env, { session_id: 'native-conversation' })
  assert.equal(read(a).last_project, repo)
  status.remove(a)
  const b = status.start({ agent: 'codex', folder: root, env, tmux: { pane_id: '%9', session_id: '$2' } })
  status.update('idle', b.env, { session_id: 'native-conversation' })
  assert.equal(read(b).last_project, repo)
  assert.equal(read(b).last_file, path.join(repo, 'new.ts'))
  assert.equal(read(b).conversation_id, 'native-conversation')
  assert.equal(read(b).session_id, '$2')
  assert.equal(read(b).pane_id, '%9')
  assert.equal(read(b).status, 'idle')
  status.update('idle', b.env, { session_id: 'different-conversation' })
  assert.equal(read(b).last_project, undefined)
  status.update('idle', b.env, { session_id: 'native-conversation' })
  assert.equal(read(b).last_project, repo)
  const c = status.start({ agent: 'claude', folder: root, env, tmux: {} })
  status.update('idle', c.env, { session_id: 'native-conversation' })
  assert.equal(read(c).last_project, undefined)
  status.remove(b); status.remove(c)
})

test('completion events survive immediate next turn and exit, and repeated Stop is deduplicated', () => {
  const env = { ...process.env, NVIM_AGENTS_DIR: path.join(root, 'events') }
  const a = status.start({ agent: 'codex', folder: root, env,
    tmux: { pane_id: '%1', session_id: '$1', tmux_socket: '/tmp/server' } })
  status.update('working', a.env, { session_id: 'conversation' })
  status.update('done', a.env, { session_id: 'conversation', turn_id: 'turn-1' })
  status.update('done', a.env, { session_id: 'conversation', turn_id: 'turn-1' })
  const dir = path.join(a.dir, 'notifications')
  assert.equal(fs.readdirSync(dir).length, 1)
  const event = JSON.parse(fs.readFileSync(path.join(dir, fs.readdirSync(dir)[0])))
  assert.equal(event.conversation_id, 'conversation')
  assert.equal(event.session_id, '$1')
  assert.equal(event.tmux_socket, '/tmp/server')
  assert.equal(event.type, 'done')
  status.update('working', a.env)
  status.update('done', a.env, { turn_id: 'turn-2' })
  status.remove(a)
  assert.equal(fs.readdirSync(dir).length, 2)
  assert.equal(fs.existsSync(a.file), false)
})

test('two Neovim instances independently notify from durable events and filter tmux sessions', async t => {
  if (spawnSync('nvim', ['--version']).error) return t.skip('Neovim is not installed')
  const dir = path.join(root, 'nvim-events')
  fs.mkdirSync(path.join(dir, 'notifications'), { recursive: true })
  const lua = path.join(root, 'notifications.lua')
  fs.writeFileSync(lua, [
    'vim.opt.rtp:append(vim.env.MESA_TEST_NVIM)',
    'vim.g.agent_view_dir = vim.env.NVIM_AGENTS_DIR',
    'vim.env.TMUX = "/tmp/test-mesa-server,1,0"; vim.env.TMUX_PANE = "%9"',
    'vim.system = function(_, _, cb) cb({ code = 0, stdout = "/tmp/test-mesa-server\\t$1\\n" }) end',
    'local count = 0',
    'vim.notify = function(message, _, opts)',
    '  if opts and opts.title == "Agent finished" then',
    '    assert(opts.timeout == 5000); assert(message:find("A finished task", 1, true)); count = count + 1',
    '  end',
    'end',
    'local agents = require("agent_view"); agents.setup()',
    'vim.fn.writefile({"ready"}, vim.env.MESA_TEST_READY)',
    'assert(vim.wait(5000, function() return count == 1 end), "completion was not delivered")',
    'vim.wait(1200, function() return false end)',
    'assert(count == 1, "completion repeated or another session leaked")',
    'package.loaded["agent_view"] = nil; agents = require("agent_view"); agents.setup()',
    'vim.wait(1200, function() return false end); assert(count == 1, "reload repeated the notification")',
    'vim.cmd("qa!")',
  ].join('\n'))
  const children = [], results = []
  for (let i = 0; i < 2; i++) {
    const ready = path.join(root, 'nvim-ready-' + i)
    const child = spawn('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', lua], {
      env: { ...process.env, NVIM_AGENTS_DIR: dir, MESA_TEST_READY: ready,
        MESA_TEST_NVIM: path.resolve(__dirname, '..') }, stdio: ['ignore', 'pipe', 'pipe'],
    })
    children.push({ child, ready })
    results.push(new Promise((resolve, reject) => {
      let output = ''
      child.stderr.on('data', data => { output += data })
      child.on('error', reject)
      child.on('exit', code => code === 0 ? resolve() : reject(new Error(output)))
    }))
  }
  try {
    const deadline = Date.now() + 5000
    while (!children.every(({ ready }) => fs.existsSync(ready))) {
      assert.ok(Date.now() < deadline, 'editors failed to initialize')
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    const event = { agent: 'codex', folder: root, title: 'A finished task', type: 'done',
      completed_at: Date.now(), session_id: '$1', tmux_socket: '/tmp/test-mesa-server' }
    fs.writeFileSync(path.join(dir, 'notifications', 'other-session.json'), JSON.stringify({ ...event, session_id: '$2' }))
    fs.writeFileSync(path.join(dir, 'notifications', 'old.json'), JSON.stringify({ ...event, completed_at: 1 }))
    fs.writeFileSync(path.join(dir, 'notifications', 'finished.json'), JSON.stringify(event))
    await Promise.all(results)
  } finally {
    for (const { child } of children) if (child.exitCode === null) child.kill()
  }
})

test('concurrent title refresh cannot overwrite edit/status metadata', async () => {
  const bin = path.join(root, 'race-bin'); fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'tmux'), '#!/bin/sh\n[ "$SLOW_TITLE" = 1 ] && sleep 0.2\nprintf "%s\\n" "A native session title"\n', { mode: 0o755 })
  const repo = path.join(root, 'race-repo'); fs.mkdirSync(path.join(repo, '.git'), { recursive: true })
  const env = { ...process.env, PATH: bin + path.delimiter + process.env.PATH, NVIM_AGENTS_DIR: path.join(root, 'race') }
  const registration = status.start({ agent: 'codex', folder: root, env, tmux: { tmux_socket: '/tmp/fake', pane_id: '%1' } })
  const writer = path.resolve(__dirname, '../scripts/agent-status.cjs')
  const run = (args, childEnv, input = '') => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [writer, ...args], { env: childEnv, stdio: ['pipe', 'ignore', 'pipe'] })
    child.on('error', reject)
    child.on('exit', code => code === 0 ? resolve() : reject(new Error('Writer failed: ' + code)))
    child.stdin.end(input)
  })
  const refresh = run(['refresh'], { ...registration.env, SLOW_TITLE: '1' })
  await new Promise(resolve => setTimeout(resolve, 20))
  const update = run(['done'], registration.env, JSON.stringify({ tool_name: 'Edit', tool_input: { file_path: path.join(repo, 'a.ts') } }))
  await Promise.all([refresh, update])
  assert.equal(read(registration).title, 'A native session title')
  assert.equal(read(registration).last_project, repo)
  assert.equal(read(registration).status, 'done')
  assert.equal(fs.readdirSync(registration.dir).some(file => file.endsWith('.lock')), false)
  status.remove(registration)
})


test('configurable UI bindings and scoped routing work in Neovim', t => {
  if (spawnSync('nvim', ['--version']).error) return t.skip('Neovim is not installed')
  for (const script of ['check-config.lua', 'check-routing.lua', 'check-table.lua']) {
    const result = spawnSync('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', path.join(__dirname, script)], {
      env: { ...process.env, AGENT_VIEW_ROOT: path.resolve(__dirname, '..') }, encoding: 'utf8', timeout: 15000,
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout + result.stderr, /PASS:/)
  }
})


test('conversation colors persist across independent Neovim instances and list order', t => {
  if (spawnSync('nvim', ['--version']).error) return t.skip('Neovim is not installed')
  const dir = path.join(root, 'colors-shared')
  const run = reverse => {
    const result = spawnSync('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', path.join(__dirname, 'check-colors.lua')], {
      env: { ...process.env, AGENT_VIEW_ROOT: path.resolve(__dirname, '..'), COLOR_STATE_DIR: dir, REVERSE_COLORS: reverse },
      encoding: 'utf8', timeout: 15000,
    })
    assert.equal(result.status, 0, result.stderr)
    return JSON.parse(result.stdout)
  }
  assert.deepEqual(run('0'), run('1'))
})
