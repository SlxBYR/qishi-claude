'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = { window: {} };
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Resources/CrossPet/motion-player.js'), 'utf8'), context);
const { clamp, ease, approach, edgeRig } = context.window.QishiMotion;
const close = (actual, expected, tolerance = 1e-10) => assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} differs from ${expected}`);

test('clamp and transition easing preserve both endpoints', () => {
  assert.equal(clamp(-4), 0); assert.equal(clamp(3), 1); assert.equal(clamp(.35), .35);
  assert.equal(clamp(12, 0, 15), 12); assert.equal(clamp(20, 0, 15), 15);
  assert.equal(ease(0), 0); assert.equal(ease(1), 1);
  assert.ok(ease(1e-4) < 1e-7); assert.ok(1 - ease(1 - 1e-4) < 1e-7);
  let previous = 0;
  for (let i = 0; i <= 1000; i++) { const current = ease(i / 1000); assert.ok(current >= previous); previous = current; }
});

test('reversing the target does not reset position or velocity at the handoff', () => {
  const state = { value: 0, velocity: 0 };
  for (let i = 0; i < 8; i++) approach(state, 15, 1 / 60);
  const before = { ...state };
  approach(state, 0, 0);
  close(state.value, before.value); close(state.velocity, before.velocity);
  approach(state, 0, 1e-6);
  close(state.value, before.value + before.velocity * 1e-6, 1e-7);
  assert.ok(Math.abs(state.velocity - before.velocity) < .01);
});

test('zero and negative frame intervals leave the presented state unchanged', () => {
  for (const dt of [0, -1, -100]) {
    const state = { value: .7, velocity: -3 };
    approach(state, 5, dt); close(state.value, .7); close(state.velocity, -3);
  }
});

test('a long pause consumes only the bounded next frame step', () => {
  const regular = { value: .3, velocity: 2 }, delayed = { ...regular };
  approach(regular, 10, .032); approach(delayed, 10, 4);
  close(delayed.value, regular.value); close(delayed.velocity, regular.velocity);
  assert.ok(delayed.value < 2, 'resuming after a pause must not teleport to the target');
});

test('damping has the same trajectory at 60 Hz and 120 Hz', () => {
  const slow = { value: 0, velocity: 0 }, fast = { ...slow };
  for (let frame = 0; frame < 120; frame++) {
    approach(slow, 15, 1 / 60);
    approach(fast, 15, 1 / 120); approach(fast, 15, 1 / 120);
    close(slow.value, fast.value); close(slow.velocity, fast.velocity);
  }
});

test('rest-to-target movement remains monotonic and converges without oscillation', () => {
  for (const [start, target] of [[0, 15], [15, 0], [-2, 8]]) {
    const state = { value: start, velocity: 0 }, direction = Math.sign(target - start);
    let previous = start;
    for (let frame = 0; frame < 240; frame++) {
      approach(state, target, 1 / 120);
      assert.ok((state.value - previous) * direction >= -1e-12);
      assert.ok((target - state.value) * direction >= -1e-12);
      previous = state.value;
    }
    close(state.value, target, 1e-6); close(state.velocity, 0, 1e-6);
  }
});

test('a mid-flight reversal retains inertia then settles at the new target', () => {
  const state = { value: 0, velocity: 0 };
  for (let i = 0; i < 10; i++) approach(state, 15, 1 / 120);
  const before = state.value;
  approach(state, 0, 1 / 120);
  assert.ok(state.value > before, 'existing forward velocity must not abruptly reverse');
  for (let i = 0; i < 360; i++) approach(state, 0, 1 / 120);
  close(state.value, 0, 1e-8); close(state.velocity, 0, 1e-7);
});

// Slow, isolated greetings leave a quiet interval instead of constant motion.
test('edge rig is calm when tucked or when reduced motion is requested', () => {
  for(const clock of [0,.1,1,6.4,7.2,8,40.35]) {
    for(const [progress,reduced] of [[0,false],[.5,true],[1,true]]) {
      const rig=edgeRig(progress,clock,reduced);
      close(rig.wave,0);close(rig.hair,0);close(rig.breath,0);
    }
  }
});

test('edge rig leaves six seconds quiet before one slow greeting', () => {
  for(let i=0;i<600;i++) {
    const rig=edgeRig(1,i/100,false);
    close(rig.wave,0);close(rig.hair,0);close(rig.breath,0);
  }
  const middle=edgeRig(1,7.2,false);
  assert.ok(middle.wave>.04,'one slow hand excursion reaches its authored amplitude');
  for(const clock of [8.6,9,9.9,10,15.9]) {
    const rig=edgeRig(1,clock,false);close(rig.wave,0);close(rig.hair,0);close(rig.breath,0);
  }
  let excursions=0,active=false;
  for(let i=0;i<2000;i++) {
    const next=edgeRig(1,i/100,false).wave>1e-8;
    if(next&&!active)excursions++;
    active=next;
  }
  assert.equal(excursions,2,'only one greeting occurs per ten-second cycle');
});

test('edge rig has continuous positions and first derivatives at greeting and loop boundaries', () => {
  const h=1e-5,period=10;
  for(const progress of [.2,.5,1]) {
    const first=edgeRig(progress,0,false),last=edgeRig(progress,period,false);
    for(const key of ['wave','hair','breath'])close(first[key],last[key],1e-12);
    for(const at of [6,6.16,8.4,8.56,10]) {
      const center=edgeRig(progress,at,false),after=edgeRig(progress,at+h,false),before=edgeRig(progress,at-h,false);
      for(const key of ['wave','hair','breath']) {
        const outgoing=(after[key]-center[key])/h;
        const incoming=(center[key]-before[key])/h;
        close(outgoing,incoming,1e-4);
      }
    }
  }
});

test('edge deformation amplitudes and adjacent-frame changes remain small', () => {
  let previous=edgeRig(1,0,false);
  for(let frame=1;frame<=2400;frame++) {
    const rig=edgeRig(1,frame/120,false);
    assert.ok(Math.abs(rig.wave)<=.0450001);
    assert.ok(Math.abs(rig.hair)<=.0012001);
    close(rig.breath,0);
    assert.ok(Math.abs(rig.wave-previous.wave)<.0012);
    assert.ok(Math.abs(rig.hair-previous.hair)<.00004);
    previous=rig;
  }
});
