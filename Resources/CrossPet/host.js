// Local adapter: authored art stays intact; a single continuous clock owns motion.
window.qishiErrors = [];
window.addEventListener('error', e => qishiErrors.push(String(e.message || e.target?.src || e.type)), true);
let registeredAt = null, accountOpen = false, accountTimer = null, accountLang = 'zh';
const { clamp: dragClamp, ease: dragEase, approach, edgeRig } = QishiMotion;
const motionRenderer = window.qishiMotionRenderer;
function loadFrames(cache, url, count) {
  return Promise.all(Array.from({length: count}, (_,frame) => new Promise((resolve,reject) => {
    const image = new Image(); image.decoding = 'async'; cache.push(image);
    image.onload = async () => { try { if (image.decode) await image.decode(); if(!image.naturalWidth) throw Error('empty frame'); resolve(); } catch(e) { reject(e); } };
    image.onerror = reject; image.src = url(frame);
  })));
}
const dragReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
let claudeDragging = false, edgeHover = null;
const renderImage = showImage;
showImage = function(url, instant) {
  if(edgeHover?.inspect().active) return;
  renderImage(url,instant);
};
function motionRect(side = null) {
  const r = active.getBoundingClientRect(), size = Math.min(r.width,r.height);
  return {x:r.left+(r.width-size)*(side==='left'?0:side==='right'?1:.5),y:r.bottom-size,width:size,height:size};
}
function paintEdgeRig(id,side,pose,rig) {
  if(!motionRenderer?.inspect().enabled || document.documentElement.classList.contains('qishi-motion-releasing')) motionRenderer?.begin(false);
  return motionRenderer?.paintRig(id,motionRect(side),pose,rig);
}
// Dragging moves the native window only. Keep the normal character pose;
// there is no pickup, sway, landing sequence, or drag animation clock.
window.qishiDrag = dragging => {
  dragging=!!dragging;
  if(dragging===claudeDragging)return;
  claudeDragging=dragging;
  if(dragging) {
    qishiDismissAccount();
    setTucked(null);
    motionRenderer?.end(true);
  }
  document.documentElement.classList.toggle('qishi-dragging',dragging);
};
// The 0..14 cursor is reveal progress, never an index into different drawings.
window.qishiEdgeHoverConfig={frameCount:1,sourceFrame:11,lastFrame:14,gesturePeriod:10};
function createEdgeHoverController(options) {
  const config=options.config,loaded={left:'loading',right:'loading'};
  let side=null,peek=false,phase='idle',active=false,paused=false,timer=null,generation=0,lastTime=null;
  let cursor={value:0,velocity:0},clock=0;
  const last=()=>config.lastFrame;
  function cancel(){++generation;if(timer!==null)options.cancel(timer);timer=null;lastTime=null;}
  function draw(){options.render(side,cursor.value,phase,clock);}
  function queue(){const token=generation;timer=options.schedule(now=>{timer=null;if(token===generation&&active&&!paused)tick(now);});}
  function tick(now){
    const dt=lastTime===null?0:Math.min(.032,Math.max(0,(now-lastTime)/1000));lastTime=now;clock+=dt;
    if(options.reduced()){cursor={value:peek?last():0,velocity:0};phase=peek?'hold':'rest';draw();return;}
    const target=peek?last():0;
    approach(cursor,target,dt,4);
    cursor.value=dragClamp(cursor.value,0,last());
    const settled=Math.abs(cursor.value-target)<.008&&Math.abs(cursor.velocity)<.05;
    phase=peek?(settled?'hold':'enter'):(settled?'rest':'exit');
    if(settled){cursor.value=target;cursor.velocity=0;}
    draw();
    if(peek||!settled)queue();
  }
  function start(){
    if(!side||loaded[side]!=='ready')return;
    if(paused){phase='paused';return;}active=true;tick(performance.now());
  }
  function request(nextSide,nextPeek){
    nextSide=['left','right'].includes(nextSide)?nextSide:null;nextPeek=!!nextSide&&!!nextPeek;
    if(nextSide===side&&nextPeek===peek)return;
    cancel();if(nextSide!==side){cursor={value:0,velocity:0};clock=0;active=false;options.end();}
    side=nextSide;peek=nextPeek;
    if(!side){active=false;phase='idle';options.end();return;}
    if(loaded[side]!=='ready'){active=false;phase=loaded[side]==='failed'?'fallback':'loading';options.end();options.fallback(side,peek);return;}
    start();
  }
  return {request,setReady(which,ok){loaded[which]=ok?'ready':'failed';if(side!==which)return;cancel();if(ok)start();else{active=false;phase='fallback';options.end();options.fallback(side,peek);}},
    setPaused(value){value=!!value;if(value===paused)return;paused=value;cancel();if(paused){if(active)phase='paused';}else if(side)start();},
    refresh(){cancel();if(side)start();},
    inspect:()=>({side,peek,frame:active?cursor.value:null,velocity:cursor.velocity,sourceFrame:config.sourceFrame,gestureClock:clock,phase,active,paused,ready:{...loaded},timerPending:timer!==null})};
}
const edgeFrameURL=(side,frame)=>`../Claude/edge-hover/${side}-${String(frame).padStart(2,'0')}.png`;
const edgeImageCache={left:[],right:[]},edgeClasses=document.documentElement.classList;
edgeHover=createEdgeHoverController({config:window.qishiEdgeHoverConfig,schedule:callback=>requestAnimationFrame(callback),cancel:handle=>cancelAnimationFrame(handle),reduced:()=>dragReducedMotion.matches,
  render(side,frame,phase,clock){
    edgeClasses.add('qishi-edge-hover');
    const source=window.qishiEdgeHoverConfig.sourceFrame;
    // One original drawing supplies the face, hand and outline on every frame.
    renderImage(edgeFrameURL(side,source),true);
    document.documentElement.style.removeProperty('--qishi-edge-offset');
    const rect=motionRect(side),progress=frame/14,cut=.46-.32*dragEase(progress);
    const rig=edgeRig(progress,clock,dragReducedMotion.matches);
    const pose={x:(side==='left'?-1:1)*rect.width*cut,y:0,rotation:0,scale:1};
    if(!paintEdgeRig(`${side}-${source}`,side,pose,rig))document.documentElement.style.setProperty('--qishi-edge-offset',`${pose.x}px`);
  },
  end(){edgeClasses.remove('qishi-edge-hover');document.documentElement.style.removeProperty('--qishi-edge-offset');motionRenderer?.end(claudeDragging);},
  fallback(side,peek){if(!claudeDragging)renderImage(framesFor(`edge_${side}${peek?'_peek':''}`)[0],true);}
});
const originalSetTucked=setTucked;
setTucked=function(side,peek=false){
  if(!side)edgeHover.request(null,false);
  originalSetTucked(side,peek);
  if(side&&!claudeDragging)edgeHover.request(side,peek);
};
const originalDockCut=dockCut;
dockCut=function(side){const state=edgeHover.inspect();if(state.active&&state.side===side)return side==='left'?0:(document.documentElement.clientWidth||innerWidth);return originalDockCut(side);};
dragReducedMotion.addEventListener('change',()=>edgeHover.refresh());
for(const side of ['left','right'])loadFrames(edgeImageCache[side],()=>edgeFrameURL(side,window.qishiEdgeHoverConfig.sourceFrame),1).then(()=>edgeHover.setReady(side,true),()=>edgeHover.setReady(side,false));
const bubble = $('bubble');
bubble.setAttribute('role', 'status');
bubble.setAttribute('aria-live', 'polite');
bubble.setAttribute('aria-atomic', 'true');
const accountLine = () => {
  const days = registeredAt === null ? null : Math.floor(Math.max(0, Date.now() / 1000 - registeredAt) / 86400);
  if (accountLang === 'en') return days === null ? 'Set the registration time first' : `Account alive for ${days} day${days === 1 ? '' : 's'}`;
  return days === null ? '请先设置账号注册时间' : `账号已存活 ${days} 天`;
};
// State changes and upstream chatter must not replace the requested account age.
say = function () {
  const line = accountOpen ? accountLine() : '';
  if (bubble.textContent !== line) bubble.textContent = line;
  bubble.classList.toggle('hide', !accountOpen);
  bubble.setAttribute('aria-hidden', String(!accountOpen));
};
window.qishiDismissAccount = () => {
  clearTimeout(accountTimer);
  accountOpen = false;
  document.documentElement.classList.remove('qishi-account-open');
  say();
};
window.qishiShowAccount = () => {
  clearTimeout(accountTimer);
  accountOpen = true;
  document.documentElement.classList.add('qishi-account-open');
  say();
  accountTimer = setTimeout(qishiDismissAccount, 8000);
};
const onBubble = (x, y) => {
  if (!accountOpen || getComputedStyle(bubble).visibility === 'hidden') return false;
  const r = bubble.getBoundingClientRect();
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
};
window.qishiClick = (x, y) => {
  if (onBubble(x, y)) { qishiDismissAccount(); return; }
  handleClick('pat', x, y);
  qishiShowAccount();
};
window.addEventListener('keydown', event => {
  if (event.key === 'Escape') qishiDismissAccount();
});
setInterval(() => { if (accountOpen) say(); }, 1000);
init(window.qishiManifest);
setShowName(false);
setAuraMode('auto');
window.qishiUpdate = payload => {
  if (payload.lang === 'en' || payload.lang === 'zh') accountLang = payload.lang;
  if (Object.prototype.hasOwnProperty.call(payload, 'registeredAt')) {
    registeredAt = typeof payload.registeredAt === 'number' && Number.isFinite(payload.registeredAt)
      ? payload.registeredAt : null;
    if (accountOpen) say();
  }
  setSessions('claude', payload.sessions || {});
  if (payload.state) applyCharState('claude', payload.state);
  if (payload.quota) setQuota('claude', payload.quota);
};
window.qishiInspect = () => ({ ...diagnoseDisplay(), errors: qishiErrors, motion: $('body').className,
  dragging: claudeDragging, dragPhase: 'idle', dragFrame: null,
  dragAnimationEnabled: false, dragAnimationPending: false,
  motionRenderer: motionRenderer?.inspect() || null,
  edgeHover: edgeHover.inspect(),
  displayPose: pose,
  fx: $('fx').querySelectorAll('svg').length, animations: document.getAnimations().length,
  accountOpen, accountText: accountOpen ? bubble.textContent : '',
  chrome: ['bubble','foot','newsCard'].filter(id => {
    const el = $(id), style = getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden' && !el.classList.contains('hide');
  }) });
window.qishiHidden = hidden => {
  edgeHover.setPaused(hidden);
  if (hidden) {
    qishiDismissAccount();
    if (claudeDragging) qishiDrag(false);
  }
  setPageHidden(hidden);
};
let hitCanvas, hitImage;
window.qishiHitTest = (x,y) => {
  if (onBubble(x, y)) return true;
  const edge = edgeHover.inspect();
  if(edge.active && edge.peek) {
    const r=motionRect(edge.side);
    // Keep the hover target fixed while hair, hands and the reveal move inside it.
    if(y>=r.y+r.height*.1&&y<=r.y+r.height&&
      (edge.side==='left'?x>=0&&x<=r.width*.8:x>=innerWidth-r.width*.8&&x<=innerWidth)) return true;
  }
  const renderedHit = motionRenderer?.hit(x, y);
  if (renderedHit !== null && renderedHit !== undefined) return renderedHit;
  const r = shownRect();
  if (!r || x<r.left || y<r.top || x>r.left+r.width || y>r.top+r.height) return false;
  try {
    if (!hitCanvas) { hitCanvas=document.createElement('canvas'); hitCanvas.width=128; hitCanvas.height=128; }
    const ctx=hitCanvas.getContext('2d',{willReadFrequently:true});
    if(hitImage!==active.src) { ctx.clearRect(0,0,128,128); ctx.drawImage(active,0,0,128,128); hitImage=active.src; }
    return ctx.getImageData(Math.min(127,Math.floor((x-r.left)/r.width*128)),Math.min(127,Math.floor((y-r.top)/r.height*128)),1,1).data[3]>20;
  } catch { return true; }
};
window.qishiReady = true;
