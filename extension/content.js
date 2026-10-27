// Omarchy Plugin Installer - content script.
// Adds action buttons to plugin detail pages, driven entirely by live local
// state reported by the native messaging host (never by the page):
//   not installed            -> "Install with Omarchy"
//   installed, enabled       -> "Disable" + "Uninstall from Omarchy"
//   installed, not enabled   -> "Enable" + "Uninstall from Omarchy"
// Gated on:
//   1. the marketplace's own availability rule for this plugin (catalog.json),
//   2. a live ping to the local native messaging host.
// No host => no buttons; the site renders untouched.

(() => {
  "use strict";

  const api = typeof browser !== "undefined" ? browser : chrome;
  const PLUGIN_ID = new URLSearchParams(window.location.search).get("id");
  const HOST_PING_TIMEOUT_MS = 2500;

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
  gap: 5px;
  margin-left: 5px;
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
  text-transform: uppercase;
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
.pi-button.pi-button-danger {
  color: var(--accent, #ffcead) !important;
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
  z-index: 6;
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
.pi-button:focus-visible .pi-tooltip {
  opacity: 1;
  visibility: visible;
  pointer-events: auto;
}
`;

  function injectStyles() {
    if (document.getElementById("pi-styles")) return;
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
    console.debug("[plugin-installer] ping response:", JSON.stringify(response));
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

  // One request per button: send the action and let the wizard on the
  // desktop be the feedback; run the optional after-action update (the
  // Enable/Disable toggle relabels itself).
  function wireAction(button, plugin, type, afterOpen) {
    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      button.disabled = true;
      const response = await talkToHost({
        type: typeof type === "function" ? type() : type,
        id: plugin.id,
        repo: plugin.repo,
        name: plugin.name,
      });
      if (response.ok && afterOpen) {
        // Toggle buttons stay usable: the host re-checks live state on every
        // click, so a cancelled wizard can simply be reopened.
        afterOpen();
      }
      // Keep toggle buttons enabled after a successful summon (the wizard may
      // be cancelled); one-shot buttons stay spent.
      button.disabled = !(response.ok && afterOpen);
      busy = false;
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

    const confirmTip = "on this machine \u2014 the Omarchy wizard will ask you to confirm";
    const buttons = [];
    if (!state.installed) {
      const install = makeButton("Install with Omarchy", "Install this plugin " + confirmTip, "", "pi-icon-install");
      wireAction(install, plugin, "install");
      buttons.push(install);
    } else {
      // Toggle flips its own label, icon and tooltip between Enable/Disable
      // after the wizard was opened; the authoritative state is re-checked
      // live by the host.
      let enabled = Boolean(state.enabled);
      const toggle = makeButton("", "", "", "pi-icon-disable");
      const applyToggle = () => {
        const verb = enabled ? "Disable" : "Enable";
        const tip = verb + " this plugin " + confirmTip;
        toggle.querySelector("[data-label]").textContent = verb;
        toggle.querySelector(".pi-icon").className =
          "pi-icon " + (enabled ? "pi-icon-disable" : "pi-icon-enable");
        toggle.setAttribute("aria-label", tip);
        toggle.querySelector(".pi-tooltip").textContent = tip;
      };
      applyToggle();
      wireAction(toggle, plugin, () => (enabled ? "disable" : "enable"), () => {
        enabled = !enabled;
        applyToggle();
      });
      const uninstall = makeButton("Uninstall", "Uninstall this plugin " + confirmTip, "pi-button-danger", "pi-icon-uninstall");
      wireAction(uninstall, plugin, "uninstall");
      buttons.push(toggle, uninstall);
    }

    head.insertBefore(group, copy);
    group.append(...buttons, copy);
    mounted = true;
  }

  async function init() {
    if (!PLUGIN_ID) return;
    injectStyles();
    // Ping first: buttons only ever exist on machines that can act on them.
    hostAvailable = await pingHost();
    console.debug("[plugin-installer] ping:", hostAvailable);
    if (!hostAvailable) return;

    let plugin = null;
    try {
      const catalog = await loadCatalog();
      plugin = (catalog.plugins || []).find((item) => item && item.id === PLUGIN_ID);
    } catch (e) {
      console.debug("[plugin-installer] catalog load failed:", e);
      return;
    }
    if (!installable(plugin)) {
      console.debug("[plugin-installer] not installable per catalog:", Boolean(plugin));
      return;
    }

    const state = await talkToHost({ type: "status", id: PLUGIN_ID });
    console.debug("[plugin-installer] status:", state);

    // The detail section renders async after the page's own catalog fetch.
    mountButtons(plugin, state);
    const target = document.querySelector("#detail-content");
    if (!target || mounted) return;
    const observer = new MutationObserver(() => {
      if (document.querySelector("#detail-content [data-install-copy]")) {
        mountButtons(plugin, state);
        observer.disconnect();
      }
    });
    observer.observe(target, { childList: true, subtree: true });
  }

  init();
})();
