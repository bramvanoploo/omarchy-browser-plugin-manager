// Omarchy PlugBrug - shared content-script helpers.
// content.js (plugin detail pages) and catalog.js (index cards) share one
// isolated world per page (the manifest lists util.js before each of them),
// so the host relay, the marketplace installability mirror, the catalog
// fetch and the icon/ribbon line-art CSS live here once instead of twice.
// background.js does NOT load this file: it runs in the worker world and
// has its own port-queue talkToHost.
//
// Styles are injected as a <style> node instead of the manifest's
// content_css pipeline: in Firefox the manifest CSS injection demonstrably
// does not reach the page, leaving buttons unstyled.

(() => {
  "use strict";

  const api = typeof browser !== "undefined" ? browser : chrome;
  const HOST_ACTION_TIMEOUT_MS = 12000;

  function injectStyles(id, css) {
    if (document.getElementById(id) || !document.head) return;
    const style = document.createElement("style");
    style.id = id;
    style.textContent = css;
    document.head.append(style);
  }

  // Icon line-art + corner ribbon, identical on both page kinds. Geometry
  // comes from each page's own button rules; these classes only draw.
  const ICON_CSS = `
.pi-icon {
  position: relative;
  display: inline-block;
  width: 13px;
  height: 13px;
  flex: none;
  /* Codicon "extensions" (U+EAE6) glyph path, copied verbatim from the
   * plugin logo (store/images/logo.svg); used as a mask (see below). */
  --pi-puzzle: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M15 4.95703C15 4.58711 14.8563 4.24054 14.5949 3.97992L12.0096 1.39234C11.4879 0.86922 10.5788 0.86922 10.0571 1.39234L8 3.45119V3.32321C8 2.55068 7.37187 1.922 6.6 1.922H2.4C1.62813 1.922 1 2.55068 1 3.32321V13.5988C1 14.3713 1.62813 15 2.4 15H12.6667C13.4385 15 14.0667 14.3713 14.0667 13.5988V9.39514C14.0667 8.62261 13.4385 7.99393 12.6667 7.99393H12.5379L14.5949 5.93508C14.8553 5.67445 15 5.32602 15 4.95703ZM2.4 2.85521H6.6C6.85667 2.85521 7.06667 3.06446 7.06667 3.32228V7.99299H1.93333V3.32228C1.93333 3.06446 2.14333 2.85521 2.4 2.85521ZM1.93333 13.5979V8.92714H7.06667V14.0649H2.4C2.14333 14.0649 1.93333 13.8547 1.93333 13.5979ZM13.1333 9.39421V13.5979C13.1333 13.8547 12.9233 14.0649 12.6667 14.0649H8V8.92714H12.6667C12.9233 8.92714 13.1333 9.13638 13.1333 9.39421ZM8 7.99299V6.46287L9.5288 7.99299H8ZM13.9351 5.2737L11.3488 7.86221C11.1789 8.03223 10.8859 8.03223 10.716 7.86221L8.12973 5.2737C8.0448 5.18963 7.99813 5.07753 7.99813 4.95796C7.99813 4.83839 8.0448 4.7263 8.12973 4.64129L10.716 2.05278C10.8009 1.96777 10.9129 1.92106 11.0324 1.92106C11.1519 1.92106 11.2639 1.96777 11.3488 2.05278L13.9351 4.64129C14.02 4.72536 14.0667 4.83746 14.0667 4.95703C14.0667 5.0766 14.02 5.1887 13.9351 5.2737Z'/%3E%3C/svg%3E");
  /* Arrow rising from a baseline ("arrow-up-from-line"), used as a mask
   * (see below). */
  --pi-update: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M12 17V3'/%3E%3Cpath d='m6 9 6-6 6 6'/%3E%3Cpath d='M5 21h14'/%3E%3C/svg%3E");
}
.pi-icon::before,
.pi-icon::after {
  position: absolute;
  content: "";
}
/* Install: the puzzle glyph (codicon "extensions", U+EAE6) from the bar
 * widget's icon: the glyph path (copied verbatim from the plugin logo,
 * store/images/logo.svg) cuts the puzzle out of a --stable block, so the
 * icon is a solid var(--stable) puzzle instead of a font glyph (the site's
 * fonts carry no Nerd Font private-use characters). */
.pi-icon-install {
  background: var(--stable, #b4c96f);
  -webkit-mask: var(--pi-puzzle) center / contain no-repeat;
  mask: var(--pi-puzzle) center / contain no-repeat;
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
/* Update: arrow rising from a baseline (arrow-up-from-line), cut out of a
 * currentColor block by a CSS mask so it keeps the button's --accent tone. */
.pi-icon-update {
  background: currentColor;
  -webkit-mask: var(--pi-update) center / contain no-repeat;
  mask: var(--pi-update) center / contain no-repeat;
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
  /* Installed with no update: the same banner in the site's calm-green
   * "stable" tone (the install button's tone). */
  background: var(--stable, #b4c96f);
}
`;
  injectStyles("pi-styles", ICON_CSS);

  // Mirrors the marketplace's marketplaceInstallAvailable() in plugin.js —
  // the same rule on both the plugin pages and the catalog cards.
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

  // Content scripts cannot open native messaging ports: relay through the
  // background worker, which queues them onto the single host port.
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

  window.PlugBrug = { api, talkToHost, installable, loadCatalog, injectStyles, HOST_ACTION_TIMEOUT_MS };
})();
