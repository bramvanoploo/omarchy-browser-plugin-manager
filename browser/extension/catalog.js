// Omarchy PlugBrug - catalog page (index.html) content script.
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

  // Host relay, marketplace installability mirror, catalog fetch, style
  // injector and the shared icon/ribbon line-art live in util.js, which the
  // manifest loads before this script (same isolated world).
  const { talkToHost, installable, loadCatalog, injectStyles } = window.PlugBrug;
  const POLL_MS = 3000;
  const SCAN_DEBOUNCE_MS = 300;
  const HOST_PING_TIMEOUT_MS = 2500;
  const HOST_STATUS_TIMEOUT_MS = 4000;
  const HOST_ACTION_TIMEOUT_MS = 12000;

  // Page geometry and tones only: the shared icon line-art and the corner
  // ribbon come from util.js (pi-styles). We only square the button
  // (icon-only) and color the icon/text with the plugin page tones
  // (icons draw with currentColor). The border stays the card's own
  // .card-install neutral line (--line, hover --muted), i.e. identical to
  // the "Copy install command" button beside it. Hover/focus tooltips
  // come free from the site's own .has-control-tooltip .control-tooltip CSS.
  const STYLES = `
.card-install.pi-card-button { width: 25px; height: 25px; min-height: 0; padding: 0; justify-content: center; }
/* Installed-state buttons carry their text (icon + verb); they replace the
 * page's copy-command button, so the width opens up from the icon square. */
.card-install.pi-card-button.pi-labelled { width: auto; display: inline-flex; align-items: center; gap: 6px; padding: 0 8px; }
.pi-card-label { font-size: 11px; letter-spacing: 0.02em; white-space: nowrap; text-transform: none; }
.card-install.pi-card-install { color: var(--stable, #b4c96f); }
.card-install.pi-card-install:hover { color: var(--stable, #b4c96f); background: var(--panel-2, rgba(127, 127, 127, 0.12)); }
.card-install.pi-card-uninstall { color: var(--accent, #ffcead); }
.card-install.pi-card-uninstall:hover { color: var(--accent, #ffcead); background: var(--panel-2, rgba(127, 127, 127, 0.12)); }
.card-install.pi-card-update { color: var(--accent, #ffcead); }
.card-install.pi-card-update:hover { color: var(--accent, #ffcead); background: var(--panel-2, rgba(127, 127, 127, 0.12)); }
.card-install.pi-card-button:disabled { opacity: 0.55; cursor: default; }
`;


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
    // Any failed refresh drops the batch snapshot: an old host without
    // status_all AND a transient host timeout both fall back to live
    // per-plugin status queries, so a hiccup never leaves cards decorated
    // from stale last-known state until the next poll lands.
    statuses = null;
    return false;
  }

  async function isInstalled(pluginId) {
    if (statuses) {
      const status = statuses.get(pluginId);
      return Boolean(status && status.installed);
    }
    if (!legacyStatuses.has(pluginId)) {
      const status = await talkToHost({ type: "status", id: pluginId }, HOST_STATUS_TIMEOUT_MS);
      legacyStatuses.set(pluginId, Boolean(status && status.ok && status.installed));
    }
    return legacyStatuses.get(pluginId);
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
    button.addEventListener("click", async (event) => {
      // Only real user clicks reach the host: the page's own scripts can
      // call button.click(), and a synthetic event must never trigger an
      // install/update on the user's behalf.
      if (!event.isTrusted) return;
      if (busy) return;
      busy = true;
      const type = button.dataset.piState;
      button.disabled = true;
      if (type === "install") registerSiteCopy(button);
      try {
        const response = await talkToHost({
          type,
          id: plugin.id,
          repo: plugin.repo,
          name: plugin.name || plugin.id,
        }, HOST_ACTION_TIMEOUT_MS);
        if (response && !response.ok) {
          const tip = button.querySelector(".control-tooltip");
          if (tip) {
            const orig = tip.textContent;
            tip.textContent = response.reason || "Action failed";
            setTimeout(() => { if (tip.isConnected) tip.textContent = orig; }, 5000);
          }
        }
      } finally {
        button.disabled = false;
        busy = false;
      }
    });
  }

  // ---- Update ribbon -----------------------------------------------------
  // Cards get a diagonal corner banner driven by live host state:
  //   installed + update available -> UPDATE banner (--accent)
  //   installed + up to date       -> INSTALLED banner (--stable)
  // updateAvailable comes from the host only when the plugin is behind
  // origin AND the "Update to unverified version" setting allows it (the
  // host hides unverified updates entirely when the setting is off).

  function cardFor(node) {
    return node.closest("li, .card, article, section, .command-panel, .panel")
      || node.parentElement;
  }

  // kind: "update" | "installed" | null. A kind change swaps the banner's
  // text and class in place; the position bookkeeping stays untouched.
  function setRibbon(card, kind) {
    if (!card) return;
    const existing = card.querySelector(":scope > .pi-ribbon");
    if (!kind) {
      if (existing) existing.remove();
      if (card.dataset.piRibbonPos) {
        card.style.position = "";
        delete card.dataset.piRibbonPos;
      }
      return;
    }
    const className = kind === "installed" ? "pi-ribbon pi-ribbon--stable" : "pi-ribbon";
    const text = kind === "installed" ? "INSTALLED" : "UPDATE";
    if (existing) {
      if (existing.className !== className) existing.className = className;
      const label = existing.firstElementChild;
      if (label && label.textContent !== text) label.textContent = text;
      return;
    }
    if (getComputedStyle(card).position === "static") {
      card.style.position = "relative";
      card.dataset.piRibbonPos = "1";
    }
    const ribbon = document.createElement("span");
    ribbon.className = className;
    ribbon.setAttribute("aria-hidden", "true");
    const banner = document.createElement("span");
    banner.textContent = text;
    ribbon.append(banner);
    card.append(ribbon);
  }

  // The card's live update state: installed + behind, gate already applied
  // by the host. Old hosts send no update fields: plain uninstall button.
  function updateStatusFor(pluginId) {
    const status = statuses && statuses.get(pluginId);
    return status && status.installed && status.updateAvailable ? status : null;
  }

  // Ribbon kind for a card the extension cannot operate (no mounted button):
  // an available update wins, otherwise an installed plugin (e.g. installed
  // on the desktop via CLI) shows the passive INSTALLED banner.
  async function passiveRibbonKind(plugin) {
    // For cards the extension cannot operate (no mounted button): "Manual",
    // "Preview only", built-in, unavailable.  No catalog entry (built-in
    // plugins) -> null.
    if (!plugin || plugin.builtIn) return null;
    if (updateStatusFor(plugin.id)) return "update";
    return (await isInstalled(plugin.id)) ? "installed" : null;
  }

  // The site renders non-installable cards with a text-only
  // span.card-install.unavailable ("Manual", "Preview only", "Unavailable").
  // When the host reports such a plugin installed, we replace that span with
  // a real Uninstall/Update button and stash the span on the card so an
  // uninstall can restore the page's original look.
  const passiveSpans = new WeakMap();

  function passiveSpanFor(card) {
    return card.querySelector("span.card-install.unavailable, span.card-install");
  }

  async function passiveCardControl(card, plugin) {
    // Built-in plugins get no ribbon and no control (marketplace rule).
    if (!plugin || plugin.builtIn) return;
    const update = updateStatusFor(plugin.id);
    const installed = update ? true : await isInstalled(plugin.id);
    setRibbon(card, update ? "update" : installed ? "installed" : null);
    if (!installed) return;
    const span = passiveSpanFor(card);
    if (!span) return;
    passiveSpans.set(card, span);
    span.replaceWith(makeCardButton(plugin, true, update));
  }

  function makeCardButton(plugin, installed, update) {
    const verb = update ? "Update" : installed ? "Uninstall" : "Install";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "card-install has-control-tooltip pi-card-button "
      + (update ? "pi-card-update" : installed ? "pi-card-uninstall" : "pi-card-install");
    button.dataset.piState = update ? "update" : installed ? "uninstall" : "install";
    button.dataset.pluginId = plugin.id;
    button.setAttribute("aria-label", `${verb} ${plugin.name || plugin.id}`);
    const icon = document.createElement("span");
    icon.className = "pi-icon "
      + (update ? "pi-icon-update" : installed ? "pi-icon-uninstall" : "pi-icon-install");
    icon.setAttribute("aria-hidden", "true");
    const tip = document.createElement("span");
    tip.className = "control-tooltip";
    tip.setAttribute("role", "tooltip");
    tip.setAttribute("aria-hidden", "true");
    tip.textContent = verb + " directly";
    button.append(icon);
    if (installed) {
      // Installed-state buttons carry their text label (the copy-command
      // button they replace is removed); the install state stays icon-only
      // next to the page's own copy button.
      const label = document.createElement("span");
      label.className = "pi-card-label";
      label.textContent = verb;
      button.classList.add("pi-labelled");
      button.append(label);
    }
    button.append(tip);
    // Every state (install / uninstall / update) acts through the host:
    // the desktop wizard panels are the only confirm and progress surface
    // (the update confirmation with version details lives there).
    wireCardAction(button, plugin);
    return button;
  }

  // Insert the icon-only action button left of every unprocessed copy
  // button, keeping the copy button and the page's own listener on it
  // (same layout idiom as the plugin pages). Buttons whose catalog entry
  // is not installable get no added button (the marketplace's own rule
  // wins, exactly like on the plugin pages) but do get the passive corner
  // banner when the host reports them installed (e.g. installed on the
  // desktop via the CLI).
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
        const pluginList = Array.isArray(catalog) ? catalog : (catalog && catalog.plugins) || [];
        pluginsById = new Map(
          pluginList.filter((p) => p && p.id).map((plugin) => [plugin.id, plugin])
        );
      }
      // Cards the extension cannot install (no copy button: "Manual", "Preview
      // only", built-in, unavailable).  Mark them so the polling refresh can
      // keep them in sync with the host state: a passive INSTALLED/UPDATE
      // ribbon, and when the plugin is installed the site's "Manual" span is
      // replaced by a real Uninstall/Update button (icon + text).
      for (const card of document.querySelectorAll("article[data-card-plugin]")) {
        if (card.querySelector("button.card-install[data-copy-command]")) continue;
        if (card.dataset.piPassiveRibbon === "1") continue;
        card.dataset.piPassiveRibbon = "1";
        card.dataset.piSeen = "1";
        const pluginId = card.dataset.cardPlugin;
        await passiveCardControl(card, pluginId ? pluginsById.get(pluginId) : null);
      }

      const targets = document.querySelectorAll(
        "button.card-install[data-copy-command]:not([data-pi-seen])"
      );
      for (const copy of targets) {
        copy.dataset.piSeen = "1";
        const plugin = pluginsById.get(copy.dataset.pluginId);
        if (!installable(plugin)) {
          // Not installable from the extension (built-in, no host install
          // command, failed upstream check, ...): no button, but the card
          // still gets the passive corner banner from live host state, so
          // CLI-installed plugins are recognizable at a glance.
          const card = cardFor(copy);
          card.dataset.piPassiveRibbon = "1";
          setRibbon(card, await passiveRibbonKind(pluginsById.get(copy.dataset.pluginId)));
          continue;
        }
        const update = updateStatusFor(plugin.id);
        const installed = update ? true : await isInstalled(plugin.id);
        if (!copy.parentElement) continue;
        const card = cardFor(copy);
        copy.parentElement.insertBefore(makeCardButton(plugin, installed, update), copy);
        // Installed: the labelled Uninstall/Update button replaces the
        // page's copy-install-command button. Resolve card before removing copy.
        if (installed) copy.remove();
        setRibbon(card, update ? "update" : installed ? "installed" : null);
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
  // plugin installed/uninstalled on the desktop), swap the button. Mirrors the
  // plugin pages' state sync at a catalog-friendly interval.
  async function syncRendered() {
    if (!statuses || !pluginsById) return;
    const buttons = document.querySelectorAll(
      'button.card-install[data-pi-state="install"], button.card-install[data-pi-state="uninstall"], button.card-install[data-pi-state="update"]'
    );
    for (const button of buttons) {
      const status = statuses.get(button.dataset.pluginId);
      const installed = Boolean(status && status.installed);
      const update = updateStatusFor(button.dataset.pluginId);
      const wanted = update ? "update" : installed ? "uninstall" : "install";
      setRibbon(cardFor(button), update ? "update" : installed ? "installed" : null);
      if (wanted === button.dataset.piState) continue;
      const plugin = pluginsById.get(button.dataset.pluginId);
      if (!plugin) continue;
      if (wanted === "install") {
        if (!installable(plugin)) {
          // A plugin the marketplace cannot install (we replaced its "Manual"
          // span) went back to not-installed: restore the page's own span.
          const card = cardFor(button);
          const span = card ? passiveSpans.get(card) : null;
          if (span) button.replaceWith(span);
          else button.remove();
          continue;
        }
        button.replaceWith(makeCardButton(plugin, false, null));
        continue;
      }
      // Installed states: the labelled button replaces the page's own
      // copy-command button (present when the card showed Install).
      const copy = button.nextElementSibling;
      if (copy && copy.matches("button[data-copy-command]")) copy.remove();
      button.replaceWith(makeCardButton(plugin, installed, update));
    }
    // Passive (non-installable) cards: keep banner and "Manual"-span
    // replacement in sync from the same batch snapshot the buttons just
    // got (statuses is non-null here, so no network round-trips).
    for (const card of document.querySelectorAll("[data-pi-passive-ribbon]")) {
      const pluginId = card.dataset.cardPlugin;
      await passiveCardControl(card, pluginId ? pluginsById.get(pluginId) : null);
    }
  }

  let syncing = false;
  async function syncOnce() {
    if (syncing || document.hidden) return;
    syncing = true;
    try {
      if (await refreshStatuses()) await syncRendered();
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
    injectStyles("pi-catalog-styles", STYLES);
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
