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

  function makeButton(label, className) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = className;
    button.textContent = label;
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
    const panel = document.querySelector("#detail-content .command-panel");
    if (!panel || panel.querySelector(".pi-row")) return;

    const row = document.createElement("div");
    row.className = "pi-row";

    const status = document.createElement("span");
    status.className = "pi-status";
    status.dataset.state = "hidden";

    if (!state.installed) {
      const install = makeButton("Install with Omarchy", "pi-button");
      wireAction(install, plugin, "install", status);
      row.append(install, status);
    } else {
      // Toggle flips its own label between Enable/Disable after the wizard
      // was opened; the authoritative state is re-checked live by the host.
      let enabled = Boolean(state.enabled);
      const toggle = makeButton("", "pi-button pi-button-secondary");
      const applyToggle = () => {
        toggle.textContent = enabled ? "Disable" : "Enable";
      };
      applyToggle();
      wireAction(toggle, plugin, () => (enabled ? "disable" : "enable"), status, () => {
        enabled = !enabled;
        applyToggle();
      });
      const uninstall = makeButton("Uninstall from Omarchy", "pi-button pi-button-danger");
      wireAction(uninstall, plugin, "uninstall", status);
      row.append(toggle, uninstall, status);
    }

    panel.prepend(row);
    mounted = true;
  }

  async function init() {
    if (!PLUGIN_ID) return;
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
      if (document.querySelector("#detail-content .command-panel")) {
        mountButtons(plugin, state);
        observer.disconnect();
      }
    });
    observer.observe(target, { childList: true, subtree: true });
  }

  init();
})();
