'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const tokens = require('../src/tokens.cjs');

const line = (id, request, time, usage, extra = {}) => JSON.stringify({ type: 'assistant', requestId: request, timestamp: new Date(time).toISOString(), message: { id, role: 'assistant', content: [{ type: 'text', text: 'secret reply' }], usage }, ...extra });

test('usage lines are parsed without keeping conversation text', () => {
  const now = Date.now();
  const text = [JSON.stringify({ type: 'user', message: { content: 'hello' } }), line('m1', 'r1', now, { input_tokens: 3, output_tokens: 5, cache_creation_input_tokens: 7, cache_read_input_tokens: 11 }), 'not json {"output_tokens"', line('m2', 'r2', now, { input_tokens: 0, output_tokens: 0 })].join('\n');
  const list = tokens.entries(text);
  assert.equal(list.length, 1);
  assert.deepEqual(list[0].counts, { input: 3, output: 5, cacheWrite: 7, cacheRead: 11 });
  assert.equal(JSON.stringify(list).includes('secret'), false);
});

test('streamed and copied replies count once, by local day, zero-filled', () => {
  const now = new Date(2026, 9, 30, 12).getTime(), yesterday = new Date(2026, 9, 29, 23, 30).getTime();
  const list = tokens.entries([
    line('m1', 'r1', now, { input_tokens: 10, output_tokens: 1 }),
    line('m1', 'r1', now + 1000, { input_tokens: 10, output_tokens: 40 }),
    line('m1', 'r1', now + 2000, { input_tokens: 10, output_tokens: 40 }),
    line('m2', 'r2', yesterday, { input_tokens: 1, output_tokens: 2 }),
  ].join('\n'));
  const days = tokens.daily(list, 3, now);
  assert.deepEqual(days.map(d => d.day), ['2026-10-28', '2026-10-29', '2026-10-30']);
  assert.deepEqual(days.map(tokens.total), [0, 3, 50]);
});

test('scanner reads nested transcripts and skips old or hidden files', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qishi-tokens-'));
  try {
    fs.mkdirSync(path.join(root, 'project', 'sub'), { recursive: true });
    fs.writeFileSync(path.join(root, 'project', 'a.jsonl'), line('m1', 'r1', Date.now(), { output_tokens: 7 }));
    fs.writeFileSync(path.join(root, 'project', 'sub', 'b.jsonl'), line('m2', 'r2', Date.now(), { output_tokens: 5 }));
    fs.writeFileSync(path.join(root, 'project', '.hidden.jsonl'), line('m3', 'r3', Date.now(), { output_tokens: 100 }));
    const old = path.join(root, 'project', 'old.jsonl');
    fs.writeFileSync(old, line('m4', 'r4', Date.now(), { output_tokens: 1000 }));
    const past = new Date(Date.now() - 400 * 86400000);
    fs.utimesSync(old, past, past);
    const days = await tokens.scanner(root).refresh();
    assert.equal(days.length, tokens.WINDOW);
    assert.equal(tokens.total(days.at(-1)), 12);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
