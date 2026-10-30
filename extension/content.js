// Omarchy Browser Plugin Manager - content script.
// Adds action buttons to plugin detail pages, driven entirely by live local
// state reported by the native messaging host (never by the page):
//   not installed            -> "Install"
//   installed, enabled       -> "Disable" + "Uninstall"
//   installed, not enabled   -> "Enable" + "Uninstall"
// Installable plugins anchor these to the command panel's Copy button; a
// manual-setup (non-installable) plugin that is installed on this machine
// gets the same installed-state buttons at the right end of its tag row
// under the preview (the host validates every action against local state).
// Gated on:
//   1. the marketplace's own availability rule for this plugin (catalog.json),
//   2. a live ping to the local native messaging host.
// No host => no buttons; the site renders untouched.
// While the page is the visible tab of a focused browser window it also runs
// the bar-icon watcher beacon: a "watch" record with the host (renewed every
// 5s, "unwatch" when the tab hides or the page closes; losing window focus
// marks the record "paused" so the bar dims promptly and focus relights it)
// that lights the
// Omarchy bar widget for this plugin.

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
  // Which flavor of detail page this is: true = manual-setup page (the
  // group anchors to the tag row, buttons only while installed), false =
  // installable page (the group anchors to the Copy button).
  let passiveMount = false;

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
/* Manual-setup pages: the group sits in the plugin tag row (a flex row of
   tag chips) under the preview; margin-left:auto pushes it to the right
   edge, align-self:center keeps it level with the chips (min-height 28px). */
.plugin-tags > .pi-group {
  margin-left: auto;
  align-self: center;
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
/* Update: clockwise circular arrow (open ring + chevron head at the gap),
 * same 13px currentColor line-art idiom as the other icons. */
.pi-icon-update::before {
  inset: 1px;
  border: 1px solid currentColor;
  border-radius: 50%;
  border-bottom-color: transparent;
}
.pi-icon-update::after {
  right: 1px;
  bottom: 2px;
  width: 5px;
  height: 5px;
  border-bottom: 1px solid currentColor;
  border-right: 1px solid currentColor;
  transform: rotate(-45deg);
}
/* Diagonal UPDATE/INSTALLED ribbon in the card's top-right corner. The corner
 * box clips the rotated banner; overflow stays local to the box so the site's
 * own tooltips (which overflow the card) are never cut off. */
.pi-ribbon {
  position: absolute;
  top: 0;
  right: 0;
  width: 96px;
  height: 96px;
  overflow: hidden;
  pointer-events: none;
  z-index: 6;
}
.pi-ribbon > span {
  position: absolute;
  /* The 96x96 corner box clips the banner along its diagonal, so the visible
   * band center lies on the axis cx + cy = 96. Span center: cx = 96 + 36.5 -
   * 64 = 68.5, cy = 18.5 + 9 = 27.5 (width 128, line-height 1.8, font 10px).
   * 68.5 + 27.5 = 96 centers the ink in the clipped band, font-independent. */
  top: 18.5px;
  right: -36.5px;
  width: 128px;
  transform: rotate(45deg);
  background: var(--accent, #ffcead);
  color: #17120d;
  font-family: var(--mono, monospace);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.14em;
  line-height: 1.8;
  text-align: center;
  box-shadow: 0 4px 14px rgb(0 0 0 / 30%);
}
.pi-ribbon--stable > span {
  background: var(--stable, #b4c96f);
}
/* Update info panel: the desktop wizard shows no version details, so the
 * extension owns the dialog. Page CSS tokens, square corners, mono type:
 * it reads like the marketplace's own panels. */
.pi-panel-backdrop {
  position: fixed;
  inset: 0;
  z-index: 9000;
  background: rgb(0 0 0 / 55%);
}
.pi-panel {
  position: fixed;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  z-index: 9001;
  width: min(430px, calc(100vw - 48px));
  box-sizing: border-box;
  padding: 18px;
  border: 1px solid var(--line-strong, #666666);
  border-radius: 0;
  background: var(--panel, #1b1b21);
  color: var(--text, #dddddd);
  font-family: var(--mono, monospace);
  box-shadow: 0 18px 48px rgb(0 0 0 / 45%);
}
.pi-panel h2 {
  margin: 0 0 10px;
  font-size: 14px;
  font-weight: 700;
  letter-spacing: 0.04em;
  color: var(--text, #dddddd);
}
.pi-panel-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  font-size: 12px;
}
.pi-panel-badge {
  padding: 1px 6px;
  border: 1px solid currentColor;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.08em;
}
.pi-panel-badge-verified {
  color: var(--stable, #b4c96f);
}
.pi-panel-badge-unverified {
  color: var(--accent, #ffcead);
}
.pi-panel-desc {
  margin: 12px 0 0;
  font-family: var(--sans, sans-serif);
  font-size: 12px;
  line-height: 1.5;
  color: var(--muted, #999999);
}
.pi-panel-foot {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  margin-top: 16px;
}
.pi-panel-note {
  margin: 12px 0 0;
  font-size: 11px;
  line-height: 1.4;
  color: var(--stable, #b4c96f);
}
.pi-panel-note[data-error="1"] {
  color: var(--accent, #ffcead);
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

  // ---- Update ribbon + info panel ---------------------------------------
  // An updatable card gets a diagonal UPDATE banner in its top-right corner
  // (only when the host reports updateAvailable, i.e. the plugin is behind
  // origin AND the "Update to unverified version" setting allows it: the
  // host hides unverified updates entirely when the setting is off, so the
  // extension never sees them). Clicking Update opens the info panel; its
  // Update button summons the desktop wizard in update mode via the host.

  // Diagonal corner banner: kind is "update" (behind origin), "installed"
  // (installed, up to date), or null to remove.  Kind changes swap the banner
  // in place (same corner box, different color and text).
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
    const text = kind === "update" ? "UPDATE" : "INSTALLED";
    if (existing) {
      if (existing.className === className) return;
      existing.className = className;
      existing.firstChild.textContent = text;
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

  // The detail page's ribbon host: the big preview image (top-right corner,
  // where the site shows "Expand image"), falling back to the Copy button.
  function detailRibbonTarget() {
    return document.querySelector("#detail-content .detail-preview")
      || document.querySelector("#detail-content [data-install-copy]");
  }

  // Size gate: the corner box is 96x96, so a preview smaller than that gets
  // no ribbon.  A ResizeObserver keeps the gate honest through responsive
  // relayout.
  const RIBBON_MIN_SIZE = 96;
  let ribbonTarget = null;
  let ribbonKind = null;
  let ribbonResizeObserver = null;

  function applyRibbonSize() {
    if (!ribbonTarget) return;
    const fits = ribbonTarget.offsetWidth >= RIBBON_MIN_SIZE
      && ribbonTarget.offsetHeight >= RIBBON_MIN_SIZE;
    setRibbon(ribbonTarget, fits ? ribbonKind : null);
  }

  function mountDetailRibbon(target, kind) {
    if (ribbonTarget && ribbonTarget !== target) setRibbon(ribbonTarget, null);
    ribbonTarget = target || null;
    ribbonKind = kind || null;
    if (ribbonResizeObserver) {
      ribbonResizeObserver.disconnect();
      ribbonResizeObserver = null;
    }
    if (!ribbonTarget) return;
    applyRibbonSize();
    if (typeof ResizeObserver === "function") {
      ribbonResizeObserver = new ResizeObserver(() => applyRibbonSize());
      ribbonResizeObserver.observe(ribbonTarget);
    }
  }

  let panelNodes = null;
  let panelKeydown = null;

  function closePanel() {
    if (!panelNodes) return;
    panelNodes.backdrop.remove();
    panelNodes.panel.remove();
    if (panelKeydown) document.removeEventListener("keydown", panelKeydown);
    panelKeydown = null;
    panelNodes = null;
  }

  function openUpdatePanel(plugin, status) {
    closePanel();
    const backdrop = document.createElement("div");
    backdrop.className = "pi-panel-backdrop";
    const panel = document.createElement("div");
    panel.className = "pi-panel";
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-modal", "true");
    panel.setAttribute("aria-label", `Update ${plugin.name}`);

    const title = document.createElement("h2");
    title.textContent = plugin.name;

    const row = document.createElement("div");
    row.className = "pi-panel-row";
    const versions = document.createElement("span");
    versions.textContent = `Installed v${status.installedVersion || "?"} → Update to v${status.latestVersion || "?"}`;
    const badge = document.createElement("span");
    badge.className = "pi-panel-badge "
      + (status.verified ? "pi-panel-badge-verified" : "pi-panel-badge-unverified");
    badge.textContent = status.verified ? "verified" : "unverified";
    row.append(versions, badge);

    panel.append(title, row);
    if (plugin.description) {
      const desc = document.createElement("p");
      desc.className = "pi-panel-desc";
      desc.textContent = plugin.description;
      panel.append(desc);
    }

    const foot = document.createElement("div");
    foot.className = "pi-panel-foot";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "pi-button";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", closePanel);
    const update = document.createElement("button");
    update.type = "button";
    update.className = "pi-button pi-button-danger";
    update.textContent = "Update";
    foot.append(cancel, update);

    const note = document.createElement("p");
    note.className = "pi-panel-note";
    note.hidden = true;

    panel.append(foot, note);
    document.body.append(backdrop, panel);

    const dismiss = (event) => {
      if (event.key === "Escape") closePanel();
    };
    document.addEventListener("keydown", dismiss);
    panelKeydown = dismiss;
    backdrop.addEventListener("click", closePanel);

    update.addEventListener("click", async () => {
      update.disabled = true;
      cancel.disabled = true;
      const response = await talkToHost({
        type: "update",
        id: plugin.id,
        repo: plugin.repo,
        name: plugin.name,
      }, HOST_ACTION_TIMEOUT_MS);
      note.hidden = false;
      if (response && response.ok) {
        foot.remove();
        note.textContent = "Confirm the update in the Omarchy window.";
        setTimeout(closePanel, 4000);
      } else {
        update.disabled = false;
        cancel.disabled = false;
        note.dataset.error = "1";
        note.textContent = `Could not start the update (${(response && response.reason) || "no-response"}).`;
      }
    });
    update.focus();
  }

  function wireUpdateButton(button, plugin, status) {
    button.addEventListener("click", () => openUpdatePanel(plugin, status));
  }

  // The installed-state buttons, shared by the installable page (anchored
  // beside the Copy button) and the manual-setup page (anchored in the tag
  // row). Label, icon and tone come from the live state; the state-sync poll
  // (1s) rebuilds the buttons when the host's answer changes, so the
  // wizard, the desktop, and the page can never drift apart.
  function installedButtons(plugin, state) {
    const buttons = [];
    const enabled = Boolean(state.enabled);
    const verb = enabled ? "Disable" : "Enable";
    const tip = verb + " this plugin";
    const toggle = makeButton(
      verb, tip,
      enabled ? "pi-button-danger" : "pi-button-install",
      enabled ? "pi-icon-disable" : "pi-icon-enable"
    );
    wireAction(toggle, plugin, () => (enabled ? "disable" : "enable"));
    buttons.push(toggle);
    if (state.updateAvailable) {
      // Updatable (and allowed by the verification setting, see the host):
      // Update replaces Uninstall and opens the info panel first.
      const update = makeButton("Update", "Update this plugin", "pi-button-danger", "pi-icon-update");
      wireUpdateButton(update, plugin, state);
      buttons.push(update);
    } else {
      const uninstall = makeButton("Uninstall", "Uninstall this plugin", "pi-button-danger", "pi-icon-uninstall");
      wireAction(uninstall, plugin, "uninstall");
      buttons.push(uninstall);
    }
    return buttons;
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
      buttons.push(...installedButtons(plugin, state));
    }

    head.insertBefore(group, copy);
    group.append(...buttons, copy);
    mountDetailRibbon(detailRibbonTarget(),
      state.installed && state.updateAvailable ? "update" : state.installed ? "installed" : null);
    mounted = true;
    lastState = state;
  }

  // Manual-setup (non-installable) pages: the same installed-state buttons,
  // appended to the plugin tag row under the preview (the injected CSS
  // right-aligns the group). Only mounted while the plugin is installed:
  // these pages carry no install path, so there is nothing to offer before
  // the wizard/desktop has installed it.
  function mountPassiveButtons(plugin, state) {
    const tags = document.querySelector(
      "#detail-content .plugin-detail-article > .plugin-tags");
    if (!tags || !state.installed) return;
    const group = document.createElement("span");
    group.className = "pi-group";
    group.append(...installedButtons(plugin, state));
    tags.appendChild(group);
    mountDetailRibbon(detailRibbonTarget(), state.updateAvailable ? "update" : "installed");
    mounted = true;
    passiveMount = true;
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
    if (passiveMount) {
      // Manual page: the group lives in the tag row (no Copy button to
      // restore). Rebuild it while installed; drop the group, the ribbon,
      // and the beacon on the uninstall transition. The poll keeps running
      // (it is what noticed), so a reinstall remounts everything.
      const group = document.querySelector(
        "#detail-content .plugin-detail-article > .plugin-tags > .pi-group");
      if (group) group.remove();
      setRibbon(detailRibbonTarget(), null);
      mounted = false;
      if (state.installed) {
        mountPassiveButtons(plugin, state);
        startBeacon(plugin);
      } else {
        stopBeacon(plugin);
      }
      return;
    }
    const group = document.querySelector(".pi-group");
    const copy = document.querySelector("#detail-content [data-install-copy]");
    if (!copy) return;
    if (group && group.parentElement) {
      group.parentElement.insertBefore(copy, group);
      group.remove();
    }
    setRibbon(detailRibbonTarget(), null);
    mounted = false;
    mountButtons(plugin, state);
  }

  async function syncOnce(plugin) {
    if (polling || document.hidden) return;
    polling = true;
    try {
      const state = await talkToHost({ type: "status", id: PLUGIN_ID }, HOST_STATUS_TIMEOUT_MS);
      if (!state || !state.ok || !lastState) return;
      if (state.installed !== lastState.installed
        || state.enabled !== lastState.enabled
        || state.updateAvailable !== lastState.updateAvailable) {
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

  // Bar-icon watcher beacon: the plugin page is watched only while it is
  // the user's visible tab in a focused browser window — the bar widget
  // shows the plugin while the record is live: fresh (≤12s) and not
  // paused. "watch" re-records the page with the local host every few
  // seconds. The tab going hidden or the page unloading sends "unwatch"
  // (id-scoped) right away, so tab switches follow instantly. Losing OS
  // window focus marks the record "paused" (id-scoped on the host): the
  // widget drops it on its next poll (≤2s), so an app switch clears the
  // bar content almost immediately. No "unwatch" on blur, because Firefox
  // fires focus/blur per window on every tab switch and the quickshell
  // bar's own popup steals focus — a blur-unwatch deleted the live record
  // under an active tab; the pause is recoverable, the next focus sends a
  // live "watch" and the icon lights again.
  const BEACON_REFRESH_MS = 5000;
  const BEACON_STALE_MS = 12000;
  let beaconTimer = null;
  let beaconActive = false;
  let beaconHandlers = null;
  // Window activation: blur/focus fire when the browser window gains or
  // loses OS focus to another application.
  let windowFocused = document.hasFocus();

  function beaconShouldBeActive() {
    return !document.hidden && windowFocused;
  }

  function sendBeacon(plugin, unwatch, paused) {
    const message = unwatch
      ? { type: "unwatch", id: plugin.id }
      : { type: "watch", id: plugin.id, repo: plugin.repo, name: plugin.name };
    if (!unwatch && paused) message.paused = true;
    talkToHost(message, HOST_STATUS_TIMEOUT_MS);
  }

  function setBeacon(plugin, active) {
    if (active === beaconActive) return;
    const wasActive = beaconActive;
    beaconActive = active;
    // Activation sends a live "watch". Deactivation (window blur) marks the
    // record paused instead of staying silent: the bar widget drops the
    // paused record on its next poll (<=2s), so switching to another
    // application clears the panel content almost immediately instead of
    // waiting out the 12s staleness. The record itself survives: the bar
    // popup's focus steal (Firefox fires blur on tab switches too) is
    // recovered by the next focus, which sends a live "watch" again.
    if (active) sendBeacon(plugin, false, false);
    else if (wasActive) sendBeacon(plugin, false, true);
  }

  function startBeacon(plugin) {
    if (beaconTimer) return;
    const refresh = () => setBeacon(plugin, beaconShouldBeActive());
    const leave = () => {
      // Explicit tab/page departure: drop the record now (id-scoped, so a
      // late arrival can never wipe a newer tab's record) so switching
      // away from the plugin tab dims the icon immediately.
      beaconActive = false;
      sendBeacon(plugin, true);
    };
    setBeacon(plugin, beaconShouldBeActive());
    // setBeacon only sends on transitions; the bar widget treats a record
    // older than 12s as gone, so an active beacon must re-send "watch" on
    // every tick, not only when focus/visibility flip.
    beaconTimer = setInterval(() => {
      if (beaconActive) sendBeacon(plugin, false, false);
      else setBeacon(plugin, beaconShouldBeActive());
    }, BEACON_REFRESH_MS);
    const onVisibility = () => {
      if (document.hidden) leave();
      else refresh();
    };
    const onFocus = () => { windowFocused = true; refresh(); };
    const onBlur = () => { windowFocused = false; refresh(); };
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("focus", onFocus);
    window.addEventListener("blur", onBlur);
    window.addEventListener("pageshow", refresh);
    window.addEventListener("pagehide", leave);
    // Keep the listener references: a passive page whose plugin gets
    // uninstalled stops the beacon (stopBeacon), and listeners the
    // closures left behind would revive it on the next focus or tab switch.
    beaconHandlers = {
      onVisibility, onFocus, onBlur, onPageshow: refresh, onPagehide: leave,
    };
  }

  // Full beacon teardown (used when a passive page's plugin transitions to
  // uninstalled): stop renewing, drop the live record, and remove the
  // listeners so nothing can restart the beacon while the plugin is gone.
  function stopBeacon(plugin) {
    if (beaconHandlers) {
      document.removeEventListener("visibilitychange", beaconHandlers.onVisibility);
      window.removeEventListener("focus", beaconHandlers.onFocus);
      window.removeEventListener("blur", beaconHandlers.onBlur);
      window.removeEventListener("pageshow", beaconHandlers.onPageshow);
      window.removeEventListener("pagehide", beaconHandlers.onPagehide);
      beaconHandlers = null;
    }
    if (beaconTimer) {
      clearInterval(beaconTimer);
      beaconTimer = null;
    }
    if (beaconActive) {
      beaconActive = false;
      sendBeacon(plugin, true);
    }
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
    if (!installable(plugin)) {
      // Not installable from the browser (no install command, built-in,
      // failed upstream check): a plugin installed on this machine is fully
      // manageable — the host validates enable/disable/update/uninstall
      // generically against local state for every installed plugin — so
      // mirror the live state here: the corner banner on the preview, the
      // installed-state action buttons in the tag row, and the bar-icon
      // beacon. Not installed: nothing to show, but keep polling so an
      // install from the wizard or the desktop mounts everything.
      const state = await talkToHost({ type: "status", id: PLUGIN_ID }, HOST_STATUS_TIMEOUT_MS);
      if (state && state.ok && !state.firstParty) {
        // Mark the page flavor and seed the sync baseline now, so the 1s
        // state poll is alive even before anything is mounted (an install
        // from the wizard or the desktop must mount the ribbon + buttons).
        passiveMount = true;
        lastState = state;
        if (state.installed) {
          startBeacon(plugin);
          // The detail section renders async: try the existing DOM first
          // (the page usually finished before this script's host ping
          // resolved), and only wait via observer until the preview and
          // the tag row are there.
          const tryMountPassive = () => {
            const preview = document.querySelector("#detail-content .detail-preview");
            const tags = document.querySelector(
              "#detail-content .plugin-detail-article > .plugin-tags");
            if (!preview || !tags) return false;
            mountPassiveButtons(plugin, state);
            return true;
          };
          if (!tryMountPassive()) {
            const detailHost = document.querySelector("#detail-content") || document.documentElement;
            const detailObserver = new MutationObserver(() => {
              if (tryMountPassive()) detailObserver.disconnect();
            });
            detailObserver.observe(detailHost, { childList: true, subtree: true });
          }
        }
        startStateSync(plugin);
      }
      return;
    }

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
