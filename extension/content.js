// Omarchy Browser Plugin Manager - content script.
// Adds action buttons to plugin detail pages, driven entirely by live local
// state reported by the native messaging host (never by the page):
//   not installed            -> "Install"
//   installed, enabled       -> "Disable" + "Uninstall"
//   installed, not enabled   -> "Enable" + "Uninstall"
// Gated on:
//   1. the marketplace's own availability rule for this plugin (catalog.json),
//   2. a live ping to the local native messaging host.
// No host => no buttons; the site renders untouched.
// While the page is the visible tab it also runs the bar-icon watcher beacon:
// a "watch" record with the host (renewed every 5s, "unwatch" on leave) that
// lights the Omarchy bar widget for this plugin.

(() => {
  "use strict";

  const api = typeof browser !== "undefined" ? browser : chrome;
  const PLUGIN_ID = new URLSearchParams(window.location.search).get("id");
  const HOST_PING_TIMEOUT_MS = 2500;
  const HOST_STATUS_TIMEOUT_MS = 4000;
  const HOST_ACTION_TIMEOUT_MS = 12000;
  const POLL_MS = 1000;

  let hostAvailable = false;
  let mounted = false;

  // Styles are injected as a <style> node by this script instead of the
  // manifest's content_css pipeline: in Firefox the manifest CSS injection
  // demonstrably does not reach the page, leaving buttons unstyled.
  // Declarations mirror the marketplace's .copy-button rule and .copy-icon
  // line-art idiom exactly, using the page's own CSS tokens.
  const STYLES = `
.pi-group {
  display: inline-flex;
  align-items: center;
  gap: 7px;
}
.pi-button {
  display: inline-flex;
  position: relative;
  min-height: 25px;
  padding: 0 8px !important;
  border: 1px solid var(--line-strong, #666666) !important;
  border-radius: 0 !important;
  background: transparent !important;
  align-items: center;
  gap: 3px;
  color: var(--text, #dddddd) !important;
  font-family: var(--mono, monospace);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: none;
  appearance: none !important;
  -moz-appearance: none !important;
}
.pi-button:hover {
  background: var(--panel-2, rgba(127, 127, 127, 0.12)) !important;
  color: var(--text, #dddddd) !important;
}
.pi-button:disabled {
  opacity: 0.55;
}
/* The page's ".command-panel-head > span span" rule (margin-left: 8px,
 * muted color, no uppercase) leaks into every span nested in our group.
 * Neutralize it on icon + label so both inherit the button's tone
 * (border color == text color == icon color via currentColor). */
.pi-button > span:not(.pi-tooltip) {
  margin-left: 0 !important;
  color: inherit !important;
}
.pi-button > [data-label] {
  letter-spacing: 0.06em !important;
}
.pi-button.pi-button-danger {
  color: var(--accent, #ffcead) !important;
}
/* Install action: the marketplace's own stable tone. Text and icon
 * (icons draw with currentColor). All button borders stay the base
 * .pi-button rule: var(--line-strong). */
.pi-button.pi-button-install {
  color: var(--stable, #b4c96f) !important;
}
.pi-icon {
  position: relative;
  display: inline-block;
  width: 13px;
  height: 13px;
  flex: none;
}
.pi-icon::before,
.pi-icon::after {
  position: absolute;
  content: "";
}
.pi-icon-install::before {
  left: 6px;
  top: 0;
  width: 1px;
  height: 7px;
  background: currentColor;
}
.pi-icon-install::after {
  left: 1px;
  right: 1px;
  bottom: 1px;
  height: 5px;
  border: 1px solid currentColor;
  border-top: 0;
}
.pi-icon-enable::before {
  inset: 3px;
  border: 1px solid currentColor;
  transform: rotate(45deg);
}
.pi-icon-disable::before,
.pi-icon-disable::after {
  top: 2px;
  width: 1px;
  height: 9px;
  background: currentColor;
}
.pi-icon-disable::before {
  left: 4px;
}
.pi-icon-disable::after {
  right: 4px;
}
.pi-icon-uninstall::before,
.pi-icon-uninstall::after {
  left: 2px;
  right: 2px;
  top: 6px;
  height: 1px;
  background: currentColor;
}
.pi-icon-uninstall::before {
  transform: rotate(45deg);
}
.pi-icon-uninstall::after {
  transform: rotate(-45deg);
}
/* Tooltip mirroring the marketplace's .control-tooltip: shown on hover/
 * focus of the button, anchored above its right edge. */
.pi-tooltip {
  position: absolute;
  z-index: 1000;
  right: 0;
  bottom: calc(100% + 8px);
  left: auto;
  width: max-content;
  max-width: min(300px, calc(100vw - 56px));
  padding: 5px 7px;
  border: 1px solid var(--line-strong, #666666);
  border-radius: 0;
  background: var(--panel-2, #1e1e24);
  color: var(--text, #dddddd);
  font-family: var(--sans, sans-serif);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0;
  line-height: 1.3;
  text-align: left;
  text-transform: none;
  box-shadow: 0 8px 24px rgb(0 0 0 / 28%);
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
}
.pi-button:hover .pi-tooltip,
.pi-button:focus .pi-tooltip {
  opacity: 1 !important;
  visibility: visible !important;
  pointer-events: auto;
}
`;

  function injectStyles() {
    if (document.getElementById("pi-styles") || !document.head) return;
    const style = document.createElement("style");
    style.id = "pi-styles";
    style.textContent = STYLES;
    document.head.append(style);
  }

  // Mirrors the marketplace's marketplaceInstallAvailable() in plugin.js.
  function installable(plugin) {
    return Boolean(
      plugin
      && plugin.installAvailable
      && plugin.upstreamCheckStatus !== "failed"
      && !plugin.builtIn
      && (plugin.installCommand || "").length > 0
      && /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(\.git)?\/?$/.test(plugin.repo || "")
    );
  }

  async function loadCatalog() {
    const url = new URL("catalog.json", window.location.href).href;
    const response = await fetch(url, { cache: "no-store" });
    if (!response.ok) throw new Error(`catalog request failed: ${response.status}`);
    return response.json();
  }

  function talkToHost(message, timeoutMs = HOST_ACTION_TIMEOUT_MS) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (value) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(value);
        }
      };
      const timer = setTimeout(() => done({ ok: false, reason: "host-timeout" }), timeoutMs);
      try {
        const sent = api.runtime.sendMessage(message, (response) => {
          void api.runtime.lastError;
          done(response || { ok: false, reason: "no-response" });
        });
        // Firefox's promise-style browser namespace ignores the callback:
        // settle from the returned promise too (done() settles once).
        if (sent && typeof sent.then === "function") {
          sent.then(done).catch(() => done({ ok: false, reason: "no-response" }));
        }
      } catch (_e) {
        done({ ok: false, reason: "extension-error" });
      }
    });
  }

  async function pingHost() {
    const response = await talkToHost({ type: "ping" }, HOST_PING_TIMEOUT_MS);
    return Boolean(response && response.ok);
  }

  // Icon + label + tooltip markup mirroring the marketplace Copy button
  // (13px CSS line-art icon, .control-tooltip hover box, aria-label).
  function makeButton(label, tooltip, extraClass, iconClass) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button has-control-tooltip pi-button" + (extraClass ? " " + extraClass : "");
    button.setAttribute("aria-label", tooltip);
    const icon = document.createElement("span");
    icon.className = "pi-icon " + iconClass;
    icon.setAttribute("aria-hidden", "true");
    const labelEl = document.createElement("span");
    labelEl.dataset.label = "";
    labelEl.textContent = label;
    const tip = document.createElement("span");
    tip.className = "control-tooltip pi-tooltip";
    tip.setAttribute("role", "tooltip");
    tip.setAttribute("aria-hidden", "true");
    tip.textContent = tooltip;
    button.append(icon, labelEl, tip);
    return button;
  }

  // Send the action and let the wizard on the desktop be the feedback.
  // Re-enable the button once the summon completes so that if the user cancels
  // the wizard, it can be reopened without reloading the page; when confirmed,
  // the state-sync poll rebuilds the buttons as soon as the live state changes.
  //
  // A one-click install is the intent behind copying the install command, so
  // the page's own copy button is clicked too: its listener writes the command
  // to the clipboard and registers the "copies" engagement event. The dispatch
  // must stay synchronous inside the user gesture: the site's clipboard write
  // needs the transient activation. The site dedupes copies per session.
  function registerSiteCopy() {
    const copy = document.querySelector("#detail-content [data-install-copy]");
    if (copy) copy.click();
  }

  function wireAction(button, plugin, type) {
    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      button.disabled = true;
      const action = typeof type === "function" ? type() : type;
      if (action === "install") registerSiteCopy();
      try {
        await talkToHost({
          type: action,
          id: plugin.id,
          repo: plugin.repo,
          name: plugin.name,
        }, HOST_ACTION_TIMEOUT_MS);
      } finally {
        button.disabled = false;
        busy = false;
      }
    });
  }

  function mountButtons(plugin, state) {
    // The marketplace renders a Copy button in the command panel head; we
    // group our buttons directly left of it and let it keep its own node
    // (the page's click listener survives the move).
    const copy = document.querySelector("#detail-content [data-install-copy]");
    if (!copy) return;
    const head = copy.closest(".command-panel-head") || copy.parentElement;
    if (!head || copy.closest(".pi-group")) return;

    const group = document.createElement("span");
    group.className = "pi-group";

    const buttons = [];
    if (!state.installed) {
      const install = makeButton("Install", "Install this plugin", "pi-button-install", "pi-icon-install");
      wireAction(install, plugin, "install");
      buttons.push(install);
    } else {
      // Label, icon and tone come from the live state; the state-sync poll
      // (1s) rebuilds the buttons when the host's answer changes, so the
      // wizard, the desktop, and the page can never drift apart.
      const enabled = Boolean(state.enabled);
      const verb = enabled ? "Disable" : "Enable";
      const tip = verb + " this plugin";
      const toggle = makeButton(
        verb, tip,
        enabled ? "pi-button-danger" : "pi-button-install",
        enabled ? "pi-icon-disable" : "pi-icon-enable"
      );
      wireAction(toggle, plugin, () => (enabled ? "disable" : "enable"));
      const uninstall = makeButton("Uninstall", "Uninstall this plugin", "pi-button-danger", "pi-icon-uninstall");
      wireAction(uninstall, plugin, "uninstall");
      buttons.push(toggle, uninstall);
    }

    head.insertBefore(group, copy);
    group.append(...buttons, copy);
    mounted = true;
    lastState = state;
  }

  // Real-time sync: poll the host's live state every second. When it
  // diverges from the mounted buttons (wizard confirmed/cancelled, plugin
  // enabled/disabled/removed on the desktop), rebuild the group. The Copy
  // button node is restored to the head first, so the page's own listener
  // survives every rebuild.
  let pollTimer = null;
  let polling = false;
  let lastState = null;

  function remountButtons(plugin, state) {
    const group = document.querySelector(".pi-group");
    const copy = document.querySelector("#detail-content [data-install-copy]");
    if (!copy) return;
    if (group && group.parentElement) {
      group.parentElement.insertBefore(copy, group);
      group.remove();
    }
    mounted = false;
    mountButtons(plugin, state);
  }

  async function syncOnce(plugin) {
    if (polling || document.hidden) return;
    polling = true;
    try {
      const state = await talkToHost({ type: "status", id: PLUGIN_ID }, HOST_STATUS_TIMEOUT_MS);
      if (!state || !state.ok || !lastState) return;
      if (state.installed !== lastState.installed || state.enabled !== lastState.enabled) {
        lastState = state;
        remountButtons(plugin, state);
      }
    } finally {
      polling = false;
    }
  }

  function startStateSync(plugin) {
    if (pollTimer) return;
    pollTimer = setInterval(() => syncOnce(plugin), POLL_MS);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) syncOnce(plugin);
    });
  }

  // Bar-icon watcher beacon: while this plugin page is the visible tab,
  // "watch" re-records the page with the local host every few seconds (the
  // bar icon lights up while that record is fresh); leaving the tab or
  // closing it sends "unwatch". Losing the unwatch (browser killed) is
  // safe: the record simply goes stale and the bar icon dims.
  const BEACON_REFRESH_MS = 5000;
  const BEACON_STALE_MS = 12000;
  let beaconTimer = null;
  let beaconActive = false;

  function sendBeacon(plugin, unwatch) {
    const message = unwatch
      ? { type: "unwatch", id: plugin.id }
      : { type: "watch", id: plugin.id, repo: plugin.repo, name: plugin.name };
    talkToHost(message, HOST_STATUS_TIMEOUT_MS);
  }

  function setBeacon(plugin, active) {
    if (active === beaconActive) return;
    beaconActive = active;
    sendBeacon(plugin, !active);
  }

  function startBeacon(plugin) {
    if (beaconTimer) return;
    setBeacon(plugin, !document.hidden);
    beaconTimer = setInterval(() => setBeacon(plugin, !document.hidden), BEACON_REFRESH_MS);
    document.addEventListener("visibilitychange", () => setBeacon(plugin, !document.hidden));
    window.addEventListener("pagehide", () => setBeacon(plugin, false));
  }

  async function init() {
    if (!PLUGIN_ID) return;
    injectStyles();
    // Ping first: buttons only ever exist on machines that can act on them.
    hostAvailable = await pingHost();
    if (!hostAvailable) return;

    let plugin = null;
    try {
      const catalog = await loadCatalog();
      plugin = (catalog.plugins || []).find((item) => item && item.id === PLUGIN_ID);
    } catch (_e) {
      return;
    }
    if (!installable(plugin)) return;

    const state = await talkToHost({ type: "status", id: PLUGIN_ID }, HOST_STATUS_TIMEOUT_MS);
    if (!state || !state.ok || state.firstParty) return;

    // The detail section renders async after the page's own catalog fetch.
    mountButtons(plugin, state);
    if (mounted) { startStateSync(plugin); startBeacon(plugin); }
    const target = document.querySelector("#detail-content");
    if (!target || mounted) return;
    const observer = new MutationObserver(() => {
      if (document.querySelector("#detail-content [data-install-copy]")) {
        mountButtons(plugin, state);
        if (mounted) { startStateSync(plugin); startBeacon(plugin); }
        observer.disconnect();
      }
    });
    observer.observe(target, { childList: true, subtree: true });
  }

  init();
})();
