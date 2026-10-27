// Omarchy Browser Plugin Manager - background service worker (MV3).
// Content scripts cannot open native messaging ports, so the extension
// relays ping/install requests to the registered native host here.

const api = typeof browser !== "undefined" ? browser : chrome;

const HOST_NAME = "bramvanoploo_omarchy_browser_plugin_manager";
const HOST_TIMEOUT_MS = 12000; // install validation fetches the catalog remotely

function talkToHost(message) {
  return new Promise((resolve) => {
    let port;
    try {
      port = api.runtime.connectNative(HOST_NAME);
    } catch (e) {
      console.warn("[plugin-installer] connectNative threw:", e);
      resolve({ ok: false, reason: "host-not-registered" });
      return;
    }
    let settled = false;
    const finish = (response) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { port.disconnect(); } catch (e) { /* already gone */ }
      resolve(response);
    };
    const timer = setTimeout(
      () => finish({ ok: false, reason: "host-timeout" }),
      HOST_TIMEOUT_MS
    );
    port.onMessage.addListener((response) => {
      console.debug("[plugin-installer] native host replied:", JSON.stringify(response));
      finish(response);
    });
    port.onDisconnect.addListener(() => {
      const err = api.runtime.lastError;
      console.warn("[plugin-installer] native host disconnected; lastError:",
        err ? err.message : "(not set by browser)");
      finish({ ok: false, reason: "host-not-registered" });
    });
    port.postMessage(message);
  });
}

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  console.debug("[plugin-installer] background got message:", message && message.type);
  const allowed = ["ping", "status", "status_all", "install", "uninstall", "enable", "disable"];
  if (!message || !allowed.includes(message.type)) return false;
  talkToHost(message)
    .then(sendResponse)
    .catch(() => sendResponse({ ok: false, reason: "host-error" }));
  return true; // keep the message channel open for the async response
});
