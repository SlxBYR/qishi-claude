// Native event adapter. Animation assets, rendering, transitions, discrete sampling,
// eye/body/shadow movement and click/drag playback remain the upstream renderer.
// What upstream's Electron main process decides is ported here from the pinned commit:
// state.js (sessions, priority, tiers, min display, auto return, sleep and DND),
// tick.js (idle looks, yawning, eye tracking, dizzy spin, mini peek),
// hit-renderer.js (click accumulator, drag reactions) and mini.js state handling.
// The native window owns geometry and reads qishiMiniPeek() to slide the peek.
const theme = window.themeConfig;
const T = theme.timings;
const STATE_SVGS = { ...theme.states, ...theme.miniMode.states };
const MIN_DISPLAY_MS = { ...T.minDisplay, executing: T.minDisplay.executing ?? T.minDisplay.working ?? 0 };
const AUTO_RETURN_MS = T.autoReturn;
const COLLAPSE_DURATION = T.collapseDuration || 0;
const SVG_IDLE_FOLLOW = theme.states.idle[0];
const STATE_PRIORITY = { error: 8, notification: 7, sweeping: 6, attention: 5, carrying: 4, juggling: 4,
  executing: 3.5, working: 3, thinking: 2, idle: 1, roam: 1, sleeping: 0 };
const ONESHOT_STATES = new Set(['attention', 'error', 'sweeping', 'notification', 'carrying']);
const SLEEP_SEQUENCE = new Set(['yawning', 'dozing', 'collapsing', 'sleeping', 'waking']);
// agents/claude-code.js eventMap; PermissionRequest flashes notification like state.js.
const EVENT_MAP = { SessionStart: 'idle', SessionEnd: 'sleeping', UserPromptSubmit: 'thinking', PreToolUse: 'working',
  PostToolUse: 'working', PostToolBatch: 'thinking', PostToolUseFailure: 'error', Stop: 'attention', StopFailure: 'error',
  SubagentStart: 'juggling', SubagentStop: 'working', PreCompact: 'sweeping', PostCompact: 'attention',
  Notification: 'notification', Elicitation: 'notification', WorktreeCreate: 'carrying', PermissionRequest: 'notification' };
const CLICK_WINDOW_MS = 400, MINI_ENTER_MS = 3200, WAKE_POLL_START_DELAY_MS = 500, WAKE_POLL_MS = 200;
const SPIN_THRESHOLD = Math.PI*4, SPIN_IDLE_RESET_MS = 500, SPIN_MIN_RADIUS = 24, DIZZY_COOLDOWN_MS = 12000;
const SOUND_COOLDOWN_MS = 10000;

// ── state.js ──
let hostState = 'idle', hostSvg = SVG_IDLE_FOLLOW, stateChangedAt = Date.now();
let pendingTimer = null, pendingState = null, autoReturnTimer = null, eyeResendTimer = null;
let hostSessions = new Map(), hostDnd = false, hostSoundOn = true, lastSoundTime = 0, hostHidden = false;
const stablePicks = new Map();
function hostRender(state, file) { qishiEmit('onStateChange', state, file); }
function pickFile(state, files) {
  if (!Array.isArray(files) || !files.length) return null;
  if (files.length === 1) return files[0];
  const signature = files.join('\n'), held = stablePicks.get(state);
  if (held && held.signature === signature) return held.file;
  const file = files[Math.floor(Math.random()*files.length)];
  stablePicks.set(state, { signature, file });
  return file;
}
function tierFiles(tiers, count, fallback) {
  for (const tier of tiers || []) if (count >= tier.minSessions) return tier.files || [tier.file];
  return fallback || [];
}
function getSvgOverride(state) {
  const sessions = [...hostSessions.values()];
  if (state === 'idle') return SVG_IDLE_FOLLOW;
  if (state === 'working' || state === 'executing') {
    const count = sessions.filter(s => ['working','executing','thinking','juggling'].includes(s.state)).length;
    return pickFile('working', tierFiles(theme.workingTiers, count, STATE_SVGS.working));
  }
  if (state === 'juggling') {
    const count = sessions.filter(s => s.state === 'juggling').reduce((n, s) => n+Math.max(1, s.agents || 0), 0);
    return pickFile('juggling', tierFiles(theme.jugglingTiers, count, STATE_SVGS.juggling));
  }
  if (state === 'thinking') return pickFile('thinking', STATE_SVGS.thinking);
  return null;
}
function resolveDisplayState() {
  if (!hostSessions.size) return 'idle';
  let best = 'sleeping';
  for (const s of hostSessions.values()) if ((STATE_PRIORITY[s.state] || 0) > (STATE_PRIORITY[best] || 0)) best = s.state;
  return best;
}
function applyResolvedDisplayState() { const r = resolveDisplayState(); applyState(r, getSvgOverride(r)); }
function clearPending() { clearTimeout(pendingTimer); pendingTimer = null; pendingState = null; }
function playSound(name) {
  if (!hostSoundOn || hostDnd) return;
  const now = Date.now();
  if (now-lastSoundTime < SOUND_COOLDOWN_MS || !theme.sounds?.[name]) return;
  lastSoundTime = now;
  qishiEmit('onPlaySound', { url: `sounds/${theme.sounds[name]}`, volume: 1 });
}
function scheduleAutoReturn(state) {
  autoReturnTimer = setTimeout(() => {
    autoReturnTimer = null;
    if (hostTucked) {
      if (miniOver && !hostDnd) {
        if (state === 'mini-peek') { miniPeeked = true; applyState('mini-idle'); }
        else { peekWindow = true; applyState('mini-peek'); }
      } else applyState(hostDnd ? 'mini-sleep' : 'mini-idle');
    } else applyResolvedDisplayState();
  }, AUTO_RETURN_MS[state]);
}
function setState(newState, svgOverride) {
  if (hostDnd) return;
  if (newState === 'yawning' && SLEEP_SEQUENCE.has(hostState)) return;
  if (newState === hostState && (!svgOverride || svgOverride === hostSvg)) {
    if (AUTO_RETURN_MS[newState] && !autoReturnTimer && !pendingTimer) scheduleAutoReturn(newState);
    return;
  }
  if (pendingTimer) {
    if (pendingState && (STATE_PRIORITY[newState] || 0) < (STATE_PRIORITY[pendingState] || 0)) return;
    clearPending();
  }
  const remaining = (MIN_DISPLAY_MS[hostState] || 0)-(Date.now()-stateChangedAt);
  if (remaining > 0) {
    clearTimeout(autoReturnTimer); autoReturnTimer = null;
    pendingState = newState;
    pendingTimer = setTimeout(() => {
      const queued = pendingState; pendingTimer = null; pendingState = null;
      if (ONESHOT_STATES.has(queued)) applyState(queued, svgOverride);
      else applyResolvedDisplayState();
    }, remaining);
  } else applyState(newState, svgOverride);
}
function applyState(state, svgOverride) {
  if (hostMiniBusy && !state.startsWith('mini-')) return;
  if (hostTucked && !state.startsWith('mini-')) {
    if (state === 'notification') return applyState('mini-alert');
    if (state === 'attention') return applyState('mini-happy');
    if (['working','executing','thinking','juggling'].includes(state)) return applyState('mini-working');
    if ((AUTO_RETURN_MS[hostState] || hostState === 'mini-working') && !autoReturnTimer)
      return applyState(miniOver ? 'mini-peek' : 'mini-idle');
    return;
  }
  hostState = state; stateChangedAt = Date.now(); idlePaused = false;
  if (state === 'attention' || state === 'mini-happy') playSound('complete');
  else if (state === 'notification' || state === 'mini-alert') playSound('confirm');
  hostSvg = svgOverride || (state === 'idle' ? SVG_IDLE_FOLLOW : pickFile(state, STATE_SVGS[state]));
  clearTimeout(eyeResendTimer);
  if (state === 'idle' || state === 'mini-idle') eyeResendTimer = setTimeout(() => { forceEyeResend = true; }, 300);
  hostRender(state, hostSvg);
  clickReacting = false; resetClickAccumulator();
  if (state !== 'idle' && state !== 'mini-idle') qishiEmit('onEyeMove', 0, 0);
  if (['dozing','collapsing','sleeping'].includes(state) && !hostDnd) scheduleWakePollStart(state);
  else stopWakePoll();
  clearTimeout(autoReturnTimer); autoReturnTimer = null;
  if (state === 'yawning') autoReturnTimer = setTimeout(() => { autoReturnTimer = null; applyState(hostDnd ? 'collapsing' : 'dozing'); }, T.yawnDuration);
  else if (state === 'collapsing') { if (COLLAPSE_DURATION > 0) autoReturnTimer = setTimeout(() => { autoReturnTimer = null; applyState('sleeping'); }, COLLAPSE_DURATION); }
  else if (state === 'waking') autoReturnTimer = setTimeout(() => { autoReturnTimer = null; applyResolvedDisplayState(); }, T.wakeDuration);
  else if (AUTO_RETURN_MS[state]) scheduleAutoReturn(state);
}
// Wake poll: dozing wakes on the first pointer move; ten still minutes collapse it into sleep.
let wakePollStartTimer = null, wakePollTimer = null, wakePollActive = false;
function scheduleWakePollStart(state) {
  if (wakePollActive) return;
  clearTimeout(wakePollStartTimer);
  wakePollStartTimer = setTimeout(() => { wakePollStartTimer = null; if (hostState === state) { wakePollActive = true; wakePollTick(); } }, WAKE_POLL_START_DELAY_MS);
}
function wakePollTick() {
  wakePollTimer = setTimeout(() => {
    if (!wakePollActive || hostDnd) return;
    if (hostState === 'dozing' && Date.now()-mouseStillSince >= T.deepSleepTimeout) applyState('collapsing');
    if (wakePollActive) wakePollTick();
  }, WAKE_POLL_MS);
}
function stopWakePoll() { clearTimeout(wakePollStartTimer); clearTimeout(wakePollTimer); wakePollStartTimer = wakePollTimer = null; wakePollActive = false; }
function wakeFromDoze() {
  if (hostState === 'sleeping' || hostState === 'collapsing') return applyState('waking');
  qishiEmit('onWakeFromDoze');
  setTimeout(() => { if (hostState === 'dozing') applyState('idle', getSvgOverride('idle')); }, 350);
}
// Claude Code sessions as reported by the native store, plus the hook events since the last update.
window.qishiClaude = (sessions, events = []) => {
  const before = JSON.stringify([...hostSessions.values()].map(s => [s.id, s.state, s.agents]));
  hostSessions = new Map(sessions.map(s => [s.id, s]));
  for (const event of events) {
    const state = EVENT_MAP[event];
    if (!state) continue;
    if (ONESHOT_STATES.has(state)) setState(state);
    else { const r = resolveDisplayState(); setState(r, getSvgOverride(r)); }
  }
  if (!events.length && before !== JSON.stringify(sessions.map(s => [s.id, s.state, s.agents]))) {
    const r = resolveDisplayState(); setState(r, getSvgOverride(r));
  }
};
// Verification and previews put a state on screen directly.
window.qishiState = (state, file) => applyState(state, file);
// Renderer callbacks: a reaction pauses the idle tick and hands the current state back when done.
let idlePaused = false;
window.qishiPauseIdle = () => { idlePaused = true; };
window.qishiResume = () => { idlePaused = false; if (!hostMiniBusy) hostRender(hostState, hostSvg); };
window.qishiDnd = on => {
  if (on === hostDnd) return;
  hostDnd = on; qishiEmit('onDndChange', on);
  if (on) {
    clearPending(); clearTimeout(autoReturnTimer); autoReturnTimer = null; stopWakePoll();
    if (hostTucked) { peekWindow = false; applyState('mini-sleep'); } else applyState('yawning');
  } else if (hostTucked) {
    if (sleepPeeked) { peekWindow = false; sleepPeeked = false; }
    miniPeeked = false; applyState('mini-idle');
  } else applyState('waking');
};
window.qishiSound = on => { hostSoundOn = !!on; };

// ── hit-renderer.js: 2-3 clicks poke, 4 clicks flail; only an idle pet reacts ──
let clickCount = 0, clickTimer = null, firstClickDir = null, clickReacting = false, dragDirection = null;
function resetClickAccumulator() { clearTimeout(clickTimer); clickTimer = null; clickCount = 0; firstClickDir = null; }
function canPlayReactionNow() { return hostState === 'idle' && !hostDnd && !clickReacting; }
function playClickReaction(file, duration) {
  clickReacting = true;
  qishiEmit('onPlayClickReaction', file, duration);
  setTimeout(() => { clickReacting = false; }, duration);
}
window.qishiClick = x => {
  if (hostTucked || isDragReacting) return;
  const r = theme.reactions;
  clickCount++;
  if (clickCount === 1) firstClickDir = x < innerWidth/2 ? 'left' : 'right';
  clearTimeout(clickTimer); clickTimer = null;
  if (clickCount >= 4 && r.double) {
    clickCount = 0; firstClickDir = null;
    if (!canPlayReactionNow()) return;
    const files = r.double.files || [r.double.file];
    playClickReaction(files[Math.floor(Math.random()*files.length)], r.double.duration || 3500);
  } else if (clickCount >= 2) {
    clickTimer = setTimeout(() => {
      const dir = firstClickDir; clickTimer = null; clickCount = 0; firstClickDir = null;
      if (!canPlayReactionNow()) return;
      if (r.annoyed && Math.random() < 0.5) playClickReaction(r.annoyed.file, r.annoyed.duration || 3500);
      else if (r.clickLeft && r.clickRight) { const react = dir === 'left' ? r.clickLeft : r.clickRight; playClickReaction(react.file, react.duration || 2500); }
    }, CLICK_WINDOW_MS);
  } else clickTimer = setTimeout(resetClickAccumulator, CLICK_WINDOW_MS);
};
window.qishiDragDir = direction => {
  if (hostDnd || (dragDirection === direction && isDragReacting)) return;
  clickReacting = false; dragDirection = direction;
  qishiEmit('onStartDragReaction', direction);
};
window.qishiDrag = active => {
  if (active) return;
  dragDirection = null;
  qishiEmit('onEndDragReaction');
};

// ── mini.js state side ──
let hostTucked = null, hostMiniBusy = false, miniOver = false, miniPeeked = false, sleepPeeked = false, peekWindow = false, miniEntryTimer = null;
window.qishiMiniPeek = () => peekWindow;
// Menu entry walks to the edge first, still in the normal-size layout.
window.qishiCrabwalk = side => {
  hostMiniBusy = true;
  qishiEmit('onMiniModeChange', true, side, { preEntry: true });
  applyState('mini-crabwalk');
};
// Entry: the native window slides (or jumps) into place, then qishiMiniEntered() plays mini-enter.
window.qishiTuck = side => {
  clearTimeout(miniEntryTimer); miniEntryTimer = null;
  peekWindow = miniPeeked = sleepPeeked = miniOver = false;
  if (side) {
    hostTucked = side; hostMiniBusy = true; stopWakePoll();
    qishiEmit('onMiniModeChange', true, side);
    return;
  }
  hostTucked = null; hostMiniBusy = false;
  qishiEmit('onMiniClip', null);
  qishiEmit('onMiniModeChange', false);
  if (hostDnd) { hostDnd = false; qishiEmit('onDndChange', false); applyState('waking'); }
  else applyResolvedDisplayState();
};
window.qishiMiniEntered = (settleDelay = 0) => {
  if (!hostTucked) return;
  applyState(hostDnd ? 'mini-enter-sleep' : 'mini-enter');
  miniEntryTimer = setTimeout(() => {
    miniEntryTimer = null; hostMiniBusy = false;
    applyState(hostDnd ? 'mini-sleep' : 'mini-idle');
  }, settleDelay+MINI_ENTER_MS);
};
// Exit jump in progress: keep the current mini drawing, stop peeking.
window.qishiMiniExit = () => {
  clearTimeout(miniEntryTimer); miniEntryTimer = null;
  hostMiniBusy = true; peekWindow = miniPeeked = sleepPeeked = false;
};
// Launch with the saved edge: rest straight in mini-idle like restoreFromPrefs().
window.qishiMiniRestore = side => {
  hostTucked = side; hostMiniBusy = false;
  qishiEmit('onMiniModeChange', true, side);
  applyState('mini-idle');
};

// ── tick.js ──
let mouseStillSince = Date.now(), isMouseIdle = false, hasTriggeredYawn = false, idleLookPlayed = false;
let idleLookReturnTimer = null, yawnDelayTimer = null, idleWasActive = false, forceEyeResend = false;
let tickEyeDx = 0, tickEyeDy = 0, lastCursorAngle = null, accumulatedSpin = 0, dizzyCooldownUntil = 0, lastSpinTickAt = 0;
function clearIdleTimers() { clearTimeout(idleLookReturnTimer); clearTimeout(yawnDelayTimer); idleLookReturnTimer = yawnDelayTimer = null; }
function resetIdlePeriodForMouseMove() {
  mouseStillSince = Date.now(); hasTriggeredYawn = false; idleLookPlayed = false;
  clearIdleTimers();
  if (isMouseIdle) { isMouseIdle = false; hostRender('idle', SVG_IDLE_FOLLOW); }
}
window.qishiPointer = (x, y, moved, onRight) => {
  qishiEmit('onPetScreenSide', onRight);
  if (moved && wakePollActive) { stopWakePoll(); wakeFromDoze(); }
  const idleNow = hostState === 'idle' && !idlePaused;
  const miniIdleNow = hostState === 'mini-idle' && !idlePaused && !hostMiniBusy;
  if (idleNow && !idleWasActive) {
    isMouseIdle = false; tickEyeDx = tickEyeDy = 0; lastCursorAngle = null; accumulatedSpin = 0; lastSpinTickAt = 0;
    clearIdleTimers(); hasTriggeredYawn = false; idleLookPlayed = false; mouseStillSince = Date.now();
  }
  if (!idleNow && idleWasActive) clearIdleTimers();
  idleWasActive = idleNow;
  if (!idleNow && !miniIdleNow && !hostTucked) return;
  if (hostTucked && !hostMiniBusy) {
    miniOver = qishiHitTest(x, y);
    const s = hostState;
    if (['mini-idle','mini-peek','mini-sleep'].includes(s)) {
      if (miniOver && s === 'mini-sleep' && !sleepPeeked) { peekWindow = true; sleepPeeked = true; }
      else if (!miniOver && s === 'mini-sleep' && sleepPeeked) { peekWindow = false; sleepPeeked = false; }
      else if (miniOver && s === 'mini-idle' && !miniPeeked) { peekWindow = true; applyState('mini-peek'); }
      else if (!miniOver && (s === 'mini-peek' || miniPeeked)) {
        peekWindow = false; miniPeeked = false;
        if (s !== 'mini-idle') applyState('mini-idle');
      }
    }
  }
  if (idleNow) {
    if (moved) resetIdlePeriodForMouseMove();
    const elapsed = Date.now()-mouseStillSince;
    if (!hasTriggeredYawn && elapsed >= T.mouseSleepTimeout) {
      hasTriggeredYawn = true;
      if (!isMouseIdle) qishiEmit('onEyeMove', 0, 0);
      yawnDelayTimer = setTimeout(() => { yawnDelayTimer = null; if (hostState === 'idle') setState('yawning'); }, isMouseIdle ? 50 : 250);
      return;
    }
    if (theme.idleAnimations.length && !isMouseIdle && !hasTriggeredYawn && !idleLookPlayed && elapsed >= T.mouseIdleTimeout) {
      isMouseIdle = true; idleLookPlayed = true;
      const pick = theme.idleAnimations[Math.floor(Math.random()*theme.idleAnimations.length)];
      qishiEmit('onEyeMove', 0, 0);
      yawnDelayTimer = setTimeout(() => {
        yawnDelayTimer = null;
        if (!isMouseIdle || hostState !== 'idle') return;
        hostRender('idle', pick.file);
        idleLookReturnTimer = setTimeout(() => {
          idleLookReturnTimer = null;
          if (!isMouseIdle || hostState !== 'idle') return;
          isMouseIdle = false;
          hostRender('idle', SVG_IDLE_FOLLOW);
          setTimeout(() => { forceEyeResend = true; }, 200);
        }, pick.duration);
      }, 250);
      return;
    }
  }
  const trackEyesNow = (idleNow && hostSvg === SVG_IDLE_FOLLOW && !isMouseIdle) || miniIdleNow;
  if (!trackEyesNow) { if (idleNow && !isMouseIdle) forceEyeResend = false; return; }
  if (!moved && !forceEyeResend) return;
  const skipDedup = forceEyeResend; forceEyeResend = false;
  const obj = document.getElementById('clawd')?.getBoundingClientRect();
  if (!obj) return;
  const relX = x-(obj.x+obj.width*theme.eyeTracking.eyeRatioX), relY = y-(obj.y+obj.height*theme.eyeTracking.eyeRatioY);
  const max = theme.eyeTracking.maxOffset, dist = Math.hypot(relX, relY);
  let dx = 0, dy = 0;
  if (dist > 1) { const s = Math.min(1, dist/300); dx = relX/dist*max*s; dy = relY/dist*max*s; }
  dx = Math.max(-max*.85, Math.min(max*.85, Math.round(dx*2)/2));
  dy = Math.max(-max*.5, Math.min(max*.5, Math.round(dy*2)/2));
  if (skipDedup || dx !== tickEyeDx || dy !== tickEyeDy) { tickEyeDx = dx; tickEyeDy = dy; qishiEmit('onEyeMove', dx, dy); }
  if (idleNow && !miniIdleNow && !isMouseIdle && moved) {
    const now = Date.now();
    if (dist < SPIN_MIN_RADIUS) { lastCursorAngle = null; accumulatedSpin = 0; }
    else {
      const angle = Math.atan2(relY, relX), stalled = lastSpinTickAt > 0 && now-lastSpinTickAt > SPIN_IDLE_RESET_MS;
      if (lastCursorAngle === null || stalled) accumulatedSpin = 0;
      else {
        let delta = angle-lastCursorAngle;
        if (delta > Math.PI) delta -= 2*Math.PI;
        if (delta < -Math.PI) delta += 2*Math.PI;
        accumulatedSpin += delta;
        if (Math.abs(accumulatedSpin) >= SPIN_THRESHOLD && now > dizzyCooldownUntil) {
          accumulatedSpin = 0; lastCursorAngle = null; lastSpinTickAt = 0; dizzyCooldownUntil = now+DIZZY_COOLDOWN_MS;
          tickEyeDx = tickEyeDy = 0;
          setState('dizzy');
          return;
        }
      }
      lastCursorAngle = angle;
    }
    lastSpinTickAt = now;
  }
};

window.qishiHidden = hidden => {
  hostHidden=hidden;
  const doc=document.getElementById('clawd')?.contentDocument;
  for(const a of doc?.getAnimations?.()||[]) hidden?a.pause():a.play();
};
window.qishiInspect = () => ({state:currentState,host:hostState,file:currentDisplayedSvg,channel:clawdEl?.tagName,
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
