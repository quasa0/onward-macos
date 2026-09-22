import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { createFocusRetries, captureRejection } from '../../BrowserExtension/capture-state.js';
import { renderAX, renderDOM } from '../../BrowserExtension/ax-text.js';

const source = readFileSync(new URL('../../BrowserExtension/background.js', import.meta.url), 'utf8').replace(/^import .*;$/gm, '');
const event = () => {
  const listeners = [];
  return { addListener: listener => listeners.push(listener), fire: (...args) => listeners.forEach(listener => listener(...args)) };
};
const settle = () => new Promise(resolve => setImmediate(resolve));

function browser({ nativeEnabled = false, finalLoader = 'document-1', duration = 1000, attachWait } = {}) {
  const state = { nativeEnabled, enabled: true, now: 10_000, attachments: 0, detachments: 0, messages: [], writes: [], connections: [], jobs: new Map() };
  let nextJob = 0, frames = 0;
  const schedule = (callback, delay) => {
    const id = ++nextJob; state.jobs.set(id, { callback, delay }); return id;
  };
  const unschedule = id => state.jobs.delete(id);
  const tab = { id: 10, windowId: 20, active: true, title: 'Onward', url: 'https://example.com/onward' };
  const chrome = {
    runtime: {
      async sendNativeMessage() { return { enabled: state.nativeEnabled }; },
      connectNative() {
        const connection = { onDisconnect: event(), disconnect() {}, postMessage: value => state.messages.push(value) };
        state.connections.push(connection); return connection;
      }
    },
    storage: {
      local: { async get() { return { enabled: state.enabled }; }, async set(value) { state.writes.push(value); } },
      onChanged: event()
    },
    windows: {
      WINDOW_ID_NONE: -1,
      async getLastFocused() { return { id: 20, focused: true }; },
      async get() { return { id: 20, focused: true }; },
      onFocusChanged: event()
    },
    tabs: { async query() { return [tab]; }, async get() { return tab; }, onActivated: event(), onUpdated: event() },
    debugger: {
      async attach() { state.attachments += 1; if (attachWait) await attachWait; },
      async detach() { state.detachments += 1; },
      async sendCommand(target, method) {
        if (method === 'Page.getFrameTree') {
          frames += 1;
          if (frames % 2 === 0) state.now += duration;
          return { frameTree: { frame: { id: 'main', loaderId: frames % 2 ? 'document-1' : finalLoader, url: tab.url } } };
        }
        if (method === 'DOMSnapshot.captureSnapshot') return { documents: [], strings: [] };
        if (method === 'Accessibility.getFullAXTree') return { nodes: [{ role: { value: 'StaticText' }, name: { value: 'Build Onward' } }] };
        return {};
      },
      onEvent: event(), onDetach: event()
    },
    alarms: { create() {}, onAlarm: event() }
  };
  vm.runInNewContext(source, {
    chrome, renderAX, renderDOM, captureRejection,
    createFocusRetries: () => createFocusRetries({ schedule, unschedule }),
    Date: { now: () => state.now }, setInterval: () => ++nextJob, clearInterval() {}
  });
  return { state, chrome };
}

test('focus retries recover from delayed native foreground status and remain bounded', async () => {
  const { state, chrome } = browser();
  await settle();
  chrome.windows.onFocusChanged.fire(20);
  await settle();
  assert.equal(state.attachments, 0);
  assert.deepEqual([...state.jobs.values()].map(job => job.delay), [250, 1000, 2500]);
  state.nativeEnabled = true;
  for (const [id, job] of [...state.jobs]) {
    state.jobs.delete(id); job.callback(); await settle();
  }
  assert.equal(state.attachments, 1);
  assert.equal(state.messages.length, 3);
  assert.equal(state.jobs.size, 0, 'retry callbacks do not schedule unbounded retry loops');
});

test('extension disable invalidates queued focus retries and alarm captures', async () => {
  const { state, chrome } = browser();
  await settle();
  chrome.windows.onFocusChanged.fire(20);
  await settle();
  const alreadyQueued = [...state.jobs.values()];
  state.enabled = false;
  chrome.storage.onChanged.fire({ enabled: { newValue: false } });
  state.nativeEnabled = true;
  alreadyQueued.forEach(job => job.callback());
  chrome.alarms.onAlarm.fire();
  await settle();
  assert.equal(state.jobs.size, 0);
  assert.equal(state.attachments, 0);
  assert.equal(state.messages.length, 0);
});

test('user debugger cancellation suppresses queued retries and subsequent alarm attachment', async () => {
  const { state, chrome } = browser({ nativeEnabled: true });
  await settle();
  chrome.windows.onFocusChanged.fire(20);
  await settle();
  const alreadyQueued = [...state.jobs.values()];
  chrome.debugger.onDetach.fire({ tabId: 10 }, 'canceled_by_user');
  alreadyQueued.forEach(job => job.callback());
  chrome.alarms.onAlarm.fire();
  await settle();
  assert.equal(state.attachments, 1);
  assert.equal(state.jobs.size, 0);
  assert.match(state.writes.at(-1).lastError, /canceled/);
});

test('disable during an in-flight attachment detaches it without publishing or retrying', async () => {
  let finishAttachment;
  const attachWait = new Promise(resolve => { finishAttachment = resolve; });
  const { state, chrome } = browser({ nativeEnabled: true, attachWait });
  await settle();
  assert.equal(state.attachments, 1);
  state.enabled = false;
  chrome.storage.onChanged.fire({ enabled: { newValue: false } });
  finishAttachment();
  await settle();
  assert.equal(state.detachments, 1);
  assert.equal(state.messages.length, 0);
  assert.equal(state.attachments, 1);
});

test('late disconnect from a stopped connection cannot detach its replacement', async () => {
  const { state, chrome } = browser({ nativeEnabled: true });
  await settle();
  const oldConnection = state.connections[0];
  chrome.windows.onFocusChanged.fire(-1);
  await settle();
  chrome.windows.onFocusChanged.fire(20);
  await settle();
  assert.equal(state.connections.length, 2);
  oldConnection.onDisconnect.fire();
  chrome.alarms.onAlarm.fire();
  await settle();
  assert.equal(state.detachments, 1);
  assert.equal(state.connections.length, 2);
  assert.equal(state.messages.length, 3);
});

test('published freshness uses capture start, and a same-URL document reload is rejected', async () => {
  const stable = browser({ nativeEnabled: true, duration: 2000 });
  await settle();
  assert.equal(stable.state.messages[0].capturedAt, 10);
  assert.equal(stable.state.now, 12_000);
  const reloaded = browser({ nativeEnabled: true, finalLoader: 'document-2' });
  await settle();
  assert.equal(reloaded.state.messages.length, 0);
  assert.match(reloaded.state.writes.at(-1).lastError, /document changed/);
});

test('slow captures are rejected instead of stamped as fresh at completion', async () => {
  const { state } = browser({ nativeEnabled: true, duration: 6001 });
  await settle();
  assert.equal(state.messages.length, 0);
  assert.match(state.writes.at(-1).lastError, /freshness budget/);
});

test('validation rejects missing document identity, moved tabs, changed fragments, and invalid elapsed time', () => {
  const frame = { id: 'main', loaderId: 'document-1', url: 'https://example.com', urlFragment: '#one' };
  const tab = { id: 1, windowId: 2, active: true, title: 'Work', url: 'https://example.com#one' };
  const input = { startedAt: 1000, finishedAt: 2000, initialFrame: frame, finalFrame: frame,
    initialTab: tab, currentTab: tab, currentWindow: { id: 2, focused: true } };
  assert.equal(captureRejection(input), null);
  assert.equal(captureRejection({ ...input, currentTab: { ...tab, title: 'Work · Saved' } }), null,
    'title-only changes do not invalidate stable tab and document identity');
  assert.match(captureRejection({ ...input, finalFrame: { ...frame, loaderId: '' } }), /identity unavailable/);
  assert.match(captureRejection({ ...input, currentTab: { ...tab, windowId: 3 } }), /tab changed/);
  assert.match(captureRejection({ ...input, finalFrame: { ...frame, urlFragment: '#two' } }), /document changed/);
  for (const finishedAt of [0, NaN, Infinity]) {
    assert.match(captureRejection({ ...input, finishedAt }), /freshness budget/);
  }
});
