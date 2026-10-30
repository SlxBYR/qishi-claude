'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const C = require('../src/core.cjs');
const Integration = require('../src/integration.cjs');
const Bridge = require('../src/bridge.cjs');
const Mail = require('../src/mail.cjs');

function temporary(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qishi-integration-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

test('install/reinstall/uninstall preserve unrelated hooks, options and original statusLine', async t => {
  const root = temporary(t), file = path.join(root, 'claude-settings.json');
  const unrelated = { type: 'command', command: 'echo keep-me', timeout: 7 };
  const statusLine = { type: 'command', command: 'printf original-status', padding: 3 };
  const original = { model: 'opus', permissions: { allow: ['Read'] }, hooks: { PreToolUse: [{ matcher: 'Read', timeout: 8, hooks: [unrelated] }], UnknownEvent: [{ hooks: [{ type: 'prompt', prompt: 'keep' }] }] }, statusLine };
  C.writeJSON(file, original);
  const options = { root, file, prepareRuntime: false };
  await Integration.configure({ ...options, enable: true });
  let config = Integration.config(file);
  assert.equal(Integration.installed(file), true);
  assert.deepEqual(config.permissions, original.permissions);
  assert.equal(config.statusLine.padding, 3);
  assert.deepEqual(config.hooks.PreToolUse[0], original.hooks.PreToolUse[0]);
  await Integration.configure({ ...options, enable: true });
  config = Integration.config(file);
  for (const event of C.events) assert.equal(config.hooks[event].filter(row => row.hooks.some(Bridge.isOwned)).length, 1, event);
  assert.deepEqual(C.readJSON(path.join(root, 'statusline-previous.json')), statusLine);
  await Integration.configure({ ...options, enable: false });
  assert.deepEqual(Integration.config(file), original);
  assert.equal(Integration.installed(file), false);
  assert.equal(fs.readdirSync(path.join(root, 'Backups')).length, 3);
});

test('uninstall preserves a user replacement statusLine made after installation', async t => {
  const root = temporary(t), file = path.join(root, 'settings.json');
  await Integration.configure({ root, file, prepareRuntime: false, enable: true });
  const config = Integration.config(file);
  config.statusLine = { type: 'command', command: 'echo user-new-status' };
  C.writeJSON(file, config);
  await Integration.configure({ root, file, prepareRuntime: false, enable: false });
  assert.deepEqual(Integration.config(file), { statusLine: config.statusLine });
});

test('unsupported hook schema fails without replacing the original configuration', async t => {
  const root = temporary(t), file = path.join(root, 'settings.json');
  for (const original of ['{"hooks":[]}', '{"hooks":{"PreToolUse":true}}', '{broken']) {
    fs.writeFileSync(file, original);
    await assert.rejects(Integration.configure({ root, file, prepareRuntime: false, enable: true }));
    assert.equal(fs.readFileSync(file, 'utf8'), original);
  }
});

test('Windows prior statuslines retain Git Bash discovery and explicit PowerShell selection', () => {
  const env = { ProgramFiles: 'C:\\Program Files', LOCALAPPDATA: 'C:\\Users\\demo\\AppData\\Local', SystemRoot: 'C:\\Windows', PATH: '' };
  const bash = 'C:\\Program Files\\Git\\bin\\bash.exe';
  const powershell = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  const exists = value => [bash, powershell].includes(value);
  const original = { command: 'printf "$HOME"' };
  assert.deepEqual(Bridge.statusShell(original, { platform: 'win32', env, exists }), { file: bash, args: ['-c', original.command] });
  assert.equal(Bridge.statusShell({ ...original, shell: 'powershell' }, { platform: 'win32', env, exists }).file, powershell);
  assert.equal(Bridge.statusShell(original, { platform: 'win32', env, exists: value => value === powershell }).file, powershell);
  assert.throws(() => Bridge.statusShell({ ...original, shell: 'bash' }, { platform: 'win32', env, exists: () => false }));
  const perUser = 'C:\\Users\\demo\\AppData\\Local\\Programs\\Git\\bin\\bash.exe';
  assert.equal(Bridge.statusShell(original, { platform: 'win32', env, exists: value => value === perUser }).file, perUser);
});

test('Windows launch commands safely retain spaces, Unicode and shell metacharacters in paths', async t => {
  const base = temporary(t), root = path.join(base, "栖时 space ' $ `"), file = path.join(base, 'settings.json');
  await Integration.configure({ root, file, prepareRuntime: false, enable: true });
  const config = Integration.config(file), line = Bridge.commandText(config.statusLine);
  assert.ok(line.startsWith('& '));
  assert.ok(line.includes("栖时 space '' $ `"));
  assert.ok(line.endsWith('--qishi-statusline'));
  assert.equal(Bridge.isOwned(config.statusLine), true);
  assert.equal(Integration.installed(file), true);
  await Integration.configure({ root, file, prepareRuntime: false, enable: false });
  assert.deepEqual(Integration.config(file), {});
});

test('stable Windows runtime contains an explicit UTF-8 stdin forwarding launcher', t => {
  const root = temporary(t), runtime = path.join(root, 'packaged'), destination = path.join(root, 'data');
  fs.mkdirSync(runtime);
  fs.writeFileSync(path.join(runtime, 'Qishi Claude.exe'), 'synthetic executable fixture');
  fs.writeFileSync(path.join(runtime, 'LICENSE'), 'synthetic license fixture');
  const stable = Integration.installRuntime(destination, runtime, path.resolve(__dirname, '../src'));
  assert.ok(fs.existsSync(path.join(stable, 'bridge.cjs')));
  assert.ok(fs.existsSync(path.join(stable, 'core.cjs')));
  assert.ok(fs.existsSync(path.join(stable, 'Qishi Claude.exe')));
  const launcher = fs.readFileSync(path.join(stable, 'qishi-bridge-launch.ps1'), 'utf8');
  assert.ok(launcher.includes('[Console]::InputEncoding = $utf8'));
  assert.ok(launcher.includes('[Console]::OutputEncoding = $utf8'));
  assert.ok(launcher.includes('$OutputEncoding = $utf8'));
  assert.ok(launcher.includes('$payload = [Console]::In.ReadToEnd()'));
  assert.ok(launcher.includes('$payload | &'));
});

test('request validity requires a live process, matching turn, unfinished session and expiry', t => {
  const root = temporary(t), session = 'session';
  const state = { sessions: { [session]: { turn: 'turn-1', closed: false, pose: 'asking' } }, events: [] };
  C.writeJSON(path.join(root, 'claude-state.json'), state);
  const request = { session, turn: 'turn-1', expires: C.now() + 60, pid: process.pid };
  assert.equal(Bridge.requestCurrent(root, request), true);
  for (const value of [{ ...request, turn: 'old-turn' }, { ...request, expires: C.now() - 1 }, { ...request, pid: 0 }]) assert.equal(Bridge.requestCurrent(root, value), false);
  for (const changes of [{ closed: true }, { pose: 'happy' }, { pose: 'error' }]) {
    C.writeJSON(path.join(root, 'claude-state.json'), { sessions: { [session]: { ...state.sessions[session], ...changes } } });
    assert.equal(Bridge.requestCurrent(root, request), false);
  }
});

test('permission delegation only runs with a fresh opted-in heartbeat', t => {
  const root = temporary(t), file = path.join(root, 'heartbeat.json');
  const heartbeat = { pid: process.pid, time: C.now(), approvals: true };
  C.writeJSON(file, heartbeat);
  assert.equal(Bridge.liveApp(root), true);
  for (const changes of [{ approvals: false }, { time: C.now() - 5 }, { time: C.now() + 60 }, { pid: 0 }]) {
    C.writeJSON(file, { ...heartbeat, ...changes });
    assert.equal(Bridge.liveApp(root), false);
  }
});

async function syntheticPermission(t, choice) {
  const root = temporary(t);
  C.writeJSON(path.join(root, 'heartbeat.json'), { pid: process.pid, time: C.now(), approvals: true });
  const child = spawn(process.execPath, [path.resolve(__dirname, '../src/bridge.cjs'), '--qishi-hook', 'PermissionRequest'], {
    env: { ...process.env, QISHI_CLAUDE_HOME: root }, stdio: ['pipe', 'pipe', 'pipe']
  });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  let output = '', stderr = '';
  child.stdout.on('data', value => { output += value; });
  child.stderr.on('data', value => { stderr += value; });
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => resolve(code)); });
  child.stdin.end(JSON.stringify({ session_id: 'synthetic-test-session', cwd: root, tool_name: 'Read', tool_input: { file_path: 'synthetic-file.txt' } }));
  const deadline = Date.now() + 3000;
  let request;
  while (!request && Date.now() < deadline) {
    const files = fs.existsSync(path.join(root, 'requests')) ? fs.readdirSync(path.join(root, 'requests')) : [];
    request = files.length ? C.readJSON(path.join(root, 'requests', files[0])) : null;
    if (!request) await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.ok(request, 'synthetic hook should publish a complete request');
  assert.equal(JSON.parse(request.input).file_path, 'synthetic-file.txt');
  if (choice === 'new-turn') {
    const stateFile = path.join(root, 'claude-state.json'), state = C.readJSON(stateFile);
    state.sessions[request.session].turn = 'a-different-turn';
    C.writeJSON(stateFile, state);
    C.writeJSON(path.join(root, 'responses', request.id + '.json'), { id: request.id, choice: 'allow' });
  } else C.writeJSON(path.join(root, 'responses', request.id + '.json'), { id: request.id, choice });
  assert.equal(await exited, 0, stderr);
  assert.deepEqual(fs.readdirSync(path.join(root, 'requests')), []);
  assert.deepEqual(fs.readdirSync(path.join(root, 'responses')), []);
  return output;
}

test('synthetic permission decisions emit only the explicit selected outcome', async t => {
  for (const choice of ['allow', 'deny']) {
    const output = await syntheticPermission(t, choice), result = JSON.parse(output);
    assert.equal(result.hookSpecificOutput.hookEventName, 'PermissionRequest');
    assert.equal(result.hookSpecificOutput.decision.behavior, choice);
  }
});

test('native fallback and changed turns never emit an approval', async t => {
  assert.equal(await syntheticPermission(t, 'native'), '');
  assert.equal(await syntheticPermission(t, 'new-turn'), '');
});

test('statusline relay preserves previous stdout and forwards the complete Unicode payload', async t => {
  const root = temporary(t), script = path.join(root, 'previous-statusline.cjs');
  fs.writeFileSync(script, "let text='';process.stdin.setEncoding('utf8');process.stdin.on('data',part=>text+=part);process.stdin.on('end',()=>{const input=JSON.parse(text);process.stdout.write(input.marker+'|'+input.large.length+'\\n');});");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  C.writeJSON(path.join(root, 'statusline-previous.json'), { type: 'command', command: quote(process.execPath) + ' ' + quote(script) });
  const child = spawn(process.execPath, [path.resolve(__dirname, '../src/bridge.cjs'), '--qishi-statusline'], { env: { ...process.env, QISHI_CLAUDE_HOME: root }, stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  let output = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', value => { output += value; });
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  child.stdin.end(JSON.stringify({ session_id: 'relay-session', marker: '栖时 🦀 原状态栏', large: 'x'.repeat(120000), rate_limits: { five_hour: { used_percentage: 28 } } }));
  assert.equal(await exited, 0);
  assert.equal(output, '栖时 🦀 原状态栏|120000\n');
  assert.equal(C.readJSON(path.join(root, 'claude-state.json')).sessions[C.hash('relay-session')].quota[0].used, 28);
});

function fakeMailbox(options = {}) {
  const calls = [], folders = [
    { path: '[Gmail]/All Mail', specialUse: '\\All' },
    { path: '[Gmail]/Spam', flags: new Set(['\\Junk']) },
    { path: '[Gmail]/Trash', specialUse: '\\Trash' }
  ];
  class Client {
    constructor(config) { calls.push(['config', config]); this.capabilities = new Set(options.capabilities || ['X-GM-EXT-1']); }
    async connect() { calls.push(['connect']); }
    async list() { return options.folders || folders; }
    async mailboxOpen(name, opts) { calls.push(['mailboxOpen', name, opts]); }
    async search(query, opts) { calls.push(['search', query, opts]); return options.ids || [1]; }
    async *fetch(ids, fields, opts) { calls.push(['fetch', ids, fields, opts]); for (const item of options.messages || [mailMessage()]) yield item; }
    async logout() { calls.push(['logout']); }
    close() { calls.push(['close']); }
  }
  return { Client, calls };
}

function mailMessage(changes = {}) {
  return { uid: 1, emailId: 'gmail-message-1', internalDate: new Date(1_700_000_100_000), envelope: { from: [{ address: 'safety@anthropic.com' }], subject: 'Account suspended' }, headers: Buffer.from('From: Safety <safety@anthropic.com>\r\nMessage-ID: <test@example.test>\r\n'), ...changes };
}
const mailSettings = { email: 'synthetic@gmail.com', registeredAt: 1_700_000_000 };

test('Gmail checks enforce TLS, read-only folders, no message bodies, complete folder coverage and deduplication', async () => {
  const { Client, calls } = fakeMailbox();
  const result = await Mail.check(mailSettings, 'synthetic-app-password', { Client });
  assert.equal(result.hits.length, 1, 'same Gmail message across folders must not duplicate');
  assert.deepEqual(result.coveredFolders, ['全部邮件', '垃圾邮件', '已删除邮件']);
  const config = calls.find(row => row[0] === 'config')[1];
  assert.equal(config.host, 'imap.gmail.com');
  assert.equal(config.port, 993);
  assert.equal(config.secure, true);
  assert.equal(config.tls.rejectUnauthorized, true);
  assert.equal(config.logger, false);
  assert.equal(calls.filter(row => row[0] === 'mailboxOpen').length, 3);
  for (const row of calls.filter(row => row[0] === 'mailboxOpen')) assert.deepEqual(row[2], { readOnly: true });
  for (const row of calls.filter(row => row[0] === 'search')) {
    assert.ok(row[1].gmailraw.includes('suspended'));
    assert.ok(row[1].gmailraw.includes('after:1699999999'));
    assert.deepEqual(row[2], { uid: true });
  }
  for (const row of calls.filter(row => row[0] === 'fetch')) {
    assert.equal(row[2].source, undefined);
    assert.equal(row[2].bodyParts, undefined);
    assert.deepEqual(row[2].headers, ['from', 'message-id']);
  }
  assert.equal(calls.at(-1)[0], 'logout');
});

test('Gmail refuses incomplete folders, partial fetches and missing identity metadata', async () => {
  for (const options of [
    { capabilities: [] },
    { folders: [{ path: 'INBOX', specialUse: '\\All' }] },
    { ids: [1, 2], messages: [mailMessage()] },
    { messages: [mailMessage({ emailId: null })] },
    { messages: [mailMessage({ internalDate: 'unparseable-date' })] },
    { messages: [mailMessage({ headers: null })] }
  ]) {
    const { Client, calls } = fakeMailbox(options);
    await assert.rejects(Mail.check(mailSettings, 'synthetic-password', { Client }));
    assert.equal(calls.at(-1)[0], 'logout');
  }
});

test('Gmail excludes deceptive senders, duplicate From headers, and pre-registration mail', async () => {
  for (const message of [
    mailMessage({ envelope: { from: [{ address: 'safety@anthropic.com.evil.test' }], subject: 'Account suspended' } }),
    mailMessage({ envelope: { from: [{ address: 'safety@anthropic.com' }, { address: 'x@evil.test' }] } }),
    mailMessage({ headers: Buffer.from('From: safety@anthropic.com\r\nFrom: x@evil.test\r\n') }),
    mailMessage({ internalDate: new Date((mailSettings.registeredAt - 1) * 1000) })
  ]) {
    const { Client } = fakeMailbox({ messages: [message] });
    const result = await Mail.check(mailSettings, 'synthetic-password', { Client });
    assert.deepEqual(result.hits, []);
  }
});
