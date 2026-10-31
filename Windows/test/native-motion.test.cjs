'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Exercise the actual host movement functions with a deterministic OS/timer boundary.
const source = fs.readFileSync(path.join(__dirname, '../src/main.cjs'), 'utf8');
const movement = source.slice(source.indexOf(' function cancelSlide('), source.indexOf(' async function pointer('));
function fixture() {
  let now = 0, nextID = 0, position = [280, 100];
  const tasks = new Map(), positions = [], bounds = [];
  const schedule = (callback, delay, repeat) => { const id = ++nextID; tasks.set(id, { callback, delay, repeat, at: now + delay }); return id; };
  const pet = { kind: 'claude', size: { width: 260, height: 300 }, dock: 'left', peek: false, out: false, dragging: false, down: null, dockGeneration: 0,
    window: { isDestroyed: () => false, getPosition: () => [...position], getBounds: () => ({ x: position[0], y: position[1], width: 260, height: 300 }),
      setBounds: b => { position = [b.x, b.y]; bounds.push(b); positions.push({ at: now, x: b.x, y: b.y }); } } };
  const context = { performance: { now: () => now }, Date: { now: () => now }, Math, JSON,
    setInterval: (fn, ms) => schedule(fn, ms, true), clearInterval: id => tasks.delete(id),
    setTimeout: (fn, ms) => schedule(fn, ms, false), clearTimeout: id => tasks.delete(id),
    prefs: { petScale: 1 }, screen: { getDisplayMatching: () => ({ workArea: { x: 0, y: 0, width: 1440, height: 900 } }) },
    runPet: async () => 0 };
  vm.createContext(context); vm.runInContext(movement, context);
  async function advance(ms) {
    const end = now + ms;
    while (true) {
      const next = [...tasks].filter(([, task]) => task.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      const [id, task] = next; now = task.at;
      if (task.repeat) task.at += task.delay; else tasks.delete(id);
      task.callback(); await Promise.resolve();
    }
    now = end; await Promise.resolve();
  }
  return { context, pet, positions, bounds, advance, position: () => position };
}

test('docking converges monotonically without an integer-coordinate stall', async () => {
  const f = fixture(); f.context.applyDock(f.pet); await f.advance(1200);
  assert.deepEqual(f.position(), [0, 100]);
  assert.ok(f.positions.length > 10);
  assert.ok(f.positions.every((p, i) => p.x >= 0 && (!i || p.x <= f.positions[i - 1].x)));
  assert.equal(f.pet.slideTimer, null);
});

test('taking over during docking cancels all window movement and delayed dock work', async () => {
  const f = fixture(); f.context.applyDock(f.pet); await f.advance(96);
  assert.ok(f.position()[0] > 0 && f.position()[0] < 280);
  f.context.cancelSlide(f.pet); f.pet.dragging = true; f.pet.dock = null;
  f.context.place(f.pet, 700, 250); const before = f.positions.length;
  await f.advance(1200);
  assert.deepEqual(f.position(), [700, 250]);
  assert.equal(f.positions.length, before);
});

test('retargeting starts at the preceding frame instead of snapping to an endpoint', async () => {
  const f = fixture(); f.context.slide(f.pet, 0, 100); await f.advance(96);
  const before = [...f.position()]; f.context.slide(f.pet, 500, 100);
  assert.deepEqual(f.position(), before);
  await f.advance(16);
  assert.ok(Math.abs(f.position()[0] - before[0]) < 40);
  await f.advance(1300); assert.deepEqual(f.position(), [500, 100]);
});

test('a stale asynchronous dockCut result cannot move a newer docking request', async () => {
  const f = fixture(); let resolveCut;
  f.context.runPet = (_pet, script) => script.startsWith('dockCut') ? new Promise(resolve => { resolveCut = resolve; }) : Promise.resolve();
  f.context.applyDock(f.pet); await f.advance(460);
  assert.equal(typeof resolveCut, 'function');
  f.pet.peek = true; f.context.applyDock(f.pet);
  resolveCut(200); await Promise.resolve(); await f.advance(300);
  assert.deepEqual(f.position(), [0, 100]);
});

test('every move writes the logical size so Windows DPI rounding cannot grow the pet', async () => {
  const f = fixture(); f.context.applyDock(f.pet); await f.advance(1200);
  f.context.place(f.pet, 12.6, 40.2);
  assert.ok(f.bounds.length > 10);
  assert.ok(f.bounds.every(b => b.width === 260 && b.height === 300 && Number.isInteger(b.x) && Number.isInteger(b.y)));
  assert.deepEqual(f.position(), [13, 40]);
});
