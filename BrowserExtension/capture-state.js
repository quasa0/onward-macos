// Retry only the short gap between browser focus events and Onward's status update.
// A canceled callback stays inert even if it was already queued by the event loop.
export function createFocusRetries({ schedule = setTimeout, unschedule = clearTimeout, delays = [250, 1000, 2500] } = {}) {
  let generation = 0, timers = [];
  const cancel = () => {
    generation += 1;
    timers.forEach(unschedule); timers = [];
  };
  return {
    cancel,
    start(attempt) {
      cancel();
      const current = generation;
      timers = delays.map(delay => schedule(() => {
        if (current === generation) attempt();
      }, delay));
      attempt();
    }
  };
}

export function captureRejection({ startedAt, finishedAt, initialFrame, finalFrame, initialTab, currentTab, currentWindow }, maxMilliseconds = 6000) {
  const elapsed = finishedAt - startedAt;
  if (!Number.isFinite(elapsed) || elapsed < 0 || elapsed > maxMilliseconds) {
    return "Browser capture exceeded its freshness budget; waiting for a fresh capture.";
  }
  if (!initialFrame?.id || !initialFrame.loaderId || !finalFrame?.id || !finalFrame.loaderId) {
    return "Browser document identity unavailable; waiting for a stable document.";
  }
  if (["id", "loaderId", "url", "urlFragment"].some(key => initialFrame[key] !== finalFrame[key])) {
    return "The browser document changed during capture; waiting for a stable document.";
  }
  if (!currentTab?.active || !currentWindow?.focused || initialTab.id !== currentTab.id
      || initialTab.windowId !== currentTab.windowId || currentTab.windowId !== currentWindow.id
      || initialTab.url !== currentTab.url) {
    return "The focused browser tab changed during capture; waiting for a stable tab.";
  }
  return null;
}
