'use strict';
// Deterministic integration tests execute the shipped host adapter with a fake clock and DOM.
// No application is launched; asset readiness and pointer changes remain under test control.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const host = fs.readFileSync(path.join(__dirname, '../Resources/CrossPet/host.js'), 'utf8');
const player = fs.readFileSync(path.join(__dirname, '../Resources/CrossPet/motion-player.js'), 'utf8');
const css = fs.readFileSync(path.join(__dirname, '../Resources/CrossPet/minimal.css'), 'utf8');
let checks = 0;
function check(condition, message) { assert.ok(condition, message); ++checks; }
function equal(actual, expected, message) { assert.equal(actual, expected, message); ++checks; }
function near(actual, expected, message) { check(Math.abs(actual - expected) < 1e-10, `${message}: ${actual} vs ${expected}`); }

function environment() {
  let now = 0, nextID = 1;
  const jobs = new Map(), images = [], renders = [], presentations = [], listeners = {}, styles = new Map();
  const classList = () => {
    const values = new Set();
    return { add: (...xs) => xs.forEach(x => values.add(x)), remove: (...xs) => xs.forEach(x => values.delete(x)),
      contains: x => values.has(x), toggle: (x, on) => { const yes = on ?? !values.has(x); if (yes) values.add(x); else values.delete(x); return yes; } };
  };
  const element = () => ({
    classList: classList(), className: '', textContent: '', attributes: {},
    style: { setProperty: (k, v) => styles.set(k, v), removeProperty: k => styles.delete(k) },
    setAttribute(k, v) { this.attributes[k] = v; }, removeAttribute(k) { delete this.attributes[k]; },
    querySelectorAll: () => [], getBoundingClientRect: () => ({ x: 0, y: 0, left: 0, top: 0, right: 250, bottom: 180, width: 250, height: 180 }),
  });
  class FakeImage {
    constructor() { Object.assign(this, element()); images.push(this); this.naturalWidth = 0; this.naturalHeight = 0; this.complete = false; }
    set src(value) { this._src = value; }
    get src() { return this._src; }
    decode() { return Promise.resolve(); }
  }
  const root = element(); root.clientWidth = 250;
  const elements = Object.fromEntries(['body', 'bubble', 'foot', 'newsCard', 'fx', 'stage'].map(id => [id, element()]));
  const active = new FakeImage(); active.naturalWidth = active.naturalHeight = 640;
  const reduced = { matches: false, handlers: [], addEventListener(type, callback) { this.handlers.push(callback); } };
  let enabled = false, last = null, presenterReady = true;
  const renderer = {
    begin() { if(!presenterReady)return false; enabled = true; return true; },
    paintRig(id,rect,pose,rig) { if(!enabled)return false; last={at:now,a:id,b:id,t:0,rect:{...rect},pose:{...pose},rig:{...rig}};presentations.push(last);return true; },
    end() { enabled = false; last = null; },
    inspect: () => ({ready:presenterReady,failed:false,enabled,last}), hit: () => null,
  };
  const context = {
    console, Image: FakeImage, Promise, innerWidth: 250, performance: { now: () => now },
    requestAnimationFrame(callback) { const id = nextID++; jobs.set(id, { due: now + 16, callback: () => callback(now) }); return id; },
    cancelAnimationFrame(id) { jobs.delete(id); },
    document: { documentElement: root, getElementById: id => elements[id], getAnimations: () => [] },
    addEventListener(type, callback) { (listeners[type] ||= []).push(callback); },
    matchMedia: () => reduced,
    setTimeout(callback, ms) { const id = nextID++; jobs.set(id, { due: now + ms, callback }); return id; },
    clearTimeout(id) { jobs.delete(id); }, setInterval: () => nextID++, clearInterval() {},
    qishiManifest: { characters: { claude: { poses: {} } } },
    qishiMotionRenderer: renderer,
    active, currentUrl: '../Claude/idle.webp', pose: 'idle', tucked: null, tuckedPeek: false,
    $: id => elements[id],
    showImage(url) { if(url===context.currentUrl)return; context.currentUrl = url; active.src = url; renders.push({ at: now, url }); },
    framesFor: name => [`../Claude/${name}.webp`], restPose: () => 'idle',
    setTucked(side, peek = false) {
      if(side===context.tucked&&!!peek===context.tuckedPeek)return;
      context.tucked = side; context.tuckedPeek = !!side && !!peek;
      context.pose = side ? `edge_${side}${peek ? '_peek' : ''}` : 'idle';
      context.showImage(`../Claude/${context.pose}.webp`, true);
    },
    dockCut: side => side === 'left' ? 0 : 250,
    say() {}, init() {}, setShowName() {}, setAuraMode() {}, setSessions() {}, applyCharState() {}, setQuota() {},
    handleClick() {}, setPageHidden(value) { root.classList.toggle('frozen', value); },
    diagnoseDisplay: () => ({ image: context.currentUrl }),
    getComputedStyle: () => ({ display: 'none', visibility: 'hidden' }),
  };
  context.window = context;
  vm.createContext(context);
  // No motion-data is installed here: the actual player exports its math only.
  vm.runInContext(player, context, { filename: 'motion-player.js' });
  vm.runInContext(host, context, { filename: 'host.js' });
  const state = () => context.qishiInspect().edgeHover;
  const drag = () => context.qishiInspect();
  async function load(side, skip = -1, fail = -1) {
    for (const image of images.filter(image => image.src?.includes(`edge-hover/${side}-`))) {
      const frame = Number(image.src.match(/-(\d+)\.png$/)[1]);
      if (frame === skip || image.complete) continue;
      if (frame === fail) { image.onerror(new Error('simulated unavailable artwork')); continue; }
      image.naturalWidth = image.naturalHeight = 640; image.complete = true; image.onload();
    }
    for (let i = 0; i < 8; ++i) await Promise.resolve();
  }
  function advance(ms) {
    const end = now + ms;
    let count = 0;
    while (true) {
      const next = [...jobs.entries()].filter(([, job]) => job.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
      if (!next) break;
      const [id, job] = next; jobs.delete(id); now = job.due; job.callback();
      if (++count > 10000) throw new Error('runaway timers');
    }
    now = end;
  }
  function setReduced(value) { reduced.matches = value; reduced.handlers.forEach(callback => callback({ matches: value })); }
  function until(predicate, maximum = 6000) {
    for(let elapsed=0;elapsed<maximum;elapsed+=16){if(predicate())return true;advance(16);}return predicate();
  }
  return { context, state, drag, load, advance, until, setReduced, renders, presentations, jobs, root, styles, images,
    setPresenterReady(value){presenterReady=value;} };
}
(async () => {
  check(/qishi-motion-active body #body img \{ visibility: hidden !important/.test(css), 'presenter exclusively owns visible artwork');
  check(/animation: none !important; transform: none !important; transition: none !important/.test(css), 'upstream transforms cannot compete');
  const a = environment();
  a.context.setTucked('left', true);
  equal(a.state().phase, 'loading', 'hover waits for decoded artwork');
  equal(a.context.currentUrl, '../Claude/edge_left_peek.webp', 'fallback available during loading');
  await a.load('left', 11);
  equal(a.state().active, false, 'undecoded source cannot start');
  await a.load('left');
  equal(a.state().frame, 0, 'ready side starts at tucked reveal position');
  equal(a.state().ready.right, 'loading', 'side readiness is independent');
  a.advance(304);
  const forward = a.state();
  check(forward.frame > 0 && forward.frame < 14 && !Number.isInteger(forward.frame), 'entry retains a fractional cursor');
  check(forward.velocity > 0, 'entry has forward velocity');
  check(a.presentations.every(p=>p.a==='left-11'&&p.b==='left-11'&&p.t===0), 'entry keeps a single original drawing');
  check(a.presentations.every(p=>p.rig.wave===0&&p.rig.hair===0), 'entry reveals quietly without an immediate wave');
  const entry = a.presentations.filter(p => p.a.startsWith('left-'));
  check(entry.every((p,i) => !i || p.pose.x >= entry[i-1].pose.x - 1e-9), 'reveal is monotonic with no backward bump');
  equal(a.context.dockCut('left'), 0, 'left cut is fixed');
  const originalBounds=a.context.active.getBoundingClientRect;
  a.context.active.getBoundingClientRect = () => ({left:-77,right:173,width:250,top:0,bottom:180,height:180});
  equal(a.context.dockCut('left'), 0, 'image transforms cannot pollute host cut');
  a.context.active.getBoundingClientRect=originalBounds;
  const beforeReverse=JSON.stringify(a.presentations.at(-1).rig), beforePose=JSON.stringify(a.presentations.at(-1).pose);
  a.context.setTucked('left', false);
  near(a.state().frame, forward.frame, 'reversal preserves exact fractional position');
  near(a.state().velocity, forward.velocity, 'reversal preserves velocity');
  equal(JSON.stringify(a.presentations.at(-1).rig),beforeReverse,'reversal retains exact current local deformation');
  equal(JSON.stringify(a.presentations.at(-1).pose),beforePose,'reversal retains exact current screen pose');
  a.advance(160);
  check(a.state().velocity < 0, 'reversal decelerates then moves inward');
  const backward = a.state();
  a.context.setTucked('left', true);
  near(a.state().frame, backward.frame, 'second reversal has no keyframe snap');
  near(a.state().velocity, backward.velocity, 'second reversal retains inward velocity initially');
  check(a.until(() => a.state().phase === 'hold'), 'entry settles into hold');
  equal(a.state().frame, 14, 'hold reaches the settled reveal position');
  const samples=[], holdStart=a.presentations.length;
  for(let i=0;i<420;++i){a.advance(16);samples.push(a.state().frame);}
  check(samples.every(v=>v===14), 'held body position cannot oscillate between different keyframes');
  const held=a.presentations.slice(holdStart);
  check(held.every(p=>p.a==='left-11'&&p.b==='left-11'&&p.t===0), 'long hover never switches face, hand or hair artwork');
  check(held.some(p=>p.rig.wave>0)&&held.some(p=>p.rig.wave===0), 'one source performs a slow local greeting separated by quiet time');
  check(held.every((p,i)=>!i||Math.abs(p.rig.wave-held[i-1].rig.wave)<.003), 'wave has no discontinuous frame or loop reset');
  check(held.every((p,i)=>!i||Math.abs(p.pose.x-held[i-1].pose.x)<1e-9), 'held horizontal reveal stays fixed');
  check(held.every((p,i)=>!i||Math.abs(p.pose.y-held[i-1].pose.y)<.03), 'breathing advances by bounded subpixel steps');
  equal(a.images.filter(i=>i!==a.context.active&&i.src?.includes('edge-hover/')).length,2,'only one source per side is preloaded');
  equal(a.jobs.size,1,'one animation clock owns edge hover');
  a.context.qishiHidden(true);
  const paused=a.state(), pausedCount=a.presentations.length;
  a.advance(10000);
  equal(a.state().frame,paused.frame,'hidden edge preserves fraction');
  equal(a.presentations.length,pausedCount,'hidden edge does not render');
  equal(a.jobs.size,0,'hidden edge cancels clock');
  a.context.qishiHidden(false);
  near(a.state().frame,paused.frame,'resume starts from paused fraction');
  a.setReduced(true);
  equal(a.state().frame,14,'reduced motion selects calm peek endpoint');
  equal(a.jobs.size,0,'reduced motion leaves no clock');
  a.context.setTucked('left',false);
  equal(a.state().frame,0,'reduced motion selects tucked endpoint');
  a.setReduced(false);
  await a.load('right');a.context.setTucked('right',true);
  equal(a.state().frame,0,'side switch starts matching artwork');
  equal(a.context.dockCut('right'),250,'right cut is fixed');
  a.advance(320);a.context.qishiDrag(true);
  equal(a.state().active,false,'drag releases edge ownership');
  const afterDrag=a.presentations.length;a.advance(400);
  check(a.presentations.slice(afterDrag).every(p=>!p.a.startsWith('left-')&&!p.a.startsWith('right-')),'stale edge callbacks cannot overwrite drag');
  a.context.qishiDrag(false);a.context.setTucked('left',true);
  check(a.state().active,'dropping at an edge immediately starts edge playback');
  a.context.setTucked(null);const released=a.presentations.length;a.advance(5000);
  equal(a.state().active,false,'undocking releases edge');
  equal(a.presentations.length,released,'undocking cancels stale callbacks');

  const b=environment();b.context.setTucked('right',true);await b.load('right',-1,11);
  equal(b.state().phase,'fallback','failed set selects original art');
  equal(b.context.currentUrl,'../Claude/edge_right_peek.webp','failed side retains matching art');
  equal(b.jobs.size,0,'failed set schedules no partial animation');
  await b.load('left');b.context.setTucked('left',true);
  equal(b.state().active,true,'failure on right does not disable left');
  b.context.qishiHidden(true);b.context.setTucked('right',false);b.advance(5000);
  equal(b.state().active,false,'hidden side change cannot start animation');
  b.context.qishiHidden(false);equal(b.state().phase,'fallback','failed side remains on fallback');

  const c=environment();c.context.qishiHidden(true);c.context.setTucked('left',true);await c.load('left');
  equal(c.state().active,false,'decoding while hidden cannot start');
  c.context.qishiHidden(false);equal(c.state().frame,0,'newly decoded edge starts at initial pose');
  c.advance(304);for(let i=0;i<50;++i)c.context.setTucked('left',i%2===0);
  check(c.until(()=>c.state().phase==='rest'),'rapid hover toggles settle at requested pose');
  equal(c.state().frame,0,'rapid toggles end tucked');equal(c.jobs.size,0,'rapid toggles leave no orphan clock');

  const d=environment();
  equal(d.images.filter(i=>/drag-motion|dragging/.test(i.src||'')).length,0,'no drag artwork is preloaded');
  equal(d.drag().dragAnimationEnabled,false,'dedicated drag animation is disabled');
  d.context.pose='thinking';d.context.showImage('../Claude/thinking.webp',true);
  const unchanged='../Claude/thinking.webp';
  d.context.qishiDrag(true);
  equal(d.drag().dragging,true,'dragging still informs the host about pointer ownership');
  equal(d.context.currentUrl,unchanged,'pickup keeps the current normal drawing');
  equal(d.drag().displayPose,'thinking','drag does not replace the active work pose');
  check(d.root.classList.contains('qishi-dragging'),'drag pauses normal visual motion');
  d.advance(8000);
  equal(d.context.currentUrl,unchanged,'holding a drag never starts sway animation');
  equal(d.presentations.length,0,'drag never invokes the motion presenter');
  equal(d.jobs.size,0,'drag creates no animation clock');
  equal(d.drag().dragFrame,null,'drag has no animated frame');
  equal(d.drag().dragAnimationPending,false,'drag has no pending animation');
  d.context.qishiDrag(false);
  equal(d.drag().dragging,false,'release clears pointer ownership immediately');
  equal(d.context.currentUrl,unchanged,'release keeps the normal drawing without landing animation');
  check(!d.root.classList.contains('qishi-dragging'),'release restores normal idle or work motion');
  d.advance(2000);
  equal(d.context.currentUrl,unchanged,'release cannot schedule a delayed pose replacement');
  equal(d.jobs.size,0,'release leaves no callback');
  for(let i=0;i<50;++i){d.context.qishiDrag(true);d.advance(i%3*16);d.context.qishiDrag(false);}
  equal(d.context.currentUrl,unchanged,'rapid re-grabs never select drag artwork');
  equal(d.jobs.size,0,'rapid re-grabs create no orphan clock');
  d.setReduced(true);d.context.qishiDrag(true);d.context.qishiDrag(false);
  equal(d.context.currentUrl,unchanged,'reduced-motion dragging retains normal art');
  d.setReduced(false);d.context.qishiDrag(true);d.context.qishiHidden(true);
  equal(d.drag().dragging,false,'hiding clears drag state');
  check(!d.root.classList.contains('qishi-dragging'),'hiding clears paused drag presentation');
  equal(d.jobs.size,0,'hidden drag leaves no clock');
  const manifestContext={window:{}};vm.createContext(manifestContext);
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../Resources/CrossPet/motion-data.js'),'utf8'),manifestContext);
  const data=manifestContext.window.qishiMotionData;
  equal(Object.keys(data.images).length,2,'motion data contains one clean drawing per edge');
  equal(Object.keys(data.pairs).length,0,'independent-image morphs cannot reintroduce outline wobble');
  check(Object.keys(data.images).every(id=>/^(left|right)-11$/.test(id)),'only the two stable source drawings can be loaded');

  const g=environment();g.setPresenterReady(false);await g.load('left');g.context.setTucked('left',true);g.advance(160);
  check(Number.isFinite(parseFloat(g.styles.get('--qishi-edge-offset'))),'loading presenter uses finite fallback offset');
  g.setPresenterReady(true);g.advance(16);
  equal(g.styles.has('--qishi-edge-offset'),false,'ready presenter removes fallback offset before measuring geometry');
  console.log(`Stable single-source edge rig and animation-free dragging: ${checks} checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
