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
  gap: 10px;
  margin-left: 10px;
}
.pi-button {
  display: inline-flex;
  min-height: 25px;
  padding: 0 8px !important;
  border: 1px solid var(--line-strong, #666666) !important;
  background: transparent !important;
  align-items: center;
  gap: 6px;
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
.pi-status {
  color: var(--muted, #aaaaaa);
  font-family: var(--mono, monospace);
  font-size: 11px;
  font-weight: 500;
  letter-spacing: 0.04em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 30vw;
}
.pi-status[data-state="hidden"] {
  display: none;
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

  // Icon + label markup mirroring the marketplace Copy button (its icon is
  // a 13px CSS line-art span); visuals come from .pi-button in content.css,
  // which mirrors the marketplace .copy-button rule.
  function makeButton(label, extraClass, iconClass) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button pi-button" + (extraClass ? " " + extraClass : "");
    const icon = document.createElement("span");
    icon.className = "pi-icon " + iconClass;
    icon.setAttribute("aria-hidden", "true");
    const labelEl = document.createElement("span");
    labelEl.dataset.label = "";
    labelEl.textContent = label;
    button.append(icon, labelEl);
    return button;
  }

  // One request per button: send the action, show the result, and run the
  // optional after-action update (the Enable/Disable toggle relabels itself).
  function wireAction(button, plugin, type, status, afterOpen) {
    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      button.disabled = true;
      setStatus(status, "Requesting installer\u2026");
      const response = await talkToHost({
        type: typeof type === "function" ? type() : type,
        id: plugin.id,
        repo: plugin.repo,
        name: plugin.name,
      });
      if (response.ok) {
        setStatus(status, "Opened in the installer \u2192 confirm it on your desktop");
        if (afterOpen) {
          // Toggle buttons stay usable: the host re-checks live state on every
          // click, so a cancelled wizard can simply be reopened.
          afterOpen();
        } else {
          button.textContent = "Installer opened";
        }
      } else {
        setStatus(status, `Installer unavailable: ${response.reason || "unknown"}`);
      }
      // Keep toggle buttons enabled after a successful summon (the wizard may
      // be cancelled); one-shot buttons stay spent.
      button.disabled = !(response.ok && afterOpen);
      busy = false;
    });
  }

  function setStatus(status, text) {
    status.textContent = text;
    status.dataset.state = "show";
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

    const status = document.createElement("span");
    status.className = "pi-status";
    status.dataset.state = "hidden";

    const buttons = [];
    if (!state.installed) {
      const install = makeButton("Install with Omarchy", "", "pi-icon-install");
      wireAction(install, plugin, "install", status);
      buttons.push(install);
    } else {
      // Toggle flips its own label and icon between Enable/Disable after the
      // wizard was opened; the authoritative state is re-checked live by the
      // host.
      let enabled = Boolean(state.enabled);
      const toggle = makeButton("", "", "pi-icon-disable");
      const applyToggle = () => {
        toggle.querySelector("[data-label]").textContent = enabled ? "Disable" : "Enable";
        toggle.querySelector(".pi-icon").className =
          "pi-icon " + (enabled ? "pi-icon-disable" : "pi-icon-enable");
      };
      applyToggle();
      wireAction(toggle, plugin, () => (enabled ? "disable" : "enable"), status, () => {
        enabled = !enabled;
        applyToggle();
      });
      const uninstall = makeButton("Uninstall", "pi-button-danger", "pi-icon-uninstall");
      wireAction(uninstall, plugin, "uninstall", status);
      buttons.push(toggle, uninstall);
    }

    head.insertBefore(group, copy);
    group.append(...buttons, status, copy);
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
