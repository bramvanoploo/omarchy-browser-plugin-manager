// Omarchy Browser Plugin Manager - background service worker (MV3).
// Content scripts cannot open native messaging ports, so the extension
// relays ping/status/action requests to the registered native host here.
// Reuses a single native port with a FIFO queue while active and closes
// it after an idle window so the host and service worker do not stay awake.

const api = typeof browser !== "undefined" ? browser : chrome;

const HOST_NAME = "bramvanoploo_omarchy_browser_plugin_manager";
const ACTION_TIMEOUT_MS = 12000; // install/uninstall/toggle validate against remote catalog
const QUERY_TIMEOUT_MS = 4000;   // ping/status/status_all are local queries
const IDLE_TIMEOUT_MS = 15000;

const ALLOWED_TYPES = new Set([
  "ping",
  "status",
  "status_all",
  "install",
  "uninstall",
  "enable",
  "disable",
  "update",
  "updates",
  "watch",
  "unwatch",
  "visit",
  "unvisit",
]);

const FAST_TYPES = new Set(["ping", "status", "status_all", "updates", "watch", "unwatch", "visit", "unvisit"]);

let activePort = null;
let currentTask = null;
let idleTimer = null;
const taskQueue = [];

function clearIdleTimer() {
  if (idleTimer !== null) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

function scheduleIdleDisconnect() {
  clearIdleTimer();
  if (currentTask || taskQueue.length > 0 || !activePort) return;
  idleTimer = setTimeout(() => {
    idleTimer = null;
    if (!currentTask && taskQueue.length === 0 && activePort) {
      const port = activePort;
      activePort = null;
      try { port.disconnect(); } catch (_e) { /* already gone */ }
    }
  }, IDLE_TIMEOUT_MS);
}

function dropPort(reason) {
  clearIdleTimer();
  const port = activePort;
  activePort = null;
  if (port) {
    try { port.disconnect(); } catch (_e) { /* already gone */ }
  }
  if (currentTask) {
    const task = currentTask;
    currentTask = null;
    clearTimeout(task.timer);
    task.resolve({ ok: false, reason });
  }
  pumpQueue();
}

function ensurePort() {
  if (activePort) return activePort;
  let port;
  try {
    port = api.runtime.connectNative(HOST_NAME);
  } catch (_e) {
    return null;
  }
  activePort = port;

  port.onMessage.addListener((response) => {
    if (!currentTask) return;
    const task = currentTask;
    currentTask = null;
    clearTimeout(task.timer);
    task.resolve(response && typeof response === "object" ? response : { ok: false, reason: "invalid-host-response" });
    pumpQueue();
  });

  port.onDisconnect.addListener(() => {
    void api.runtime.lastError;
    if (activePort === port) activePort = null;
    dropPort("host-not-registered");
  });

  return port;
}

function pumpQueue() {
  if (currentTask) return;
  const next = taskQueue.shift();
  if (!next) {
    scheduleIdleDisconnect();
    return;
  }
  clearIdleTimer();
  const port = ensurePort();
  if (!port) {
    next.resolve({ ok: false, reason: "host-not-registered" });
    pumpQueue();
    return;
  }
  const timeoutMs = FAST_TYPES.has(next.payload.type) ? QUERY_TIMEOUT_MS : ACTION_TIMEOUT_MS;
  next.timer = setTimeout(() => {
    if (currentTask === next) {
      dropPort("host-timeout");
    }
  }, timeoutMs);
  currentTask = next;
  try {
    port.postMessage(next.payload);
  } catch (_e) {
    dropPort("host-not-registered");
  }
}

function sanitizeMessage(message) {
  if (!message || typeof message !== "object" || !ALLOWED_TYPES.has(message.type)) {
    return null;
  }
  const payload = { type: message.type };
  if (typeof message.id === "string") payload.id = message.id.slice(0, 128);
  if (typeof message.repo === "string") payload.repo = message.repo.slice(0, 256);
  if (typeof message.name === "string") payload.name = message.name.slice(0, 128);
  if (typeof message.source === "string") payload.source = message.source.slice(0, 32);
  if (typeof message.key === "string") payload.key = message.key.slice(0, 64);
  if (typeof message.url === "string") payload.url = message.url.slice(0, 512);
  return payload;
}

function isTrustedSender(sender) {
  if (!sender || sender.id !== api.runtime.id) return false;
  const url = sender.url || (sender.tab && sender.tab.url) || "";
  return typeof url === "string" && url.startsWith("https://plugins.omarchy.org/");
}

function talkToHost(payload) {
  return new Promise((resolve) => {
    taskQueue.push({ payload, resolve, timer: null });
    pumpQueue();
  });
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!isTrustedSender(sender)) return false;
  const payload = sanitizeMessage(message);
  if (!payload) return false;
  talkToHost(payload)
    .then(sendResponse)
    .catch(() => sendResponse({ ok: false, reason: "host-error" }));
  return true; // keep the message channel open for the async response
});

// Presence heartbeat and focus jump (bar widget left click).
//
// The heartbeat lives in the service worker, not in page scripts: a
// backgrounded tab's page timers are throttled hard by the browser (Firefox:
// one timer per minute), which made the tab records go stale exactly when the
// marketplace tab is not the active tab — the failing case. The worker is
// driven by tab events and its own interval, so presence stays fresh for
// every marketplace tab regardless of which tab is focused.
//
// Every open plugins.omarchy.org tab sends "visit" (per-tab random key) every
// couple of seconds; the host records it in browser-tabs.json for the bar
// widget. When the widget asks for a marketplace tab, the host answers that
// tab's visit with activate:true and the worker raises it: focus the window,
// select the tab.

const PRESENCE_INTERVAL_MS = 2000;
const PRESENCE_URL_PATTERN = "https://plugins.omarchy.org/*";

const presenceKeys = new Map(); // tabId -> per-load random key
let presenceTimer = null;
let presenceSource = null; // "firefox" | "chrome" (host field), resolved lazily

function makePresenceKey() {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;
}

async function detectSource() {
  if (presenceSource) return presenceSource;
  try {
    const info = await api.runtime.getBrowserInfo();
    presenceSource = info && info.name === "Firefox" ? "firefox" : "chrome";
  } catch (_e) {
    presenceSource = "chrome";
  }
  return presenceSource;
}

async function activateTab(tab) {
  try {
    await api.windows.update(tab.windowId, { focused: true });
    await api.tabs.update(tab.id, { active: true });
  } catch (_e) { /* window closed mid-focus: nothing to do */ }
}

async function syncPresence() {
  let tabs = [];
  try {
    tabs = await api.tabs.query({ url: PRESENCE_URL_PATTERN });
  } catch (_e) {
    return; // API unavailable: keep existing records, retry on next tick
  }
  const seen = new Set(tabs.map((tab) => tab.id));
  for (const [tabId, key] of presenceKeys) {
    if (!seen.has(tabId)) {
      presenceKeys.delete(tabId);
      talkToHost({ type: "unvisit", key }).catch(() => {});
    }
  }
  if (tabs.length === 0) {
    stopPresenceLoop();
    return;
  }
  const source = await detectSource();
  for (const tab of tabs) {
    if (typeof tab.id !== "number" || typeof tab.url !== "string") continue;
    let key = presenceKeys.get(tab.id);
    if (!key) {
      key = makePresenceKey();
      presenceKeys.set(tab.id, key);
    }
    try {
      const response = await talkToHost({
        type: "visit",
        source,
        key,
        url: tab.url.slice(0, 512),
      });
      if (response && response.activate === true) await activateTab(tab);
    } catch (_e) { /* host down: retry next tick */ }
  }
}

function stopPresenceLoop() {
  if (presenceTimer !== null) {
    clearInterval(presenceTimer);
    presenceTimer = null;
  }
}

function schedulePresenceSync() {
  if (presenceTimer === null) {
    presenceTimer = setInterval(() => { void syncPresence(); }, PRESENCE_INTERVAL_MS);
  }
  void syncPresence();
}

api.tabs.onCreated.addListener(() => schedulePresenceSync());
api.tabs.onRemoved.addListener(() => schedulePresenceSync());
api.tabs.onUpdated.addListener((tabId, changeInfo) => {
  // A completed navigation replaced the page: the old presence key belongs
  // to the previous document, so mint a fresh one for the new load.
  if (changeInfo.status === "complete") presenceKeys.set(tabId, makePresenceKey());
  schedulePresenceSync();
});

if (api.runtime.onStartup) api.runtime.onStartup.addListener(() => schedulePresenceSync());
if (api.runtime.onInstalled) api.runtime.onInstalled.addListener(() => schedulePresenceSync());
schedulePresenceSync(); // worker boot (also covers browser start on Firefox)
