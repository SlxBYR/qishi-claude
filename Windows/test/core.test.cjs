'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const core = require('../src/core.cjs');

function fixture() {
  const state = core.empty(), input = { session_id: 'test-session', cwd: 'C:\\Projects\\栖时' };
  core.ingest(state, input, 'SessionStart', 1000);
  return { state, input, session: state.sessions[core.hash(input.session_id)] };
}

test('a new user turn invalidates the old turn and starts with empty activity', () => {
  const { state, input, session } = fixture(), oldTurn = session.turn;
  core.ingest(state, { ...input, tool_name: 'Read', tool_use_id: 'read-1' }, 'PreToolUse', 1001);
  core.ingest(state, { ...input, agent_id: 'worker-1' }, 'SubagentStart', 1002);
  core.ingest(state, input, 'UserPromptSubmit', 1003);
  assert.notEqual(session.turn, oldTurn);
  assert.equal(session.pose, 'thinking');
  assert.equal(session.toolCount, 0);
  assert.deepEqual(session.activeTools, {});
  assert.deepEqual(session.agents, []);
});

test('one completed parallel tool does not hide another active tool', () => {
  const { state, input, session } = fixture();
  core.ingest(state, { ...input, tool_name: 'Read', tool_use_id: 'read-1' }, 'PreToolUse', 1001);
  core.ingest(state, { ...input, tool_name: 'Edit', tool_use_id: 'edit-1' }, 'PreToolUse', 1002);
  core.ingest(state, { ...input, tool_name: 'Read', tool_use_id: 'read-1' }, 'PostToolUse', 1003);
  assert.equal(session.tool, 'Edit');
  assert.equal(session.pose, 'writing');
  assert.equal(session.toolCount, 2);
  core.ingest(state, { ...input, tool_name: 'Edit', tool_use_id: 'edit-1' }, 'PostToolUse', 1004);
  assert.equal(session.pose, 'thinking');
});

test('subagent completion preserves remaining agents and active tools', () => {
  const { state, input, session } = fixture();
  core.ingest(state, { ...input, tool_name: 'Bash', tool_use_id: 'bash-1' }, 'PreToolUse', 1001);
  for (const id of ['worker-1', 'worker-1', 'worker-2']) core.ingest(state, { ...input, agent_id: id }, 'SubagentStart', 1002);
  assert.deepEqual(session.agents, ['worker-1', 'worker-2']);
  core.ingest(state, { ...input, agent_id: 'worker-1' }, 'SubagentStop', 1003);
  assert.equal(session.pose, 'delegating');
  core.ingest(state, { ...input, agent_id: 'worker-2' }, 'SubagentStop', 1004);
  assert.equal(session.pose, 'running');
});

test('stop, failure and session end clear activity and only session end closes', () => {
  for (const [event, pose, closed] of [['Stop', 'happy', false], ['StopFailure', 'error', false], ['SessionEnd', 'idle', true]]) {
    const { state, input, session } = fixture();
    core.ingest(state, { ...input, tool_name: 'Edit' }, 'PreToolUse', 1001);
    core.ingest(state, { ...input, agent_id: 'worker' }, 'SubagentStart', 1002);
    core.ingest(state, input, event, 1003);
    assert.equal(session.pose, pose);
    assert.equal(session.closed, closed);
    assert.deepEqual(session.activeTools, {});
    assert.deepEqual(session.agents, []);
  }
});

test('invalid or unrecognized hook data cannot create sessions', () => {
  const state = core.empty();
  for (const input of [{}, { session_id: '' }, { session_id: 42 }, { session_id: 'x'.repeat(513) }]) core.ingest(state, input, 'SessionStart', 1000);
  core.ingest(state, { session_id: 'valid' }, 'UnknownEvent', 1000);
  assert.deepEqual(state, core.empty());
});

test('session and event retention remain bounded', () => {
  const state = core.empty();
  for (let i = 0; i < 180; i++) core.ingest(state, { session_id: String(i) }, 'SessionStart', 1000 + i);
  assert.equal(Object.keys(state.sessions).length, 100);
  assert.equal(state.events.length, 150);
  core.ingest(state, { session_id: 'tomorrow' }, 'SessionStart', 100_000);
  assert.equal(Object.keys(state.sessions).length, 1);
});

test('stale work is excluded from live sessions while recent idle sessions remain', () => {
  const { state, input, session } = fixture();
  core.ingest(state, { ...input, tool_name: 'Read' }, 'PreToolUse', 1000);
  assert.equal(core.liveSessions(state, 1300).length, 1);
  assert.equal(core.liveSessions(state, 1301).length, 0);
  session.pose = 'idle';
  assert.equal(core.liveSessions(state, 1301).length, 1);
  session.closed = true;
  assert.equal(core.liveSessions(state, 1301).length, 0);
});

test('pending permission takes precedence over working and completion animation', () => {
  const { state, input } = fixture();
  core.ingest(state, { ...input, tool_name: 'Edit' }, 'PreToolUse', 1001);
  assert.equal(core.currentPose(state, [], 1002), 'writing');
  assert.equal(core.currentPose(state, [{ id: 'request' }], 1002), 'asking');
  core.ingest(state, input, 'Stop', 1003);
  assert.equal(core.currentPose(state, [], 1017), 'happy');
  assert.equal(core.currentPose(state, [], 1018), 'idle');
  assert.equal(core.currentPose(state, [], 1604), 'sleeping');
  assert.equal(core.currentPose(core.empty(), [], 1604), 'idle');
});

test('quota percentages accept only finite numbers and never infer missing telemetry', () => {
  for (const value of [true, false, '20', null, undefined, NaN, Infinity, -Infinity]) assert.equal(core.percent(value), null);
  assert.equal(core.percent(-1), 0);
  assert.equal(core.percent(120), 100);
  assert.equal(core.percent(23.5), 23.5);
  const { state, input, session } = fixture();
  core.statusline(state, { ...input, rate_limits: { five_hour: { used_percentage: 25, resets_at: 2000 }, seven_day: { used_percentage: true } }, context_window: { used_percentage: 12 } }, 1100);
  assert.deepEqual(session.quota, [{ id: 'five_hour', used: 25, resetsAt: 2000 }]);
  assert.equal(session.contextUsed, 12);
  assert.equal(session.quotaUpdated, 1100);
  assert.equal(session.updated, 1000, 'statusline telemetry is not proof of active work');
  core.statusline(state, input, 1200);
  assert.deepEqual(session.quota, []);
  assert.equal(session.quotaUpdated, null);
});

test('project names support Windows and POSIX paths', () => {
  assert.equal(core.project({ cwd: 'C:\\Projects\\栖时' }), '栖时');
  assert.equal(core.project({ cwd: '\\\\server\\share\\repo' }), 'repo');
  assert.equal(core.project({ cwd: '/Users/demo/repo/' }), 'repo');
  assert.equal(core.project({ cwd: '' }), 'Claude 会话');
});

test('trusted sender matching checks the complete mailbox domain', () => {
  for (const value of ['support@anthropic.com', 'Safety@ANTHROPIC.COM', 'notice@mail.anthropic.com']) assert.equal(core.senderAllowed(value), true, value);
  for (const value of ['support@anthropic.com.evil.test', 'support@fake-anthropic.com', 'anthropic.com@evil.test', 'Anthropic <support@evil.test>', 'support@anthropic.com\r\nBcc:x@evil.test', '', null]) assert.equal(core.senderAllowed(value), false, value);
});

test('settings normalize email and preserve unrelated saved values', () => {
  const before = { ...core.defaults(), positions: { clawd: { x: 60, y: 80 } }, showClawd: false };
  const after = core.validateSettings({ email: ' DEMO@GMAIL.COM ', intervalMinutes: 10, registeredAt: 1_600_000_000, password: 'not-persisted', arbitrary: true }, before);
  assert.equal(after.email, 'demo@gmail.com');
  assert.equal(after.intervalMinutes, 10);
  assert.equal(after.showClawd, false);
  assert.equal(after.showClaude, true);
  assert.deepEqual(after.positions, before.positions);
  assert.equal('password' in after, false);
  assert.equal('arbitrary' in after, false);
  assert.equal(before.email, '');
});

test('settings reject invalid dates, addresses, scale and poll intervals', () => {
  for (const value of [{ email: 'missing-at.test' }, { registeredAt: Infinity }, { registeredAt: -1 }, { registeredAt: core.now() + 3600 }, { intervalMinutes: 0 }, { intervalMinutes: '5' }, { petScale: 0.2 }, { petScale: 2 }, { petScale: NaN }]) assert.throws(() => core.validateSettings(value));
  assert.equal(core.validateSettings({ registeredAt: null }).registeredAt, null);
});

test('a partial or failed mail check cannot be presented as a clean check', () => {
  const prefs = { ...core.defaults(), email: 'demo@gmail.com', registeredAt: 1000 };
  assert.equal(core.monitorStatus(prefs, {}, 2000), '等待首次检查');
  assert.equal(core.monitorStatus(prefs, { lastChecked: 1990, hits: [] }, 2000), '未发现匹配邮件');
  assert.equal(core.monitorStatus(prefs, { lastChecked: 1990, hits: [], error: 'missing folder' }, 2000), '检查未完成');
  assert.equal(core.monitorStatus(prefs, { lastChecked: 1000, hits: [] }, 2000), '结果待更新');
  assert.equal(core.monitorStatus({ ...prefs, monitoring: false }, { lastChecked: 1990 }, 2000), '检测已暂停');
});

test('the original Clawd renderer receives available SVG assets for every state', () => {
  for (const pose of Object.keys(core.titles)) {
    const { state, session } = fixture();
    session.pose = pose;
    const [rendererState, file] = core.clawdState(state, [], 1001);
    assert.equal(typeof rendererState, 'string');
    assert.equal(fs.existsSync(path.resolve(__dirname, '../../Resources/ClawdWeb/assets', file)), true, `${pose}: ${file}`);
  }
});

test('concurrent sessions and subagents choose original busy animations', () => {
  const { state } = fixture();
  for (let i = 0; i < 3; i++) core.ingest(state, { session_id: 'worker-' + i, tool_name: 'Read' }, 'PreToolUse', 1001);
  assert.deepEqual(core.clawdState(state, [], 1002), ['working', 'clawd-working-building.svg']);
  core.ingest(state, { session_id: 'worker-0', agent_id: 'first' }, 'SubagentStart', 1002);
  core.ingest(state, { session_id: 'worker-0', agent_id: 'second' }, 'SubagentStart', 1002);
  assert.deepEqual(core.clawdState(state, [], 1003), ['juggling', 'clawd-working-juggling.svg']);
  assert.deepEqual(core.clawdState(state, [{ id: 'approval' }], 1003), ['notification', 'clawd-notification.svg']);
});

test('original Claude payload preserves account age, special poses and recent quota', () => {
  const { state, session } = fixture();
  session.pose = 'error';
  assert.equal(core.petPayload(state, { registeredAt: 100 }, [], 1001).state.pose, 'oops');
  session.pose = 'happy'; session.toolCount = 8;
  session.quotaUpdated = 1000; session.quota = [{ id: 'five_hour', used: 95 }];
  let payload = core.petPayload(state, { registeredAt: 100 }, [], 1001);
  assert.equal(payload.state.pose, 'proud');
  assert.equal(payload.registeredAt, 100);
  assert.equal(payload.quota.low, true);
  payload = core.petPayload(state, { registeredAt: 100 }, [{ id: 'approval' }], 1001);
  assert.equal(payload.state.pose, 'asking');
  assert.equal(core.petPayload(state, { registeredAt: 100 }, [], 2000).quota.low, false);
});

test('atomic persistence and concurrent hooks retain every update', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qishi-core-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, 'state.json');
  core.writeJSON(file, { count: 0 });
  await Promise.all(Array.from({ length: 8 }, (_, i) => core.locked(root, 'state', async () => {
    const state = core.readJSON(file);
    await new Promise(resolve => setTimeout(resolve, i % 3));
    state.count++;
    core.writeJSON(file, state);
  })));
  assert.equal(core.readJSON(file).count, 8);
  assert.deepEqual(fs.readdirSync(root), ['state.json']);
  fs.writeFileSync(file, '{invalid');
  assert.equal(core.readJSON(file, 'fallback'), 'fallback');
});

test('legacy single companion switch splits into one per character', () => {
  const legacy = core.loadSettings({ showPet: false, petScale: 1.2 });
  assert.equal(legacy.showClaude, false);
  assert.equal(legacy.showClawd, false);
  assert.equal(legacy.petScale, 1.2);
  assert.equal('showPet' in legacy, false);
  const mixed = core.loadSettings({ showPet: false, showClaude: true });
  assert.deepEqual([mixed.showClaude, mixed.showClawd], [true, false]);
  assert.deepEqual([core.loadSettings(null).showClaude, core.loadSettings({}).showClawd], [true, true]);
});
