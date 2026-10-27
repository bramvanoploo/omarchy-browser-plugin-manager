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
    if (document.getElementById("pi-catalog-styles")) return;
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

  function talkToHost(message) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (value) => {
        if (!settled) {
          settled = true;
          resolve(value);
        }
      };
      setTimeout(() => done({ ok: false, reason: "host-timeout" }), 12000);
      try {
        api.runtime.sendMessage(message, (response) => {
          done(response || { ok: false, reason: "no-response" });
        });
      } catch (e) {
        done({ ok: false, reason: "extension-error" });
      }
    });
  }

  async function pingHost() {
    const response = await talkToHost({ type: "ping" });
    console.debug("[plugin-installer] catalog ping response:", JSON.stringify(response));
    return Boolean(response && response.ok);
  }

  // id -> {installed, enabled} from the host's batch report. null = the
  // host has no status_all (old host): fall back to per-plugin status.
  let statuses = null;
  // Legacy per-plugin cache, id -> installed boolean.
  const legacyStatuses = new Map();

  async function refreshStatuses() {
    const response = await talkToHost({ type: "status_all" });
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
      const status = await talkToHost({ type: "status", id: plugin.id });
      legacyStatuses.set(plugin.id, Boolean(status && status.ok && status.installed));
    }
    return legacyStatuses.get(plugin.id);
  }

  // One request per button: send the action and let the wizard on the
  // desktop be the feedback. Mirrors content.js wireAction: a successful
  // summon spends the button (the wizard may be cancelled; the state-sync
  // poll swaps the button as soon as the live state changes), a failed
  // summon leaves it usable.
  function wireCardAction(button, plugin) {
    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      const type = button.dataset.piState;
      button.disabled = true;
      const response = await talkToHost({
        type,
        id: plugin.id,
        repo: plugin.repo,
        name: plugin.name,
      });
      button.disabled = !(response && response.ok);
      busy = false;
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

  async function scan() {
    if (scanning) return;
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
        copy.parentElement.insertBefore(makeCardButton(plugin, await isInstalled(plugin)), copy);
      }
    } catch (e) {
      console.debug("[plugin-installer] catalog scan failed:", e);
      pluginsById = null;
    } finally {
      scanning = false;
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
    if (!statuses) return;
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

  function startStateSync() {
    setInterval(async () => {
      if (document.hidden) return;
      if (await refreshStatuses()) syncRendered();
    }, POLL_MS);
  }

  async function init() {
    // Buttons only ever exist on machines that can act on them.
    if (!(await pingHost())) {
      console.debug("[plugin-installer] catalog: no host, page untouched");
      return;
    }
    injectStyles();
    if (!(await refreshStatuses())) {
      console.debug("[plugin-installer] catalog: host without status_all, per-plugin status fallback");
    }
    await scan();
    const observer = new MutationObserver(scheduleScan);
    observer.observe(document.body, { childList: true, subtree: true });
    startStateSync();
  }

  init();
})();
