// Omarchy Browser Plugin Manager - catalog page (index.html) content script.
// Places ONE icon-only action button directly left of each card's
// "Copy install command" button (which keeps its own node and click
// behavior, exactly like on the plugin pages), driven entirely by live
// local state from the native messaging host (never by the page):
//   not installed -> install icon, --stable tone, tooltip "Install directly"
//   installed     -> uninstall icon, --accent tone, tooltip "Uninstall directly"
// Icons, tones, and click action are identical to the plugin page's
// buttons: the wizard is summoned with the catalog-validated id/repo/name.
// The no-action "Manual" spans and cards whose catalog entry fails the
// marketplace's own installability rule get no added button.
// Gated on: a live ping to the local native messaging host.
// No host => no buttons; the site renders untouched.

(() => {
  "use strict";

  const api = typeof browser !== "undefined" ? browser : chrome;
  const POLL_MS = 3000;
  const SCAN_DEBOUNCE_MS = 300;
  const HOST_PING_TIMEOUT_MS = 2500;
  const HOST_STATUS_TIMEOUT_MS = 4000;
  const HOST_ACTION_TIMEOUT_MS = 12000;

  // Icon line-art copied verbatim from content.js (plugin pages). Geometry
  // stays the site's own .card-install rule; we only square the button
  // (icon-only) and color the icon/text with the plugin page tones
  // (icons draw with currentColor). The border stays the card's own
  // .card-install neutral line (--line, hover --muted), i.e. identical to
  // the "Copy install command" button beside it. Hover/focus tooltips
  // come free from the site's own .has-control-tooltip .control-tooltip CSS.
  const STYLES = `
.pi-icon { position: relative; display: inline-block; width: 13px; height: 13px; flex: none; }
.pi-icon::before, .pi-icon::after { position: absolute; content: ""; }
.pi-icon-install::before { left: 6px; top: 0; width: 1px; height: 7px; background: currentColor; }
.pi-icon-install::after { left: 1px; right: 1px; bottom: 1px; height: 5px; border: 1px solid currentColor; border-top: 0; }
.pi-icon-uninstall::before, .pi-icon-uninstall::after { left: 2px; right: 2px; top: 6px; height: 1px; background: currentColor; }
.pi-icon-uninstall::before { transform: rotate(45deg); }
.pi-icon-uninstall::after { transform: rotate(-45deg); }
.card-install.pi-card-button { width: 25px; height: 25px; min-height: 0; padding: 0; justify-content: center; }
.card-install.pi-card-install { color: var(--stable, #b4c96f); }
.card-install.pi-card-install:hover { color: var(--stable, #b4c96f); background: var(--panel-2, rgba(127, 127, 127, 0.12)); }
.card-install.pi-card-uninstall { color: var(--accent, #ffcead); }
.card-install.pi-card-uninstall:hover { color: var(--accent, #ffcead); background: var(--panel-2, rgba(127, 127, 127, 0.12)); }
.card-install.pi-card-button:disabled { opacity: 0.55; cursor: default; }
`;

  function injectStyles() {
    if (document.getElementById("pi-catalog-styles") || !document.head) return;
    const style = document.createElement("style");
    style.id = "pi-catalog-styles";
    style.textContent = STYLES;
    document.head.append(style);
  }

  // Mirrors the marketplace's marketplaceInstallAvailable() in plugin.js
  // (same rule content.js uses on the plugin pages).
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

  // id -> {installed, enabled} from the host's batch report. null = the
  // host has no status_all (old host): fall back to per-plugin status.
  let statuses = null;
  // Legacy per-plugin cache, id -> installed boolean.
  const legacyStatuses = new Map();

  async function refreshStatuses() {
    const response = await talkToHost({ type: "status_all" }, HOST_STATUS_TIMEOUT_MS);
    if (response && response.ok && Array.isArray(response.plugins)) {
      statuses = new Map(response.plugins.map((p) => [p.id, p]));
      return true;
    }
    statuses = null;
    return false;
  }

  async function isInstalled(plugin) {
    if (statuses) {
      const status = statuses.get(plugin.id);
      return Boolean(status && status.installed);
    }
    if (!legacyStatuses.has(plugin.id)) {
      const status = await talkToHost({ type: "status", id: plugin.id }, HOST_STATUS_TIMEOUT_MS);
      legacyStatuses.set(plugin.id, Boolean(status && status.ok && status.installed));
    }
    return legacyStatuses.get(plugin.id);
  }

  // Send the action and let the wizard on the desktop be the feedback.
  // Re-enable the button once the summon finishes so a cancelled wizard can
  // be reopened without refreshing the page; when confirmed, the state-sync
  // poll swaps the button as soon as the live state changes.
  //
  // Install clicks also click the card's own copy button (our button is
  // inserted directly before it), so the page copies the command and
  // registers the "copies" engagement event. The synchronous dispatch inside
  // the user gesture keeps the activation the site's clipboard write needs.
  // The site dedupes copies per session.
  function registerSiteCopy(button) {
    const copy = button.nextElementSibling;
    if (copy && copy.matches("button[data-copy-command]")) copy.click();
  }

  function wireCardAction(button, plugin) {
    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      const type = button.dataset.piState;
      button.disabled = true;
      if (type === "install") registerSiteCopy(button);
      try {
        await talkToHost({
          type,
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

  function makeCardButton(plugin, installed) {
    const verb = installed ? "Uninstall" : "Install";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "card-install has-control-tooltip pi-card-button "
      + (installed ? "pi-card-uninstall" : "pi-card-install");
    button.dataset.piState = installed ? "uninstall" : "install";
    button.dataset.pluginId = plugin.id;
    button.setAttribute("aria-label", `${verb} ${plugin.name}`);
    const icon = document.createElement("span");
    icon.className = "pi-icon " + (installed ? "pi-icon-uninstall" : "pi-icon-install");
    icon.setAttribute("aria-hidden", "true");
    const tip = document.createElement("span");
    tip.className = "control-tooltip";
    tip.setAttribute("role", "tooltip");
    tip.setAttribute("aria-hidden", "true");
    tip.textContent = verb + " directly";
    button.append(icon, tip);
    wireCardAction(button, plugin);
    return button;
  }

  // Insert the icon-only action button left of every unprocessed copy
  // button, keeping the copy button and the page's own listener on it
  // (same layout idiom as the plugin pages). Buttons whose catalog entry
  // is not installable get no added button (the marketplace's own rule
  // wins, exactly like on the plugin pages).
  let pluginsById = null;
  let scanning = false;
  let scanPending = false;

  async function scan() {
    if (scanning) {
      scanPending = true;
      return;
    }
    scanning = true;
    try {
      if (!pluginsById) {
        const catalog = await loadCatalog();
        pluginsById = new Map(
          (catalog.plugins || []).filter(Boolean).map((plugin) => [plugin.id, plugin])
        );
      }
      const targets = document.querySelectorAll(
        "button.card-install[data-copy-command]:not([data-pi-seen])"
      );
      for (const copy of targets) {
        copy.dataset.piSeen = "1";
        const plugin = pluginsById.get(copy.dataset.pluginId);
        if (!installable(plugin)) continue;
        const installed = await isInstalled(plugin);
        if (!copy.parentElement) continue;
        copy.parentElement.insertBefore(makeCardButton(plugin, installed), copy);
      }
    } catch (_e) {
      pluginsById = null;
    } finally {
      scanning = false;
      if (scanPending) {
        scanPending = false;
        scheduleScan();
      }
    }
  }

  // Grid re-renders (pagination, search, filters, split view, gems) create
  // fresh copy buttons; the "show all" mode renders the whole registry.
  // Coalesce bursts (the Just-landed feed animates on a timer) into one
  // debounced scan.
  let scanTimer = null;
  function scheduleScan() {
    if (scanTimer) return;
    scanTimer = setTimeout(() => {
      scanTimer = null;
      scan();
    }, SCAN_DEBOUNCE_MS);
  }

  // Real-time sync: refresh the host's batch state on a poll. When a card's
  // live state diverges from its mounted button (wizard confirmed/cancelled,
  // plugin installed/removed on the desktop), swap the button. Mirrors the
  // plugin pages' state sync at a catalog-friendly interval.
  function syncRendered() {
    if (!statuses || !pluginsById) return;
    const buttons = document.querySelectorAll(
      'button.card-install[data-pi-state="install"], button.card-install[data-pi-state="uninstall"]'
    );
    for (const button of buttons) {
      const status = statuses.get(button.dataset.pluginId);
      const installed = Boolean(status && status.installed);
      const wanted = installed ? "uninstall" : "install";
      if (wanted === button.dataset.piState) continue;
      const plugin = pluginsById.get(button.dataset.pluginId);
      if (plugin) button.replaceWith(makeCardButton(plugin, installed));
    }
  }

  let syncing = false;
  async function syncOnce() {
    if (syncing || document.hidden) return;
    syncing = true;
    try {
      if (await refreshStatuses()) syncRendered();
    } finally {
      syncing = false;
    }
  }

  function startStateSync() {
    setInterval(syncOnce, POLL_MS);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) syncOnce();
    });
  }

  async function init() {
    // Buttons only ever exist on machines that can act on them.
    if (!(await pingHost())) return;
    injectStyles();
    await refreshStatuses();
    await scan();
    if (document.body) {
      const observer = new MutationObserver(scheduleScan);
      observer.observe(document.body, { childList: true, subtree: true });
    }
    startStateSync();
  }

  init();
})();
