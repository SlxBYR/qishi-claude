// Local adapter: authored art stays intact; the upstream renderer owns all motion.
window.qishiErrors = [];
window.addEventListener('error', e => qishiErrors.push(String(e.message || e.target?.src || e.type)), true);
let registeredAt = null, accountOpen = false, accountTimer = null, accountLang = 'zh';
let claudeDragging = false;
// Dragging moves the native window only. Keep the normal character pose;
// there is no pickup, sway, landing sequence, or drag animation clock.
window.qishiDrag = dragging => {
  dragging=!!dragging;
  if(dragging===claudeDragging)return;
  claudeDragging=dragging;
  if(dragging) {
    qishiDismissAccount();
    setTucked(null);
  }
  document.documentElement.classList.toggle('qishi-dragging',dragging);
};
// Edge docking is static: the tucked drawing stays put. Hover never swaps in
// the peek drawing, and there is no reveal, retract or wave animation.
const originalSetTucked=setTucked;
setTucked=function(side){originalSetTucked(side||null,false);};
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
  displayPose: pose,
  fx: $('fx').querySelectorAll('svg').length, animations: document.getAnimations().length,
  accountOpen, accountText: accountOpen ? bubble.textContent : '',
  chrome: ['bubble','foot','newsCard'].filter(id => {
    const el = $(id), style = getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden' && !el.classList.contains('hide');
  }) });
window.qishiHidden = hidden => {
  if (hidden) {
    qishiDismissAccount();
    if (claudeDragging) qishiDrag(false);
  }
  setPageHidden(hidden);
};
let hitCanvas, hitImage;
window.qishiHitTest = (x,y) => {
  if (onBubble(x, y)) return true;
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
