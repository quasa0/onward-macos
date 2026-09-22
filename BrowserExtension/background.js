import { renderAX, renderDOM } from "./ax-text.js";
import { createFocusRetries, captureRejection } from "./capture-state.js";

const HOST = "com.quasa0.onward";
let busy = false, port, attachedTab, timer, blockedTab;
let captureGeneration = 0;
const focusRetries = createFocusRetries();
const childSessions = new Map();
const command = (target, method, params = {}) => chrome.debugger.sendCommand(target, method, params);

async function status() {
  return chrome.runtime.sendNativeMessage(HOST, { type: "status" });
}
async function detach() {
  const tabId = attachedTab; attachedTab = undefined; childSessions.clear();
  if (tabId !== undefined) { try { await chrome.debugger.detach({ tabId }); } catch {} }
}
async function stop() {
  clearInterval(timer); timer = undefined;
  const connection = port; port = undefined;
  connection?.disconnect();
  await detach();
}
function cancelCapture() {
  captureGeneration += 1;
  focusRetries.cancel();
}
function focusChanged() {
  cancelCapture();
  focusRetries.start(() => void capture());
}
async function capture() {
  if (busy) return;
  busy = true;
  const generation = captureGeneration, startedAt = Date.now();
  const currentCapture = () => generation === captureGeneration;
  try {
    const preferences = await chrome.storage.local.get({ enabled: true });
    if (!currentCapture()) return;
    if (!preferences.enabled) { cancelCapture(); await stop(); return; }
    const state = await status();
    if (!currentCapture()) return;
    if (!state.enabled) { await stop(); return; }
    const win = await chrome.windows.getLastFocused();
    if (!currentCapture()) return;
    if (!win.focused) { await stop(); return; }
    const [tab] = await chrome.tabs.query({ active: true, windowId: win.id });
    if (!currentCapture()) return;
    if (!tab?.id || !/^(https?|file):/.test(tab.url ?? "") || tab.id === blockedTab) { await detach(); return; }
    if (!port) {
      const connection = chrome.runtime.connectNative(HOST);
      port = connection;
      connection.onDisconnect.addListener(() => {
        const error = chrome.runtime.lastError?.message;
        if (port !== connection) return;
        port = undefined; cancelCapture(); void detach(); clearInterval(timer); timer = undefined;
        void chrome.storage.local.set({ lastError: error || "Onward's browser connection closed. Capture will retry when the app is available." });
      });
      timer = setInterval(() => void capture(), 4000);
    }
    if (attachedTab !== tab.id) {
      await detach();
      if (!currentCapture()) return;
      await chrome.debugger.attach({ tabId: tab.id }, "1.3");
      attachedTab = tab.id;
      if (!currentCapture()) { await detach(); return; }
      await command({ tabId: tab.id }, "Accessibility.enable");
      if (!currentCapture()) return;
      await command({ tabId: tab.id }, "Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true, filter: [{ type: "iframe", exclude: false }] });
    }
    if (!currentCapture()) return;
    const target = { tabId: tab.id }, warnings = [];
    const [{ frameTree }, dom] = await Promise.all([
      command(target, "Page.getFrameTree"),
      command(target, "DOMSnapshot.captureSnapshot", { computedStyles: [], includePaintOrder: false, includeDOMRects: false })
    ]);
    if (!currentCapture()) return;
    const frames = [];
    const walk = tree => { frames.push(tree.frame); for (const child of tree.childFrames ?? []) walk(child); };
    walk(frameTree);
    const sections = [];
    for (const frame of frames) {
      if (!currentCapture()) return;
      try {
        const { nodes } = await command(target, "Accessibility.getFullAXTree", { frameId: frame.id });
        sections.push(`FRAME ${frame.url}\n${renderAX(nodes)}`);
      } catch { warnings.push(`Frame text unavailable: ${frame.url || frame.id}`); }
    }
    for (const [sessionId, session] of childSessions) {
      if (!currentCapture()) return;
      try {
        const { nodes } = await command({ tabId: tab.id, sessionId }, "Accessibility.getFullAXTree");
        sections.push(`IFRAME ${session.url}\n${renderAX(nodes)}`);
      } catch { warnings.push(`Cross-process iframe text unavailable: ${session.url}`); }
    }
    if (!currentCapture()) return;
    const [{ frameTree: finalTree }, current, currentWindow] = await Promise.all([
      command(target, "Page.getFrameTree"), chrome.tabs.get(tab.id), chrome.windows.get(win.id)
    ]);
    if (!currentCapture()) return;
    const text = `${sections.join("\n\n")}\n\nDOM TEXT (may include off-screen content)\n${renderDOM(dom)}`.slice(0, 24000);
    const rejection = captureRejection({ startedAt, finishedAt: Date.now(), initialFrame: frameTree.frame,
      finalFrame: finalTree.frame, initialTab: tab, currentTab: current, currentWindow });
    if (rejection) throw new Error(rejection);
    port?.postMessage({ type: "snapshot", capturedAt: startedAt / 1000, tabId: tab.id, title: current.title ?? "", url: current.url, text, warnings });
    await chrome.storage.local.set({ lastCapture: Date.now(), lastTitle: current.title, lastError: "" });
  } catch (error) {
    if (currentCapture()) await chrome.storage.local.set({ lastError: String(error.message ?? error) });
    if (!port) await detach();
  } finally { busy = false; }
}
chrome.debugger.onEvent.addListener((source, method, params) => {
  if (source.tabId !== attachedTab) return;
  if (method === "Target.attachedToTarget") {
    childSessions.set(params.sessionId, { url: params.targetInfo.url });
    void command({ tabId: source.tabId, sessionId: params.sessionId }, "Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true, filter: [{ type: "iframe", exclude: false }] }).catch(() => {});
  }
  if (method === "Target.detachedFromTarget") childSessions.delete(params.sessionId);
});
chrome.debugger.onDetach.addListener((source, reason) => {
  // detach() clears attachedTab first, so our own detach cannot block a later capture.
  if (source.tabId !== attachedTab) return;
  attachedTab = undefined; childSessions.clear();
  if (reason === "canceled_by_user") {
    blockedTab = source.tabId; cancelCapture();
    void chrome.storage.local.set({ lastError: "Browser capture canceled. Change tabs or re-enable capture to resume." });
    void stop();
  }
});
chrome.tabs.onActivated.addListener(() => { blockedTab = undefined; focusChanged(); });
chrome.tabs.onUpdated.addListener((id, change, tab) => { if (tab.active && (change.url || change.title || change.status === "complete")) void capture(); });
chrome.windows.onFocusChanged.addListener(windowId => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) { cancelCapture(); void stop(); }
  else focusChanged();
});
chrome.storage.onChanged.addListener(changes => {
  if (!changes.enabled) return;
  cancelCapture();
  if (changes.enabled.newValue === false) void stop();
  else { blockedTab = undefined; focusRetries.start(() => void capture()); }
});
chrome.alarms.create("onward-refresh", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => void capture());
void capture();
