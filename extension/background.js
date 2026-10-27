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
]);

const FAST_TYPES = new Set(["ping", "status", "status_all"]);

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
