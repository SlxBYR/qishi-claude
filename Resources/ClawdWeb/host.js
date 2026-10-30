// Native event adapter. Animation assets, rendering, transitions, discrete sampling,
// eye/body/shadow movement and click/drag playback remain the upstream renderer.
const theme = window.themeConfig;
let hostPose = 'idle', hostFile = theme.states.idle[0], hostIdleAt = Date.now();
let hostIdlePlayed = false, hostSleepTimer, hostReactionUntil = 0;
let hostTucked = null, hostPeek = false, hostClickTimes = [], hostHidden = false;
let spinAngle = null, spinTotal = 0, spinAt = 0;
function hostRender(state, file) { qishiEmit('onStateChange', state, file); }
window.qishiResume = () => hostRender(hostPose, hostFile);
window.qishiState = (state, file) => {
  if (state === hostPose && file === hostFile) return;
  clearTimeout(hostSleepTimer);
  hostPose = state; hostFile = file; hostIdleAt = Date.now(); hostIdlePlayed = false;
  hostRender(state, file);
};
window.qishiClick = (x, clicks = 1) => {
  const now = Date.now(); hostClickTimes = hostClickTimes.filter(t => now-t < 2500); hostClickTimes.push(now);
  const r = clicks > 1 ? theme.reactions.double : hostClickTimes.length >= 4 ? theme.reactions.annoyed : x < innerWidth/2 ? theme.reactions.clickLeft : theme.reactions.clickRight;
  const file = r.file || r.files[Math.floor(Math.random()*r.files.length)];
  hostReactionUntil = now + r.duration;
  qishiEmit('onPlayClickReaction', file, r.duration);
};
window.qishiDrag = active => {
  if (active) qishiEmit('onStartDragReaction', 'right');
  else { qishiEmit('onEndDragReaction'); qishiResume(); }
};
window.qishiShake = () => {
  hostReactionUntil = Date.now()+6000;
  qishiEmit('onPlayClickReaction', theme.states.dizzy[0], 6000);
};
window.qishiTuck = (side, peek = false) => {
  hostTucked = side; hostPeek = peek;
  qishiEmit('onMiniModeChange', !!side, side);
  if (side) hostRender(peek ? 'mini-peek' : 'mini-idle', theme.miniMode.states[peek ? 'mini-peek' : 'mini-idle'][0]);
  else qishiResume();
};
window.qishiPointer = (x, y, moved, onRight) => {
  qishiEmit('onPetScreenSide', onRight);
  if (moved) {
    hostIdleAt = Date.now(); hostIdlePlayed = false;
    if(hostPose==='idle' && !hostTucked && currentState==='idle' && currentDisplayedSvg!==hostFile && Date.now()>hostReactionUntil) {
      clearTimeout(hostSleepTimer); qishiResume();
    }
    if (hostPose === 'idle' && !hostTucked && Date.now()>hostReactionUntil && ['dozing','yawning','sleeping','collapsing'].includes(currentState)) {
      clearTimeout(hostSleepTimer); hostRender('waking', theme.states.waking[0]);
      hostSleepTimer = setTimeout(qishiResume, theme.timings.wakeDuration);
    }
  }
  const obj = document.getElementById('clawd')?.getBoundingClientRect();
  if (!obj) return;
  const rx = x - (obj.x+obj.width*theme.eyeTracking.eyeRatioX), ry = y-(obj.y+obj.height*theme.eyeTracking.eyeRatioY);
  const distance = Math.hypot(rx, ry), max = theme.eyeTracking.maxOffset;
  let dx=0, dy=0;
  if (distance>1) { const s=Math.min(1,distance/300); dx=rx/distance*max*s; dy=ry/distance*max*s; }
  dx=Math.max(-max*.85,Math.min(max*.85,Math.round(dx*2)/2));
  dy=Math.max(-max*.5,Math.min(max*.5,Math.round(dy*2)/2));
  qishiEmit('onEyeMove',dx,dy);
  if (moved && hostPose==='idle' && !hostTucked && distance>25 && distance<400) {
    const angle=Math.atan2(ry,rx), now=Date.now();
    if (spinAngle!==null && now-spinAt<500) { let d=angle-spinAngle; if(d>Math.PI)d-=2*Math.PI; if(d<-Math.PI)d+=2*Math.PI; spinTotal+=d; }
    else spinTotal=0;
    spinAngle=angle; spinAt=now;
    if(Math.abs(spinTotal)>=4*Math.PI) { spinTotal=0; qishiShake(); }
  }
};
setInterval(() => {
  if (hostPose!=='idle' || hostTucked || hostHidden || Date.now()<hostReactionUntil) return;
  const elapsed=Date.now()-hostIdleAt;
  if (elapsed>=theme.timings.deepSleepTimeout && !['sleeping','collapsing'].includes(currentState)) {
    hostRender('collapsing',theme.states.collapsing[0]);
    hostSleepTimer=setTimeout(()=>hostRender('sleeping',theme.states.sleeping[0]),3000);
  } else if (elapsed>=theme.timings.mouseSleepTimeout && currentState==='idle') {
    hostRender('yawning',theme.states.yawning[0]);
    hostSleepTimer=setTimeout(()=>hostRender('dozing',theme.states.dozing[0]),theme.timings.yawnDuration);
  } else if (elapsed>=theme.timings.mouseIdleTimeout && !hostIdlePlayed) {
    hostIdlePlayed=true;
    const a=theme.idleAnimations[Math.floor(Math.random()*theme.idleAnimations.length)];
    hostRender('idle',a.file); hostSleepTimer=setTimeout(qishiResume,a.duration);
  }
},250);
window.qishiHidden = hidden => {
  hostHidden=hidden;
  const doc=document.getElementById('clawd')?.contentDocument;
  for(const a of doc?.getAnimations?.()||[]) hidden?a.pause():a.play();
};
window.qishiInspect = () => ({state:currentState,file:currentDisplayedSvg,channel:clawdEl?.tagName,
  loaded:clawdEl?.tagName==='OBJECT'?!!clawdEl.contentDocument?.documentElement:(clawdEl?.naturalWidth>0),
  eyes:!!eyeTarget, animations:clawdEl?.contentDocument?.getAnimations?.().length||0,errors:qishiErrors});
window.qishiHitTest = (x,y) => {
  if(!clawdEl) return false;
  const r=clawdEl.getBoundingClientRect(), vb=theme.fileViewBoxes?.[currentDisplayedSvg]||theme.viewBox;
  const box=theme.fileHitBoxes?.[currentDisplayedSvg] || theme.hitBoxes[theme.sleepingHitboxFiles.includes(currentDisplayedSvg)?'sleeping':theme.wideHitboxFiles.includes(currentDisplayedSvg)?'wide':'default'];
  const ratio=Math.min(r.width/vb.width,r.height/vb.height);
  let px=(x-r.left-(r.width-vb.width*ratio)/2)/ratio+vb.x;
  const py=(y-r.top-(r.height-vb.height*ratio)/2)/ratio+vb.y;
  if(hostTucked==='left') px=vb.x+vb.width-(px-vb.x);
  return px>=box.x && px<=box.x+box.w && py>=box.y && py<=box.y+box.h;
};
window.qishiReady=true;
