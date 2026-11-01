# Architecture

```
browser (extension)  ->  native messaging host  ->  shell IPC  ->  wizard overlay
                          validates vs catalog.json     omarchy plugin add/enable/
                          never installs                disable/remove/update;
                          watch beacon  ---------------->  bar widget (watcher)
                                                        confirm first, notify when done
```

- **`browser/extension/`** — MV3 WebExtension for Chrome, Chromium, Brave
  (Firefox-compatible MV3; the source manifest carries no Chrome-only
  `"key"` — Firefox flags it and the CWS dashboard rejects it). Buttons are
  injected on `plugin.html?id=...` (button groups) and the catalog
  `index.html` (icon-only button) only when the marketplace's own rule
  passes (`installAvailable && upstreamCheckStatus !== "failed" &&
  installCommand`) **and** a ping to the local host succeeds; the button set
  then follows the host's live `status` report (`omarchy plugin list
  --json`). Manual-setup pages and machines without this plugin show no
  buttons — the site renders untouched.
  While the plugin page is the visible tab, a `watch` beacon is renewed
  every 5s (`watch` with `"paused":true` on window blur, `unwatch` on
  leave).
- **`bin/omarchy-plugin-install-host`** — native messaging host: `ping`,
  `status`, `status_all` (batch for the catalog page), `install`,
  `uninstall`, `enable`, `disable`. Each action is re-validated against a
  **fresh** `catalog.json` fetch (id, repo match) and live local state
  (`not-installed`, `already-enabled`, `already-disabled`,
  `already-installed`). It summons the wizard and never installs anything.
  `watch` is format-checked only and records the page in
  `browser-watch.json` (state dir); a `"paused":true` watch stamps an
  existing same-id record paused, `unwatch` and host exit remove it.
- **`bin/plugin-installer-setup`** — registers the native host manifest for
  Chrome, Chromium, Brave, and Firefox; `--uninstall` unregisters. The
  shell plugin runs it automatically on every shell start (idempotent) and
  unregisters at uninstall.
- **`Wizard.qml` + `manifest.json`** — the shell overlay plugin
  (`bramvanoploo.omarchy-browser-plugin-manager`). Re-fetches catalog + repo
  manifest (the payload is never trusted for display), re-checks local
  state for destructive/toggle/update flows, and drives install / enable /
  disable / remove / update via the official `omarchy plugin` CLI; its own
  uninstall runs detached (unregistering the host first).
- **`BarWatch.qml`** — the bar widget: reads the beacon record, lights up
  while it is live (fresh ≤12s and not paused: a blurred browser dims the
  icon within its 2s poll, a killed browser clears itself via staleness),
  and offers the plugin’s manage dropdown. Install/Update/Uninstall route
  through the wizard with the beacon’s id/repo/name as hint only.
