// The original Electron renderer runs unchanged; AppKit supplies its event channel.
window.qishiErrors = [];
window.addEventListener('error', e => qishiErrors.push(String(e.message || e.target?.src || e.type)), true);
const hostListeners = new Map();
window.qishiEmit = (event, ...args) => hostListeners.get(event)?.(...args);
window.electronAPI = new Proxy({}, { get: (_, key) => {
  if (String(key).startsWith('on')) return fn => hostListeners.set(key, fn);
  if (key === 'resumeFromReaction') return () => window.qishiResume?.();
  if (key === 'reportSoundPlaybackError') return error => qishiErrors.push(String(error));
  return () => {};
}});
