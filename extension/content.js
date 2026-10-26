// Omarchy Plugin Installer - content script.
// Adds an "Install with Omarchy" button to plugin detail pages, gated on:
//   1. the marketplace's own availability rule for this plugin (catalog.json),
//   2. a live ping to the local native messaging host.
// No host => no button; the site renders untouched.

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

  function pingHost() {
    return new Promise((resolve) => {
      let settled = false;
      const done = (value) => {
        if (!settled) {
          settled = true;
          resolve(value);
        }
      };
      setTimeout(() => done(false), HOST_PING_TIMEOUT_MS);
      try {
        api.runtime.sendMessage({ type: "ping" }, (response) => {
          done(Boolean(response && response.ok));
        });
      } catch (e) {
        done(false);
      }
    });
  }

  function sendInstall(plugin) {
    return new Promise((resolve) => {
      try {
        api.runtime.sendMessage(
          {
            type: "install",
            id: plugin.id,
            repo: plugin.repo,
            name: plugin.name,
          },
          (response) => resolve(response || { ok: false, reason: "no-response" })
        );
      } catch (e) {
        resolve({ ok: false, reason: "extension-error" });
      }
    });
  }

  function setStatus(status, text) {
    status.textContent = text;
    status.dataset.state = "show";
  }

  function mountButton(plugin) {
    const panel = document.querySelector("#detail-content .command-panel");
    if (!panel || panel.querySelector(".pi-row")) return;

    const row = document.createElement("div");
    row.className = "pi-row";

    const button = document.createElement("button");
    button.type = "button";
    button.className = "pi-button";
    button.textContent = "Install with Omarchy";

    const status = document.createElement("span");
    status.className = "pi-status";
    status.dataset.state = "hidden";

    let busy = false;
    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      button.disabled = true;
      setStatus(status, "Requesting installer\u2026");
      const response = await sendInstall(plugin);
      if (response.ok) {
        setStatus(status, "Installer opened \u2192 confirm it in the overlay");
        button.textContent = "Installer opened";
      } else {
        setStatus(status, `Installer unavailable: ${response.reason || "unknown"}`);
        button.disabled = false;
        busy = false;
      }
    });

    row.append(button, status);
    panel.prepend(row);
    mounted = true;
  }

  async function init() {
    if (!PLUGIN_ID) return;
    // Ping first: the button only ever exists on machines that can act on it.
    hostAvailable = await pingHost();
    if (!hostAvailable) return;

    let plugin = null;
    try {
      const catalog = await loadCatalog();
      plugin = (catalog.plugins || []).find((item) => item && item.id === PLUGIN_ID);
    } catch (e) {
      return;
    }
    if (!installable(plugin)) return;

    // The detail section renders async after the page's own catalog fetch.
    mountButton(plugin);
    const target = document.querySelector("#detail-content");
    if (!target || mounted) return;
    const observer = new MutationObserver(() => {
      if (document.querySelector("#detail-content .command-panel")) {
        mountButton(plugin);
        observer.disconnect();
      }
    });
    observer.observe(target, { childList: true, subtree: true });
  }

  init();
})();
